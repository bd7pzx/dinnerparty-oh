import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { curves, promptAction, window } from '@kit.ArkUI';
import { hdsMaterial, HdsTabs, HdsTabsController, SystemMaterialParams } from '@kit.UIDesignKit';
import { Theme } from '../common/Theme';
import { Store } from '../common/Store';
import { PoiCache } from '../common/PoiCache';
import { AuthService, MiscService } from '../service/Services';
import { MapTab } from '../view/MapTab';
import { FavoritesTab } from '../view/FavoritesTab';
import { CommunityTab } from '../view/CommunityTab';
import { ProfileTab } from '../view/ProfileTab';
import { NoticeBar, PrimaryButton } from '../view/Widgets';

/** 悬浮导航栏高度（vp），与 barHeight 对应 */
const BAR_HEIGHT: number = 60;
/** 内容底部为悬浮栏预留的空间（含与栏的呼吸间距） */
const CONTENT_BOTTOM: number = 92;

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State booted: boolean = false;
  @State consent: boolean = true;
  @State noticeText: string = '';
  @State showNotice: boolean = true;
  @State dark: boolean = false;
  /** 登录态：用于把第 5 个页签换成头像 + 用户名 */
  @State loggedIn: boolean = false;
  @State userId: string = '';
  @State userName: string = '';
  @State hasAvatar: boolean = false;
  /** 沉浸光感材质等级：设备支持 IMMERSIVE 走 ADAPTIVE，否则降 SMOOTH */
  @State materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;

  /** 避让区（由 EntryAbility 写入） */
  @StorageProp('safeTopVp') safeTop: number = 0;
  @StorageProp('safeBottomVp') safeBottom: number = 0;

  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.resolveMaterialLevel();
    this.boot();
  }

  /** 按设备能力选择材质等级 */
  private resolveMaterialLevel(): void {
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
        this.materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
      } else {
        this.materialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
      }
    } catch (err) {
      this.materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }
  }

  private materialParams(): SystemMaterialParams {
    return {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: this.materialLevel
    };
  }

  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      await Store.init(ctx);
    } catch (err) {
      // 持久化不可用时仍可运行
    }
    // 缓存预初始化：放在这里，地图页创建时就能同步读到点位，不必等异步
    try {
      await PoiCache.init(ctx);
    } catch (err) {
      // 缓存不可用就退回线上
    }
    this.consent = Store.consent;
    this.dark = Store.dark;
    this.booted = true;
    this.applySystemBar();
    this.applyColorMode();
    if (Store.isLoggedIn()) {
      const me = await AuthService.me();
      if (me.ok && me.data !== null) {
        this.loggedIn = true;
        this.userId = me.data.user.id;
        this.userName = me.data.user.username;
        this.hasAvatar = me.data.user.has_avatar === true;
        Store.nickname = me.data.user.username;
      }
    }
    const r = await MiscService.notice();
    if (r.ok && r.data !== null && r.data.notice !== null) {
      this.noticeText = `${r.data.notice.title}：${r.data.notice.content}`;
    }
  }

  /** 头像地址：与原项目一致，有自定义头像走带时间戳的原图，否则走默认图 */
  private avatarUrl(): string {
    const base = Store.baseUrl.replace(/\/+$/, '');
    const tail = this.hasAvatar ? `?t=${Date.now()}` : '?fallback=default';
    return `${base}/users/${this.userId}/avatar${tail}`;
  }

  /**
   * 顶栏按钮：在「深色 / 浅色 / 跟随系统」之间循环。
   * 颜色全部走 app.color 资源（base / dark 两套），用系统级 setColorMode 触发整树重绘。
   */
  private switchTheme(): void {
    const mode = Store.themeMode;
    if (mode === 'system') {
      Store.themeMode = 'dark';
    } else if (mode === 'dark') {
      Store.themeMode = 'light';
    } else {
      Store.themeMode = 'system';
    }
    this.applyColorMode();
    this.applySystemBar();
  }

  /** 按已保存偏好应用颜色模式（system 时交回系统决定） */
  private applyColorMode(): void {
    const mode = Store.themeMode;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const app = ctx.getApplicationContext();
      if (mode === 'system') {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
        // 跟随系统时，用当前生效的资源配置判断深浅，供系统栏图标与地图样式使用
        const isDark = ctx.resourceManager.getConfigurationSync().colorMode ===
          resourceManager.ColorMode.DARK;
        this.dark = isDark;
        Store.dark = isDark;
      } else {
        const isDark = mode === 'dark';
        this.dark = isDark;
        Store.dark = isDark;
        app.setColorMode(isDark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      }
    } catch (err) {
      // 不支持时保持默认
    }
  }

  /** 系统栏保持透明（沉浸），只切换图标明暗 */
  private async applySystemBar(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      const fg = this.dark ? '#F6E8ED' : '#4A2438';
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: fg,
        navigationBarContentColor: fg
      });
    } catch (err) {
      // 系统栏属性不可用时忽略
    }
  }

  build() {
    Column() {
      if (!this.booted) {
        this.splash()
      } else if (!this.consent) {
        this.consentGate()
      } else {
        this.shell()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  splash() {
    Column() {
      Text('东方饭联地图')
        .fontSize(Theme.F_XL)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink'))
      Text('觅食 · 行程 · 口味')
        .fontSize(Theme.F_SM)
        .fontColor($r('app.color.ink_faint'))
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 隐私同意门 */
  @Builder
  consentGate() {
    Column() {
      Text('欢迎来到东方饭联')
        .fontSize(Theme.F_XL)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink'))
      Text('我们会在你同意后记录以下内容：\n· 你浏览与收藏的地点，用于计算口味画像\n· 到店打卡时的定位数据（仅用于 50 米 / 10 分钟规则判定）\n· 搜索与筛选行为，用于改进推荐\n\n这些数据不会用于广告，你可以随时关闭社区同步。')
        .fontSize(Theme.F_BASE)
        .fontColor($r('app.color.ink_soft'))
        .lineHeight(23)
        .margin({ top: Theme.S_LG })
      Column() {
        PrimaryButton({
          label: '同意并继续',
          onTap: () => {
            Store.consent = true;
            this.consent = true;
          }
        })
      }
      .width('100%')
      .margin({ top: Theme.S_XL })

      Text('游客模式：不登录也能浏览地点、饭局与公告，打卡与社区互动需登录')
        .fontSize(Theme.F_CAP)
        .fontColor($r('app.color.ink_faint'))
        .margin({ top: Theme.S_MD })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding({ left: Theme.S_XL, right: Theme.S_XL })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  shell() {
    // 地图铺满整屏，顶栏与悬浮导航都浮在上面，所以用 Stack 而不是 Column
    Stack({ alignContent: Alignment.TopStart }) {
      HdsTabs({ controller: this.tabsController, index: this.currentTab }) {
        TabContent() {
          this.tabPage(0)
        }
        .tabBar(this.tabBarItem(0, '地', '地图'))

        // 未登录时只把 tabBar 换成空占位，TabContent 数量保持 4 个不变——
        // 动态增删 TabContent 会让 HdsTabs 的索引错乱，出现两页内容并排显示。
        TabContent() {
          this.tabPage(1)
        }
        .tabBar(this.loggedIn ? this.tabBarItem(1, '收', '收藏') : this.hiddenBar())

        TabContent() {
          this.tabPage(2)
        }
        .tabBar(this.loggedIn ? this.tabBarItem(2, '邻', '同好') : this.hiddenBar())

        TabContent() {
          this.tabPage(3)
        }
        .tabBar(this.profileTabBar(3))
      }
      .barPosition(BarPosition.End)
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .animationDuration(240)
      .barHeight(BAR_HEIGHT)
      .barOverlap(true)
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: this.safeBottom + 12,
        thermoCtrl: true,
        barOpacity: 1,
        systemMaterialEffect: this.materialParams()
      })
      .onChange((index: number) => {
        this.currentTab = index;
      })
      .width('100%')
      .height('100%')

      // 顶栏浮层：底部渐隐，让文字压在地图上也能读清
      Column() {
        Row() {
          Column() {
            Text('东方饭联地图')
              .fontSize(Theme.F_LG)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'))
            Text(Store.isLoggedIn()
              ? `已登录 · ${Store.nickname.length > 0 ? Store.nickname : Store.username}`
              : '游客模式 · 未登录')
              .fontSize(Theme.F_CAP)
              .fontColor($r('app.color.ink_faint'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 定位按钮（原深色切换的位置）：通知地图回到我的位置
          Text('◎')
            .fontSize(16)
            .fontColor($r('app.color.primary'))
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.tint'))
            .borderRadius(17)
            .onClick(() => {
              const next = (AppStorage.get<number>('recenterTick') ?? 0) + 1;
              AppStorage.setOrCreate<number>('recenterTick', next);
            })

        }
        .width('100%')
        .padding({
          left: Theme.S_LG,
          right: Theme.S_LG,
          top: this.safeTop + Theme.S_SM,
          bottom: Theme.S_SM
        })

        if (this.showNotice && this.noticeText.length > 0) {
          Column() {
            NoticeBar({
              text: this.noticeText,
              onClose: () => {
                this.showNotice = false;
              }
            })
          }
          .padding({ left: Theme.S_LG, right: Theme.S_LG, bottom: Theme.S_SM })
        }
      }
      .width('100%')
      .linearGradient({
        angle: 180,
        colors: [
          [$r('app.color.bg'), 0],
          [$r('app.color.bg'), 0.68],
          [$r('app.color.bg_clear'), 1]
        ]
      })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }

  /** 页内容：地图页铺满整屏，其余页让开顶部浮层并给悬浮栏留空间 */
  @Builder
  tabPage(idx: number) {
    Column() {
      if (idx === 0) {
        MapTab()
      } else if (idx === 1) {
        FavoritesTab()
      } else if (idx === 2) {
        CommunityTab()
      } else {
        ProfileTab()
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      // 顶栏现在是浮层，非地图页要让开它
      top: idx === 0 ? 0 : this.safeTop + 52,
      bottom: idx === 0 ? 0 : CONTENT_BOTTOM + this.safeBottom
    })
  }

  /** 普通页签：选中放大上移 + 弹簧曲线（官方示例做法） */
  @Builder
  tabBarItem(idx: number, icon: string, label: string) {
    Column() {
      Text(icon)
        .fontSize(16)
        .fontWeight(this.currentTab === idx ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentTab === idx ? $r('app.color.primary') : $r('app.color.ink_faint'))
      Text(label)
        .fontSize(Theme.F_CAP)
        .fontColor(this.currentTab === idx ? $r('app.color.primary') : $r('app.color.ink_faint'))
        .margin({ top: 3 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.currentTab === idx ? 1.06 : 0.96, y: this.currentTab === idx ? 1.06 : 0.96 })
    .translate({ y: this.currentTab === idx ? -2 : 0 })
    .opacity(this.currentTab === idx ? 1 : 0.82)
    .animation({ duration: 320, curve: curves.springMotion() })
  }

  /** 占位页签：未登录时隐藏「收藏 / 同好」 */
  @Builder
  hiddenBar() {
    Column()
      .width('100%')
      .height('100%')
  }

  /** 第 4 个页签：未登录显示「我 / 我的」，登录后显示服务端头像 + 用户名 */
  @Builder
  profileTabBar(pidx: number) {
    Column() {
      if (this.loggedIn && this.userId.length > 0) {
        Image(this.avatarUrl())
          .width(26)
          .height(26)
          .borderRadius(13)
          .objectFit(ImageFit.Cover)
          .border({ width: 1, color: $r('app.color.glass_border') })
          .draggable(false)
      } else {
        Text('我')
          .fontSize(16)
          .fontWeight(this.currentTab === pidx ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.currentTab === pidx ? $r('app.color.primary') : $r('app.color.ink_faint'))
      }
      Text(this.loggedIn && this.userName.length > 0 ? this.userName : '我的')
        .fontSize(Theme.F_CAP)
        .fontColor(this.currentTab === pidx ? $r('app.color.primary') : $r('app.color.ink_faint'))
        .margin({ top: 3 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 62 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.currentTab === pidx ? 1.06 : 0.96, y: this.currentTab === pidx ? 1.06 : 0.96 })
    .translate({ y: this.currentTab === pidx ? -2 : 0 })
    .opacity(this.currentTab === pidx ? 1 : 0.82)
    .animation({ duration: 320, curve: curves.springMotion() })
  }
}

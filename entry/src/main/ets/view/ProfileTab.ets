/** 我的页：登录、口味自评、外观与数据源设置、关于 */
import { Theme } from '../common/Theme';
import { Store, APP_VERSION, DEFAULT_BASE } from '../common/Store';
import { PoiCache, CACHE_LIMIT_MIN, CACHE_LIMIT_MAX } from '../common/PoiCache';
import { TASTE_AXES, TasteAxis, User, LoginResult } from '../model/Types';
import { AuthService, UserContainer } from '../service/Services';
import { PrimaryButton, SectionCard, MetricCell, LoadingRow, EmptyState } from './Widgets';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

@Component
export struct ProfileTab {
  @State username: string = '';
  @State password: string = '';
  @State loggedIn: boolean = false;
  @State displayName: string = '';
  @State userId: string = '';
  @State busy: boolean = false;
  @State message: string = '';
  @State taste: TasteAxis[] = [];
  @State baseUrl: string = DEFAULT_BASE;
  @State dark: boolean = false;
  /** 是否跟随系统深浅色 */
  @State followSystem: boolean = true;
  /** 地点缓存设置 */
  @State cacheEnabled: boolean = true;
  @State cacheLimitText: string = '2000';
  @State cacheCount: number = 0;
  @State cacheMsg: string = '';

  aboutToAppear(): void {
    this.baseUrl = Store.baseUrl;
    this.dark = Store.dark;
    this.followSystem = Store.themeMode === 'system';
    this.taste = [];
    this.refreshSession();
    this.loadCacheState();
  }

  /** 应用主题模式：system 交给系统，light/dark 显式指定 */
  private applyTheme(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const app = ctx.getApplicationContext();
      if (Store.themeMode === 'system') {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      } else {
        app.setColorMode(Store.themeMode === 'dark'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      }
    } catch (err) {
      // 设备不支持时保持默认
    }
  }

  /** 读取缓存配置与当前条数 */
  private async loadCacheState(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await PoiCache.init(ctx);
    this.cacheEnabled = PoiCache.isEnabled();
    this.cacheLimitText = `${PoiCache.getLimit()}`;
    this.cacheCount = PoiCache.count();
  }

  private async applyCacheLimit(): Promise<void> {
    const n = parseInt(this.cacheLimitText, 10);
    if (isNaN(n)) {
      this.cacheLimitText = `${PoiCache.getLimit()}`;
      this.cacheMsg = '请输入 20–10000 之间的数字';
      return;
    }
    const clamped = n < CACHE_LIMIT_MIN ? CACHE_LIMIT_MIN : (n > CACHE_LIMIT_MAX ? CACHE_LIMIT_MAX : n);
    await PoiCache.setLimit(clamped);
    this.cacheLimitText = `${clamped}`;
    this.cacheCount = PoiCache.count();
    this.cacheMsg = `上限已设为 ${clamped} 个`;
  }

  private async clearCache(): Promise<void> {
    await PoiCache.clear();
    this.cacheCount = 0;
    this.cacheMsg = '缓存已清除';
  }

  private async refreshSession(): Promise<void> {
    this.loggedIn = Store.isLoggedIn();
    this.displayName = Store.nickname.length > 0 ? Store.nickname : Store.username;
    if (!this.loggedIn) return;
    this.busy = true;
    const r = await AuthService.me();
    this.busy = false;
    if (r.ok && r.data !== null) {
      const c: UserContainer = r.data;
      this.loggedIn = true;
      this.displayName = c.user.username;
      this.userId = c.user.id;
      Store.nickname = c.user.username;
      this.loadTaste(c.user.id);
    } else if (r.status === 401) {
      Store.logout();
      this.loggedIn = false;
    }
  }

  /** 口味画像来自 /users/{id}/profile 顶层的 taste */
  private async loadTaste(userId: string): Promise<void> {
    const p = await AuthService.profile(userId);
    if (p.ok && p.data !== null && p.data.taste !== undefined) {
      this.taste = p.data.taste;
    }
  }

  private async doLogin(): Promise<void> {
    if (this.username.trim().length === 0 || this.password.length === 0) {
      this.message = '请填写账号与密码';
      return;
    }
    this.busy = true;
    this.message = '';
    const r = await AuthService.login(this.username.trim(), this.password);
    this.busy = false;
    if (r.ok && r.data !== null) {
      const res: LoginResult = r.data;
      Store.token = res.token;
      Store.username = res.user.username;
      Store.nickname = res.user.username;
      this.loggedIn = true;
      this.displayName = res.user.username;
      this.password = '';
      this.message = '登录成功';
      this.loadTaste(res.user.id);
    } else {
      this.message = r.error;
    }
  }

  private async doLogout(): Promise<void> {
    await AuthService.logout();
    Store.logout();
    this.loggedIn = false;
    this.message = '已退出登录';
  }

  private async setTaste(axis: string, level: number): Promise<void> {
    const next: TasteAxis[] = [];
    for (const t of this.taste) {
      if (t.key === axis) {
        const copy: TasteAxis = {
          key: t.key,
          value: t.value,
          basis: 'self',
          self_level: level,
          self_level_label: this.labelOf(level)
        };
        next.push(copy);
      } else {
        next.push(t);
      }
    }
    this.taste = next;
    if (this.loggedIn) {
      await AuthService.putTaste(axis, level);
    }
  }

  private labelOf(level: number): string {
    if (level >= 4) return '很爱';
    if (level === 3) return '喜欢';
    if (level === 2) return '一般';
    if (level === 1) return '无感';
    return '未评';
  }

  build() {
    Scroll() {
      Column({ space: Theme.S_MD }) {
        // 账号
        SectionCard({ title: this.loggedIn ? '账号' : '登录' }) {
          Column({ space: 8 }) {
            if (this.loggedIn) {
              Row() {
                Text(this.displayName)
                  .fontSize(Theme.F_MD)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.ink'))
                  .layoutWeight(1)
                Text('退出')
                  .fontSize(Theme.F_SM)
                  .fontColor($r('app.color.danger'))
                  .onClick(() => this.doLogout())
              }
              .width('100%')
              if (this.userId.length > 0) {
                Text(`ID ${this.userId.slice(0, 8)}…`)
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .width('100%')
              }
              Text('登录后可同步收藏、行程与到店记录。')
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .width('100%')
            } else {
              TextInput({ text: this.username, placeholder: '用户名' })
                .height(40)
                .fontSize(Theme.F_BASE)
                .onChange((v: string) => {
                  this.username = v;
                })
              TextInput({ text: this.password, placeholder: '密码' })
                .height(40)
                .fontSize(Theme.F_BASE)
                .type(InputType.Password)
                .onChange((v: string) => {
                  this.password = v;
                })
              Column() {
                PrimaryButton({
                  label: this.busy ? '登录中…' : '登录',
                  active: !this.busy,
                  onTap: () => this.doLogin()
                })
              }
              .width('100%')
              Text('注册与找回密码需要 QQ 号接收验证码。')
                .fontSize(Theme.F_CAP)
                .fontColor($r('app.color.ink_faint'))
                .width('100%')
            }
            if (this.message.length > 0) {
              Text(this.message)
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .width('100%')
            }
          }
        }

        // 口味
        SectionCard({ title: '我的口味', subtitle: '点数字调整' }) {
          Column() {
            if (this.taste.length === 0) {
              EmptyState({
                title: this.loggedIn ? '还没有口味画像' : '登录后生成口味画像',
                hint: this.loggedIn ? '多收藏几家店，画像会自动算出来' : '游客态不展示个人口味'
              })
            } else {
              ForEach(this.taste, (t: TasteAxis) => {
                Row() {
                  Column() {
                    Text(this.axisName(t.key))
                      .fontSize(Theme.F_BASE)
                      .fontColor($r('app.color.ink'))
                    Text(`强度 ${(t.value * 100).toFixed(0)}%`)
                      .fontSize(Theme.F_CAP)
                      .fontColor($r('app.color.ink_faint'))
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Row({ space: 4 }) {
                    ForEach([1, 2, 3, 4], (lv: number) => {
                      Text(`${lv}`)
                        .fontSize(Theme.F_SM)
                        .fontColor(t.self_level === lv ? $r('app.color.on_primary') : $r('app.color.ink_faint'))
                        .width(26)
                        .height(26)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(t.self_level === lv ? $r('app.color.primary') : $r('app.color.tint'))
                        .borderRadius(13)
                        .onClick(() => this.setTaste(t.key, lv))
                    }, (lv: number) => `${t.key}-${lv}`)
                  }
                }
                .width('100%')
                .padding({ top: 7, bottom: 7 })
                .border({ width: { bottom: 1 }, color: $r('app.color.line') })
              }, (t: TasteAxis) => t.key)
            }
          }
        }

        // 设置
        SectionCard({ title: '设置' }) {
          Column({ space: 10 }) {
            Row() {
              Column() {
                Text('深色外观')
                  .fontSize(Theme.F_BASE)
                  .fontColor($r('app.color.ink'))
                Text(this.followSystem ? '当前跟随系统' : '手动指定')
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.dark })
                .enabled(!this.followSystem)
                .selectedColor($r('app.color.primary'))
                .onChange((on: boolean) => {
                  this.dark = on;
                  // 手动切换即退出「跟随系统」
                  this.followSystem = false;
                  Store.themeMode = on ? 'dark' : 'light';
                  Store.dark = on;
                  this.applyTheme();
                })
            }
            .width('100%')

            Row() {
              Column() {
                Text('跟随系统')
                  .fontSize(Theme.F_BASE)
                  .fontColor($r('app.color.ink'))
                Text('由系统深浅色自动决定')
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.followSystem })
                .selectedColor($r('app.color.primary'))
                .onChange((on: boolean) => {
                  this.followSystem = on;
                  if (on) {
                    Store.themeMode = 'system';
                  } else {
                    Store.themeMode = this.dark ? 'dark' : 'light';
                  }
                  this.applyTheme();
                })
            }
            .width('100%')

            Row() {
              Column() {
                Text('后端地址')
                  .fontSize(Theme.F_BASE)
                  .fontColor($r('app.color.ink'))
                Text(this.baseUrl)
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .margin({ top: 2 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            TextInput({ text: this.baseUrl, placeholder: '后端地址' })
              .height(38)
              .fontSize(Theme.F_SM)
              .textAlign(TextAlign.Center)
              .onChange((v: string) => {
                this.baseUrl = v;
              })
              .onSubmit(() => {
                Store.baseUrl = this.baseUrl;
              })
          }
        }

        // 地点缓存
        SectionCard({
          title: '地点缓存',
          subtitle: this.cacheEnabled ? '已开启' : '已关闭'
        }) {
          Column({ space: 10 }) {
            Row() {
              Column() {
                Text('启用缓存')
                  .fontSize(Theme.F_BASE)
                  .fontColor($r('app.color.ink'))
                Text('只缓存坐标与名称，其它信息仍从线上拉取')
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.cacheEnabled })
                .selectedColor($r('app.color.primary'))
                .onChange((on: boolean) => {
                  this.cacheEnabled = on;
                  PoiCache.setEnabled(on);
                  this.cacheMsg = on ? '缓存已开启' : '缓存已关闭';
                })
            }
            .width('100%')

            Row({ space: 8 }) {
              Text('缓存上限')
                .fontSize(Theme.F_BASE)
                .fontColor($r('app.color.ink'))
              TextInput({ text: this.cacheLimitText, placeholder: `${CACHE_LIMIT_MIN}` })
                .type(InputType.Number)
                .height(34)
                .width(78)
                .textAlign(TextAlign.Center)
                .fontSize(Theme.F_SM)
                .onChange((v: string) => {
                  this.cacheLimitText = v;
                })
                .onSubmit(() => {
                  this.applyCacheLimit();
                })
              Text('个')
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_faint'))
                .layoutWeight(1)
              Column() {
                PrimaryButton({
                  label: '应用',
                  onTap: () => {
                    this.applyCacheLimit();
                  }
                })
              }
              .width(62)
            }
            .width('100%')

            Row() {
              Text(`当前已缓存 ${this.cacheCount} 个地点`)
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .layoutWeight(1)
              Column() {
                PrimaryButton({
                  label: '清除',
                  kind: 'ghost',
                  onTap: () => {
                    this.clearCache();
                  }
                })
              }
              .width(76)
            }
            .width('100%')

            if (this.cacheMsg.length > 0) {
              Text(this.cacheMsg)
                .fontSize(Theme.F_CAP)
                .fontColor($r('app.color.primary'))
                .width('100%')
            }
          }
        }
      }
      .padding(Theme.S_LG)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  private axisName(key: string): string {
    for (const a of TASTE_AXES) {
      if (a === key) {
        if (key === 'homestyle') return '家常';
        if (key === 'noodles') return '面食';
        if (key === 'hotpotBbq') return '火锅烧烤';
        if (key === 'dessert') return '甜品';
        if (key === 'drinks') return '饮品';
        if (key === 'foreign') return '异国';
      }
    }
    return key;
  }
}

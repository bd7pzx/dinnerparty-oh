/** 我的页：登录、口味自评、外观与数据源设置、关于 */
import { Theme } from '../common/Theme';
import { Store, APP_VERSION, DEFAULT_BASE } from '../common/Store';
import { TASTE_AXES, TasteAxis, User, LoginResult } from '../model/Types';
import { AuthService, UserContainer } from '../service/Services';
import { PrimaryButton, SectionCard, MetricCell, LoadingRow, EmptyState } from './Widgets';

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

  aboutToAppear(): void {
    this.baseUrl = Store.baseUrl;
    this.dark = Store.dark;
    this.taste = [];
    this.refreshSession();
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
                Text('跟随手动开关')
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.dark })
                .selectedColor($r('app.color.primary'))
                .onChange((on: boolean) => {
                  this.dark = on;
                  Store.dark = on;
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
              .onChange((v: string) => {
                this.baseUrl = v;
              })
              .onSubmit(() => {
                Store.baseUrl = this.baseUrl;
              })
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

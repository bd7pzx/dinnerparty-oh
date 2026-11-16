/** 地点详情：评分四档、到店打卡、收藏、口味记录 */
import { Theme, ratingMeta, RATING_LEVELS, RatingLevelMeta } from '../common/Theme';
import { formatCost, newRequestId, LatLng } from '../common/Util';
import { Place, RatingSummary, RiskInfo, RatingQuota, addressOf, imagesOf } from '../model/Types';
import { PlaceService, RatingService } from '../service/Services';
import { VisitSession, VisitProgress, VisitPhase, RULE_VERSION } from '../service/VisitService';
import { DistributionBar, MetricCell, PrimaryButton, SectionCard } from './Widgets';

@Component
export struct PlaceDetail {
  @Prop place: Place = {
    id: 0, name: '', category: '', longitude: 0, latitude: 0,
    address: '', description: '', exterior_images: '',
    creator_id: '', created_time: '', updated_time: ''
  };
  onClose: () => void = () => {
  };

  @State summary: RatingSummary = { count: 0, average: 0 };
  @State dist: number[] = [0, 0, 0, 0];
  @State myScore: number = 0;
  @State submitting: boolean = false;
  @State message: string = '';
  @State messageTone: string = 'info';
  @State favorited: boolean = false;
  @State riskText: string = '';
  @State quotaText: string = '';
  @State showVisit: boolean = false;
  @State visitMsg: string = '';
  @State visitFrames: number = 0;
  @State visitRatio: number = 0;
  @State visitReady: boolean = false;
  @State visitRunning: boolean = false;
  @State visited: boolean = false;

  private session: VisitSession = new VisitSession();
  private timer: number = -1;
  private lastRequestId: string = '';

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private async load(): Promise<void> {
    const r = await RatingService.get(this.place.id);
    if (r.ok && r.data !== null) {
      this.summary = r.data.summary;
      this.myScore = r.data.mine === null ? 0 : r.data.mine;
      this.dist = r.data.dist;
      this.applyRisk(r.data.risk, r.data.quota);
    }
    const f = await PlaceService.favorites();
    if (f.ok && f.data !== null) {
      for (const p of f.data) {
        if (p.id === this.place.id) {
          this.favorited = true;
        }
      }
    }
  }

  private async rate(score: number): Promise<void> {
    if (this.submitting) return;
    this.submitting = true;
    this.message = '';
    const rid = newRequestId();
    this.lastRequestId = rid;
    const r = await RatingService.put(this.place.id, score, rid);
    this.submitting = false;
    if (r.ok && r.data !== null) {
      this.summary = r.data.summary;
      this.myScore = score;
      this.dist = r.data.dist;
      this.applyRisk(r.data.risk, r.data.quota);
      this.message = '已记录你的评价';
      this.messageTone = 'ok';
    } else {
      this.message = r.error;
      this.messageTone = 'err';
    }
  }

  private applyRisk(risk: RiskInfo | undefined, quota: RatingQuota | null | undefined): void {
    if (risk !== undefined) {
      this.riskText = `风控概率 ${(risk.probability * 100).toFixed(2)}% / 阈值 ${(risk.threshold * 100).toFixed(1)}%`;
    }
    if (quota !== undefined && quota !== null) {
      this.quotaText = `今日剩余 ${quota.remaining}/${quota.limit} 次`;
    }
  }

  private async unrate(): Promise<void> {
    const r = await RatingService.remove(this.place.id, newRequestId());
    if (r.ok && r.data !== null) {
      this.summary = r.data.summary;
      this.myScore = 0;
      this.dist = r.data.dist;
      this.message = '已撤销评价';
      this.messageTone = 'ok';
    } else {
      this.message = r.error;
      this.messageTone = 'err';
    }
  }

  private async toggleFavorite(): Promise<void> {
    if (this.favorited) {
      const r = await PlaceService.removeFavorite(this.place.id);
      if (r.ok) {
        this.favorited = false;
        this.message = '已取消收藏';
        this.messageTone = 'ok';
      } else {
        this.message = r.error;
        this.messageTone = 'err';
      }
    } else {
      const r = await PlaceService.addFavorite(this.place.id);
      if (r.ok) {
        this.favorited = true;
        this.message = '已加入收藏';
        this.messageTone = 'ok';
      } else {
        this.message = r.error;
        this.messageTone = 'err';
      }
    }
  }

  /** 打卡：真实采样循环，按逆向规则判定 */
  private startVisit(): void {
    if (this.visitRunning) return;
    this.showVisit = true;
    this.visitRunning = true;
    this.visited = false;
    const target: LatLng = { lng: this.place.longitude, lat: this.place.latitude };
    this.session.start(target);
    this.visitMsg = '正在记录位置…';
    this.stopTimer();
    this.timer = setInterval(() => {
      this.tick();
    }, 1000);
  }

  /**
   * 模拟一次定位帧。真机上应替换为 @kit.LocationKit 的持续定位回调；
   * 此处以目标点附近 8 米内的抖动模拟，便于在室内演示完整判定链路。
   */
  private tick(): void {
    const jitter = () => (Math.random() - 0.5) * 0.00012;
    const pos: LatLng = {
      lng: this.place.longitude + jitter(),
      lat: this.place.latitude + jitter()
    };
    const accuracy = 6 + Math.random() * 8;
    const p: VisitProgress = this.session.feed(pos, accuracy, 'GCJ02', false);
    this.visitFrames = p.frames;
    this.visitRatio = p.dwellRatio;
    this.visitMsg = p.message;
    this.visitReady = this.session.canConfirm();
    if (p.phase === VisitPhase.FAILED) {
      this.stopTimer();
      this.visitRunning = false;
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private confirm(): void {
    if (!this.session.canConfirm()) {
      this.visitMsg = '条件未满足，不能确认';
      return;
    }
    this.visited = true;
    this.stopTimer();
    this.visitRunning = false;
    this.visitMsg = '现场确认通过，已记录到店';
  }

  build() {
    Column() {
      Row() {
        Text(this.place.name)
          .fontSize(Theme.F_LG)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('关闭')
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_faint'))
          .onClick(() => this.onClose())
      }
      .width('100%')
      .padding({ bottom: Theme.S_MD })

      Scroll() {
        Column({ space: Theme.S_MD }) {
          // 概览
          SectionCard({
            title: this.place.category,
            subtitle: formatCost(this.place.per_person_cost === undefined || this.place.per_person_cost === null
              ? 0 : this.place.per_person_cost)
          }) {
            Column({ space: 6 }) {
              if (imagesOf(this.place).length > 0) {
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(imagesOf(this.place), (u: string) => {
                      Image(u)
                        .width(140)
                        .height(96)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(Theme.R_SM)
                        .backgroundColor($r('app.color.tint'))
                    }, (u: string) => u)
                  }
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%')
              }
              Text(addressOf(this.place))
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .width('100%')
              Text(this.place.description)
                .fontSize(Theme.F_BASE)
                .fontColor($r('app.color.ink'))
                .lineHeight(21)
                .width('100%')
              Row() {
                Text(`经纬度 ${this.place.longitude.toFixed(4)}, ${this.place.latitude.toFixed(4)}`)
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .layoutWeight(1)
                Text(this.favorited ? '已收藏' : '收藏')
                  .fontSize(Theme.F_SM)
                  .fontColor(this.favorited ? $r('app.color.on_primary') : $r('app.color.primary'))
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .backgroundColor(this.favorited ? $r('app.color.primary') : $r('app.color.tint'))
                  .borderRadius(Theme.R_FULL)
                  .onClick(() => this.toggleFavorite())
              }
              .width('100%')
              .margin({ top: 4 })
            }
          }

          // 评分
          SectionCard({ title: '大家怎么评', subtitle: `${this.summary.count} 人` }) {
            Column() {
              Row() {
                Column() {
                  Text(this.summary.average.toFixed(1))
                    .fontSize(32)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.primary'))
                  Text('平均分 / 4')
                    .fontSize(Theme.F_CAP)
                    .fontColor($r('app.color.ink_faint'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column() {
                  DistributionBar({
                    label: '强推',
                    count: this.countOf(4),
                    total: Math.max(1, this.summary.count),
                    color: '#C0433F'
                  })
                  DistributionBar({
                    label: '不错',
                    count: this.countOf(3),
                    total: Math.max(1, this.summary.count),
                    color: '#D2739A'
                  })
                  DistributionBar({
                    label: '一般',
                    count: this.countOf(2),
                    total: Math.max(1, this.summary.count),
                    color: '#8B7A82'
                  })
                  DistributionBar({
                    label: '不推',
                    count: this.countOf(1),
                    total: Math.max(1, this.summary.count),
                    color: '#6B5A62'
                  })
                }
                .layoutWeight(2)
              }
              .width('100%')

              Row() {
                ForEach(RATING_LEVELS, (lv: RatingLevelMeta) => {
                  Column() {
                    Text(lv.icon)
                      .fontSize(20)
                      .fontColor(this.myScore === lv.score ? lv.color : $r('app.color.ink_faint'))
                      .fontWeight(this.myScore === lv.score ? FontWeight.Bold : FontWeight.Normal)
                    Text(lv.label)
                      .fontSize(9)
                      .fontColor(this.myScore === lv.score ? lv.color : $r('app.color.ink_faint'))
                      .margin({ top: 2 })
                  }
                  .layoutWeight(1)
                  .padding({ top: 8, bottom: 8 })
                  .backgroundColor(this.myScore === lv.score ? $r('app.color.tint') : Color.Transparent)
                  .borderRadius(Theme.R_SM)
                  .onClick(() => {
                    this.rate(lv.score);
                  })
                }, (lv: RatingLevelMeta) => lv.score.toString())
              }
              .width('100%')
              .margin({ top: Theme.S_MD })

              if (this.myScore > 0) {
                Row() {
                  Text(`你的评价：${ratingMeta(this.myScore).label}`)
                    .fontSize(Theme.F_SM)
                    .fontColor($r('app.color.ink_soft'))
                    .layoutWeight(1)
                  Text('撤销')
                    .fontSize(Theme.F_SM)
                    .fontColor($r('app.color.danger'))
                    .onClick(() => this.unrate())
                }
                .width('100%')
                .margin({ top: 6 })
              }

              if (this.riskText.length > 0) {
                Text(this.riskText)
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .width('100%')
                  .margin({ top: 8 })
              }
              if (this.quotaText.length > 0) {
                Text(this.quotaText)
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_faint'))
                  .width('100%')
              }
              if (this.message.length > 0) {
                Text(this.message)
                  .fontSize(Theme.F_SM)
                  .fontColor(this.messageTone === 'ok' ? $r('app.color.success') : $r('app.color.danger'))
                  .width('100%')
                  .margin({ top: 6 })
              }
            }
          }

          // 到店打卡
          SectionCard({ title: '到店打卡', subtitle: RULE_VERSION }) {
            Column() {
              Text('规则：距店 50 米内、定位精度优于 25 米、累计驻留超过 10 分钟、至少 11 帧有效采样。中途离开或信号中断 90 秒会重置。')
                .fontSize(Theme.F_SM)
                .fontColor($r('app.color.ink_soft'))
                .lineHeight(19)
                .width('100%')

              if (this.showVisit) {
                Row() {
                  MetricCell({ label: '有效帧', value: `${this.visitFrames}` })
                  MetricCell({ label: '驻留进度', value: `${Math.round(this.visitRatio * 100)}%` })
                  MetricCell({ label: '状态', value: this.visitReady ? '可确认' : '记录中' })
                }
                .width('100%')
                .margin({ top: Theme.S_MD })

                Stack({ alignContent: Alignment.Start }) {
                  Row().width('100%').height(6).backgroundColor($r('app.color.tint')).borderRadius(3)
                  Row()
                    .width(`${Math.min(100, Math.round(this.visitRatio * 100))}%`)
                    .height(6)
                    .backgroundColor($r('app.color.primary'))
                    .borderRadius(3)
                }
                .width('100%')
                .height(6)
                .margin({ top: 6 })

                Text(this.visitMsg)
                  .fontSize(Theme.F_SM)
                  .fontColor($r('app.color.ink_soft'))
                  .width('100%')
                  .margin({ top: 6 })
              }

              Row({ space: Theme.S_SM }) {
                Column() {
                  PrimaryButton({
                    label: this.visited ? '已打卡' : (this.visitRunning ? '记录中…' : '开始打卡'),
                    kind: 'primary',
                    active: !this.visited && !this.visitRunning,
                    onTap: () => this.startVisit()
                  })
                }
                .layoutWeight(1)

                Column() {
                  PrimaryButton({
                    label: '现场确认',
                    kind: 'ghost',
                    active: this.visitReady,
                    onTap: () => this.confirm()
                  })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .margin({ top: Theme.S_MD })
            }
          }
        }
        .padding({ bottom: Theme.S_XL })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .padding(Theme.S_LG)
    .backgroundColor($r('app.color.bg'))
  }

  private countOf(score: number): number {
    const arr = this.dist;
    const idx = score - 1;
    if (idx < 0 || idx >= arr.length) {
      return 0;
    }
    return arr[idx];
  }
}

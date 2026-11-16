/** 地图页：搜索、分类筛选、自绘地图、随机推荐、地点详情 */
import { Theme } from '../common/Theme';
import { formatCost, formatDistance, truncate } from '../common/Util';
import { Place, Category, RandomContainer, addressOf, splitCategory } from '../model/Types';
import { ClusterPoint, Supercluster, scaleLabel, scaleOf } from '../common/Cluster';
import { CommunityService, DrawResult, MiscService, PlaceService } from '../service/Services';
import { MapCanvas } from './MapCanvas';
import { AmapView } from './AmapView';
import { PlaceDetail } from './PlaceDetail';
import { getFix } from '../common/Location';
import { EmptyState, LoadingRow, PillTag, PrimaryButton, SectionCard } from './Widgets';

@Component
export struct MapTab {
  @State places: Place[] = [];
  @State categories: Category[] = [];
  @State activeCategory: string = '';
  @State keyword: string = '';
  @State selectedId: number = 0;
  @State selected: Place | null = null;
  @State loading: boolean = false;
  @State tip: string = '';
  @State showDetail: boolean = false;
  /** 默认高德地图；不可用时自动降级到自绘底图 */
  @State useAmap: boolean = true;
  @State petalMsg: string = '';
  @State drawn: Place | null = null;
  @State excludeIds: number[] = [];
  /** 地图中心（优先取用户定位，失败回落荔湾） */
  @State centerLat: number = 23.1189;
  @State centerLng: number = 113.2442;
  @State centerZoom: number = 15;
  @State locating: boolean = false;
  /** 当前缩放与聚合结果 */
  @State zoom: number = 15;
  @State clusters: ClusterPoint[] = [];
  /** 点击聚合点后展开的成员 */
  @State clusterPanel: ClusterPoint | null = null;
  /** 当前视野 bbox（西南 → 东北），聚合查询用 */
  private lastBounds: number[] = [113.22, 23.10, 113.29, 23.14];
  /** supercluster 实例：radius 68 / extent 512 / minPoints 2 / maxZoom 16（同原项目） */
  private clusterer: Supercluster = new Supercluster(68, 512, 2, 16);
  /** 已载入数据的签名，只有地点集合变化时才重新聚类 */
  private loadedSig: string = '';

  aboutToAppear(): void {
    this.boot();
  }

  /** 先定位再按视野拉数据；无权限时用默认中心，并如实提示 */
  private async boot(): Promise<void> {
    this.locating = true;
    const fix = await getFix();
    this.locating = false;
    if (fix.ok && fix.pos !== null) {
      this.centerLat = fix.pos.lat;
      this.centerLng = fix.pos.lng;
      this.tip = '';
    } else {
      this.tip = fix.message;
    }
    // 首屏：以中心点构造约 2km 视野，loadRegion 内部再按 3×3 预取
    await this.loadRegion(
      this.centerLng - 0.010, this.centerLat - 0.008,
      this.centerLng + 0.010, this.centerLat + 0.008
    );
    const c = await PlaceService.categories();
    if (c.ok && c.data !== null) {
      this.categories = c.data;
    }
  }

  /**
   * 视野驱动加载：请求范围 = 可视区 3×3 倍（预取），
   * 同时把真实视野 view* 报给服务端用于排序。
   */
  private async loadRegion(minLng: number, minLat: number, maxLng: number, maxLat: number): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const cx = (minLng + maxLng) / 2;
    const cy = (minLat + maxLat) / 2;
    const halfLng = (maxLng - minLng) * 1.5;
    const halfLat = (maxLat - minLat) * 1.5;
    const r = await PlaceService.nearby(
      cx - halfLng, cy - halfLat, cx + halfLng, cy + halfLat,
      minLng, minLat, maxLng, maxLat
    );
    this.loading = false;
    if (r.ok && r.data !== null) {
      this.places = r.data;
      this.refreshCluster();
      if (this.tip.length === 0) {
        this.tip = r.data.length === 0 ? '这一带还没有人标注过店铺，拖到别处看看' : '';
      }
    } else {
      this.tip = `加载失败：${r.error}`;
    }
  }

  /** 重算聚合：聚类只在地点集合变化时做，缩放/平移只重新查询 */
  private refreshCluster(): void {
    const list = this.filtered();
    let sig = '';
    for (const p of list) {
      sig += `${p.id}_`;
    }
    if (sig !== this.loadedSig) {
      this.loadedSig = sig;
      this.clusterer.load(list);
    }
    const b = this.lastBounds;
    this.clusters = this.clusterer.query(b[0], b[1], b[2], b[3], this.zoom);
  }

  /** 点击聚合水滴：把地图放大到该聚合拆开后的下一层 */
  private expandCluster(c: ClusterPoint): void {
    const target = Math.min(c.originZoom + 1, 18);
    this.clusterPanel = null;
    this.showDetail = false;
    this.centerLat = c.lat;
    this.centerLng = c.lng;
    this.centerZoom = target;
    this.zoom = target;
    this.refreshCluster();
  }

  private async search(): Promise<void> {
    this.loading = true;
    const r = await PlaceService.byKeyword(this.keyword);
    this.loading = false;
    if (r.ok && r.data !== null) {
      this.places = r.data;
      this.refreshCluster();
      this.tip = r.data.length === 0 ? `没有找到与「${this.keyword}」相关的地点` : '';
    } else {
      this.tip = r.error;
    }
  }

  /** 找出该地点从聚合里脱开、能单独显示的最近 zoom（supercluster 的 maxZoom+1 层必为原始点） */
  private targetZoomFor(placeId: number): number {
    for (let z = 13; z <= 17; z++) {
      const list = this.clusterer.query(-180, -85, 180, 85, z);
      for (const c of list) {
        if (c.count === 1 && c.placeId === placeId) {
          return z;
        }
      }
    }
    return 17;
  }

  private async drawOne(): Promise<void> {
    this.loading = true;
    const d = await CommunityService.draw();
    if (d.ok && d.data !== null) {
      const res: DrawResult = d.data;
      this.drawn = res.place;
      this.selected = res.place;
      this.selectedId = res.place.id;
      // 把地图中心挪到抽到的店，并放大到它能单独显示的层级
      this.centerLat = res.place.latitude;
      this.centerLng = res.place.longitude;
      this.centerZoom = this.targetZoomFor(res.place.id);
      this.zoom = this.centerZoom;
      this.tip = '今天吃这家吧';
      this.loading = false;
      return;
    }
    const r = await PlaceService.random(this.centerLat, this.centerLng, 5, this.excludeIds);
    this.loading = false;
    if (r.ok && r.data !== null) {
      const rc: RandomContainer = r.data;
      this.drawn = rc.place;
      this.selected = rc.place;
      this.selectedId = rc.place.id;
      // 把地图中心挪到抽到的店，并放大到它能单独显示的层级
      this.centerLat = rc.place.latitude;
      this.centerLng = rc.place.longitude;
      this.centerZoom = this.targetZoomFor(rc.place.id);
      this.zoom = this.centerZoom;
      this.excludeIds.push(rc.place.id);
      if (this.excludeIds.length > 6) {
        this.excludeIds = this.excludeIds.slice(-2);
      }
      this.tip = '今天吃这家吧';
    } else {
      this.tip = r.error;
    }
  }

  private filtered(): Place[] {
    if (this.activeCategory.length === 0) return this.places;
    const out: Place[] = [];
    for (const p of this.places) {
      const parts = splitCategory(p.category);
      for (const s of parts) {
        if (s === this.activeCategory) {
          out.push(p);
          break;
        }
      }
    }
    return out;
  }

  @Builder
  clusterSheet(c: ClusterPoint) {
    Column() {
      Row() {
        Text(`${c.count} 家 · ${scaleLabel(c.scale)}`)
          .fontSize(Theme.F_MD)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
        Text('关闭')
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_faint'))
          .onClick(() => {
            this.clusterPanel = null;
          })
      }
      .width('100%')
      .padding({ bottom: Theme.S_MD })

      Scroll() {
        Column() {
          ForEach(c.places, (p: Place) => {
            Column() {
              Row() {
                Text(truncate(p.name, 16))
                  .fontSize(Theme.F_BASE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.ink'))
                  .layoutWeight(1)
                if (p.rating_average !== undefined && p.rating_average > 0) {
                  Text(`${p.rating_average.toFixed(1)} 分`)
                    .fontSize(Theme.F_CAP)
                    .fontColor($r('app.color.primary'))
                }
              }
              .width('100%')
              Text(`${splitCategory(p.category).join(' / ')}` +
                (p.per_person_cost !== undefined && p.per_person_cost !== null
                  ? ` · ${formatCost(p.per_person_cost)}` : ''))
                .fontSize(Theme.F_CAP)
                .fontColor($r('app.color.ink_faint'))
                .width('100%')
                .margin({ top: 2 })
            }
            .width('100%')
            .padding({ top: 9, bottom: 9 })
            .border({ width: { bottom: 1 }, color: $r('app.color.line') })
            .onClick(() => {
              this.selected = p;
              this.selectedId = p.id;
              this.clusterPanel = null;
              this.showDetail = true;
            })
          }, (p: Place) => `${p.id}`)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('58%')
    .padding(Theme.S_LG)
    .backgroundColor($r('app.color.bg'))
    .borderRadius({ topLeft: Theme.R_XL, topRight: Theme.R_XL })
    .shadow(Theme.floatShadow())
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 搜索条
        Row() {
          Text('搜')
            .fontSize(Theme.F_SM)
            .fontColor($r('app.color.ink_faint'))
            .margin({ right: 6 })
          TextInput({ text: this.keyword, placeholder: '搜店名、分类，比如「肠粉」' })
            .layoutWeight(1)
            .height(38)
            .fontSize(Theme.F_BASE)
            .backgroundColor(Color.Transparent)
            .onChange((v: string) => {
              this.keyword = v;
            })
            .onSubmit(() => {
              this.search();
            })
          Text('今天吃什么')
            .fontSize(Theme.F_SM)
            .fontColor($r('app.color.on_primary'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.primary'))
            .borderRadius(Theme.R_FULL)
            .onClick(() => this.drawOne())
        }
        .width('100%')
        .padding({ left: 12, right: 8 })
        .height(46)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(Theme.R_FULL)
        .shadow(Theme.cardShadow())

        // 分类
        Scroll() {
          Row({ space: 8 }) {
            Column() {
              PillTag({
                text: '全部',
                active: this.activeCategory.length === 0
              })
            }
            .onClick(() => {
              this.activeCategory = '';
              this.refreshCluster();
            })

            ForEach(this.categories, (c: Category) => {
              Column() {
                PillTag({ text: c.name, active: this.activeCategory === c.name })
              }
              .onClick(() => {
                this.activeCategory = c.name;
                this.refreshCluster();
              })
            }, (c: Category) => `${c.id}`)
          }
          .padding({ right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: Theme.S_SM })

        // 地图
        Stack({ alignContent: Alignment.TopEnd }) {
          if (this.useAmap) {
            AmapView({
              clusters: this.clusters,
              selectedId: this.selectedId,
              centerLat: this.centerLat,
              centerLng: this.centerLng,
              centerZoom: this.centerZoom,
              onPick: (p: Place) => {
                this.selected = p;
                this.selectedId = p.id;
                this.drawn = null;
              },
              onCluster: (c: ClusterPoint) => {
                // 点聚合水滴：放大到能拆开它的下一层，而不是弹窗
                this.expandCluster(c);
              },
              onMapClick: () => {
                // 点地图空白处收起底部信息卡（详情浮层有自己的关闭按钮）
                if (!this.showDetail) {
                  this.selected = null;
                  this.selectedId = 0;
                  this.clusterPanel = null;
                }
              },
              onStatus: (ok: boolean, msg: string) => {
                this.petalMsg = ok ? '' : msg;
              },
              onRegion: (a: number, b: number, c: number, d: number, z: number) => {
                this.lastBounds = [a, b, c, d];
                this.zoom = z;
                this.loadRegion(a, b, c, d);
              }
            })
          } else {
            MapCanvas({
              places: this.filtered(),
              selectedId: this.selectedId,
              onPick: (p: Place) => {
                this.selected = p;
                this.selectedId = p.id;
                this.drawn = null;
              },
              onBlank: () => {
                this.selected = null;
                this.selectedId = 0;
              }
            })
          }

          Row({ space: 6 }) {
            Text(this.useAmap ? '高德地图' : '自绘底图')
              .fontSize(Theme.F_CAP)
              .fontColor($r('app.color.primary'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.tint'))
              .borderRadius(Theme.R_FULL)
              .onClick(() => {
                this.useAmap = !this.useAmap;
              })
            if (this.useAmap && scaleLabel(scaleOf(this.zoom)).length > 0) {
              Text(scaleLabel(scaleOf(this.zoom)))
                .fontSize(Theme.F_CAP)
                .fontColor($r('app.color.primary'))
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor($r('app.color.tint'))
                .borderRadius(Theme.R_FULL)
            }
            Text(`${this.filtered().length} 家`)
              .fontSize(Theme.F_CAP)
              .fontColor($r('app.color.ink_soft'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.surface'))
              .borderRadius(Theme.R_FULL)
          }
          .margin(Theme.S_SM)
          .shadow(Theme.cardShadow())

          // ---- 地图内浮层：状态提示（左上） ----
          Column({ space: 6 }) {
            if (this.loading) {
              Row({ space: 6 }) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color($r('app.color.primary'))
                Text('加载地点…')
                  .fontSize(Theme.F_CAP)
                  .fontColor($r('app.color.ink_soft'))
              }
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.surface'))
              .borderRadius(Theme.R_FULL)
              .shadow(Theme.cardShadow())
            }
            if (this.petalMsg.length > 0) {
              Text(this.petalMsg)
                .fontSize(Theme.F_CAP)
                .fontColor($r('app.color.danger'))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor($r('app.color.surface'))
                .borderRadius(Theme.R_SM)
                .constraintSize({ maxWidth: 230 })
                .maxLines(3)
                .shadow(Theme.cardShadow())
            }
            if (this.tip.length > 0) {
              Text(this.tip)
                .fontSize(Theme.F_CAP)
                .fontColor($r('app.color.ink_soft'))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor($r('app.color.surface'))
                .borderRadius(Theme.R_SM)
                .constraintSize({ maxWidth: 230 })
                .maxLines(3)
                .shadow(Theme.cardShadow())
            }
          }
          .alignItems(HorizontalAlign.Start)
          .position({ x: 10, y: 10 })

          // 底部信息卡（选中地点）显示时，点地图任意空白处关闭它
          if (this.selected !== null && !this.showDetail) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.selected = null;
                this.selectedId = 0;
                this.clusterPanel = null;
              })
          }

          // ---- 地图内浮层：选中地点卡片（底部） ----
          Stack({ alignContent: Alignment.Bottom }) {
            if (this.selected !== null) {
              Row() {
                Column() {
                  Text(truncate(this.selected.name, 14))
                    .fontSize(Theme.F_MD)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.ink'))
                  Text(`${this.selected.category}` +
                    (this.selected.rating_average !== undefined && this.selected.rating_average > 0
                      ? ` · ${this.selected.rating_average.toFixed(1)} 分` : '') +
                    (this.selected.per_person_cost !== undefined && this.selected.per_person_cost !== null
                      ? ` · ${formatCost(this.selected.per_person_cost)}` : ''))
                    .fontSize(Theme.F_CAP)
                    .fontColor($r('app.color.ink_faint'))
                    .margin({ top: 2 })
                  Text(truncate(addressOf(this.selected), 22))
                    .fontSize(Theme.F_SM)
                    .fontColor($r('app.color.ink_soft'))
                    .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column() {
                  PrimaryButton({
                    label: '看详情',
                    onTap: () => {
                      this.showDetail = true;
                    }
                  })
                }
                .width(96)
              }
              .width('100%')
              .padding(Theme.S_MD)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(Theme.R_LG)
              .shadow(Theme.floatShadow())
              .margin({ left: Theme.S_MD, right: Theme.S_MD, bottom: Theme.S_MD })
            }
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .layoutWeight(1)
        .width('100%')
        .borderRadius(Theme.R_LG)
        .clip(true)
        .margin({ top: Theme.S_SM })

      }
      .width('100%')
      .height('100%')
      .padding({ left: Theme.S_LG, right: Theme.S_LG, top: Theme.S_MD })
      .clip(true)

      // 聚合成员浮层
      if (this.clusterPanel !== null) {
        this.clusterSheet(this.clusterPanel as ClusterPoint)
      }

      // 详情浮层
      if (this.showDetail && this.selected !== null) {
        Column() {
          PlaceDetail({
            place: this.selected,
            onClose: () => {
              this.showDetail = false;
            }
          })
        }
        .width('100%')
        .height('68%')
        .backgroundColor($r('app.color.bg'))
        .borderRadius({ topLeft: Theme.R_XL, topRight: Theme.R_XL })
        .shadow(Theme.floatShadow())
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
      }
    }
    .width('100%')
    .height('100%')
  }
}

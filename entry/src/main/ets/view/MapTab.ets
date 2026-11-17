/** 地图页：搜索、分类筛选、自绘地图、随机推荐、地点详情 */
import { Theme } from '../common/Theme';
import { Store } from '../common/Store';
import { LatLng, distanceMeters, formatCost, formatDistance, truncate } from '../common/Util';
import { Place, Category, RandomContainer, addressOf, splitCategory } from '../model/Types';
import { ClusterPoint, Supercluster, scaleLabel, scaleOf } from '../common/Cluster';
import { CommunityService, DrawResult, MiscService, PlaceService } from '../service/Services';
import { MapCanvas } from './MapCanvas';
import { AmapView } from './AmapView';
import { PlaceDetail } from './PlaceDetail';
import { getFix } from '../common/Location';
import { PoiCache } from '../common/PoiCache';
import { common } from '@kit.AbilityKit';
import { EmptyState, LoadingRow, PillTag, PrimaryButton, SectionCard } from './Widgets';

@Component
export struct MapTab {
  @State places: Place[] = [];
  @State categories: Category[] = [];
  @State activeCategory: string = '';
  /** 分类筛选模式：0 无 / 1 只看 / 2 排除 */
  @State categoryMode: number = 0;
  /** 每个分类的显示态（与 categories 同序），预计算成状态才能驱动 UI 刷新 */
  @State catStates: number[] = [];
  /** 当前地图上的聚合点数（预计算，避免 build 里调方法读状态） */
  @State shownCount: number = 0;
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
  @State centerLat: number = Store.lastLat !== 0 ? Store.lastLat : 23.1189;
  @State centerLng: number = Store.lastLng !== 0 ? Store.lastLng : 113.2442;
  @State centerZoom: number = 15;
  /** 用户当前位置（0 表示未定位成功），地图上画小圆点 */
  @State userLat: number = 0;
  @State userLng: number = 0;
  /** 搜索结果卡片：按距离排序，可左右滑动切换 */
  @State searchResults: Place[] = [];
  @State searchIndex: number = 0;
  private swiperController: SwiperController = new SwiperController();
  /** 该时间戳之前不因视野变化去请求接口（卡片切换时的静默移动） */
  private silentUntil: number = 0;
  /** 搜索输入防抖定时器 */
  private searchTimer: number = -1;
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

  /**
   * 启动流程：缓存先渲染 → 再定位 → 视情况补充。
   * 地图一出现就应该有点位，所以渲染不等定位结果；定位回来只是纠正中心。
   */
  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    // Index 已预初始化过缓存；万一没就绪再兜一次
    if (!PoiCache.isReady()) {
      await PoiCache.init(ctx);
    }

    // ① 立刻用「上次地图中心」附近的缓存铺图（打开即见点）
    let fromCache = false;
    if (PoiCache.isEnabled() && PoiCache.count() > 0) {
      const near = this.cacheNear(this.centerLng, this.centerLat, 0.15);
      console.info(`[MapTab] cache total=${PoiCache.count()} near=${near.length} center=${this.centerLat},${this.centerLng}`);
      if (near.length > 0) {
        this.places = near;
        this.refreshCluster();
        fromCache = true;
      }
    } else {
      console.info(`[MapTab] cache empty or disabled: enabled=${PoiCache.isEnabled()} count=${PoiCache.count()}`);
    }

    // ② 定位（不阻塞首帧渲染）
    this.locating = true;
    const fix = await getFix();
    this.locating = false;
    if (fix.ok && fix.pos !== null) {
      this.centerLat = fix.pos.lat;
      this.centerLng = fix.pos.lng;
      this.userLat = fix.pos.lat;
      this.userLng = fix.pos.lng;
      this.tip = '';
      // 定位点与上次中心不同时，用定位点附近的缓存补一次
      if (!fromCache && PoiCache.isEnabled() && PoiCache.count() > 0) {
        const near = this.cacheNear(this.centerLng, this.centerLat, 0.15);
        if (near.length > 0) {
          this.places = near;
          this.refreshCluster();
          fromCache = true;
        }
      }
    } else {
      this.tip = fix.message;
    }

    if (!fromCache) {
      await this.loadRegion(
        this.centerLng - 0.010, this.centerLat - 0.008,
        this.centerLng + 0.010, this.centerLat + 0.008
      );
    } else {
      // 静默更新缓存：延迟 4s、只发一次请求，清掉服务端已不存在的点
      this.scheduleCacheSync();
    }

    const c = await PlaceService.categories();
    if (c.ok && c.data !== null) {
      this.categories = c.data;
      // 分类到位后初始化各 tag 的显示态
      this.refreshCluster();
    }
  }

  /** 取缓存中落在某个中心附近（度）的点 */
  private cacheNear(lng: number, lat: number, pad: number): Place[] {
    const out: Place[] = [];
    for (const it of PoiCache.all()) {
      if (it.lng >= lng - pad && it.lng <= lng + pad &&
        it.lat >= lat - pad && it.lat <= lat + pad) {
        out.push({
          id: it.id,
          name: it.name,
          category: it.category,
          longitude: it.lng,
          latitude: it.lat
        });
      }
    }
    return out;
  }

  /**
   * 后台静默校验缓存：以缓存质心为中心取一小块范围拉一次线上数据，
   * 把线上没有的缓存点删掉。只发一个请求、延迟执行，避免占用后台资源。
   */
  private scheduleCacheSync(): void {
    if (!PoiCache.isEnabled() || PoiCache.count() === 0) {
      return;
    }
    setTimeout(() => {
      this.syncCacheSilently();
    }, 4000);
  }

  private async syncCacheSilently(): Promise<void> {
    const center = PoiCache.centroid();
    if (center === null) {
      return;
    }
    const pad = 0.12;
    const r = await PlaceService.nearby(
      center.lng - pad, center.lat - pad, center.lng + pad, center.lat + pad
    );
    if (!r.ok || r.data === null) {
      return;
    }
    const alive = new Set<number>();
    for (const p of r.data) {
      alive.add(p.id);
    }
    // 只清理落在这次校验范围内的缓存点：范围内的且线上没有 → 判定为已删除
    const stale: number[] = [];
    for (const it of PoiCache.all()) {
      const inRange = it.lng >= center.lng - pad && it.lng <= center.lng + pad &&
        it.lat >= center.lat - pad && it.lat <= center.lat + pad;
      if (inRange && !alive.has(it.id)) {
        stale.push(it.id);
      }
    }
    if (stale.length > 0) {
      PoiCache.removeIds(stale);
    }
    PoiCache.put(r.data);
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
      // 合并：线上结果优先，缓存里这次没返回的点补上（去重，不会重复显示）
      const merged: Place[] = [];
      const seen = new Set<number>();
      for (const p of r.data) {
        merged.push(p);
        seen.add(p.id);
      }
      if (PoiCache.isEnabled()) {
        for (const c of this.cacheNear(cx, cy, Math.max(halfLng, halfLat) + 0.05)) {
          if (!seen.has(c.id)) {
            merged.push(c);
            seen.add(c.id);
          }
        }
      }
      this.places = merged;
      // 只缓存 id / 名称 / 分类 / 坐标，其它字段仍走线上
      PoiCache.put(r.data);
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

    // 预计算展示状态：方法内读 @State 不会被 ArkUI 追踪，必须落到状态变量上
    this.shownCount = list.length;
    const st: number[] = [];
    for (const c of this.categories) {
      st.push(this.activeCategory === c.name ? this.categoryMode : 0);
    }
    this.catStates = st;
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
    const r = await PlaceService.byKeyword(this.keyword, this.centerLat, this.centerLng);
    this.loading = false;
    if (r.ok && r.data !== null) {
      this.places = r.data;
      PoiCache.put(r.data);
      this.refreshCluster();
      this.tip = r.data.length === 0 ? `没有找到与「${this.keyword}」相关的地点` : '';
      // 搜索结果：按离用户（未定位时用当前地图中心）的距离从近到远
      const anchor: LatLng = this.userLat !== 0
        ? { lng: this.userLng, lat: this.userLat }
        : { lng: this.centerLng, lat: this.centerLat };
      const sorted: Place[] = [];
      for (const p of r.data) {
        sorted.push(p);
      }
      sorted.sort((a: Place, b: Place) => {
        const da = distanceMeters(anchor, { lng: a.longitude, lat: a.latitude });
        const db = distanceMeters(anchor, { lng: b.longitude, lat: b.latitude });
        return da - db;
      });
      this.searchResults = sorted;
      this.searchIndex = 0;
      this.swiperController = new SwiperController();
      if (sorted.length > 0) {
        this.moveToPlace(sorted[0]);
      }
    } else {
      this.tip = r.error;
      this.searchResults = [];
      this.searchIndex = 0;
    }
  }

  /** 相机移到某个地点（不改缩放） */
  private moveToPlace(p: Place): void {
    this.selected = p;
    this.selectedId = p.id;
    this.centerLat = p.latitude;
    this.centerLng = p.longitude;
    // 卡片切换导致的移动不重新拉接口，只重算聚合，保证左右滑动顺畅
    this.silentUntil = Date.now() + 1600;
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

  /**
   * 分类三态筛选：0 无筛选 / 1 只看该分类 / 2 排除该分类。
   * 点一次选中、再点一次变成排除、第三次恢复；切换分类时其它 tag 自动回到普通态。
   */
  private cycleCategory(name: string): void {
    if (this.activeCategory === name) {
      if (this.categoryMode === 1) {
        this.categoryMode = 2;
      } else {
        this.activeCategory = '';
        this.categoryMode = 0;
      }
    } else {
      this.activeCategory = name;
      this.categoryMode = 1;
    }
    this.refreshCluster();
  }

  private categoryStateOf(name: string): number {
    return this.activeCategory === name ? this.categoryMode : 0;
  }

  private filtered(): Place[] {
    if (this.activeCategory.length === 0 || this.categoryMode === 0) {
      return this.places;
    }
    const out: Place[] = [];
    for (const p of this.places) {
      const parts = splitCategory(p.category);
      let hit = false;
      for (const s of parts) {
        if (s === this.activeCategory) {
          hit = true;
          break;
        }
      }
      if (this.categoryMode === 1 ? hit : !hit) {
        out.push(p);
      }
    }
    return out;
  }

  /** 与用户（未定位时用地图中心）的距离文案 */
  private distText(p: Place): string {
    const anchor: LatLng = this.userLat !== 0
      ? { lng: this.userLng, lat: this.userLat }
      : { lng: this.centerLng, lat: this.centerLat };
    return formatDistance(distanceMeters(anchor, { lng: p.longitude, lat: p.latitude }));
  }

  /** 搜索结果卡片（Swiper 的一页），样式与地点详情卡片一致 */
  @Builder
  resultCard(p: Place, idx: number) {
    Row() {
      Column() {
        Row() {
          Text(`${idx + 1}/${this.searchResults.length}`)
            .fontSize(Theme.F_CAP)
            .fontColor($r('app.color.on_primary'))
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .backgroundColor($r('app.color.primary'))
            .borderRadius(Theme.R_FULL)
          Text(truncate(p.name, 12))
            .fontSize(Theme.F_MD)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
            .margin({ left: 6 })
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Text(`${splitCategory(p.category).join(' / ')}` +
          (p.rating_average !== undefined && p.rating_average > 0
            ? ` · ${p.rating_average.toFixed(1)} 分` : '') +
          (p.per_person_cost !== undefined && p.per_person_cost !== null
            ? ` · ${formatCost(p.per_person_cost)}` : '') +
          ` · ${this.distText(p)}`)
          .fontSize(Theme.F_CAP)
          .fontColor($r('app.color.ink_faint'))
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(truncate(addressOf(p), 20))
          .fontSize(Theme.F_SM)
          .fontColor($r('app.color.ink_soft'))
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        PrimaryButton({
          label: '看详情',
          onTap: () => {
            this.selected = p;
            this.selectedId = p.id;
            this.showDetail = true;
          }
        })
      }
      .width(92)
    }
    .width('100%')
    .padding(Theme.S_MD)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.R_LG)
    .shadow(Theme.floatShadow())
    .onClick(() => {
      this.selected = p;
      this.selectedId = p.id;
    })
    .margin({ left: Theme.S_MD, right: Theme.S_MD })
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
              // 输入防抖自动搜索：不用按回车也能出结果
              if (this.searchTimer >= 0) {
                clearTimeout(this.searchTimer);
                this.searchTimer = -1;
              }
              const kw = v.trim();
              if (kw.length === 0) {
                this.searchResults = [];
                this.searchIndex = 0;
                return;
              }
              this.searchTimer = setTimeout(() => {
                this.searchTimer = -1;
                this.search();
              }, 600);
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

        // 分类（横向滚动；点击依赖 PillTag 内部的 onClick + catStates 预计算）
        Scroll() {
          Row() {
            Column() {
              PillTag({
                text: '全部',
                state: this.activeCategory.length === 0 ? 1 : 0,
                onTap: () => {
                  this.activeCategory = '';
                  this.categoryMode = 0;
                  this.refreshCluster();
                }
              })
            }
            .margin({ right: 8 })

            ForEach(this.categories, (c: Category, idx: number) => {
              Column() {
                PillTag({
                  text: c.name,
                  state: idx < this.catStates.length ? this.catStates[idx] : 0,
                  onTap: () => {
                    this.cycleCategory(c.name);
                  }
                })
              }
              .margin({ right: 8 })
            }, (c: Category, idx: number) =>
              `${c.id}-${idx < this.catStates.length ? this.catStates[idx] : 0}`)
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
              userLat: this.userLat,
              userLng: this.userLng,
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
                // 记住视野中心，下次启动直接用缓存铺这一带
                Store.lastLat = (b + d) / 2;
                Store.lastLng = (a + c) / 2;
                if (Date.now() < this.silentUntil) {
                  // 卡片切换引起的相机移动：只重算聚合，不请求接口
                  this.refreshCluster();
                  return;
                }
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
            Text(`${this.shownCount} 家`)
              .fontSize(Theme.F_CAP)
              .fontColor($r('app.color.ink_soft'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.surface'))
              .borderRadius(Theme.R_FULL)
          }
          .margin(Theme.S_SM)

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

          // ---- 地图内浮层：搜索结果卡片（可左右滑动）/ 单个选中卡片 ----
          Stack({ alignContent: Alignment.Bottom }) {
            if (this.searchResults.length > 0) {
              Swiper(this.swiperController) {
                ForEach(this.searchResults, (p: Place, idx: number) => {
                  this.resultCard(p, idx)
                }, (p: Place) => `sr-${p.id}`)
              }
              .index(this.searchIndex)
              .indicator(false)
              .loop(false)
              .width('100%')
              .height(120)
              .margin({ bottom: Theme.S_MD })
              .onChange((i: number) => {
                this.searchIndex = i;
                if (i >= 0 && i < this.searchResults.length) {
                  this.moveToPlace(this.searchResults[i]);
                }
              })
            } else if (this.selected !== null) {
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

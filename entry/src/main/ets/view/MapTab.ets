/** 地图页：搜索、分类筛选、自绘地图、随机推荐、地点详情 */
import { display } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { Store } from '../common/Store';
import { LatLng, distanceMeters, formatCost, formatDistance, truncate } from '../common/Util';
import { Place, Category, RandomContainer, addressOf, splitCategory } from '../model/Types';
import { ClusterPoint, clusterSingle, scaleLabel, scaleOf } from '../common/Cluster';
import { CommunityService, DrawResult, MiscService, PlaceService } from '../service/Services';
import { MapCanvas } from './MapCanvas';
import { AmapView } from './AmapView';
import { PlaceDetail } from './PlaceDetail';
import { getFix } from '../common/Location';
import { PoiCache } from '../common/PoiCache';
import { common } from '@kit.AbilityKit';
import { EmptyState, LoadingRow, PillTag, PrimaryButton, SectionCard } from './Widgets';

/** 近期查看过的点位（20 秒内存缓存，滑回去不用重新请求） */
/** 顶栏高度（不含安全区）：顶部浮层据此下移避开标题 */
const TITLE_BAND: number = 46;
/** 横屏时单张搜索结果卡片的宽度（一屏能并排 3~4 张） */
const WIDE_CARD_W: number = 330;
/** 悬浮导航高度（vp），与 Index 里 barHeight 保持一致 */
const BAR_HEIGHT_VP: number = 60;
/** 地图浮层卡片统一高度：搜索结果卡与单个信息卡保持一致 */
const CARD_H: number = 116;
/** 右上角药丸行下移，避开顶部搜索/分类浮层 */
const PILL_TOP: number = 188;

interface RecentPoi {
  place: Place;
  ts: number;
}

/** 最近拉取过的范围 */
interface FetchedRegion {
  minLng: number;
  minLat: number;
  maxLng: number;
  maxLat: number;
  ts: number;
}

@Component
export struct MapTab {  @State places: Place[] = [];
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
  /**
   * 近期点位缓存：滑走过的区域保留 20 秒，
   * 20 秒内滑回去直接用本地数据渲染，不再请求服务端。
   */
  private recent: Map<number, RecentPoi> = new Map<number, RecentPoi>();
  /** 最近拉取过的范围（西南→东北 + 时间戳），用于判断能否跳过请求 */
  private fetchedRegions: FetchedRegion[] = [];
  private recentTimer: number = -1;
  /** 大尺度分块加载的会话号，视野变化即失效 */
  private loadSeq: number = 0;
  /** 是否横屏（平板 / 折叠屏展开）：横屏时搜索结果用横向连续滑动 */
  @State isWide: boolean = false;
  /** 顶栏「定位」按钮通过 AppStorage 通知地图重新居中 */
  @StorageProp('recenterTick') @Watch('onGlobalRecenter') recenterTick: number = 0;
  private orientCb: Callback<number> | null = null;
  /** 底部悬浮导航占用的高度：浮层卡片要据此上移，避免被遮住 */
  private barClearance: number = 0;
  /** 近期点位保留时长 */
  private readonly RECENT_TTL: number = 20000;
  /** 近期点位最多保留多少个（避免聚合器被喂太多点） */
  private readonly RECENT_MAX: number = 600;
  @State locating: boolean = false;
  /** 当前缩放与聚合结果 */
  @State zoom: number = 15;
  @State clusters: ClusterPoint[] = [];
  /** 点击聚合点后展开的成员 */
  @State clusterPanel: ClusterPoint | null = null;
  /** 当前视野 bbox（西南 → 东北），聚合查询用 */
  private lastBounds: number[] = [113.22, 23.10, 113.29, 23.14];

  aboutToAppear(): void {
    this.boot();
    // 每 5 秒清一次过期的近期点位
    this.recentTimer = setInterval(() => {
      this.pruneRecent();
    }, 5000);
    // 屏幕方向：横屏时搜索结果改成横向连续滑动
    this.syncOrientation();
    try {
      const cb = (code: number): void => {
        this.syncOrientation();
      };
      this.orientCb = cb;
      display.on('change', cb);
    } catch (err) {
      this.orientCb = null;
    }
  }

  /** 顶栏定位按钮触发的重新居中 */
  onGlobalRecenter(): void {
    this.centerLat = Store.lastLat !== 0 ? Store.lastLat : this.centerLat;
    this.centerLng = Store.lastLng !== 0 ? Store.lastLng : this.centerLng;
    if (this.userLat !== 0) {
      this.centerLat = this.userLat;
      this.centerLng = this.userLng;
    }
  }

  /** 读取当前是否处在横屏（平板 / 折叠屏展开），同时算出底部悬浮栏让位高度 */
  private syncOrientation(): void {
    try {
      const d = display.getDefaultDisplaySync();
      this.isWide = d.width > d.height;
    } catch (err) {
      this.isWide = false;
    }
    const safeBottom = AppStorage.get<number>('safeBottomVp') ?? 0;
    // 悬浮栏高 60 + 距底 12 + 呼吸间距
    this.barClearance = BAR_HEIGHT_VP + 12 + 12 + safeBottom;
  }

  aboutToDisappear(): void {
    if (this.recentTimer >= 0) {
      clearInterval(this.recentTimer);
      this.recentTimer = -1;
    }
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    if (this.orientCb !== null) {
      try {
        display.off('change', this.orientCb);
      } catch (err) {
        // 忽略
      }
      this.orientCb = null;
    }
  }

  /** 清理超过 20 秒的近期点位；只是让「跳过请求」失效，不动当前已显示的 pin */
  private pruneRecent(): void {
    const now = Date.now();
    const drop: number[] = [];
    this.recent.forEach((it: RecentPoi, id: number) => {
      if (now - it.ts > this.RECENT_TTL) {
        drop.push(id);
      }
    });
    for (const id of drop) {
      this.recent.delete(id);
    }
    // 已拉取范围过期后，下次移动会重新请求
    const keepRegions: FetchedRegion[] = [];
    for (const r of this.fetchedRegions) {
      if (now - r.ts <= this.RECENT_TTL) {
        keepRegions.push(r);
      }
    }
    this.fetchedRegions = keepRegions;
  }

  /** 用近期点位重建 places（保留当前筛选） */
  private rebuildPlacesFromRecent(): void {
    const now = Date.now();
    const out: Place[] = [];
    this.recent.forEach((it: RecentPoi) => {
      if (now - it.ts <= this.RECENT_TTL) {
        out.push(it.place);
      }
    });
    this.places = out;
    this.refreshCluster();
  }

  /** 目标视野是否已被 20 秒内拉取过的范围覆盖 */
  private recentlyFetched(minLng: number, minLat: number, maxLng: number, maxLat: number): boolean {
    const now = Date.now();
    for (const r of this.fetchedRegions) {
      if (now - r.ts > this.RECENT_TTL) {
        continue;
      }
      if (minLng >= r.minLng && minLat >= r.minLat && maxLng <= r.maxLng && maxLat <= r.maxLat) {
        return true;
      }
    }
    return false;
  }

  /** 记下已拉取范围并写入近期点位 */
  private rememberFetched(minLng: number, minLat: number, maxLng: number, maxLat: number,
    list: Place[]): void {
    const now = Date.now();
    this.fetchedRegions.push({
      minLng: minLng, minLat: minLat, maxLng: maxLng, maxLat: maxLat, ts: now
    });
    // 只留最近 8 个范围，避免无限增长
    if (this.fetchedRegions.length > 8) {
      this.fetchedRegions = this.fetchedRegions.slice(this.fetchedRegions.length - 8);
    }
    for (const p of list) {
      this.recent.set(p.id, { place: p, ts: now });
    }
    // 超过上限时丢弃最早的
    if (this.recent.size > this.RECENT_MAX) {
      const entries: RecentPoi[] = [];
      this.recent.forEach((it: RecentPoi) => {
        entries.push(it);
      });
      entries.sort((a: RecentPoi, b: RecentPoi) => a.ts - b.ts);
      const dropCount = this.recent.size - this.RECENT_MAX;
      for (let i = 0; i < dropCount; i++) {
        this.recent.delete(entries[i].place.id);
      }
    }
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
   * 大尺度分块加载：把整个 bbox 切成 cols×rows 小块，逐块请求并限速，
   * 每块回来就并入 places 重新聚合，边加载边出点位。
   * 视野一变（loadSeq 递增）就放弃剩余块，避免堆积请求。
   */
  private async loadBigRegion(minLng: number, minLat: number, maxLng: number, maxLat: number): Promise<void> {
    const seq = ++this.loadSeq;
    const cols = 4;
    const rows = 3;
    const dLng = (maxLng - minLng) / cols;
    const dLat = (maxLat - minLat) / rows;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        if (seq !== this.loadSeq) {
          return;
        }
        const x0 = minLng + c * dLng;
        const y0 = minLat + r * dLat;
        const x1 = x0 + dLng;
        const y1 = y0 + dLat;
        const res = await PlaceService.nearby(x0, y0, x1, y1);
        if (seq !== this.loadSeq) {
          return;
        }
        if (res.ok && res.data !== null && res.data.length > 0) {
          this.rememberFetched(x0, y0, x1, y1, res.data);
          PoiCache.put(res.data);
          // 并入现有集合（按 id 去重）
          const seen = new Set<number>();
          const merged: Place[] = [];
          for (const p of this.places) {
            merged.push(p);
            seen.add(p.id);
          }
          for (const p of res.data) {
            if (!seen.has(p.id)) {
              merged.push(p);
              seen.add(p.id);
            }
          }
          this.places = merged;
          this.refreshCluster();
        }
        // 限速，避免连续打满
        await new Promise<void>((resolve) => {
          setTimeout(() => {
            resolve();
          }, 320);
        });
      }
    }
    if (seq === this.loadSeq) {
      this.tip = '';
    }
  }
  private async loadRegion(minLng: number, minLat: number, maxLng: number, maxLat: number): Promise<void> {
    // 20 秒内拉过这一带：直接用本地数据渲染，不发请求
    if (this.recentlyFetched(minLng, minLat, maxLng, maxLat)) {
      this.rebuildPlacesFromRecent();
      this.tip = '';
      return;
    }
    // 缩到省/国尺度时 bbox 太大：一次请求会拖回海量数据把主线程压死，
    // 改为切成小块顺序补齐。注意这里不能被 loading 挡住，
    // 否则从街区缩到省级时，上一个请求还没回来就整段跳过，屏幕上会一片空白。
    if ((maxLng - minLng) > 2.5 || (maxLat - minLat) > 2.5) {
      const local: Place[] = [];
      const seenIds = new Set<number>();
      const nowTs = Date.now();
      this.recent.forEach((it: RecentPoi) => {
        if (nowTs - it.ts <= this.RECENT_TTL) {
          local.push(it.place);
          seenIds.add(it.place.id);
        }
      });
      if (PoiCache.isEnabled()) {
        for (const p of PoiCache.toPlaces()) {
          if (!seenIds.has(p.id)) {
            local.push(p);
            seenIds.add(p.id);
          }
        }
      }
      if (local.length > 0) {
        this.places = local;
        this.refreshCluster();
      }
      this.tip = '省/国尺度，分块加载中…';
      // 大尺度一次拉不完，切成小块顺序补
      this.loadBigRegion(minLng, minLat, maxLng, maxLat);
      return;
    }
    if (this.loading) {
      return;
    }
    this.loading = true;
    const cx = (minLng + maxLng) / 2;
    const cy = (minLat + maxLat) / 2;
    const halfLng = (maxLng - minLng) * 1.0;
    const halfLat = (maxLat - minLat) * 1.0;
    const r = await PlaceService.nearby(
      cx - halfLng, cy - halfLat, cx + halfLng, cy + halfLat,
      minLng, minLat, maxLng, maxLat
    );
    this.loading = false;
    if (r.ok && r.data !== null) {
      // 记下这次拉取的范围与实际预取 bbox，20 秒内再回到这里就不重复请求
      this.rememberFetched(cx - halfLng, cy - halfLat, cx + halfLng, cy + halfLat, r.data);
      // 合并：线上结果 → 当前已显示的 pin → 20 秒内看过的 → 本地缓存。
      // 这样刷新过程中地图上的 pin 不会突然消失。
      const merged: Place[] = [];
      const seen = new Set<number>();
      for (const p of r.data) {
        merged.push(p);
        seen.add(p.id);
      }
      for (const p of this.places) {
        const inside = p.longitude >= cx - halfLng && p.longitude <= cx + halfLng &&
          p.latitude >= cy - halfLat && p.latitude <= cy + halfLat;
        if (inside && !seen.has(p.id)) {
          merged.push(p);
          seen.add(p.id);
        }
      }
      const now = Date.now();
      this.recent.forEach((it: RecentPoi) => {
        if (now - it.ts <= this.RECENT_TTL && !seen.has(it.place.id)) {
          merged.push(it.place);
          seen.add(it.place.id);
        }
      });
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

  /**
   * 重算聚合。
   * 只把「当前视野 + 缓冲」内的点拿去聚类，且只算当前 zoom 这一层（clusterSingle），
   * 不再像 supercluster 那样预计算 17 层——那是 17 倍的冗余计算和内存。
   */
  private refreshCluster(): void {
    const b = this.lastBounds;
    // 缓冲放宽到 2 倍视野：大尺度下也能覆盖屏幕外的相邻区域，不会出现点位缺失
    const padLng = Math.max((b[2] - b[0]) * 2.0, 0.02);
    const padLat = Math.max((b[3] - b[1]) * 2.0, 0.02);
    const minLng = b[0] - padLng;
    const maxLng = b[2] + padLng;
    const minLat = b[1] - padLat;
    const maxLat = b[3] + padLat;

    const list: Place[] = [];
    const hasFilter = this.activeCategory.length > 0 && this.categoryMode !== 0;
    for (const p of this.places) {
      if (p.longitude < minLng || p.longitude > maxLng ||
        p.latitude < minLat || p.latitude > maxLat) {
        continue;
      }
      if (hasFilter) {
        const parts = splitCategory(p.category);
        let hit = false;
        for (const s of parts) {
          if (s === this.activeCategory) {
            hit = true;
            break;
          }
        }
        if (this.categoryMode === 1 ? !hit : hit) {
          continue;
        }
      }
      list.push(p);
    }

    // 单层聚类：只算当前 zoom 这一层，不再预计算 17 层
    this.clusters = clusterSingle(list, this.zoom, 68, 512, 2, true);

    // 只保留落在真实视野内的节点（clusterSingle 不按 bbox 过滤）
    const visible: ClusterPoint[] = [];
    for (const c of this.clusters) {
      if (c.lng >= b[0] && c.lng <= b[2] && c.lat >= b[1] && c.lat <= b[3]) {
        visible.push(c);
      }
    }
    this.clusters = visible;

    // 右上角显示「视野内的店铺数」＝各聚合节点 count 之和（不是节点个数）
    let total = 0;
    for (const c of this.clusters) {
      total += c.count;
    }
    this.shownCount = total;
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

  /** 找出该地点从聚合里脱开、能单独显示的最近 zoom */
  private targetZoomFor(placeId: number): number {
    for (let z = 13; z <= 17; z++) {
      const list = clusterSingle(this.places, z, 68, 512, 2, false);
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
    .height(CARD_H)
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

        // 地图
        Stack({ alignContent: Alignment.TopEnd }) {
          if (this.useAmap) {
            AmapView({
              clusters: this.clusters,
              selectedId: this.selectedId,
              centerLat: this.centerLat,
              centerLng: this.centerLng,
              centerZoom: this.centerZoom,
              recenterTick: this.recenterTick,
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
          .margin({ top: PILL_TOP, right: Theme.S_SM })

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
                .constraintSize({ maxWidth: 168 })
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
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
              // 外层留出悬浮导航的高度，否则卡片会被压在导航下面
              Column() {
                if (this.isWide) {
                  // 横屏（平板 / 折叠屏展开）：横向连续滑动，一屏同时看到多张卡片
                  List({ space: Theme.S_MD }) {
                    ForEach(this.searchResults, (p: Place, idx: number) => {
                      ListItem() {
                        Column() {
                          this.resultCard(p, idx)
                        }
                        .width(WIDE_CARD_W)
                      }
                      .onClick(() => {
                        this.searchIndex = idx;
                        this.moveToPlace(p);
                      })
                    }, (p: Place) => `sr-${p.id}`)
                  }
                  .listDirection(Axis.Horizontal)
                  .scrollBar(BarState.Off)
                  .width('100%')
                  .height(CARD_H)
                  .padding({ left: Theme.S_MD, right: Theme.S_MD })
                } else {
                  Swiper(this.swiperController) {
                    ForEach(this.searchResults, (p: Place, idx: number) => {
                      this.resultCard(p, idx)
                    }, (p: Place) => `sr-${p.id}`)
                  }
                  .index(this.searchIndex)
                  .indicator(false)
                  .loop(false)
                  .width('100%')
                  .height(CARD_H)
                  .onChange((i: number) => {
                    this.searchIndex = i;
                    if (i >= 0 && i < this.searchResults.length) {
                      this.moveToPlace(this.searchResults[i]);
                    }
                  })
                }
              }
              .width('100%')
              .padding({ bottom: this.barClearance })
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
              // 单个信息卡：横屏时限制宽度，避免在宽屏上拉成一条
              .height(CARD_H)
              // 单个信息卡：横屏时限制宽度，避免在宽屏上拉成一条
              .width(this.isWide ? 460 : 340)
              .padding(Theme.S_MD)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(Theme.R_LG)
              .shadow(Theme.floatShadow())
              .margin({ left: Theme.S_MD, right: Theme.S_MD, bottom: this.barClearance })
            }
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
        }
        // 地图铺满整屏：去掉圆角与外边距，顶栏与底栏都是浮层
        .width('100%')
        .height('100%')

      }
      .width('100%')
      .height('100%')

      // ===== 顶部浮层：搜索 + 分类（渐变渐隐，压在地图上也能读清） =====
      // 外层撑满并顶部对齐：Stack 是 Bottom 对齐，不能直接放这里的子节点
      Column() {
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
          .padding({ left: 0, right: 0 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: Theme.S_SM })
        }
        .width('100%')
        .padding({
          left: Theme.S_LG,
          right: Theme.S_LG,
          top: (AppStorage.get<number>('safeTopVp') ?? 0) + TITLE_BAND,
          bottom: Theme.S_MD
        })
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.bg'), 0],
            [$r('app.color.bg'), 0.62],
            [$r('app.color.bg_clear'), 1]
          ]
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Transparent)


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

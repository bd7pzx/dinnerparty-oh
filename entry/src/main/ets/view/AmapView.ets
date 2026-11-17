/**
 * 高德地图（鸿蒙星河版地图 SDK）原生组件。
 * 依赖：@amap/amap_lbs_map3d + @amap/amap_lbs_common（ohpm 已安装）
 *
 * 视野驱动：地图移动后取可视区域 bbox 回调上层，由上层按 3×3 倍范围请求 /places/nearby。
 * 点聚合：上层按 zoom 聚合后传 clusters 进来，聚合点用 fromView 生成带数字的徽标图标。
 */
import {
  AMap, BitmapDescriptor, BitmapDescriptorFactory, CameraUpdateFactory, LatLng, MapType,
  MapView, MapViewComponent, MapViewManager, MapsInitializer, Marker, MarkerOptions
} from '@amap/amap_lbs_map3d';
import { AMapPrivacyAgreeStatus, AMapPrivacyInfoStatus, AMapPrivacyShowStatus } from '@amap/amap_lbs_common';
import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { Store } from '../common/Store';
import { ClusterPoint } from '../common/Cluster';
import { Place } from '../model/Types';

/** 用户位置小圆点颜色（#ff0a59f7） */
const USER_DOT_COLOR: string = '#0A59F7';

/** 高德 Key（HarmonyOS 平台） */
export const AMAP_KEY: string = 'f96314c579e55a67c27388e7b32d340e';

const DEFAULT_ZOOM: number = 15;
const POLL_MS: number = 900;

@Component
export struct AmapView {
  @Prop @Watch('onClustersChanged') clusters: ClusterPoint[] = [];
  @Prop selectedId: number = 0;
  /** 初始相机（通常是用户当前位置） */
  @Prop @Watch('onCenterChanged') centerLat: number = 23.1189;
  @Prop @Watch('onCenterChanged') centerLng: number = 113.2442;
  /** centerZoom 也要参与 watch，否则「点聚合点放大」只改缩放不改中心时不会触发相机移动 */
  @Prop @Watch('onCenterChanged') centerZoom: number = DEFAULT_ZOOM;
  /** 用户当前位置（0 表示尚未定位），用于画小圆点 */
  @Prop @Watch('onUserMoved') userLat: number = 0;
  @Prop @Watch('onUserMoved') userLng: number = 0;

  onPick: (p: Place) => void = () => {
  };
  /** 点击聚合点 */
  onCluster: (c: ClusterPoint) => void = () => {
  };
  /** 点击地图空白处 */
  onMapClick: () => void = () => {
  };
  onStatus: (ok: boolean, msg: string) => void = () => {
  };
  /** 视野变化（西南 → 东北 + 当前 zoom） */
  onRegion: (minLng: number, minLat: number, maxLng: number, maxLat: number, zoom: number) => void =
    (minLng: number, minLat: number, maxLng: number, maxLat: number, zoom: number) => {
    };

  @State statusText: string = '正在加载高德地图…';
  @StorageProp('dark') @Watch('onDarkChanged') darkMode: boolean = false;

  private aMap: AMap | null = null;
  private mapView: MapView | null = null;
  private idToCluster: Map<string, ClusterPoint> = new Map<string, ClusterPoint>();
  private iconCache: Map<number, BitmapDescriptor> = new Map<number, BitmapDescriptor>();
  private pollTimer: number = -1;
  /** 用户当前位置小圆点（独立于聚合标记，不受 clear 影响） */
  private userMarker: Marker | null = null;
  private lastKey: string = '';
  /** key → Marker，用于增量更新（避免每次 clear 重建全部标记） */
  private markerByKey: Map<string, Marker> = new Map<string, Marker>();
  /** key → 当前数量，数量变化时才换图标 */
  private countByKey: Map<string, number> = new Map<string, number>();
  /** 本轮新增的聚合点数量，用于决定是否播放动画 */
  private freshCount: number = 0;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      MapsInitializer.updatePrivacyShow(AMapPrivacyShowStatus.DidShow, AMapPrivacyInfoStatus.DidContain, ctx);
      MapsInitializer.updatePrivacyAgree(AMapPrivacyAgreeStatus.DidAgree, ctx);
      MapsInitializer.initialize(ctx);
      MapsInitializer.setApiKey(AMAP_KEY);
      MapsInitializer.setInitCamera(this.centerLat, this.centerLng, this.centerZoom);
    } catch (err) {
      this.statusText = '高德 SDK 初始化异常';
    }

    MapViewManager.getInstance().registerMapViewCreatedCallback((mapview?: MapView) => {
      if (mapview === undefined || mapview === null) {
        this.statusText = '高德地图视图创建失败';
        this.onStatus(false, this.statusText);
        return;
      }
      this.mapView = mapview;
      mapview.onCreate();
      mapview.getMapAsync((map: AMap) => {
        this.aMap = map;
        this.statusText = '';
        this.onStatus(true, '高德地图已就绪');
        map.setMapType(Store.dark ? MapType.MAP_TYPE_NIGHT : MapType.MAP_TYPE_NORMAL);
        map.setOnMarkerClickListener((marker: Marker): boolean => {
          const c = this.idToCluster.get(marker.getId());
          if (c !== undefined) {
            if (c.count >= 2) {
              this.onCluster(c);
            } else if (c.places.length > 0) {
              this.onPick(c.places[0]);
            }
            return true;
          }
          return false;
        });
        // 点击地图空白处（非标记）→ 通知上层收起浮层
        map.setOnMapClickListener((point: LatLng) => {
          this.onMapClick();
        });
        this.moveTo(this.centerLat, this.centerLng, this.centerZoom);
        this.syncMarkers();
        this.syncUserMarker();
        this.startPoll();
        this.warmUp();
      });
    });
  }

  aboutToDisappear(): void {
    this.stopPoll();
    if (this.mapView !== null) {
      this.mapView.onDestroy();
    }
  }

  onCenterChanged(): void {
    this.moveTo(this.centerLat, this.centerLng, this.centerZoom);
  }

  onDarkChanged(): void {
    if (this.aMap !== null) {
      this.aMap.setMapType(this.darkMode ? MapType.MAP_TYPE_NIGHT : MapType.MAP_TYPE_NORMAL);
    }
  }

  onClustersChanged(): void {
    this.syncMarkers();
  }

  /** 用户位置变化：更新小圆点 */
  onUserMoved(): void {
    this.syncUserMarker();
  }

  /** 用户位置小圆点图标（纯矢量，无图片加载） */
  @Builder
  userDot() {
    Column()
      .width(vp2px(6))
      .height(vp2px(6))
      .borderRadius(vp2px(3))
      .backgroundColor(USER_DOT_COLOR)
      .border({ width: vp2px(1.2), color: Color.White })
      .shadow({ radius: vp2px(2), color: 'rgba(10,89,247,0.4)', offsetX: 0, offsetY: vp2px(1) })
  }

  private async userDotIcon(): Promise<BitmapDescriptor | undefined> {
    const hit = this.iconCache.get(-2);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const desc = await BitmapDescriptorFactory.fromView(() => {
        this.userDot();
      });
      if (desc !== undefined && desc !== null) {
        this.iconCache.set(-2, desc);
        return desc;
      }
    } catch (err) {
      // 失败时用默认图标
    }
    return undefined;
  }

  private async syncUserMarker(): Promise<void> {
    if (this.aMap === null || this.userLat === 0 || this.userLng === 0) {
      return;
    }
    const pos = new LatLng(this.userLat, this.userLng);
    if (this.userMarker !== null) {
      this.userMarker.setPosition(pos);
      return;
    }
    const icon = await this.userDotIcon();
    const opts = new MarkerOptions();
    opts.setPosition(pos);
    opts.setTitle('我的位置');
    // 圆点以中心对齐坐标
    opts.setAnchor(0.5, 0.5);
    if (icon !== undefined) {
      opts.setIcon(icon);
    }
    const added = this.aMap.addMarker(opts);
    this.userMarker = added === undefined ? null : added;
  }

  private moveTo(lat: number, lng: number, zoom: number): void {
    if (this.aMap === null) {
      return;
    }
    this.aMap.moveCamera(CameraUpdateFactory.newLatLngZoom(new LatLng(lat, lng), zoom));
  }

  private startPoll(): void {
    this.stopPoll();
    this.pollTimer = setInterval(() => {
      this.pollRegion();
    }, POLL_MS);
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 读可视区域与 zoom，变化才回调 */
  private pollRegion(): void {
    if (this.aMap === null) {
      return;
    }
    const proj = this.aMap.getProjection();
    if (proj === undefined || proj === null) {
      return;
    }
    const vr = proj.getVisibleRegion();
    if (vr === undefined || vr === null) {
      return;
    }
    const cam = this.aMap.getCameraPosition();
    const zoom = cam === undefined || cam === null ? DEFAULT_ZOOM : cam.zoom;
    const b = vr.latLngBounds;
    const sw = b.southwest;
    const ne = b.northeast;
    // zoom 取整参与比较：缩放过程中小数抖动不再触发重新聚合
    const key = `${sw.longitude.toFixed(3)},${sw.latitude.toFixed(3)},` +
      `${ne.longitude.toFixed(3)},${ne.latitude.toFixed(3)},${Math.round(zoom)}`;
    if (key === this.lastKey) {
      return;
    }
    this.lastKey = key;
    this.onRegion(sw.longitude, sw.latitude, ne.longitude, ne.latitude, zoom);
  }

  /** 原项目 AC()：聚合标记随数量放大，最大 1.3 倍 */
  private clusterScale(count: number): number {
    if (count < 2) {
      return 1;
    }
    const r = Math.min(0.55, 0.09 * Math.log2(Math.max(1, count / 2)));
    return 1 + r * (0.3 / 0.55);
  }

  /** 原项目 PC()：<1000 原样；<10000 取 k 一位小数；否则取整 k */
  private countText(count: number): string {
    if (count < 1000) {
      return `${count}`;
    }
    if (count < 10000) {
      const s = (Math.floor(count / 100) / 10).toFixed(1);
      return s.endsWith('.0') ? `${s.slice(0, s.length - 2)}k` : `${s}k`;
    }
    return `${Math.floor(count / 1000)}k`;
  }

  /** 原项目 IC()：数量字号随位数与缩放变化 */
  private countFontSize(text: string, scale: number): number {
    const base = text.length <= 2 ? 20 : (text.length === 3 ? 16 : 13);
    return Math.round(base * scale * 10) / 10;
  }

  /**
   * 聚合标记。图源取自网页版 union 图（已裁掉四周留白，2481×3508 → 905×1295 的水滴本体），
   * 显示尺寸同网页版 36×52，数量落在水滴圆心（原项目 CSS 的 54% / 30% 换算到裁剪图后为 50% / 36%）。
   */
  @Builder
  clusterMarker(count: number) {
    Stack() {
      Image($rawfile('marker_cluster.png'))
        .width(36 * this.clusterScale(count))
        .height(52 * this.clusterScale(count))
        .objectFit(ImageFit.Fill)
        .syncLoad(true)
        .draggable(false)
      Text(this.countText(count))
        .fontSize(this.countFontSize(this.countText(count), this.clusterScale(count)))
        .fontWeight(FontWeight.Bold)
        .fontColor('#2B2440')
        .offset({ x: 0, y: -7 * this.clusterScale(count) })
    }
    .width(36 * this.clusterScale(count))
    .height(52 * this.clusterScale(count))
  }

  /** 单点标记：原项目地点图，强制缩放到 36×43 */
  @Builder
  placeMarker() {
    Column() {
      Image($rawfile('marker_place.png'))
        .width(36)
        .height(43)
        .objectFit(ImageFit.Fill)
        .syncLoad(true)
        .draggable(false)
    }
    .width(36)
    .height(43)
    .clip(true)
  }

  /** 单点图标（走 fromView 才能按 vp 缩放） */
  private async placeIcon(): Promise<BitmapDescriptor | undefined> {
    const hit = this.iconCache.get(-1);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const desc = await BitmapDescriptorFactory.fromView(() => {
        this.placeMarker();
      });
      if (desc !== undefined && desc !== null) {
        this.iconCache.set(-1, desc);
        return desc;
      }
    } catch (err) {
      // 退回默认图标
    }
    return undefined;
  }

  /** 生成并缓存聚合徽标图标 */
  private async clusterIcon(count: number): Promise<BitmapDescriptor | undefined> {
    const hit = this.iconCache.get(count);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const desc = await BitmapDescriptorFactory.fromView(() => {
        this.clusterMarker(count);
      });
      if (desc !== undefined && desc !== null) {
        this.iconCache.set(count, desc);
        return desc;
      }
    } catch (err) {
      // 生成失败时退回默认图标
    }
    return undefined;
  }

  /**
   * 增量同步标记：只增删差集、数量变化才换图标，
   * 避免每次视野刷新都 clear() 重建全部 Marker（那是卡顿的根源）。
   */
  private async syncMarkers(): Promise<void> {
    if (this.aMap === null) {
      return;
    }
    const map = this.aMap;
    const alive = new Set<string>();
    for (const c of this.clusters) {
      alive.add(c.key);
    }

    // 统计本轮新增的聚合点
    let fresh = 0;
    for (const c of this.clusters) {
      if (c.count >= 2 && !this.markerByKey.has(c.key)) {
        fresh++;
      }
    }
    this.freshCount = fresh;

    // 1. 移除已消失的
    const gone: string[] = [];
    this.markerByKey.forEach((m: Marker, k: string) => {
      if (!alive.has(k)) {
        gone.push(k);
      }
    });
    for (const k of gone) {
      const m = this.markerByKey.get(k);
      this.markerByKey.delete(k);
      this.countByKey.delete(k);
      if (m !== undefined && m !== null) {
        this.idToCluster.delete(m.getId());
        m.remove();
      }
    }

    // 2. 并行准备图标：fromView 是异步渲染，串行 await 会让标记一个个「排队出现」，很慢
    const iconCache = new Map<string, BitmapDescriptor>();
    const jobs: Promise<void>[] = [];
    for (const c of this.clusters) {
      const exist = this.markerByKey.get(c.key);
      const prevCount = this.countByKey.get(c.key);
      const needIcon = exist === undefined || exist === null || prevCount !== c.count;
      if (!needIcon) {
        continue;
      }
      jobs.push(this.prepareIcon(c).then((ic: BitmapDescriptor | undefined) => {
        if (ic !== undefined) {
          iconCache.set(c.key, ic);
        }
      }));
    }
    if (jobs.length > 0) {
      await Promise.all(jobs);
    }

    // 3. 新增 / 更新（图标已就绪，不再逐个等待）
    for (const c of this.clusters) {
      const exist = this.markerByKey.get(c.key);
      if (exist !== undefined && exist !== null) {
        const prevCount = this.countByKey.get(c.key);
        if (prevCount !== c.count) {
          const icon = iconCache.get(c.key);
          if (icon !== undefined) {
            exist.setIcon(icon);
          }
          this.countByKey.set(c.key, c.count);
        }
        this.idToCluster.set(exist.getId(), c);
        continue;
      }

      const opts = new MarkerOptions();
      opts.setPosition(new LatLng(c.lat, c.lng));
      opts.setTitle(c.count >= 2 ? `${c.count} 家` : c.name);
      const icon = iconCache.get(c.key);
      if (icon !== undefined) {
        opts.setIcon(icon);
      }
      const marker = map.addMarker(opts);
      if (marker !== undefined && marker !== null) {
        this.markerByKey.set(c.key, marker);
        this.countByKey.set(c.key, c.count);
        this.idToCluster.set(marker.getId(), c);
      }
    }
  }

  private async prepareIcon(c: ClusterPoint): Promise<BitmapDescriptor | undefined> {
    const first = c.count >= 2 ? await this.clusterIcon(c.count) : await this.placeIcon();
    if (first !== undefined) {
      return first;
    }
    // 并发渲染时 fromView 偶发失败，稍后重试一次，避免退回高德默认蓝水滴
    await new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, 80);
    });
    return c.count >= 2 ? this.clusterIcon(c.count) : this.placeIcon();
  }
  private warmUp(): void {
    setTimeout(() => {
      this.warmLoop(2);
    }, 1500);
  }

  private async warmLoop(n: number): Promise<void> {
    if (n > 40 || this.iconCache.has(n)) {
      if (n > 40) {
        return;
      }
    }
    await this.clusterIcon(n);
    if (n < 40) {
      this.warmLoop(n + 1);
    }
  }

  private recenter(): void {
    this.moveTo(this.centerLat, this.centerLng, this.centerZoom);
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      MapViewComponent()
        .width('100%')
        .height('100%')

      if (this.statusText.length > 0) {
        Row() {
          Text(this.statusText)
            .fontSize(Theme.F_SM)
            .fontColor($r('app.color.ink_soft'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.surface'))
      }

      Column() {
        Text('◎')
          .fontSize(16)
          .fontColor($r('app.color.primary'))
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(19)
          .shadow(Theme.cardShadow())
          .onClick(() => this.recenter())
      }
      .margin(Theme.S_MD)
    }
    .width('100%')
    .height('100%')
  }
}

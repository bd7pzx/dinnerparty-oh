/**
 * 花瓣地图（Map Kit）原生组件封装。
 *
 * 接入前提（缺一不可）：
 *  1. AppGallery Connect 创建应用，包名与本工程一致（com.pzx.dinnerparty）
 *  2. 在 AGC 为该项目「开通地图服务 Map Kit」
 *  3. 把 AGC 的应用 client_id 写入 entry/src/main/module.json5 的 metadata（name=client_id）
 *  4. 用于签名的证书指纹（SHA-256）登记到 AGC
 * 任一缺失时：本组件仍会渲染，但瓦片不出图（日志表现为 accessToken 获取失败），
 * 此时 statusText 会提示原因，并可由上层降级到自绘底图。
 */
import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../common/Theme';
import { Place } from '../model/Types';

/** 初始视野：荔湾一带 */
const HOME_TARGET: mapCommon.LatLng = { latitude: 23.1189, longitude: 113.2442 };
const HOME_CAMERA: mapCommon.CameraPosition = { target: HOME_TARGET, zoom: 15 };
const HOME_OPTIONS: mapCommon.MapOptions = { position: HOME_CAMERA };
/** 瓦片加载超时（毫秒） */
const TILE_TIMEOUT_MS: number = 10000;

@Component
export struct PetalMap {
  @Prop @Watch('onPlacesChanged') places: Place[] = [];
  @Prop selectedId: number = 0;
  onPick: (p: Place) => void = () => {
  };
  /** fatal=true 表示组件级失败，上层应降级 */
  onStatus: (fatal: boolean, msg: string) => void = () => {
  };

  @State statusText: string = '';
  @State tileLoaded: boolean = false;

  private controller: map.MapComponentController | null = null;
  private idToPlace: Map<string, Place> = new Map<string, Place>();
  private tileTimer: number = -1;

  private callback: AsyncCallback<map.MapComponentController> = (err: BusinessError, ctrl: map.MapComponentController) => {
    if (err !== undefined && err !== null && err.code !== 0) {
      this.statusText = `花瓣地图初始化失败（${err.code}），已改用自绘底图`;
      this.onStatus(true, this.statusText);
      return;
    }
    this.controller = ctrl;
    this.statusText = '';
    this.onStatus(false, '花瓣地图已加载');
    ctrl.on('mapLoad', () => {
      this.tileLoaded = true;
      this.statusText = '';
      this.clearTileTimer();
    });
    ctrl.on('markerClick', (marker: map.Marker) => {
      const p = this.idToPlace.get(marker.getId());
      if (p !== undefined) {
        this.onPick(p);
      }
    });
    this.startTileTimer();
    this.syncMarkers();
  };

  private startTileTimer(): void {
    this.clearTileTimer();
    this.tileTimer = setTimeout(() => {
      if (!this.tileLoaded) {
        this.statusText = '瓦片未出图：需在 AGC 开通「地图服务」并把 client_id 写入 module.json5';
      }
    }, TILE_TIMEOUT_MS);
  }

  private clearTileTimer(): void {
    if (this.tileTimer >= 0) {
      clearTimeout(this.tileTimer);
      this.tileTimer = -1;
    }
  }

  aboutToDisappear(): void {
    this.clearTileTimer();
  }

  onPlacesChanged(): void {
    this.syncMarkers();
  }

  private async syncMarkers(): Promise<void> {
    if (this.controller === null) {
      return;
    }
    const ctrl = this.controller;
    ctrl.clear();
    this.idToPlace = new Map<string, Place>();
    for (const p of this.places) {
      const opt: mapCommon.PointAnnotationParams = {
        position: { latitude: p.latitude, longitude: p.longitude },
        titles: [{ content: p.name, fontSize: 10 }]
      };
      try {
        const ann = await ctrl.addPointAnnotation(opt);
        this.idToPlace.set(ann.getId(), p);
      } catch (e) {
        // 单点失败不影响其余
      }
    }
  }

  private recenter(): void {
    if (this.controller === null) {
      return;
    }
    const update: map.CameraUpdate = map.newCameraPosition(HOME_CAMERA);
    this.controller.moveCamera(update);
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      MapComponent({ mapOptions: HOME_OPTIONS, mapCallback: this.callback })
        .width('100%')
        .height('100%')

      if (this.statusText.length > 0) {
        Row() {
          Text(this.statusText)
            .fontSize(Theme.F_SM)
            .fontColor($r('app.color.danger'))
            .layoutWeight(1)
            .maxLines(3)
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

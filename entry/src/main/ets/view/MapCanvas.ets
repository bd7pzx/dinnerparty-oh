/**
 * 自绘地图画布 —— 不依赖任何地图 SDK：
 * 底层 Canvas 画街区网格与主干道，上层用原生组件定位 marker，可点击。
 * 尺寸完全取自容器实测值，容器变化时重算投影并重绘。
 */
import { Theme } from '../common/Theme';
import { LatLng, Projection, ScreenPoint, makeProjection, project } from '../common/Util';
import { Place } from '../model/Types';

@Component
export struct MapCanvas {
  @Prop @Watch('onPlacesChanged') places: Place[] = [];
  @Prop selectedId: number = 0;
  onPick: (p: Place) => void = () => {
  };
  onBlank: () => void = () => {
  };

  /** 容器实测尺寸与投影（必须是状态，否则 marker 不会随尺寸渲染） */
  @State canvasW: number = 0;
  @State canvasH: number = 0;
  @State proj: Projection | null = null;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  onPlacesChanged(): void {
    this.ensureDraw();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.ensureDraw();
        })

      if (this.proj !== null) {
        ForEach(this.places, (p: Place) => {
          this.marker(p, this.proj as Projection)
        }, (p: Place) => `${p.id}-${this.selectedId}-${this.canvasW}-${this.canvasH}`)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = Number(newV.width);
      const h = Number(newV.height);
      if (w === this.canvasW && h === this.canvasH) {
        return;
      }
      this.canvasW = w;
      this.canvasH = h;
      this.ensureDraw();
    })
    .onClick(() => this.onBlank())
  }

  @Builder
  marker(p: Place, proj: Projection) {
    Column() {
      Text(this.badgeOf(p))
        .fontSize(10)
        .fontColor($r('app.color.on_primary'))
        .fontWeight(FontWeight.Bold)
        .width(this.isSelected(p) ? 30 : 24)
        .height(this.isSelected(p) ? 30 : 24)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colorOf(p))
        .borderRadius(this.isSelected(p) ? 15 : 12)
        .border({ width: this.isSelected(p) ? 2 : 1, color: $r('app.color.surface') })
        .shadow(Theme.floatShadow())
      Text(p.name)
        .fontSize(9)
        .fontColor($r('app.color.ink'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 72 })
        .backgroundColor($r('app.color.surface'))
        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        .borderRadius(4)
        .margin({ top: 2 })
        .opacity(this.isSelected(p) ? 1 : 0.85)
    }
    .alignItems(HorizontalAlign.Center)
    .position(this.ptOf(p, proj))
    .translate({ x: -16, y: -32 })
    .onClick(() => this.onPick(p))
  }

  private isSelected(p: Place): boolean {
    return this.selectedId === p.id;
  }

  private badgeOf(p: Place): string {
    const c = p.category;
    if (c === '甜品' || c === '饮品') return '杯';
    if (c === '面食') return '面';
    if (c === '火锅烧烤') return '锅';
    if (c === '异国') return '异';
    return '食';
  }

  private colorOf(p: Place): ResourceColor {
    const c = p.category;
    if (c === '甜品') return '#D2739A';
    if (c === '饮品') return '#7A9BB5';
    if (c === '面食') return '#C9873A';
    if (c === '火锅烧烤') return '#C0433F';
    if (c === '异国') return '#5E8F7D';
    return $r('app.color.primary');
  }

  private ptOf(p: Place, proj: Projection): Position {
    const pt: ScreenPoint = project(proj, p.longitude, p.latitude, this.canvasW, this.canvasH, 26);
    return { x: pt.x, y: pt.y };
  }

  private anchors(): LatLng[] {
    const out: LatLng[] = [];
    for (const p of this.places) {
      out.push({ lng: p.longitude, lat: p.latitude });
    }
    return out;
  }

  private ensureDraw(): void {
    if (this.canvasW <= 2 || this.canvasH <= 2) {
      return;
    }
    this.proj = makeProjection(this.anchors(), this.canvasW, this.canvasH, 26);
    this.drawBase(this.proj);
  }

  private drawBase(proj: Projection): void {
    const w = this.canvasW;
    const h = this.canvasH;
    const ctx = this.ctx;
    const pal = Theme.palette();

    ctx.fillStyle = pal.surfaceAlt;
    ctx.fillRect(0, 0, w, h);

    // 街区网格
    ctx.strokeStyle = pal.line;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.35;
    const step = 38;
    for (let x = step; x < w; x += step) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, h);
      ctx.stroke();
    }
    for (let y = step; y < h; y += step) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // 主干道
    ctx.strokeStyle = pal.tint;
    ctx.lineWidth = 14;
    ctx.beginPath();
    ctx.moveTo(-20, h * 0.74);
    ctx.lineTo(w * 0.46, h * 0.36);
    ctx.lineTo(w + 20, h * 0.5);
    ctx.stroke();

    ctx.lineWidth = 9;
    ctx.beginPath();
    ctx.moveTo(w * 0.24, -20);
    ctx.lineTo(w * 0.4, h * 0.56);
    ctx.lineTo(w * 0.32, h + 20);
    ctx.stroke();

    // 水系
    ctx.fillStyle = 'rgba(122,155,181,0.16)';
    ctx.beginPath();
    ctx.moveTo(w, h * 0.04);
    ctx.lineTo(w, h * 0.28);
    ctx.quadraticCurveTo(w * 0.74, h * 0.34, w * 0.62, h * 0.16);
    ctx.lineTo(w * 0.66, h * 0.02);
    ctx.closePath();
    ctx.fill();

    // 命中点之间的连线，暗示街区可达关系
    if (this.places.length > 1) {
      ctx.strokeStyle = 'rgba(181,70,110,0.28)';
      ctx.lineWidth = 1.5;
      for (let i = 1; i < this.places.length; i++) {
        const a = project(proj, this.places[i - 1].longitude, this.places[i - 1].latitude, w, h, 26);
        const b = project(proj, this.places[i].longitude, this.places[i].latitude, w, h, 26);
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
      }
    }
  }
}

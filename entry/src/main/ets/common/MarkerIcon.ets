import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { common2D } from '@kit.ArkGraphics2D';

/**
 * 用 drawing 直绘标记图标，替代 BitmapDescriptorFactory.fromView。
 *
 * fromView 要走一整条 ArkUI 渲染管线再截帧，单张 50~100ms，缩放换级时会集中触发，
 * 表现为「标记一个个排队冒出来」。这里把水滴底图一次性解码成 PixelMap，
 * 之后每个数量只需在 Canvas 上叠一行数字，单张约 1~2ms，且完全同步。
 */

/** 水滴底图的原始像素尺寸（rawfile/marker_cluster.png） */
const BASE_W: number = 108;
const BASE_H: number = 156;
/** 数字中心在原图里的相对位置（对应网页端 50% / 36%） */
const COUNT_X: number = 0.5;
const COUNT_Y: number = 0.36;
/** 数字颜色 #2B2440 */
const INK_R: number = 43;
const INK_G: number = 36;
const INK_B: number = 64;
/** 水滴底色：半透明白（能透出底图），描边取原图的粉色 */
const FILL_ALPHA: number = 232;
const FILL_R: number = 252;
const FILL_G: number = 248;
const FILL_B: number = 253;
const EDGE_R: number = 255;
const EDGE_G: number = 176;
const EDGE_B: number = 208;

export class MarkerIcon {
  private static base: image.PixelMap | null = null;
  private static placeImg: image.PixelMap | null = null;
  /** 屏幕密度（px / vp），用于把 vp 字号换算成像素 */
  private static density: number = 3;

  static setDensity(d: number): void {
    if (d > 0) {
      MarkerIcon.density = d;
    }
  }

  static vp2px(v: number): number {
    return v * MarkerIcon.density;
  }

  /** 预解码水滴底图与地点图（启动时调一次即可） */
  static prepare(ctx: common.UIAbilityContext): void {
    if (MarkerIcon.base === null) {
      try {
        const buf = ctx.resourceManager.getRawFileContentSync('marker_cluster.png');
        const src = image.createImageSource(buf.buffer as ArrayBuffer);
        MarkerIcon.base = src.createPixelMapSync();
        src.release();
      } catch (err) {
        MarkerIcon.base = null;
      }
    }
    if (MarkerIcon.placeImg === null) {
      try {
        const buf = ctx.resourceManager.getRawFileContentSync('marker_place.png');
        const src = image.createImageSource(buf.buffer as ArrayBuffer);
        MarkerIcon.placeImg = src.createPixelMapSync();
        src.release();
      } catch (err) {
        MarkerIcon.placeImg = null;
      }
    }
  }

  static isReady(): boolean {
    return MarkerIcon.base !== null;
  }

  /** 新建一张全透明画布（全 0 缓冲 = RGBA(0,0,0,0)，否则默认是不透明黑） */
  private static blank(w: number, h: number): image.PixelMap | undefined {
    try {
      const buf = new ArrayBuffer(w * h * 4);
      return image.createPixelMapSync(buf, {
        size: { width: w, height: h },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        // 与源图保持一致的预乘 alpha，否则半透明区域混合后会变成实心
        alphaType: image.AlphaType.PREMUL,
        editable: true
      });
    } catch (err) {
      return undefined;
    }
  }

  /** 把源图画到指定尺寸的画布上（纯贴图，不写字） */
  private static scaleTo(src: image.PixelMap, w: number, h: number, sw: number, sh: number): image.PixelMap | undefined {
    const pm = MarkerIcon.blank(w, h);
    if (pm === undefined) {
      return undefined;
    }
    try {
      const canvas = new drawing.Canvas(pm);
      canvas.save();
      canvas.scale(w / sw, h / sh);
      canvas.drawImage(src, 0, 0);
      canvas.restore();
      return pm;
    } catch (err) {
      return undefined;
    }
  }

  /** 单点图标：地点图缩放到 36×43 vp */
  static place(): image.PixelMap | undefined {
    const img = MarkerIcon.placeImg;
    if (img === null) {
      return undefined;
    }
    const w = Math.round(MarkerIcon.vp2px(36));
    const h = Math.round(MarkerIcon.vp2px(43));
    const size = img.getImageInfoSync().size;
    return MarkerIcon.scaleTo(img, w, h, size.width, size.height);
  }

  /** 水滴外形（保留备用，当前走 PNG 底图） */
  private static dropPath(w: number, h: number): drawing.Path {
    const path = new drawing.Path();
    const cx = w * 0.5;
    const cy = h * 0.365;
    const r = w * 0.415;
    path.addCircle(cx, cy, r);
    path.moveTo(cx, h * 0.96);
    path.lineTo(cx - r * 0.66, cy + r * 0.62);
    path.lineTo(cx + r * 0.66, cy + r * 0.62);
    path.close();
    return path;
  }

  /**
   * 生成聚合图标：水滴 PNG 铺底 + 数量数字。
   * @param scale 聚合缩放（1.0 ~ 1.3）
   * @param text 已格式化的数量文本（如 12 / 1.2k）
   * @param fontVp 字号（vp），会乘 density 换成像素
   */
  static cluster(scale: number, text: string, fontVp: number): image.PixelMap | undefined {
    const base = MarkerIcon.base;
    if (base === null) {
      return undefined;
    }
    const s = scale <= 0 ? 1 : scale;
    const w = Math.max(1, Math.round(BASE_W * s));
    const h = Math.max(1, Math.round(BASE_H * s));
    try {
      const pm = MarkerIcon.blank(w, h);
      if (pm === undefined) {
        return undefined;
      }
      const canvas = new drawing.Canvas(pm);
      // 底图按 scale 铺满
      canvas.save();
      canvas.scale(w / BASE_W, h / BASE_H);
      canvas.drawImage(base, 0, 0);
      canvas.restore();

      // 字号：按水滴可用宽度自适应，位数多就等比缩小，避免数字溢出边界
      let fontPx = Math.max(8, Math.round(MarkerIcon.vp2px(fontVp) * s));
      const maxTextW = w * 0.56;
      let font = new drawing.Font();
      font.setSize(fontPx);
      let tw = font.measureText(text, drawing.TextEncoding.TEXT_ENCODING_UTF8);
      if (tw > maxTextW && tw > 0) {
        fontPx = Math.max(8, Math.floor(fontPx * maxTextW / tw));
        font = new drawing.Font();
        font.setSize(fontPx);
        tw = font.measureText(text, drawing.TextEncoding.TEXT_ENCODING_UTF8);
      }
      const blob = drawing.TextBlob.makeFromString(text, font, drawing.TextEncoding.TEXT_ENCODING_UTF8);
      const cx = w * COUNT_X - tw / 2;
      // drawTextBlob 的 y 是基线，按字号上抬约 0.36 倍让视觉居中
      const cy = h * COUNT_Y + fontPx * 0.36;
      // 文字颜色由 canvas 的 brush 决定
      const ink = new drawing.Brush();
      const inkColor: common2D.Color = {
        alpha: 255, red: INK_R, green: INK_G, blue: INK_B
      };
      ink.setColor(inkColor);
      canvas.attachBrush(ink);
      canvas.drawTextBlob(blob, cx, cy);
      canvas.detachBrush();
      return pm;
    } catch (err) {
      return undefined;
    }
  }
}

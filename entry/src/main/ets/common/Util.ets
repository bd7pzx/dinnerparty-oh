/** 通用工具：几何、投影、格式化、ID */

export interface LatLng {
  lng: number;
  lat: number;
}

export interface ScreenPoint {
  x: number;
  y: number;
}

/** 包围盒 */
export interface BBox {
  minLng: number;
  maxLng: number;
  minLat: number;
  maxLat: number;
}

/** 地球半径（米），与逆向代码中的克拉索夫斯基椭球常量同量级 */
const EARTH_R: number = 6378245.0;

function toRad(d: number): number {
  return (d * Math.PI) / 180.0;
}

/** Haversine 距离（米） */
export function distanceMeters(a: LatLng, b: LatLng): number {
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const la1 = toRad(a.lat);
  const la2 = toRad(b.lat);
  const h = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(la1) * Math.cos(la2) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
  return 2 * EARTH_R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** 粗略判定是否位于中国境内（GCJ-02 适用区），逆向用 53 行纬度栅格表实现，此处取等效包络 */
export function isInChina(lng: number, lat: number): boolean {
  return lng >= 73.0 && lng <= 135.1 && lat >= 3.8 && lat <= 53.6;
}

export function formatDistance(m: number): string {
  if (!isFinite(m) || m < 0) return '';
  if (m < 1000) return `${Math.round(m)}m`;
  return `${(m / 1000).toFixed(1)}km`;
}

/** bbox 线性投影（经度按纬度余弦压缩，保持视觉比例） */
export interface Projection {
  minLng: number;
  maxLng: number;
  minLat: number;
  maxLat: number;
  width: number;
  height: number;
  cosLat: number;
}

export function makeProjection(points: LatLng[], width: number, height: number, pad: number): Projection {
  let minLng = 180;
  let maxLng = -180;
  let minLat = 90;
  let maxLat = -90;
  for (const p of points) {
    if (p.lng < minLng) minLng = p.lng;
    if (p.lng > maxLng) maxLng = p.lng;
    if (p.lat < minLat) minLat = p.lat;
    if (p.lat > maxLat) maxLat = p.lat;
  }
  if (minLng > maxLng) {
    minLng = 113.2;
    maxLng = 113.4;
    minLat = 23.0;
    maxLat = 23.2;
  }
  const padLng = (maxLng - minLng) * 0.12 + 0.0006;
  const padLat = (maxLat - minLat) * 0.12 + 0.0006;
  const b: BBox = {
    minLng: minLng - padLng,
    maxLng: maxLng + padLng,
    minLat: minLat - padLat,
    maxLat: maxLat + padLat
  };
  const w = width - pad * 2;
  const h = height - pad * 2;
  const rawW = (b.maxLng - b.minLng) * Math.cos(toRad((b.minLat + b.maxLat) / 2));
  const rawH = b.maxLat - b.minLat;
  const scale = Math.min(w / Math.max(rawW, 1e-9), h / Math.max(rawH, 1e-9));
  const cosLat = Math.cos(toRad((b.minLat + b.maxLat) / 2));
  return {
    minLng: b.minLng,
    maxLng: b.maxLng,
    minLat: b.minLat,
    maxLat: b.maxLat,
    width: rawW * scale,
    height: rawH * scale,
    cosLat: cosLat
  };
}

export function project(p: Projection, lng: number, lat: number, width: number, height: number, pad: number): ScreenPoint {
  const cx = (p.minLng + p.maxLng) / 2;
  const cy = (p.minLat + p.maxLat) / 2;
  const dx = (lng - cx) * Math.cos(toRad(cy));
  const dy = lat - cy;
  const rawW = (p.maxLng - p.minLng) * Math.cos(toRad(cy));
  const rawH = p.maxLat - p.minLat;
  const w = width - pad * 2;
  const h = height - pad * 2;
  const scale = Math.min(w / Math.max(rawW, 1e-9), h / Math.max(rawH, 1e-9));
  return {
    x: width / 2 + (dx / Math.max(rawW, 1e-9)) * rawW * scale,
    y: height / 2 - (dy / Math.max(rawH, 1e-9)) * rawH * scale
  };
}

/** 请求幂等键：与逆向 K4() 同构（uuid 优先，退化 base36 时间戳） */
export function newRequestId(): string {
  const t = Date.now().toString(36);
  const r = Math.random().toString(36).slice(2, 12);
  return `hm-${t}-${r}`;
}

export function newUuid(): string {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      out += '-';
    } else if (i === 14) {
      out += '4';
    } else if (i === 19) {
      out += hex.charAt(Math.floor(Math.random() * 4) + 8);
    } else {
      out += hex.charAt(Math.floor(Math.random() * 16));
    }
  }
  return out;
}

export function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

export function formatDate(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function today(): string {
  return formatDate(new Date());
}

export function addDays(base: string, days: number): string {
  const parts = base.split('-');
  const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  d.setDate(d.getDate() + days);
  return formatDate(d);
}

export function formatDateTime(raw: string): string {
  if (!raw) return '';
  return raw.replace('T', ' ').slice(0, 16);
}

export function clamp(v: number, lo: number, hi: number): number {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

export function truncate(s: string, n: number): string {
  if (!s) return '';
  return s.length <= n ? s : `${s.slice(0, n)}…`;
}

/** 人均消费展示 */
export function formatCost(cost: number): string {
  if (!cost || cost <= 0) return '人均未知';
  return `人均 ¥${Math.round(cost)}`;
}

/**
 * 点聚合 —— 直接移植原项目使用的 supercluster 算法（v8 核心逻辑），
 * 参数与原项目一致：radius 68px、extent 512、maxZoom 16、minPoints 2。
 * 原库依赖 KDBush 空间索引，这里改为线性扫描（地点数量在百级，足够快），
 * 其余（墨卡托投影、按层聚类、加权中心、clusterId 编解码、成员展开）与原实现保持一致。
 */
import { Place } from '../model/Types';

const STRIDE = 6;
const O_ZOOM = 2;
const O_ID = 3;
const O_PARENT = 4;
const O_NUM = 5;

export enum ClusterScale {
  NONE = 0,
  BLOCK = 1,
  DISTRICT = 2,
  CITY = 3,
  PROVINCE = 4,
  COUNTRY = 5
}

export interface ClusterPoint {
  key: string;
  lng: number;
  lat: number;
  count: number;
  name: string;
  scale: ClusterScale;
  placeId: number;
  places: Place[];
  /** 聚合点的 clusterId，点击时才用它展开成员 */
  nodeId: number;
  /** 生成该聚合的 zoom；点击展开时放大到 originZoom + 1 即可看到下一层 */
  originZoom: number;
}

function lngX(lng: number): number {
  return lng / 360 + 0.5;
}

function latY(lat: number): number {
  const sin = Math.sin(lat * Math.PI / 180);
  const y = 0.5 - 0.25 * Math.log((1 + sin) / (1 - sin)) / Math.PI;
  return y < 0 ? 0 : (y > 1 ? 1 : y);
}

function xLng(x: number): number {
  return (x - 0.5) * 360;
}

function yLat(y: number): number {
  const y2 = (180 - y * 360) * Math.PI / 180;
  return 360 * Math.atan(Math.exp(y2)) / Math.PI - 90;
}

export function scaleOf(zoom: number): ClusterScale {
  if (zoom >= 16) {
    return ClusterScale.NONE;
  }
  if (zoom >= 13) {
    return ClusterScale.BLOCK;
  }
  if (zoom >= 11) {
    return ClusterScale.DISTRICT;
  }
  if (zoom >= 9) {
    return ClusterScale.CITY;
  }
  if (zoom >= 6) {
    return ClusterScale.PROVINCE;
  }
  return ClusterScale.COUNTRY;
}

export function scaleLabel(scale: ClusterScale): string {
  if (scale === ClusterScale.BLOCK) {
    return '街区';
  }
  if (scale === ClusterScale.DISTRICT) {
    return '区镇';
  }
  if (scale === ClusterScale.CITY) {
    return '市';
  }
  if (scale === ClusterScale.PROVINCE) {
    return '省';
  }
  if (scale === ClusterScale.COUNTRY) {
    return '国';
  }
  return '';
}

/** supercluster 移植版 */
/**
 * 单层聚类：只算当前 zoom 这一层，替代 supercluster 的「预计算 17 层」。
 *
 * 与其从 maxZoom 逐层递推到 minZoom（17 层 × O(n·k)），
 * 这里直接按当前 zoom 的半径做一次网格合并，复杂度 O(n·k)。
 * 聚合语义仍是「半径 r 内合并 + 数量加权求中心」，与原实现视觉一致，
 * 但省掉 16 层多余计算和 16 份常驻内存。
 */
export function clusterSingle(source: Place[], zoom: number, radius: number, extent: number,
  minPoints: number, clustersOnly: boolean): ClusterPoint[] {
  const n = source.length;
  if (n === 0) {
    return [];
  }
  const z = zoom < 0 ? 0 : zoom;
  const r = radius / (extent * Math.pow(2, z));
  const rr = r * r;
  const scale = scaleOf(z);

  const xs: number[] = [];
  const ys: number[] = [];
  for (const p of source) {
    xs.push(lngX(p.longitude));
    ys.push(latY(p.latitude));
  }

  // 网格索引：cell 边长 = r
  const grid = new Map<string, number[]>();
  for (let i = 0; i < n; i++) {
    const key = `${Math.floor(xs[i] / r)}_${Math.floor(ys[i] / r)}`;
    const arr = grid.get(key);
    if (arr === undefined) {
      grid.set(key, [i]);
    } else {
      arr.push(i);
    }
  }

  const used: boolean[] = new Array<boolean>(n);
  for (let i = 0; i < n; i++) {
    used[i] = false;
  }

  const out: ClusterPoint[] = [];
  for (let i = 0; i < n; i++) {
    if (used[i]) {
      continue;
    }
    used[i] = true;
    const cx = Math.floor(xs[i] / r);
    const cy = Math.floor(ys[i] / r);
    const members: number[] = [i];
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        const arr = grid.get(`${cx + dx}_${cy + dy}`);
        if (arr === undefined) {
          continue;
        }
        for (const j of arr) {
          if (j === i || used[j]) {
            continue;
          }
          const ddx = xs[j] - xs[i];
          const ddy = ys[j] - ys[i];
          if (ddx * ddx + ddy * ddy <= rr) {
            used[j] = true;
            members.push(j);
          }
        }
      }
    }

    if (members.length >= minPoints && !(clustersOnly && members.length < minPoints)) {
      // 聚合点：数量加权求中心
      let wx = 0;
      let wy = 0;
      const places: Place[] = [];
      for (const j of members) {
        wx += xs[j];
        wy += ys[j];
        places.push(source[j]);
      }
      const c = members.length;
      out.push({
        key: `c_${c}_${xLng(wx / c).toFixed(6)}_${yLat(wy / c).toFixed(6)}`,
        lng: xLng(wx / c),
        lat: yLat(wy / c),
        count: c,
        name: '',
        scale: scale,
        placeId: -1,
        places: places,
        nodeId: c,
        originZoom: z
      });
    } else {
      // 单点（或被排除的孤立点）
      for (const j of members) {
        const p = source[j];
        out.push({
          key: `p_${p.id}`,
          lng: p.longitude,
          lat: p.latitude,
          count: 1,
          name: p.name,
          scale: ClusterScale.NONE,
          placeId: p.id,
          places: [p],
          nodeId: -1,
          originZoom: z
        });
      }
    }
  }
  return out;
}

export class Supercluster {
  private radius: number;
  private extent: number;
  private minPoints: number;
  private maxZoom: number;
  private minZoom: number = 0;
  private points: Place[] = [];
  private trees: number[][] = [];

  constructor(radius: number, extent: number, minPoints: number, maxZoom: number) {
    this.radius = radius;
    this.extent = extent;
    this.minPoints = minPoints;
    this.maxZoom = maxZoom;
  }

  /** 载入点集，按 zoom 从高到低逐层聚类 */
  load(places: Place[]): void {
    this.points = places;
    this.trees = [];
    const data: number[] = [];
    for (let i = 0; i < places.length; i++) {
      const p = places[i];
      data.push(lngX(p.longitude), latY(p.latitude), Infinity, i, -1, 1);
    }
    this.trees[this.maxZoom + 1] = data;
    for (let z = this.maxZoom; z >= this.minZoom; z--) {
      const upper = this.trees[z + 1];
      this.trees[z] = this.clusterLevel(upper === undefined ? [] : upper, z);
    }
  }

  /** 半径查询（原库为 KDBush.within） */
  private within(data: number[], x: number, y: number, r: number): number[] {
    const out: number[] = [];
    const rr = r * r;
    for (let i = 0; i < data.length; i += STRIDE) {
      const dx = data[i] - x;
      const dy = data[i + 1] - y;
      if (dx * dx + dy * dy <= rr) {
        out.push(Math.floor(i / STRIDE));
      }
    }
    return out;
  }

  /**
   * 单层聚类（等价 supercluster._cluster），邻域查询改用网格哈希。
   * 原库用 KDBush 做空间索引；这里之前退化成线性扫描（O(n²)），
   * 上千点会卡住主线程。改成按 r 分桶 + 3×3 邻域，复杂度降到 O(n·k)。
   */
  private clusterLevel(data: number[], zoom: number): number[] {
    const r = this.radius / (this.extent * Math.pow(2, zoom));
    const next: number[] = [];
    const rr = r * r;

    // 网格索引：cell 边长 = r，查 3×3 邻域即可覆盖半径 r
    const grid = new Map<string, number[]>();
    for (let i = 0; i < data.length; i += STRIDE) {
      const key = `${Math.floor(data[i] / r)}_${Math.floor(data[i + 1] / r)}`;
      const arr = grid.get(key);
      if (arr === undefined) {
        grid.set(key, [i]);
      } else {
        arr.push(i);
      }
    }

    for (let i = 0; i < data.length; i += STRIDE) {
      if (data[i + O_ZOOM] <= zoom) {
        continue;
      }
      data[i + O_ZOOM] = zoom;
      const x = data[i];
      const y = data[i + 1];

      const neighbors: number[] = [];
      const cx = Math.floor(x / r);
      const cy = Math.floor(y / r);
      for (let dx = -1; dx <= 1; dx++) {
        for (let dy = -1; dy <= 1; dy++) {
          const arr = grid.get(`${cx + dx}_${cy + dy}`);
          if (arr === undefined) {
            continue;
          }
          for (const idx of arr) {
            const ddx = data[idx] - x;
            const ddy = data[idx + 1] - y;
            if (ddx * ddx + ddy * ddy <= rr) {
              neighbors.push(Math.floor(idx / STRIDE));
            }
          }
        }
      }

      const numOrigin = data[i + O_NUM];
      let num = numOrigin;
      for (const nid of neighbors) {
        const k = nid * STRIDE;
        if (data[k + O_ZOOM] > zoom) {
          num += data[k + O_NUM];
        }
      }

      if (num > numOrigin && num >= this.minPoints) {
        let wx = x * numOrigin;
        let wy = y * numOrigin;
        const id = ((Math.floor(i / STRIDE)) << 5) + (zoom + 1) + this.points.length;
        for (const nid of neighbors) {
          const k = nid * STRIDE;
          if (data[k + O_ZOOM] <= zoom) {
            continue;
          }
          data[k + O_ZOOM] = zoom;
          const n2 = data[k + O_NUM];
          wx += data[k] * n2;
          wy += data[k + 1] * n2;
          data[k + O_PARENT] = id;
        }
        data[i + O_PARENT] = id;
        next.push(wx / num, wy / num, Infinity, id, -1, num);
      } else {
        for (let j = 0; j < STRIDE; j++) {
          next.push(data[i + j]);
        }
        if (num > 1) {
          for (const nid of neighbors) {
            const k = nid * STRIDE;
            if (data[k + O_ZOOM] <= zoom) {
              continue;
            }
            data[k + O_ZOOM] = zoom;
            for (let j = 0; j < STRIDE; j++) {
              next.push(data[k + j]);
            }
          }
        }
      }
    }
    return next;
  }

  private limitZoom(z: number): number {
    return Math.max(this.minZoom, Math.min(Math.floor(z), this.maxZoom + 1));
  }

  /** 取当前 zoom 层、bbox 内的节点（等价 supercluster.getClusters） */
  query(minLng: number, minLat: number, maxLng: number, maxLat: number, zoom: number): ClusterPoint[] {
    const z = this.limitZoom(zoom);
    const data = this.trees[z];
    const out: ClusterPoint[] = [];
    if (data === undefined) {
      return out;
    }
    const x1 = lngX(minLng);
    const x2 = lngX(maxLng);
    const y1 = latY(maxLat);
    const y2 = latY(minLat);
    const scale = scaleOf(zoom);

    for (let i = 0; i < data.length; i += STRIDE) {
      const x = data[i];
      const y = data[i + 1];
      if (x < x1 || x > x2 || y < y1 || y > y2) {
        continue;
      }
      const num = data[i + O_NUM];
      const nodeId = data[i + O_ID];
      if (num > 1) {
        // 不在 query 里展开成员（那是 O(n²)），点击时再调 leaves()
        // clusterId 低 5 位编码了生成它的 zoom，展开到 +1 层即可看到子节点
        const originZoom = ((nodeId - this.points.length) & 31) - 1;
        out.push({
          key: `c-${nodeId}`,
          lng: xLng(x),
          lat: yLat(y),
          count: num,
          name: `${num} 家`,
          scale: scale,
          placeId: 0,
          places: [],
          nodeId: nodeId,
          originZoom: originZoom
        });
      } else {
        const p = this.points[nodeId];
        if (p === undefined) {
          continue;
        }
        out.push({
          key: `p-${p.id}`,
          lng: p.longitude,
          lat: p.latitude,
          count: 1,
          name: p.name,
          scale: scale,
          placeId: p.id,
          places: [p],
          nodeId: nodeId,
          originZoom: -1
        });
      }
    }
    return out;
  }

  /** 展开某聚合点下的全部原始地点（等价 getLeaves），点击聚合点时调用 */
  leaves(clusterId: number): Place[] {
    return this.leavesOf(clusterId);
  }

  private leavesOf(clusterId: number): Place[] {
    const out: Place[] = [];
    // clusterId 低 5 位记录了生成它的 zoom
    const zoom = ((clusterId - this.points.length) & 31) - 1;
    if (zoom < 0 || zoom > this.maxZoom) {
      return out;
    }
    const data = this.trees[zoom];
    if (data === undefined) {
      return out;
    }
    for (let i = 0; i < data.length; i += STRIDE) {
      if (data[i + O_PARENT] !== clusterId) {
        continue;
      }
      const num = data[i + O_NUM];
      if (num > 1) {
        const deeper = this.leavesOf(data[i + O_ID]);
        for (const p of deeper) {
          out.push(p);
        }
      } else {
        const p = this.points[data[i + O_ID]];
        if (p !== undefined) {
          out.push(p);
        }
      }
    }
    return out;
  }
}

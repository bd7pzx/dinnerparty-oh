/**
 * POI 本地缓存。
 * 只缓存「坐标 + 名称 + id + 分类」（地图渲染与聚合够用），其它字段仍从线上拉。
 * 容量可配（20–10000，默认 2000），超出后按写入顺序淘汰最旧的。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Place } from '../model/Types';

export interface CachedPoi {
  id: number;
  name: string;
  category: string;
  lng: number;
  lat: number;
}

const STORE = 'poi_cache';
const K_LIST = 'list';
const K_ENABLED = 'enabled';
const K_LIMIT = 'limit';

export const CACHE_LIMIT_MIN: number = 20;
export const CACHE_LIMIT_MAX: number = 10000;
export const CACHE_LIMIT_DEFAULT: number = 2000;

export class PoiCache {
  private static store: preferences.Preferences | null = null;
  private static items: CachedPoi[] = [];
  private static enabled: boolean = true;
  private static limit: number = CACHE_LIMIT_DEFAULT;
  private static dirty: boolean = false;
  private static flushTimer: number = -1;

  /** 启动时调用一次；读不到就按空缓存工作 */
  static async init(ctx: common.UIAbilityContext): Promise<void> {
    if (PoiCache.store !== null) {
      return;
    }
    try {
      const opt: preferences.Options = { name: STORE };
      const store = await preferences.getPreferences(ctx, opt);
      PoiCache.store = store;
      PoiCache.enabled = store.getSync(K_ENABLED, true) as boolean;
      const lim = store.getSync(K_LIMIT, CACHE_LIMIT_DEFAULT) as number;
      PoiCache.limit = PoiCache.clampLimit(lim);
      const raw = store.getSync(K_LIST, '[]') as string;
      PoiCache.items = PoiCache.parse(raw);
    } catch (err) {
      PoiCache.store = null;
      PoiCache.items = [];
    }
  }

  private static clampLimit(n: number): number {
    if (isNaN(n) || n < CACHE_LIMIT_MIN) {
      return CACHE_LIMIT_MIN;
    }
    if (n > CACHE_LIMIT_MAX) {
      return CACHE_LIMIT_MAX;
    }
    return Math.round(n);
  }

  private static parse(raw: string): CachedPoi[] {
    const out: CachedPoi[] = [];
    try {
      const arr = JSON.parse(raw) as CachedPoi[];
      if (Array.isArray(arr)) {
        for (const it of arr) {
          if (it !== null && it !== undefined && typeof it.id === 'number') {
            out.push(it);
          }
        }
      }
    } catch (err) {
      // 损坏的缓存直接丢弃
    }
    return out;
  }

  static isEnabled(): boolean {
    return PoiCache.enabled;
  }

  static getLimit(): number {
    return PoiCache.limit;
  }

  static count(): number {
    return PoiCache.items.length;
  }

  static all(): CachedPoi[] {
    return PoiCache.items;
  }

  /** 缓存转 Place（只填渲染/聚合需要的字段） */
  static toPlaces(): Place[] {
    const out: Place[] = [];
    for (const it of PoiCache.items) {
      out.push({
        id: it.id,
        name: it.name,
        category: it.category,
        longitude: it.lng,
        latitude: it.lat
      });
    }
    return out;
  }

  static async setEnabled(v: boolean): Promise<void> {
    PoiCache.enabled = v;
    await PoiCache.persistFlag(K_ENABLED, v);
  }

  static async setLimit(n: number): Promise<void> {
    PoiCache.limit = PoiCache.clampLimit(n);
    // 上限调小后立即裁剪
    if (PoiCache.items.length > PoiCache.limit) {
      PoiCache.items = PoiCache.items.slice(PoiCache.items.length - PoiCache.limit);
    }
    await PoiCache.persistFlag(K_LIMIT, PoiCache.limit);
    PoiCache.scheduleFlush();
  }

  static async clear(): Promise<void> {
    PoiCache.items = [];
    PoiCache.dirty = true;
    await PoiCache.flush();
  }

  /** 写入一批地点；已存在的按最近使用移到末尾 */
  static put(places: Place[]): void {
    if (!PoiCache.enabled || places.length === 0) {
      return;
    }
    const index = new Map<number, number>();
    for (let i = 0; i < PoiCache.items.length; i++) {
      index.set(PoiCache.items[i].id, i);
    }
    for (const p of places) {
      const item: CachedPoi = {
        id: p.id,
        name: p.name,
        category: p.category,
        lng: p.longitude,
        lat: p.latitude
      };
      const at = index.get(p.id);
      if (at !== undefined) {
        PoiCache.items.splice(at, 1);
        index.clear();
        for (let i = 0; i < PoiCache.items.length; i++) {
          index.set(PoiCache.items[i].id, i);
        }
      }
      PoiCache.items.push(item);
    }
    if (PoiCache.items.length > PoiCache.limit) {
      PoiCache.items = PoiCache.items.slice(PoiCache.items.length - PoiCache.limit);
    }
    PoiCache.dirty = true;
    PoiCache.scheduleFlush();
  }

  private static async persistFlag(key: string, value: boolean | number): Promise<void> {
    const store = PoiCache.store;
    if (store === null) {
      return;
    }
    try {
      if (typeof value === 'boolean') {
        store.putSync(key, value);
      } else {
        store.putSync(key, value);
      }
      await store.flush();
    } catch (err) {
      // 持久化失败不影响内存态
    }
  }

  /** 写盘防抖，避免每个视野都同步落盘 */
  private static scheduleFlush(): void {
    if (PoiCache.flushTimer >= 0) {
      clearTimeout(PoiCache.flushTimer);
    }
    PoiCache.flushTimer = setTimeout(() => {
      PoiCache.flushTimer = -1;
      PoiCache.flush();
    }, 800);
  }

  private static async flush(): Promise<void> {
    const store = PoiCache.store;
    if (store === null || !PoiCache.dirty) {
      return;
    }
    PoiCache.dirty = false;
    try {
      store.putSync(K_LIST, JSON.stringify(PoiCache.items));
      await store.flush();
    } catch (err) {
      PoiCache.dirty = true;
    }
  }
}

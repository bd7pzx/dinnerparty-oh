/**
 * 东方饭联地图 · 数据模型
 * 依据 APK 2.2.4 逆向契约定义；字段命名与后端一致（snake_case 保留）。
 */

/** 评分四档，取值严格 1..4（实测 5/99 均被服务端拒绝） */
export enum RatingScore {
  STRONG_NO = 1,
  BELOW_AVERAGE = 2,
  ABOVE_AVERAGE = 3,
  STRONG_YES = 4
}

/** 管理员三级 + 普通用户 */
export enum AdminLevel {
  NONE = '',
  KOMACHI = 'KOMACHI', // 最低：普通用户管理 / 标记点 / 反馈 / 日志
  YOUMU = 'YOUMU',     // 中：+ QQ白名单 / 公告 / 展讯
  YUYUKO = 'YUYUKO'    // 超管：+ 全量用户管理 / 皮肤兑换码
}

export function parseAdminLevel(raw: string | null | undefined): AdminLevel {
  if (raw === 'YUYUKO') return AdminLevel.YUYUKO;
  if (raw === 'YOUMU') return AdminLevel.YOUMU;
  if (raw === 'KOMACHI') return AdminLevel.KOMACHI;
  return AdminLevel.NONE;
}

/** 用户 */
export interface User {
  id: string;
  username: string;
  admin_level: string | null;
  has_avatar: boolean;
  is_banned?: boolean;
  ban_reason?: string | null;
  ban_expires?: string | null;
  qq?: string;
  city?: string | null;
}

/** 与当前用户的关系（点赞/屏蔽判定） */
export interface Relation {
  self: boolean;
  can_block: boolean;
  blocked: boolean;
}

/** 地点（字段对齐服务端 /places/nearby 实测返回） */
export interface Place {
  id: number;
  name: string;
  category: string;
  longitude: number;
  latitude: number;
  /** 服务端可能为 null，此时用 province/city/district 拼接展示 */
  address?: string | null;
  description?: string;
  /** 注意：服务端返回的是 JSON 字符串，需 imagesOf() 解析 */
  exterior_images?: string | null;
  menu_images?: string | null;
  per_person_cost?: number | null;
  creator_id?: string;
  creator_name?: string;
  created_time?: string;
  updated_time?: string;
  updated_by?: string;
  updated_by_name?: string;
  province?: string;
  city?: string;
  district?: string;
  moderation_status?: string;
  rating_count?: number;
  rating_average?: number;
  rating_negative_count?: number;
  has_vector?: number;
}

/** 解析服务端下发的图片 JSON 字符串 */
export function imagesOf(p: Place): string[] {
  const raw = p.exterior_images;
  if (raw === undefined || raw === null || raw.length === 0) {
    return [];
  }
  try {
    const arr = JSON.parse(raw) as string[];
    if (Array.isArray(arr)) {
      return arr;
    }
  } catch (err) {
    // 非 JSON，忽略
  }
  return [];
}

/** 展示用地址：address 优先，否则省市区拼接（服务端这些字段可能是 null，必须判 null） */
export function addressOf(p: Place): string {
  const a = p.address;
  if (a !== undefined && a !== null && a.length > 0) {
    return a;
  }
  const parts: string[] = [];
  if (p.province !== undefined && p.province !== null && p.province.length > 0) {
    parts.push(p.province);
  }
  if (p.city !== undefined && p.city !== null && p.city.length > 0 && p.city !== p.province) {
    parts.push(p.city);
  }
  if (p.district !== undefined && p.district !== null && p.district.length > 0) {
    parts.push(p.district);
  }
  return parts.join(' ');
}

/** 评分汇总（服务端 summary 只有 count/average/tier，分布单独在 distribution 对象里） */
export interface RatingSummary {
  count: number;
  average: number;
  tier?: number;
}

/** 评分响应（mine/risk/estimate/quota 均在顶层） */
export interface RatingResponse {
  place_id?: number;
  summary: RatingSummary;
  mine: number | null;
  risk?: RiskInfo;
  estimate?: EstimateInfo;
  quota?: RatingQuota | null;
}

/** 贝叶斯估计（服务端下发） */
export interface EstimateInfo {
  prior_average: number;
  evidence_count: number;
  method: string;
}

/** 风控模型输出（服务端下发，实测存在） */
export interface RiskInfo {
  probability: number;
  threshold: number;
  model_version: string;
}

export interface RatingQuota {
  limit: number;
  used: number;
  remaining: number;
  place_counted: boolean;
  resets_at: number;
}

/** 分类（服务端返回对象数组，不是字符串数组） */
export interface Category {
  id: number;
  name: string;
  is_common?: boolean;
  sort_order?: number;
  created_by?: string | null;
  created_time?: string;
}

/** /places/random 用 {place: ...} 包裹 */
export interface RandomContainer {
  place: Place;
}

/** 分类值是「小吃, 快餐」这类多值串，按五种分隔符拆分（与原项目一致） */
export function splitCategory(s: string): string[] {
  const out: string[] = [];
  if (s === undefined || s === null) {
    return out;
  }
  let cur = '';
  for (let i = 0; i < s.length; i++) {
    const ch = s.charAt(i);
    if (ch === ',' || ch === '，' || ch === '/' || ch === '、' || ch === '|') {
      const t = cur.trim();
      if (t.length > 0) {
        out.push(t);
      }
      cur = '';
    } else {
      cur += ch;
    }
  }
  const last = cur.trim();
  if (last.length > 0) {
    out.push(last);
  }
  return out;
}

/** 口味六轴 */
export const TASTE_AXES: string[] = ['homestyle', 'noodles', 'hotpotBbq', 'dessert', 'drinks', 'foreign'];

export function tasteAxisLabel(axis: string): string {
  if (axis === 'homestyle') return '家常';
  if (axis === 'noodles') return '面食';
  if (axis === 'hotpotBbq') return '火锅烧烤';
  if (axis === 'dessert') return '甜品';
  if (axis === 'drinks') return '饮品';
  if (axis === 'foreign') return '异国';
  return axis;
}

export interface TasteAxis {
  key: string;
  value: number;
  basis: string;
  self_level: number;
  self_level_label: string;
}

/** 首页展示的口味近邻（x/y 由后端下发，前端零投影） */
export interface Neighbor {
  id: string;
  username: string;
  similarity: number;
  x: number;
  y: number;
  confidence: string;
  shared?: string[] | null;
}

export function sharedText(nb: Neighbor): string {
  const s = nb.shared;
  if (s === undefined || s === null || s.length === 0) {
    return '暂无共同偏好';
  }
  return s.join(' / ');
}

/** 饭局 */
export interface Dinner {
  id: number;
  title: string;
  description?: string;
  address?: string;
  start_time?: string;
  creator_id?: string;
  creator_name?: string | null;
  created_time?: string;
  updated_time?: string;
  cover?: string;
}

/** 行程站点（服务端可能缺字段） */
export interface JourneyStop {
  place_id: number;
  name: string;
  note?: string;
  day?: number;
  order?: number;
}

export interface Journey {
  id: string;
  title: string;
  start_date: string;
  end_date: string;
  stops?: JourneyStop[] | null;
  revision: number;
  public_id?: string;
  visibility?: string;
  cover_media_id?: string | null;
  updated_at?: string;
}

export function stopCount(j: Journey): number {
  const s = j.stops;
  if (s === undefined || s === null) {
    return 0;
  }
  return s.length;
}

export function stopNames(j: Journey): string {
  const s = j.stops;
  if (s === undefined || s === null || s.length === 0) {
    return '';
  }
  const names: string[] = [];
  for (const x of s) {
    names.push(x.name);
  }
  return names.join(' · ');
}

/** 行程能力开关（实测四项 + 版本号） */
export interface JourneyCapabilities {
  text_ai: boolean;
  vision_ai: boolean;
  amap_search: boolean;
  amap_export: boolean;
  version: string;
}

/** AI 生成任务状态机 queued -> running -> ready */
export interface JourneyJob {
  id: string;
  status: string;
  draft_id?: string;
  progress?: number;
  error?: string;
}

/** 收藏夹（服务端字段可能为 null，一律按可选处理） */
export interface Collection {
  id: string;
  title: string;
  is_public?: boolean;
  place_ids?: number[] | null;
  places?: Place[] | null;
  owner_id?: string;
}

export function collectionCount(c: Collection): number {
  const ids = c.place_ids;
  if (ids === undefined || ids === null) {
    return 0;
  }
  return ids.length;
}

/** 社区同意状态（version 单调递增，不可回退） */
export interface CommunityConsent {
  feedback: boolean;
  version: number;
}

/** 通知：服务端是 {notice: Notice|null} 包裹 */
export interface Notice {
  id: string;
  title: string;
  content: string;
  color_key: string;
  published_at?: string;
}

export interface NoticeContainer {
  notice: Notice | null;
}

/** 皮肤 */
export interface SkinOwned {
  id: string;
  name: string;
  unlocked_time: string;
}

export interface SkinState {
  active: string;
  owned: SkinOwned[];
}

/** 地区树（/places/regions） */
export interface RegionNode {
  name: string;
  count: number;
  bounds: number[];
  children?: RegionNode[];
}

/** 统一 API 错误载荷 */
export interface ApiError {
  error: string;
  requestId?: string;
  code?: string;
}

/** 登录结果 */
export interface LoginResult {
  user: User;
  token: string;
}

/** 打卡状态 */
export interface VisitStatus {
  enabled: boolean;
}

/** 打卡证据（题目由服务端下发，答案回传） */
export interface VisitEvidence {
  prompt: string;
  place_id: number;
}

/** 地图筛选条件 */
export interface PlaceFilter {
  keyword: string;
  category: string;
  region: string;
  minCost: number;
  maxCost: number;
}

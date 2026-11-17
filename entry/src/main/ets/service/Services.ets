/** 账号、地点、评分、收藏、饭局、社区、通知、皮肤 */
import { ApiClient, ApiResult, BodyKind, RequestOptions, formOf } from './ApiClient';
import {
  Category, Collection, Dinner, LoginResult, Neighbor, Notice, NoticeContainer, Place, RandomContainer,
  RatingQuota, RatingResponse, RatingSummary, RegionNode, RiskInfo, SkinState, TasteAxis, User, VisitStatus
} from '../model/Types';

function jsonBody(obj: Object): RequestOptions {
  return { body: JSON.stringify(obj), bodyKind: BodyKind.JSON };
}

interface CollectionBody {
  title: string;
  is_public: boolean;
}

interface TitleBody {
  title: string;
}

interface DrawBody {
  draw_id: string;
  radiusKm: number;
  consent_version: number;
}

interface RedeemBody {
  code: string;
}

interface DinnerBody {
  title: string;
  description: string;
  address: string;
  start_time: string;
}

export class AuthService {
  /** 登录：username + password + client[platform] + client[app_version] */
  static async login(username: string, password: string): Promise<ApiResult<LoginResult>> {
    return ApiClient.post<LoginResult>('/users/login', {
      body: formOf(username, password),
      bodyKind: BodyKind.FORM,
      auth: false,
      withRequestId: true,
      timeoutMs: 15000
    });
  }

  static async me(): Promise<ApiResult<UserContainer>> {
    return ApiClient.get<UserContainer>('/users/me');
  }

  /** 用户主页：user / taste / relation 都在顶层，游客态亦可读 */
  static async profile(userId: string): Promise<ApiResult<ProfileContainer>> {
    return ApiClient.get<ProfileContainer>(`/users/${userId}/profile`);
  }

  /** 续签：实测不刷新有效期，只返回同值 token */
  static async renew(): Promise<ApiResult<TokenContainer>> {
    return ApiClient.post<TokenContainer>('/users/me/session', { body: '{}', bodyKind: BodyKind.JSON });
  }

  static async logout(): Promise<ApiResult<Object>> {
    return ApiClient.post<Object>('/users/logout');
  }

  static async logoutAll(): Promise<ApiResult<Object>> {
    return ApiClient.post<Object>('/users/logout-all');
  }

  /** 修改地图设置（map_settings 为自由对象） */
  static async patchSettings(settingsJson: string): Promise<ApiResult<Object>> {
    return ApiClient.patch<Object>('/users/me/settings', {
      body: `{"map_settings":${settingsJson}}`,
      bodyKind: BodyKind.JSON
    });
  }

  /** 口味自评：level 为 1..4 */
  static async putTaste(axis: string, level: number): Promise<ApiResult<Object>> {
    return ApiClient.put<Object>('/users/me/taste', {
      body: `{"axis":"${axis}","level":${level}}`,
      bodyKind: BodyKind.JSON
    });
  }

  static async profileWidgets(widgetsJson: string): Promise<ApiResult<Object>> {
    return ApiClient.put<Object>('/users/me/profile', {
      body: `{"widgets":${widgetsJson}}`,
      bodyKind: BodyKind.JSON
    });
  }
}

export interface UserContainer {
  user: User;
}

export interface ProfileContainer {
  user: User;
  taste?: TasteAxis[];
  city?: string | null;
  widgets?: Object[];
}

export interface TokenContainer {
  token: string;
  upgraded?: boolean;
}

export class PlaceService {
  /**
   * 视野内地点。按原项目做法：请求范围取可视区 3×3 倍预取，
   * 同时上报真实视野（viewMinLng..viewMaxLat）供服务端排序。
   */
  static async nearby(minLng: number, minLat: number, maxLng: number, maxLat: number,
    viewMinLng?: number, viewMinLat?: number, viewMaxLng?: number, viewMaxLat?: number): Promise<ApiResult<Place[]>> {
    let q = `?minLng=${minLng.toFixed(6)}&minLat=${minLat.toFixed(6)}&maxLng=${maxLng.toFixed(6)}&maxLat=${maxLat.toFixed(6)}`;
    if (viewMinLng !== undefined && viewMinLat !== undefined && viewMaxLng !== undefined && viewMaxLat !== undefined) {
      q += `&viewMinLng=${viewMinLng.toFixed(6)}&viewMinLat=${viewMinLat.toFixed(6)}`;
      q += `&viewMaxLng=${viewMaxLng.toFixed(6)}&viewMaxLat=${viewMaxLat.toFixed(6)}`;
    }
    return ApiClient.get<Place[]>(`/places/nearby${q}`);
  }

    /**
   * 关键词搜索。服务端 /api/places/search/fast 是全文匹配，地名和分类 tag 都能命中
   * （实测「粤菜」「咖啡」「日料」都返回对应分类的店），客户端无需再补 tag 逻辑。
   */
  static async byKeyword(keyword: string, lat: number, lng: number): Promise<ApiResult<Place[]>> {
    const q = encodeURIComponent(keyword);
    return ApiClient.get<Place[]>(`/api/places/search/fast?q=${q}&limit=30&lat=${lat}&lng=${lng}`);
  }

  /**
   * 随机推荐。注意：服务端对空的 excludeIds 会返回 400「最近推荐地点参数无效」，
   * 所以没有排除项时不能带这个参数；坐标用调用方的当前地图中心。
   */
  static async random(lat: number, lng: number, radiusKm: number,
    excludeIds: number[]): Promise<ApiResult<RandomContainer>> {
    let q = `?lat=${lat}&lng=${lng}&radiusKm=${radiusKm}`;
    if (excludeIds.length > 0) {
      q += `&excludeIds=${excludeIds.slice(-2).join(',')}`;
    }
    return ApiClient.get<RandomContainer>(`/places/random${q}`);
  }

  static async detail(id: number): Promise<ApiResult<Place>> {
    return ApiClient.get<Place>(`/places/${id}`);
  }

  static async categories(): Promise<ApiResult<Category[]>> {
    return ApiClient.get<Category[]>('/categories');
  }

  static async regions(): Promise<ApiResult<RegionContainer>> {
    return ApiClient.get<RegionContainer>('/places/regions');
  }

  static async favorites(): Promise<ApiResult<Place[]>> {
    return ApiClient.get<Place[]>('/api/favorites');
  }

  static async addFavorite(id: number): Promise<ApiResult<Object>> {
    return ApiClient.post<Object>(`/api/favorites/${id}`);
  }

  static async removeFavorite(id: number): Promise<ApiResult<Object>> {
    return ApiClient.del<Object>(`/api/favorites/${id}`);
  }
}

export interface RegionContainer {
  regions: RegionNode[];
}

export class RatingService {
  static async get(placeId: number): Promise<ApiResult<RatingContainer>> {
    const r = await ApiClient.get<RatingResponse>(`/api/ratings/places/${placeId}`);
    return toRatingContainer(r);
  }

  /** 提交评分：score 1..4；request_id 作幂等键，confirm 不具否决力 */
  static async put(placeId: number, score: number, requestId: string): Promise<ApiResult<RatingContainer>> {
    const payload = `{"score":${score},"request_id":"${requestId}","confirm":true}`;
    const r = await ApiClient.put<RatingResponse>(`/api/ratings/places/${placeId}`, {
      body: payload,
      bodyKind: BodyKind.JSON
    });
    return toRatingContainer(r);
  }

  static async remove(placeId: number, requestId: string): Promise<ApiResult<RatingContainer>> {
    const r = await ApiClient.del<RatingResponse>(`/api/ratings/places/${placeId}`, {
      body: `{"request_id":"${requestId}"}`,
      bodyKind: BodyKind.JSON
    });
    return toRatingContainer(r);
  }
}

/** 评分展示容器：把服务端分布对象展平成定长数组（ArkTS 不支持索引访问） */
export interface RatingContainer {
  summary: RatingSummary;
  mine: number | null;
  risk?: RiskInfo;
  quota?: RatingQuota | null;
  dist: number[];
}

function parseDistribution(raw: string): number[] {
  const out: number[] = [0, 0, 0, 0];
  const at = raw.indexOf('"distribution"');
  if (at < 0) {
    return out;
  }
  const seg = raw.slice(at, at + 200);
  for (let k = 0; k < 4; k++) {
    const key = `"${k + 1}"`;
    const idx = seg.indexOf(key);
    if (idx < 0) {
      continue;
    }
    const colon = seg.indexOf(':', idx);
    if (colon < 0) {
      continue;
    }
    let j = colon + 1;
    let digits = '';
    while (j < seg.length) {
      const ch = seg.charAt(j);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
        j++;
      } else if (digits.length === 0 && (ch === ' ' || ch === '\t' || ch === '\n')) {
        j++;
      } else {
        break;
      }
    }
    out[k] = digits.length > 0 ? Number(digits) : 0;
  }
  return out;
}

function toRatingContainer(r: ApiResult<RatingResponse>): ApiResult<RatingContainer> {
  if (!r.ok || r.data === null) {
    return {
      ok: false, status: r.status, data: null, error: r.error,
      requestId: r.requestId, raw: r.raw
    };
  }
  const d = r.data;
  const c: RatingContainer = {
    summary: d.summary,
    mine: d.mine,
    risk: d.risk,
    quota: d.quota,
    dist: parseDistribution(r.raw)
  };
  return {
    ok: true, status: r.status, data: c, error: '',
    requestId: r.requestId, raw: r.raw
  };
}

export class DinnerService {
  static async list(): Promise<ApiResult<Dinner[]>> {
    return ApiClient.get<Dinner[]>('/dinners');
  }

  static async detail(id: number): Promise<ApiResult<Dinner>> {
    return ApiClient.get<Dinner>(`/dinners/${id}`);
  }

  static async create(title: string, description: string, address: string, startTime: string): Promise<ApiResult<Dinner>> {
    const b: DinnerBody = {
      title: title,
      description: description,
      address: address,
      start_time: startTime
    };
    return ApiClient.post<Dinner>('/dinners', jsonBody(b));
  }

  static async remove(id: number): Promise<ApiResult<Object>> {
    return ApiClient.del<Object>(`/dinners/${id}`);
  }
}

export class CommunityService {
  static async neighbors(): Promise<ApiResult<NeighborContainer>> {
    return ApiClient.get<NeighborContainer>('/api/community/neighbors');
  }

  static async collections(): Promise<ApiResult<CollectionContainer>> {
    return ApiClient.get<CollectionContainer>('/api/community/collections');
  }

  static async createCollection(title: string, isPublic: boolean): Promise<ApiResult<Collection>> {
    const b: CollectionBody = { title: title, is_public: isPublic };
    return ApiClient.post<Collection>('/api/community/collections', jsonBody(b));
  }

  static async updateCollection(id: string, title: string): Promise<ApiResult<Collection>> {
    const b: TitleBody = { title: title };
    return ApiClient.put<Collection>(`/api/community/collections/${id}`, jsonBody(b));
  }

  static async deleteCollection(id: string): Promise<ApiResult<Object>> {
    return ApiClient.del<Object>(`/api/community/collections/${id}`);
  }

  static async consent(): Promise<ApiResult<ConsentContainer>> {
    return ApiClient.get<ConsentContainer>('/api/community/consent');
  }

  /**
   * 保存发现设置。服务端契约（逆向 + 实测）：
   * PUT /api/community/consent  body {version, tags, discovery, feedback, research, research_choice}
   * version 必须回传当前值，缺失或过期服务端一律 409「设置已更新，请重新载入」；
   * research_choice 表示「研究授权是否与原值不同」。
   */
  static async putConsent(tags: string[], discovery: boolean, feedback: boolean,
    research: boolean, researchChoice: boolean, version: number): Promise<ApiResult<ConsentContainer>> {
    const tagsJson = JSON.stringify(tags);
    const body = `{"version":${version},"tags":${tagsJson},"discovery":${discovery},` +
      `"feedback":${feedback},"research":${research},"research_choice":${researchChoice}}`;
    return ApiClient.put<ConsentContainer>('/api/community/consent', {
      body: body,
      bodyKind: BodyKind.JSON
    });
  }

  /** 交互记录留存策略与计数 */
  static async feedbackStats(): Promise<ApiResult<FeedbackStats>> {
    return ApiClient.get<FeedbackStats>('/api/community/feedback');
  }

  /** 清除交互记录 */
  static async clearFeedback(): Promise<ApiResult<Object>> {
    return ApiClient.del<Object>('/api/community/feedback');
  }

  /** 「今天吃什么」——不是社区抽签 */
  static async draw(): Promise<ApiResult<DrawResult>> {
    const b: DrawBody = {
      draw_id: `draw-${Date.now()}`,
      radiusKm: 5,
      consent_version: 1
    };
    return ApiClient.post<DrawResult>('/api/community/draw', jsonBody(b));
  }
}

export interface NeighborContainer {
  neighbors?: Neighbor[] | null;
}

export interface CollectionContainer {
  collections?: Collection[] | null;
  favorites?: Place[] | null;
}

export interface ConsentContainer {
  feedback?: boolean;
  research?: boolean;
  discovery?: boolean;
  tags?: string[] | null;
  version: number;
}

export interface FeedbackCount {
  kind: string;
  count: number;
}

export interface FeedbackStats {
  retention_days: number;
  retention_policy_version?: string;
  research_purpose_version?: string;
  legacy_retention_days?: number;
  counts?: FeedbackCount[] | null;
}

export interface DrawResult {
  place: Place;
  draw_id: string;
}

export class MiscService {
  /** 公告：服务端返回 {notice: Notice|null} */
  static async notice(): Promise<ApiResult<NoticeContainer>> {
    return ApiClient.get<NoticeContainer>('/notices/current');
  }

  static async skins(): Promise<ApiResult<SkinState>> {
    return ApiClient.get<SkinState>('/api/skins/me');
  }

  static async redeem(code: string): Promise<ApiResult<SkinState>> {
    const b: RedeemBody = { code: code };
    return ApiClient.post<SkinState>('/api/skins/redeem', jsonBody(b));
  }

  static async visitStatus(): Promise<ApiResult<VisitStatus>> {
    return ApiClient.get<VisitStatus>('/api/visits/status');
  }
}

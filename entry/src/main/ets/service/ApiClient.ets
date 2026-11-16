/**
 * HTTP 客户端 —— 对齐 APK 逆向契约：
 *  · Bearer 鉴权（游客态不带 Authorization，公开接口照常可读）
 *  · request_id 走 query
 *  · 登录类表单为 application/x-www-form-urlencoded
 *  · 服务端「方法不匹配也返回 404」，故 404 不等价于端点不存在
 */
import { http } from '@kit.NetworkKit';
import { Store, APP_VERSION, CLIENT_PLATFORM } from '../common/Store';
import { newRequestId } from '../common/Util';
import { ApiError } from '../model/Types';

export interface ApiResult<T> {
  ok: boolean;
  status: number;
  data: T | null;
  error: string;
  requestId: string;
  /** 原始响应文本，供无法用接口表达的字段（如 JSON 对象键名）做二次解析 */
  raw: string;
}

export enum BodyKind {
  NONE = 0,
  JSON = 1,
  FORM = 2
}

export interface RequestOptions {
  body?: string;
  bodyKind?: BodyKind;
  auth?: boolean;
  withRequestId?: boolean;
  timeoutMs?: number;
}

function encodeForm(fields: Record<string, string>): string {
  const parts: string[] = [];
  for (const k of Object.keys(fields)) {
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(fields[k])}`);
  }
  return parts.join('&');
}

export function formOf(username: string, password: string): string {
  const fields: Record<string, string> = {};
  fields['username'] = username;
  fields['password'] = password;
  fields['client[platform]'] = CLIENT_PLATFORM;
  fields['client[app_version]'] = APP_VERSION;
  return encodeForm(fields);
}

function buildUrl(path: string, withRequestId: boolean): string {
  const base = Store.baseUrl.replace(/\/+$/, '');
  const p = path.startsWith('/') ? path : `/${path}`;
  let url = `${base}${p}`;
  if (withRequestId) {
    const sep = url.includes('?') ? '&' : '?';
    url += `${sep}request_id=${encodeURIComponent(newRequestId())}`;
  }
  return url;
}

function pickString(o: Object | string | ArrayBuffer | undefined): string {
  if (o === undefined || o === null) return '';
  if (typeof o === 'string') return o;
  if (o instanceof ArrayBuffer) {
    return '';
  }
  return JSON.stringify(o);
}

function extractError(status: number, raw: string): string {
  if (raw.length === 0) {
    return statusText(status);
  }
  try {
    const e = JSON.parse(raw) as ApiError;
    if (e.error !== undefined && e.error !== null && e.error.length > 0) {
      return e.error;
    }
  } catch (err) {
    // 非 JSON 响应，降级为状态码描述
  }
  return statusText(status);
}

export function statusText(status: number): string {
  if (status === 0) return '网络不可达';
  if (status === 401) return '登录状态已失效，请重新登录';
  if (status === 403) return '权限不足';
  if (status === 404) return '接口不存在或方法不被接受';
  if (status === 409) return '状态冲突，请重新载入';
  if (status === 410) return '资源已失效';
  if (status === 413) return '内容超过大小限制';
  if (status === 429) return '操作过于频繁，请稍后再试';
  if (status >= 500) return `服务器错误 ${status}`;
  return `请求失败 ${status}`;
}

export class ApiClient {
  static async get<T>(path: string, opts?: RequestOptions): Promise<ApiResult<T>> {
    return ApiClient.send<T>('GET', path, opts);
  }

  static async post<T>(path: string, opts?: RequestOptions): Promise<ApiResult<T>> {
    return ApiClient.send<T>('POST', path, opts);
  }

  static async put<T>(path: string, opts?: RequestOptions): Promise<ApiResult<T>> {
    return ApiClient.send<T>('PUT', path, opts);
  }

  static async patch<T>(path: string, opts?: RequestOptions): Promise<ApiResult<T>> {
    return ApiClient.send<T>('PATCH', path, opts);
  }

  static async del<T>(path: string, opts?: RequestOptions): Promise<ApiResult<T>> {
    return ApiClient.send<T>('DELETE', path, opts);
  }

  static async send<T>(method: string, path: string, opts?: RequestOptions): Promise<ApiResult<T>> {
    const o: RequestOptions = opts ?? {};
    const auth: boolean = o.auth !== false;
    const withRid: boolean = o.withRequestId === true;

    const url = buildUrl(path, withRid);
    const header: Record<string, string> = {};
    if (auth && Store.isLoggedIn()) {
      header['Authorization'] = `Bearer ${Store.token}`;
    }
    if (o.bodyKind === BodyKind.JSON) {
      header['Content-Type'] = 'application/json';
    } else if (o.bodyKind === BodyKind.FORM) {
      header['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
    }

    const req = http.createHttp();
    const timeout = o.timeoutMs ?? 12000;
    try {
      const resp = await req.request(url, {
        method: ApiClient.methodOf(method),
        header: header,
        extraData: o.body ?? '',
        connectTimeout: timeout,
        readTimeout: timeout,
        expectDataType: http.HttpDataType.STRING
      });
      const status = resp.responseCode;
      const raw = pickString(resp.result);
      const ok = status >= 200 && status < 300;
      if (!ok) {
        return {
          ok: false,
          status: status,
          data: null,
          error: extractError(status, raw),
          requestId: '',
          raw: raw
        };
      }
      let parsed: T | null = null;
      if (raw.length > 0) {
        try {
          parsed = JSON.parse(raw) as T;
        } catch (err) {
          parsed = null;
        }
      }
      return { ok: true, status: status, data: parsed, error: '', requestId: '', raw: raw };
    } catch (err) {
      const msg = err instanceof Error ? err.message : '网络请求异常';
      return { ok: false, status: 0, data: null, error: msg, requestId: '', raw: '' };
    } finally {
      req.destroy();
    }
  }

  private static methodOf(m: string): http.RequestMethod {
    if (m === 'POST') return http.RequestMethod.POST;
    if (m === 'PUT') return http.RequestMethod.PUT;
    if (m === 'DELETE') return http.RequestMethod.DELETE;
    if (m === 'PATCH') return http.RequestMethod.POST;
    return http.RequestMethod.GET;
  }
}

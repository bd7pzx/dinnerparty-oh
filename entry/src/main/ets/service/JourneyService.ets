/**
 * 行程服务 —— 复刻 APK 的四段式草稿链路：
 *   PUT /drafts/{id}（乐观锁）→ POST /drafts/{id}/rank（候选补全）
 *   → POST /drafts/{id}/map-preview（产出 preview_hash）→ POST /drafts/{id}/commit
 * 关键约束：preview_hash 缺失 / 过期 / 伪造一律 409 preview_stale；commit 后草稿转 410。
 */
import { ApiClient, ApiResult, BodyKind } from './ApiClient';
import { Journey, JourneyCapabilities, JourneyJob, JourneyStop } from '../model/Types';

export interface DraftState {
  id: string;
  title: string;
  start_date: string;
  end_date: string;
  stops: JourneyStop[];
  visibility: string;
  base_revision: number;
  draft_revision: number;
  preview_hash: string;
}

export interface DraftContainer {
  id: string;
  title: string;
  revision: number;
  draft_revision: number;
  base_revision: number;
}

export interface PreviewContainer {
  preview_hash: string;
  preview_id: string;
}

export interface JobContainer {
  id: string;
  status: string;
  progress: number;
  draft_id?: string;
  output?: Object;
  error?: string;
}

export class JourneyService {
  static newDraft(): DraftState {
    return {
      id: '',
      title: '',
      start_date: '',
      end_date: '',
      stops: [],
      visibility: 'private',
      base_revision: 0,
      draft_revision: 0,
      preview_hash: ''
    };
  }

  static async capabilities(): Promise<ApiResult<JourneyCapabilities>> {
    return ApiClient.get<JourneyCapabilities>('/api/journeys/capabilities');
  }

  static async list(): Promise<ApiResult<Journey[]>> {
    return ApiClient.get<Journey[]>('/api/journeys');
  }

  static async unfinished(): Promise<ApiResult<Object>> {
    return ApiClient.get<Object>('/api/journeys/unfinished');
  }

  static async detail(id: string): Promise<ApiResult<Journey>> {
    return ApiClient.get<Journey>(`/api/journeys/${id}`);
  }

  static async remove(id: string): Promise<ApiResult<Object>> {
    return ApiClient.del<Object>(`/api/journeys/${id}`);
  }

  /** 第一段：写草稿（upsert，id 由客户端生成） */
  static async putDraft(d: DraftState): Promise<ApiResult<DraftContainer>> {
    const stopsJson = JSON.stringify(d.stops);
    const body = `{"title":${JSON.stringify(d.title)},"start_date":"${d.start_date}",` +
      `"end_date":"${d.end_date}","stops":${stopsJson},"visibility":"${d.visibility}",` +
      `"base_revision":${d.base_revision},"draft_revision":${d.draft_revision}}`;
    return ApiClient.put<DraftContainer>(`/api/journeys/drafts/${d.id}`, {
      body: body,
      bodyKind: BodyKind.JSON
    });
  }

  /** 第二段：候选补全（有未确认站点时触发） */
  static async rank(draftId: string): Promise<ApiResult<Object>> {
    return ApiClient.post<Object>(`/api/journeys/drafts/${draftId}/rank`, {
      body: '{}',
      bodyKind: BodyKind.JSON
    });
  }

  /** 第三段：出预览，返回 preview_hash（确定性、无 nonce） */
  static async mapPreview(draftId: string, draftRevision: number): Promise<ApiResult<PreviewContainer>> {
    return ApiClient.post<PreviewContainer>(`/api/journeys/drafts/${draftId}/map-preview`, {
      body: `{"draft_revision":${draftRevision}}`,
      bodyKind: BodyKind.JSON
    });
  }

  /** 第四段：提交，必须带 preview_hash 与幂等键 */
  static async commit(draftId: string, previewHash: string, requestId: string): Promise<ApiResult<Journey>> {
    const body = `{"preview_hash":"${previewHash}","request_id":"${requestId}"}`;
    return ApiClient.post<Journey>(`/api/journeys/drafts/${draftId}/commit`, {
      body: body,
      bodyKind: BodyKind.JSON
    });
  }

  static async discard(draftId: string): Promise<ApiResult<Object>> {
    return ApiClient.del<Object>(`/api/journeys/drafts/${draftId}`);
  }

  /** AI 生成：202 + queued，之后轮询 jobs */
  static async generate(title: string, startDate: string, endDate: string, material: string): Promise<ApiResult<JobContainer>> {
    const body = JSON.stringify({
      title: title,
      start_date: startDate,
      end_date: endDate,
      material: material
    });
    return ApiClient.post<JobContainer>('/api/journeys/compose-drafts', {
      body: body,
      bodyKind: BodyKind.JSON
    });
  }

  static async job(jobId: string): Promise<ApiResult<JobContainer>> {
    return ApiClient.get<JobContainer>(`/api/journeys/jobs/${jobId}`);
  }

  /** 轮询直到 ready / failed，返回终态 */
  static async waitJob(jobId: string, onTick: (j: JobContainer) => void, maxTicks: number): Promise<JobContainer | null> {
    for (let i = 0; i < maxTicks; i++) {
      const r = await JourneyService.job(jobId);
      if (r.ok && r.data !== null) {
        onTick(r.data);
        if (r.data.status === 'ready' || r.data.status === 'failed') {
          return r.data;
        }
      }
      await JourneyService.sleep(i < 6 ? 2000 : 4000);
    }
    return null;
  }

  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 把草稿的 stops 按天分组，供 UI 渲染 */
  static groupByDay(stops: JourneyStop[]): Map<number, JourneyStop[]> {
    const map = new Map<number, JourneyStop[]>();
    for (const s of stops) {
      const day = s.day === undefined || s.day <= 0 ? 1 : s.day;
      const arr = map.get(day);
      if (arr === undefined) {
        map.set(day, [s]);
      } else {
        arr.push(s);
      }
    }
    return map;
  }
}

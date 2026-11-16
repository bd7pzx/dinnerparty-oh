/**
 * 到店打卡采样器 —— 复刻 APK 2.2.4 的 `visit-50m-10min-v1` 规则：
 *   距离 + 精度 ≤ 50m、精度 ≤ 25m、必须 GCJ-02、禁 IP 源、
 *   帧龄 ≤ 15s、≥ 11 帧、驻留跨度 > 10 分钟、断链 90s 重置、
 *   出圈立即清零、切后台终止、15 分钟尝试上限。
 * 题目由服务端下发，前端只回传 answer。
 */
import { ApiClient, ApiResult, BodyKind } from './ApiClient';
import { LatLng, distanceMeters } from '../common/Util';
import { VisitStatus } from '../model/Types';

export const RULE_VERSION: string = 'visit-50m-10min-v1';

export const DISTANCE_LIMIT_M: number = 50;
export const ACCURACY_LIMIT_M: number = 25;
export const MAX_FRAME_AGE_MS: number = 15000;
export const MIN_FRAMES: number = 11;
export const MIN_DWELL_MS: number = 10 * 60 * 1000;
export const GAP_RESET_MS: number = 90000;
export const SESSION_LIMIT_MS: number = 15 * 60 * 1000;

export enum VisitPhase {
  IDLE = 0,
  SAMPLING = 1,
  READY = 2,
  FAILED = 3,
  DONE = 4
}

export interface VisitSample {
  t: number;
  distance: number;
  accuracy: number;
  inside: boolean;
}

export interface VisitProgress {
  phase: VisitPhase;
  frames: number;
  dwellMs: number;
  dwellRatio: number;
  lastDistance: number;
  lastAccuracy: number;
  message: string;
}

export class VisitSession {
  private target: LatLng = { lng: 0, lat: 0 };
  private samples: VisitSample[] = [];
  private startedAt: number = 0;
  private lastFrameAt: number = 0;
  private phase: VisitPhase = VisitPhase.IDLE;
  private message: string = '';

  start(target: LatLng): void {
    this.target = target;
    this.samples = [];
    this.startedAt = Date.now();
    this.lastFrameAt = 0;
    this.phase = VisitPhase.SAMPLING;
    this.message = '正在记录位置…';
  }

  reset(): void {
    this.samples = [];
    this.startedAt = 0;
    this.lastFrameAt = 0;
    this.phase = VisitPhase.IDLE;
    this.message = '';
  }

  stop(reason: string): void {
    this.phase = VisitPhase.FAILED;
    this.message = reason;
  }

  /** 喂一帧定位结果；返回最新进度 */
  feed(pos: LatLng, accuracy: number, coordType: string, fromIp: boolean): VisitProgress {
    const now = Date.now();
    if (this.phase !== VisitPhase.SAMPLING) {
      return this.progress();
    }
    if (this.startedAt > 0 && now - this.startedAt > SESSION_LIMIT_MS) {
      this.stop('本次打卡已超时，请重新开始');
      return this.progress();
    }
    if (fromIp) {
      this.stop('定位来源不可用，请开启 GPS');
      return this.progress();
    }
    if (coordType !== 'GCJ02' && coordType !== 'gcj02') {
      this.stop('坐标系不匹配，无法记录');
      return this.progress();
    }
    if (!isFinite(accuracy) || accuracy <= 0 || accuracy > ACCURACY_LIMIT_M) {
      this.message = '定位精度不足，请到空旷处稍等';
      return this.progress();
    }
    const d = distanceMeters(pos, this.target);
    const inside = d + accuracy <= DISTANCE_LIMIT_M;
    if (!inside) {
      // 出圈：立即清零重来
      this.samples = [];
      this.startedAt = now;
      this.lastFrameAt = now;
      this.message = '已离开打卡范围，记录已重置';
      return this.progress();
    }
    if (this.lastFrameAt > 0 && now - this.lastFrameAt > GAP_RESET_MS) {
      this.samples = [];
      this.startedAt = now;
      this.message = '信号中断超过 90 秒，记录已重置';
    }
    this.samples.push({ t: now, distance: d, accuracy: accuracy, inside: inside });
    this.lastFrameAt = now;
    const p = this.progress();
    if (this.samples.length >= MIN_FRAMES && p.dwellMs > MIN_DWELL_MS) {
      this.phase = VisitPhase.READY;
      this.message = '驻留条件已满足，可以做现场确认';
    } else {
      this.message = `已记录 ${this.samples.length}/${MIN_FRAMES} 帧，还需驻留 ${Math.ceil((MIN_DWELL_MS - p.dwellMs) / 1000)} 秒`;
    }
    return this.progress();
  }

  progress(): VisitProgress {
    const frames = this.samples.length;
    const dwellMs = frames >= 2 ? this.samples[frames - 1].t - this.samples[0].t : 0;
    const last = frames > 0 ? this.samples[frames - 1] : null;
    return {
      phase: this.phase,
      frames: frames,
      dwellMs: dwellMs,
      dwellRatio: Math.min(1, dwellMs / MIN_DWELL_MS),
      lastDistance: last === null ? 0 : last.distance,
      lastAccuracy: last === null ? 0 : last.accuracy,
      message: this.message
    };
  }

  canConfirm(): boolean {
    const p = this.progress();
    return this.phase === VisitPhase.READY && p.frames >= MIN_FRAMES && p.dwellMs > MIN_DWELL_MS;
  }

  /** 提交到店证据，拿服务端下发的题目 */
  static async submitEvidence(placeId: number): Promise<ApiResult<EvidenceContainer>> {
    return ApiClient.post<EvidenceContainer>(`/api/visits/places/${placeId}/evidence`, {
      body: `{"rule_version":"${RULE_VERSION}"}`,
      bodyKind: BodyKind.JSON
    });
  }

  /** 回传现场确认答案（服务端判定，answer === "yes" 视为通过） */
  static async answer(placeId: number, id: string, answer: string): Promise<ApiResult<Object>> {
    return ApiClient.post<Object>(`/api/visits/places/${placeId}/answer`, {
      body: JSON.stringify({ id: id, answer: answer }),
      bodyKind: BodyKind.JSON
    });
  }

  static async status(): Promise<ApiResult<VisitStatus>> {
    return ApiClient.get<VisitStatus>('/api/visits/status');
  }
}

export interface EvidenceContainer {
  prompt: string;
  id: string;
}

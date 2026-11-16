/** 设备定位（游客态也可用，仅需位置权限） */
import { geoLocationManager } from '@kit.LocationKit';
import { ensureLocationPermission } from './Permission';
import { LatLng } from './Util';

export interface FixResult {
  ok: boolean;
  pos: LatLng | null;
  accuracy: number;
  message: string;
}

/** 取一次当前位置；先确保权限，失败返回可读原因 */
export async function getFix(): Promise<FixResult> {
  const granted = await ensureLocationPermission();
  if (!granted) {
    return { ok: false, pos: null, accuracy: 0, message: '未获得位置权限，无法定位到你附近' };
  }
  try {
    const req: geoLocationManager.CurrentLocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
      maxAccuracy: 200
    };
    const loc = await geoLocationManager.getCurrentLocation(req);
    return {
      ok: true,
      pos: { lng: loc.longitude, lat: loc.latitude },
      accuracy: loc.accuracy,
      message: ''
    };
  } catch (err) {
    const msg = err instanceof Error ? err.message : '定位失败';
    return { ok: false, pos: null, accuracy: 0, message: msg };
  }
}

/** 运行时权限申请（位置用于到店打卡判定） */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

export async function ensureLocationPermission(): Promise<boolean> {
  try {
    const ctx = getContext() as common.UIAbilityContext;
    const mgr = abilityAccessCtrl.createAtManager();
    const perms: Permissions[] = [
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION'
    ];
    const result = await mgr.requestPermissionsFromUser(ctx, perms);
    const codes = result.authResults;
    for (const c of codes) {
      if (c !== 0) {
        return false;
      }
    }
    return true;
  } catch (err) {
    return false;
  }
}

/**
 * 运动/握持感知权限。
 * - ohos.permission.DETECT_GESTURE 是 system_grant，装机即授予，这里只做校验；
 * - ohos.permission.ACTIVITY_MOTION 是 user_grant，仅作为 operatingHandChanged 的兜底。
 */
export async function ensureMotionPermission(): Promise<boolean> {
  try {
    const ctx = getContext() as common.UIAbilityContext;
    const mgr = abilityAccessCtrl.createAtManager();
    const tokenId = ctx.applicationInfo.accessTokenId;
    const perms: Permissions[] = [
      'ohos.permission.DETECT_GESTURE',
      'ohos.permission.ACTIVITY_MOTION'
    ];
    for (const p of perms) {
      const status = await mgr.checkAccessToken(tokenId, p);
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
    }
    const result = await mgr.requestPermissionsFromUser(ctx, ['ohos.permission.ACTIVITY_MOTION']);
    return result.authResults.length > 0 && result.authResults[0] === 0;
  } catch (err) {
    return false;
  }
}

export async function hasLocationPermission(): Promise<boolean> {
  try {
    const ctx = getContext() as common.UIAbilityContext;
    const mgr = abilityAccessCtrl.createAtManager();
    const tokenId = ctx.applicationInfo.accessTokenId;
    const status = await mgr.checkAccessToken(tokenId, 'ohos.permission.APPROXIMATELY_LOCATION');
    return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (err) {
    return false;
  }
}

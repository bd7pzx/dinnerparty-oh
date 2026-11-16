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

/**
 * 全局状态：会话、主题、筛选、缓存。
 * 使用 AppStorage 做跨页共享，preferences 做持久化。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Theme } from './Theme';
import { PlaceFilter, User } from '../model/Types';

const PREF_NAME: string = 'fanlian_store';

export class Store {
  private static pref: preferences.Preferences | null = null;

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (Store.pref === null) {
      Store.pref = await preferences.getPreferences(context, { name: PREF_NAME });
    }
    const token = Store.pref.getSync('token', '') as string;
    const username = Store.pref.getSync('username', '') as string;
    const nick = Store.pref.getSync('nickname', '') as string;
    const dark = Store.pref.getSync('dark', false) as boolean;
    const themeMode = Store.pref.getSync('themeMode', 'system') as string;
    const baseUrl = Store.pref.getSync('baseUrl', '') as string;
    const consent = Store.pref.getSync('consent', false) as boolean;

    Theme.dark = dark;
    AppStorage.setOrCreate<string>('token', token);
    AppStorage.setOrCreate<string>('username', username);
    AppStorage.setOrCreate<string>('nickname', nick);
    AppStorage.setOrCreate<boolean>('dark', dark);
    AppStorage.setOrCreate<string>('themeMode', themeMode);
    AppStorage.setOrCreate<string>('baseUrl', baseUrl.length > 0 ? baseUrl : DEFAULT_BASE);
    AppStorage.setOrCreate<boolean>('consent', consent);
    AppStorage.setOrCreate<number>('tabIndex', 0);
  }

  /** 主题模式：system 跟随系统 / light 浅色 / dark 深色 */
  static get themeMode(): string {
    return AppStorage.get<string>('themeMode') ?? 'system';
  }

  static set themeMode(v: string) {
    AppStorage.setOrCreate<string>('themeMode', v);
    Store.put('themeMode', v);
  }

  static get baseUrl(): string {
    return AppStorage.get<string>('baseUrl') ?? DEFAULT_BASE;
  }

  static set baseUrl(v: string) {
    AppStorage.setOrCreate<string>('baseUrl', v);
    Store.put('baseUrl', v);
  }

  static get token(): string {
    return AppStorage.get<string>('token') ?? '';
  }

  static set token(v: string) {
    AppStorage.setOrCreate<string>('token', v);
    Store.put('token', v);
  }

  static get username(): string {
    return AppStorage.get<string>('username') ?? '';
  }

  static set username(v: string) {
    AppStorage.setOrCreate<string>('username', v);
    Store.put('username', v);
  }

  static get nickname(): string {
    return AppStorage.get<string>('nickname') ?? '';
  }

  static set nickname(v: string) {
    AppStorage.setOrCreate<string>('nickname', v);
    Store.put('nickname', v);
  }

  static get dark(): boolean {
    return AppStorage.get<boolean>('dark') ?? false;
  }

  static set dark(v: boolean) {
    Theme.dark = v;
    AppStorage.setOrCreate<boolean>('dark', v);
    Store.put('dark', v);
  }

  static get consent(): boolean {
    return AppStorage.get<boolean>('consent') ?? false;
  }

  static set consent(v: boolean) {
    AppStorage.setOrCreate<boolean>('consent', v);
    Store.put('consent', v);
  }

  static isLoggedIn(): boolean {
    return Store.token.length > 0;
  }

  static logout(): void {
    Store.token = '';
    AppStorage.setOrCreate<User | null>('user', null);
    Store.username = '';
    Store.nickname = '';
  }

  private static put(key: string, value: string | boolean): void {
    if (Store.pref === null) return;
    Store.pref.putSync(key, value);
    Store.pref.flush();
  }
}

/** 默认后端：与 APK 逆向出的运行时配置一致 */
export const DEFAULT_BASE: string = 'https://www.dinnerparty.cc/backend';

/** 应用版本（对齐 APK 2.2.4 (1101)） */
export const APP_VERSION: string = '2.2.4 (1101)';
export const CLIENT_PLATFORM: string = 'harmony';

/** 默认筛选 */
export function emptyFilter(): PlaceFilter {
  return { keyword: '', category: '', region: '', minCost: 0, maxCost: 0 };
}

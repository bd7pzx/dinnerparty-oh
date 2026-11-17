import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';

const DOMAIN = 0x0000;
/** 避让区尺寸（vp），供页面用 padding 让开状态栏 / 底部导航条 */
const KEY_SAFE_TOP = 'safeTopVp';
const KEY_SAFE_BOTTOM = 'safeBottomVp';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testApp', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testApp', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testApp', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testApp', 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testApp', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    this.applyImmersive(windowStage);
  }

  /**
   * 沉浸式：
   *  1. setWindowLayoutFullScreen(true) 让内容延伸到状态栏与导航条之下；
   *  2. 系统栏设透明，内容透出；
   *  3. 读取避让区高度存入 AppStorage，页面里用 padding 保证内容落在安全区内；
   *  4. 监听 avoidAreaChange，旋转/分屏时动态更新。
   */
  private applyImmersive(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      this.mainWindow = win;
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#4A2438',
        navigationBarContentColor: '#4A2438'
      });
      this.readAvoidArea(win);
      win.on('avoidAreaChange', () => {
        this.readAvoidArea(win);
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testApp', 'applyImmersive failed: %{public}s', JSON.stringify(err));
    }
  }

  private readAvoidArea(win: window.Window): void {
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topPx = sys.topRect.height;
      const bottomPx = indicator.bottomRect.height > 0 ? indicator.bottomRect.height : sys.bottomRect.height;
      const topVp = density > 0 ? topPx / density : 0;
      const bottomVp = density > 0 ? bottomPx / density : 0;
      AppStorage.setOrCreate<number>(KEY_SAFE_TOP, topVp);
      AppStorage.setOrCreate<number>(KEY_SAFE_BOTTOM, bottomVp);
      hilog.info(DOMAIN, 'testApp', 'avoid area top=%{public}d vp, bottom=%{public}d vp',
        Math.round(topVp), Math.round(bottomVp));
    } catch (err) {
      hilog.error(DOMAIN, 'testApp', 'readAvoidArea failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    this.mainWindow = null;
    hilog.info(DOMAIN, 'testApp', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testApp', '%{public}s', 'Ability onForeground');
    // 通知页面恢复：地图 onResume + 重启轮询。只改一次值，避免重复触发
    if (AppStorage.get<boolean>('appForeground') !== true) {
      AppStorage.setOrCreate<boolean>('appForeground', true);
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testApp', '%{public}s', 'Ability onBackground');
    // 通知页面暂停：停掉轮询与定时器，避免后台堆积回调把主线程堵死
    if (AppStorage.get<boolean>('appForeground') !== false) {
      AppStorage.setOrCreate<boolean>('appForeground', false);
    }
  }
}

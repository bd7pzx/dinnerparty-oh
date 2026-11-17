# 东方饭联地图 · HarmonyOS 原生实现

依据 `dinnerparty-2.2.4-1101.apk` 的逆向结论，用 **ArkTS + ArkUI 原生组件**重写的 HarmonyOS 应用。
不内嵌 WebView，不使用任何前端框架产物，**不含离线/Mock 数据层**，所有数据实时取自服务端。

- 包名：`com.pzx.dinnerparty`
- targetSdk：26.0.0（HarmonyOS 7.0），compatibleSdkVersion：6.0.0(20)
- 地图：**高德地图（鸿蒙星河版地图 SDK）**

---

## 一、目录结构
```
entry/src/main/ets/
├── entryability/EntryAbility.ets      入口 Ability
├── common/
│   ├── Theme.ets                      设计令牌（绯色系 / 深色 / 圆角 / 阴影 / 评分档位）
│   ├── Store.ets                      会话与设置（AppStorage + preferences 持久化）
│   ├── Util.ets                       投影、Haversine、UUID、日期
│   ├── Permission.ets                 位置权限运行时申请
│   └── Location.ets                   设备定位（geoLocationManager）
├── model/Types.ets                    全部实体与枚举 + 真实字段解析（imagesOf / addressOf / splitCategory）
├── service/
│   ├── ApiClient.ets                  HTTP（Bearer、request_id、form-urlencoded、错误语义、raw 原文）
│   ├── Services.ets                   账号 / 地点 / 评分 / 收藏 / 饭局 / 社区 / 通知 / 皮肤
│   ├── VisitService.ets               到店打卡采样器（50m / 10min 反作弊全阈值）
│   └── JourneyService.ets             行程四段式草稿链路
├── view/
│   ├── Widgets.ets                    通用组件（卡片 / 标签 / 按钮 / 分布条 / 空态）
│   ├── AmapView.ets                   高德地图（MapViewComponent + 视野轮询 + Marker 点击）
│   ├── MapCanvas.ets                  自绘地图（高德不可用时的降级底图）
│   ├── MapTab.ets                     地图页：搜索 / 分类 / 今天吃什么 / 视野加载 / 浮层
│   ├── PlaceDetail.ets                详情：评分四档、到店打卡、收藏
│   ├── JourneyTab.ets                 行程页：能力开关 + 四段式提交 + 列表
│   ├── FavoritesTab.ets               收藏页（独立页签）：收藏地点 + 收藏夹管理
│   ├── CommunityTab.ets               同好页：口味星图 + 公开收藏夹 + 发现设置
│   └── ProfileTab.ets                 我的：登录 / 口味 / 设置 / 关于
└── pages/Index.ets                    主容器：隐私同意门 + 五页签（地图/行程/收藏/同好/我的）
```

---

## 二、地图：高德地图（默认）

### 2.1 依赖

```json5
// entry/oh-package.json5
"dependencies": {
  "@amap/amap_lbs_common": "11.2.1",
  "@amap/amap_lbs_map3d": "11.2.1"
}
```

初始化（`AmapView.ets`，顺序不可颠倒）：

```ts
MapsInitializer.updatePrivacyShow(AMapPrivacyShowStatus.DidShow, AMapPrivacyInfoStatus.DidContain, ctx);
MapsInitializer.updatePrivacyAgree(AMapPrivacyAgreeStatus.DidAgree, ctx);
MapsInitializer.initialize(ctx);
MapsInitializer.setApiKey(AMAP_KEY);
MapsInitializer.setInitCamera(lat, lng, zoom);

MapViewManager.getInstance().registerMapViewCreatedCallback((mapview?: MapView) => {
  mapview.onCreate();
  mapview.getMapAsync((map: AMap) => { /* 画点 / 定位 / 监听 */ });
});
```

UI 用 `MapViewComponent()` 原生组件，标记用 `MarkerOptions` + `AMap.addMarker()`，点击用 `setOnMarkerClickListener`。

### 2.2 Key

```ts
export const AMAP_KEY: string = 'f96314c579e55a67c27388e7b32d340e';
```

该 Key 取自 APK 清单，真机实测可用。若日后鉴权失败（底图空白 + 日志出现鉴权错误），
到 [高德控制台](https://console.amap.com/dev/key) 创建 Key 时选择 **HarmonyOS 平台**，并填入本应用签名 AppID：

```
com.pzx.dinnerparty_BHKqKyovVJXsyHIGSD55HlE6Qlw/z1Rae/CQYuevDFGHCLHeijolB9wltgu5PpzSO+wwDY1h09PocnoR8TQl40I=
```

> 换签名/换机器后 AppID 会变，用 `bm dump -n com.pzx.dinnerparty` 重新取。

### 2.3 视野驱动加载（按原项目做法）

高德 SDK 未导出 `OnCameraChangeListener` 类型，故用轮询 + 去抖：

1. `AmapView` 每 1.2 秒读 `getProjection().getVisibleRegion().latLngBounds`；
2. 西南/东北角变化即回调上层（`onRegion`）；
3. `MapTab.loadRegion()` 按**可视区 3×3 倍**预取，同时把真实视野作为 `view*` 参数上报：

```
GET /places/nearby?minLng&minLat&maxLng&maxLat          // 3× 预取范围
                   &viewMinLng&viewMinLat&viewMaxLng&viewMaxLat   // 真实视野
```

### 2.4 降级

`AmapView` 初始化失败时，地图区右上角可一键切到自绘底图（`MapCanvas`，Canvas 绘制的街区网格 + 分类色标 marker），保证任何环境都能继续用。

---

## 三、数据层：只有服务端

- **没有离线数据、没有 Mock 路由**（`MockData.ets` / `MockRouter.ets` 已删除）。
- 游客态（未登录）也能读公开接口：地点、饭局、公告、分类、地区、口味近邻等。
- 请求失败不做本地兜底，直接显示服务端错误或网络错误。
- `ApiClient` 会把原始响应文本一并返回（`ApiResult.raw`），用于解析 ArkTS 无法直接索引的 JSON 对象键名（如评分分布 `{"1":0,…,"4":1}`）。

真实契约对齐点（实测）：

| 端点 | 结构 |
|---|---|
| `/notices/current` | `{"notice": Notice|null}` 包裹 |
| `/api/ratings/places/{id}` | `summary{count,average,tier}` + 顶层 `mine / risk / estimate / quota` |
| `/places/nearby` | 数组；`exterior_images` 是 **JSON 字符串**，`address` 可能为 null（用 province/city/district 拼） |
| `/places/random` | `{"place": Place}` 包裹 |
| `/categories` | 对象数组 `[{id,name,is_common,sort_order}]` |
| `category` 字段 | 多值串「小吃, 快餐」，按 `[,，/、\|]` 拆分 |

---

## 四、业务规则（与逆向结论一一对应）

| 结论 | 落点 |
|---|---|
| 评分严格 1–4，`confirm:false` 仍落库 | `PlaceDetail.rate()` / `RatingService.put()` |
| 风控 `risk{probability,threshold,model_version}` 与 `quota` 下发 | 详情页展示概率、阈值、今日剩余次数 |
| 打卡 `visit-50m-10min-v1`：50m、精度 25m、≥11 帧、驻留 >10min、断链 90s 重置、出圈清零、15min 上限 | `VisitService.VisitSession` |
| 题库由服务端下发，前端回 `answer` | `VisitSession.submitEvidence()` / `answer()` |
| 行程四段式：PUT 草稿 → rank → map-preview（出 hash）→ commit | `JourneyService` / `JourneyTab.runPipeline()` |
| `preview_hash` 缺失/过期 → 409 `preview_stale` | 提交前强校验，页面输出步骤日志 |
| `/capabilities` 四开关 + `journey-v1` | 行程页能力 chips |
| `/neighbors` 是口味近邻，x/y 由后端下发 | `CommunityTab.drawStar()` 仅线性映射 |
| 「今天吃什么」= `POST /api/community/draw` | `MapTab.drawOne()` |
| 登录 `username+password+client[platform]+client[app_version]`，`request_id` 在 query | `ApiClient.formOf()` |
| 服务端方法不匹配也返 404 | `ApiClient.statusText()` 文案 |
| 无成长体系（无 level/exp/quest/badge/fog） | 未实现，模型里也没有 |

---

## 五、收藏与发现设置

### 5.1 收藏（独立页签）

底部导航第 3 项「收藏」，对应 `FavoritesTab.ets`：

- **我收藏的地点**：`GET /api/favorites`，展示名称 / 分类 / 评分均值 / 人均 / 地址，可「取消收藏」（`DELETE /api/favorites/{id}`），点击进详情。
- **收藏夹**：`GET|POST|PUT|DELETE /api/community/collections`，支持新建、删除；提示文案沿用原项目「收藏夹默认私密，公开后可以让他人看见」。

### 5.2 同好页的两个分段

与原项目一致：`公开收藏夹` / `发现设置`。

### 5.3 发现设置（文案与字段同原项目）

字段来自 `GET /api/community/consent`，实测返回：

```json
{"feedback":true,"research":true,"discovery":true,"tags":[],"version":0}
```

| 项 | 说明 |
|---|---|
| 兴趣标签 | 逗号分隔，最多 20 个（`tags`） |
| `discovery` | 允许按我的口味匹配同好，并向其他用户展示我的用户名、兴趣标签和公开收藏夹 |
| `feedback` | 记录搜索、可见结果、点选、收藏、纠错及定位推断的到访；定位采样仅在前台进行 |
| `research` | 允许将这些交互记录用于改进用户体验 |
| 交互记录 | `GET /api/community/feedback` 返回 `retention_days`（实测 90）与各 `kind` 计数 |
| 清除交互记录 | `DELETE /api/community/feedback` |

保存走 `PUT /api/community/consent`：

```json
{"version":2,"tags":[],"discovery":true,"feedback":true,"research":true,"research_choice":false}
```

> **`version` 必须回传当前值**。缺失或过期时服务端一律返回 409「设置已更新，请重新载入」——
> 这是实测踩到的坑，初次实现漏了 `version`，点保存就被服务端拒绝；补上后 `version` 正常 1 → 2 递增。

`research_choice` 表示「研究授权相对原值是否变化」，用于服务端记录授权变更事件。

---

```powershell
devecocli build                        # 构建
devecocli check lint                   # 代码检查
devecocli run --device <serial>        # 构建+安装+拉起
devecocli auth login                   # 首次签名需登录华为开发者账号
devecocli signature generate           # 生成调试签名
```

---

## 六、点聚合（跟随原项目）

### 6.1 算法：直接移植 supercluster

原项目用的是 [supercluster](https://github.com/mapbox/supercluster)。这里把它的 v8 核心逻辑移植成 ArkTS
（`common/Cluster.ets`），参数照抄原项目：

```
radius = 68px, extent = 512, maxZoom = 16, minPoints = 2
```

移植内容：Web 墨卡托 `lngX/latY` 双向投影、从 maxZoom 向下逐层聚类、`r = radius / (extent · 2^zoom)`
半径聚合、按点数加权求中心、`clusterId = (i << 5) + (zoom+1) + points.length` 的编解码、
以及按 `parent` 链展开成员（等价 `getLeaves`）。

原库依赖 KDBush 空间索引，这里改成线性扫描（地点百级规模足够），其余逻辑一致。

### 6.2 多尺度

聚合粒度由 zoom 决定，同时在上图右上角显示当前尺度：

| zoom | 尺度 | 效果 |
|---|---|---|
| ≥16 | — | 全部单点 |
| 13–16 | 街区 | 约 1km 内合并 |
| 11–13 | 区镇 | 约 5km 内合并 |
| 9–11 | 市 | 约 20km 内合并 |
| <9 | 省 | 大范围合并 |

### 6.3 标记样式（取自网页端）

网页端（`www.dinnerparty.cc`）当前构建里，标记图与尺寸常量是：

```js
const Sf="/assets/yes-CZX7drg2.png", kf="/assets/no-D523jddQ.png", _f="/assets/union-GxmyVaJg.png";
dy = {width:36, height:43}   // 地点
my = {width:36, height:52}   // 聚合
fy = 44                      // 最小点击区
```

`union-GxmyVaJg.png` 实际是 2481×3508 的大图，水滴本体只占中间 905×1295 的区域
（比例 0.699，正好等于 36:52）。直接用会让水滴缩得很小、位置也偏，
所以已裁掉四周留白并重采样为 `rawfile/marker_cluster.png`（108×156）。

数量显示：

- 位置：水滴圆心（原 CSS `--skin-marker-count-x/y` 的 54% / 30% 换算到裁剪图后约 50% / 36%）
- 颜色：深色 `#2B2440`
- 文本：`<1000` 原样、`<10000` 取一位小数 k（`1.2k`）、否则整数 k
- 字号：位数 ≤2 → 20、=3 → 16、>3 → 13，再乘聚合缩放
- 聚合缩放：`1 + min(0.55, 0.09 · log2(n/2)) · (0.3/0.55)`，最大 1.3 倍

### 6.4 入场动画

已移除。高德 Marker 的原生 `ScaleAnimation` / `AlphaAnimation` 在标记数量多时仍会造成掉帧，
权衡后放弃入场动画，标记直接呈现，优先保证缩放与拖动流畅。

网页端的动画是 rAF 逐帧改 transform 做位置插值（`merge 260 / reposition 220 / fadeIn 160`），
高德 Marker 不支持逐帧定位，无法等价移植。

### 6.5 性能

几处会导致卡顿的实现都已修掉：

- **不再 `map.clear()` 全量重建**：按 key 增量 diff，只增删差集；数量变化时 `setIcon` 原地换图。
- **图标并行预取**：`fromView` 是异步渲染，串行 `await` 会让标记一个个「排队出现」；
  改为先 `Promise.all` 批量准备好图标，再一次性建 marker。
- **后台预热 2~40 的聚合图标**：进地图 1.5s 后异步生成并缓存，缩放换级时直接命中。
- **聚类只在数据变化时做**：`load()` 用地点集合签名缓存，缩放/平移只走 `query()`（O(n) 扫描）。
- **`query()` 不展开成员**：`leaves()` 改为点击聚合点时才递归展开（之前是 O(n²)）。
- **zoom 取整参与去抖**：缩放中的小数抖动不再触发重新聚合。

### 6.6 交互

- **分类标签三态**：点一次「只看该分类」（主色底），再点一次「排除该分类」（警示色底 + 白边），
  第三次恢复。点「全部」清空所有筛选；选中任一标签时「全部」自动取消高亮。
- **点聚合水滴**：以该水滴为中心放大地图到 `originZoom + 1`，
  即该聚合拆开后的下一层（clusterId 低 5 位编码了生成它的 zoom，直接解码即可）。
- **点地点标记**：底部弹出信息卡（名称 / 分类评分 / 地址 / 看详情）。
- **点地图空白处**：收起底部信息卡。高德的 `OnMapClickListener` 在命中底图 POI 时不回调，
  所以另加了一层透明点击层（仅信息卡显示时挂载），保证任意空白位置都能关闭。
- **详情浮层**：自带「关闭」按钮，高度 68%，上方仍留出地图区域。

> ArkUI 依赖追踪的坑：`PillTag` 的 `state` 原本是普通成员变量，父组件重跑 build 时子组件不更新，
> 表现为「点击确实触发（日志可见）但界面不变」；改成 `@Prop` 后才真正驱动 UI。
> 同理 `filtered().length` 这类在 build 里调方法读 `@State` 的写法不会被追踪，
> 已改为把结果预计算进 `shownCount` / `catStates` 状态变量。

### 6.7 已修复：点标记闪退

`addressOf()` 里 `province / city / district` 只判了 `undefined`，服务端这些字段可能是 `null`，
点开标记时触发 `Cannot read property length of null`，进程被拉起。已统一补 `null` 判断。

### 6.8 已修复：部分聚合点只有数字没有水滴

`BitmapDescriptorFactory.fromView()` 是异步截帧，而 `Image($rawfile(...))` 默认异步解码，
截帧时图片还没就绪，于是只渲染出 `Text`。表现为 11、12 这类数量较大的聚合点只有一串数字。
给标记里的 `Image` 加 `.syncLoad(true)` 后消失。

### 6.9 已修复：「今天吃什么」不可用

两个问题叠在一起：

- 请求里 `excludeIds` 为空时仍拼成 `&excludeIds=`，服务端对空值直接返回 400
  「最近推荐地点参数无效」。改为没有排除项时不带该参数（实测：不带 → 200，空值 → 400）。
- 经纬度是硬编码的 `23.12 / 113.25`，与当前地图位置无关。改为传当前地图中心。
- 顺带加上：抽到结果后把地图中心移到该店坐标（`centerLat/centerLng` 触发 AmapView 的
  `@Watch` 相机移动），底部信息卡同步显示这家店。
- 缩放也跟着走：`targetZoomFor(placeId)` 从 13 层逐级往上查 supercluster，
  取该店第一次以单点（`count === 1`）出现的层级作为目标 zoom，
  保证抽到的店一定在屏幕上单独显示，而不是被合进聚合水滴。

### 6.10 用户当前位置小圆点

- 位置来自 `common/Location.ets` 的 `getFix()`（`geoLocationManager.getCurrentLocation`），
  `MapTab` 启动时定位一次，结果同时写入 `centerLat/centerLng`（相机）和 `userLat/userLng`（圆点）。
- `AmapView` 用 `@Prop @Watch('onUserMoved')` 接收坐标，画一个独立 Marker：
  直径 6vp、`borderRadius` 做圆、颜色 `#0A59F7`（即 `#ff0a59f7`）、白色 1.2vp 描边 + 淡蓝投影。
- 圆点走 `BitmapDescriptorFactory.fromView` 生成（纯矢量，不加载图片），
  锚点设为 `(0.5, 0.5)` 让圆心对齐坐标。
- 它不参与聚合、不会被 `syncMarkers` 的差集删除，定位失败（`userLat === 0`）时不创建。
- 没有使用高德内置的 `setMyLocationEnabled` 定位图层：那套需要自己实现 `LocationSource`
  喂系统定位，且内置样式是水滴形 marker，与「小圆点」的要求不符。

> 冷启动时 `fromView` 渲染管线尚未就绪，生成会失败，之前会退回高德默认的蓝水滴图标。
> 现在做了三层兜底：失败延迟 80ms 重试一次 → 仍失败则用 `fromRawfilePathSync('marker_cluster.png')`
> 的**无数字水滴图**兜底（至少形状正确）→ 后台预热 2~40 结束后调用 `refreshClusterIcons()`，
> 把兜底图标换成带数字的。

### 6.11 搜索结果卡片

搜索走 `GET /api/places/search/fast?q&limit=30&lat&lng`（坐标用当前地图中心，不再是硬编码）。
服务端是全文匹配，**地名和分类 tag 都能命中**（实测「粤菜」「咖啡」「日料」均返回对应分类的店），
所以客户端没有额外补 tag 检索。

- 输入框带 600ms 防抖，输入即搜，不必按回车；
- 结果按到用户位置（未定位时用地图中心）的距离**从近到远**排序，卡片显示 `序号/总数` 与距离；
- 底部用 `Swiper` 卡片呈现，样式与地点详情卡片一致，可左右滑动；
- `onChange` 时把相机移到该卡片对应坐标；
- **切换卡片不重新拉接口**：`moveToPlace()` 记录 `silentUntil = now + 1.6s`，
  `onRegion` 在该时间窗内只重算聚合、跳过 `loadRegion()`，保证滑动流畅。

### 6.12 POI 本地缓存

`common/PoiCache.ets`，preferences 存储（`poi_cache`）。

- **只存 `id / name / category / lng / lat`**，其余字段（地址、图片、人均、评分）一律仍从线上拉；
- 容量可配 **20–10000，默认 2000**；超出后按写入顺序淘汰最旧的，命中已有点会移到末尾（近似 LRU）；
- 写入 800ms 防抖，避免每个视野都同步落盘；
- **启动顺序**：先 `PoiCache.init()` → 若有缓存直接铺到地图（避免白屏）→ 再延迟 1.2s 拉线上覆盖；
  没有缓存时才立即请求。这样缓存能覆盖时不会在启动瞬间打网络；
- `MapTab.loadRegion()` 与 `search()` 成功后都会 `PoiCache.put()`。

「我的」页新增**地点缓存**卡片：启用开关、上限数字输入（居中显示）+「应用」、当前已缓存数量、「清除」。
开关与上限都即时持久化，上限调小会立刻裁剪已有缓存。

> 顺带把地图右上角「高德地图 / 街区 / N 家」三个药丸的 `cardShadow()` 去掉了，只保留底色圆角。

---

## 七、沉浸式 · 悬浮导航 · 深色模式

### 7.1 沉浸式与安全区

`EntryAbility.applyImmersive()`：

```ts
win.setWindowLayoutFullScreen(true);            // 内容延伸到状态栏/导航条之下
win.setWindowSystemBarProperties({              // 系统栏透明
  statusBarColor: '#00000000', navigationBarColor: '#00000000',
  statusBarContentColor: fg, navigationBarContentColor: fg
});
```

避让区高度由 `getWindowAvoidArea(TYPE_SYSTEM / TYPE_NAVIGATION_INDICATOR)` 读取并换算成 vp，
写入 `AppStorage('safeTopVp' / 'safeBottomVp')`，同时监听 `avoidAreaChange` 动态更新。

真机实测：`top = 39vp，bottom = 28vp`。

页面侧：

- 内容层 `.expandSafeArea([SafeAreaType.SYSTEM], [TOP, BOTTOM])` 让背景铺到状态栏下；
- 顶栏 `padding.top = safeTop + 8`；
- 内容区 `padding.bottom = 64(导航高) + 10(间距) + safeBottom`，保证既不遮挡也落在安全区内。

### 7.2 悬浮导航栏（UIDesignKit 官方方案）

参考华为开发者联盟《给 APP 接入鸿蒙 6.1 的「悬浮导航 + 沉浸光感」》，不使用手搓胶囊，
而是用 **`HdsTabs` 的 `barFloatingStyle` + `systemMaterialEffect`**：

```ts
import { hdsMaterial, HdsTabs, HdsTabsController, SystemMaterialParams } from '@kit.UIDesignKit';

HdsTabs({ controller: this.tabsController, index: this.currentTab }) { /* 5 个 TabContent */ }
  .barPosition(BarPosition.End)
  .barMode(BarMode.Fixed)
  .scrollable(false)
  .animationDuration(240)
  .barHeight(60)
  .barOverlap(true)                       // 内容延伸到栏下方
  .barFloatingStyle({
    barSideMargin: 16,                    // 左右留白
    barBottomMargin: this.safeBottom + 12,// 距底间距，含安全区
    thermoCtrl: true,                     // 温控降级
    barOpacity: 1,
    systemMaterialEffect: this.materialParams()   // 沉浸光感
  })
  .onChange((i: number) => { this.currentTab = i; })
```

沉浸光感按设备能力选级（同官方做法）：

```ts
const types = hdsMaterial.getSystemMaterialTypes();
this.materialLevel = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0
  ? hdsMaterial.MaterialLevel.SMOOTH      // 不支持 IMMERSIVE 时降级
  : hdsMaterial.MaterialLevel.ADAPTIVE;
```

切换动画沿用官方 tabBar 写法：选中项 `scale 1.06 / translate -2 / opacity 1`，
`animation({ duration: 320, curve: curves.springMotion() })`，是非线性的弹簧曲线。

内容侧：`barOverlap(true)` 让页面延伸到栏下，各页统一 `padding.bottom = 92 + safeBottom`，
保证末尾内容不被悬浮栏压住，同时让地图底边与悬浮栏之间留出呼吸间距。

### 7.3 第 5 个页签：登录后显示头像

- 未登录：`我 / 我的`
- 已登录：圆形头像 + 用户名（如「冬瓜」）
- 头像地址与逆向结论一致：`{backend}/users/{id}/avatar`，
  有自定义头像加 `?t=<ts>` 破缓存，否则 `?fallback=default`。

### 7.4 深色模式（与地图同步，支持跟随系统）

颜色不在代码里硬编码，而是**全部走 `app.color` 资源**，`base/` 与 `dark/` 两套：

```
entry/src/main/resources/base/element/color.json
entry/src/main/resources/dark/element/color.json
```

- 组件里统一用 `$r('app.color.xxx')`（共替换 177 处引用）；
- 三种模式并存（`Store.themeMode`）：`system` 跟随系统（`COLOR_MODE_NOT_SET`）、`light`、`dark`；
- 切换用系统级 `applicationContext.setColorMode(...)`，由系统重载资源配置，**整棵树即时重绘**，不是重启生效；
- 启动时也按已保存偏好调用一次，避免重启后主题与开关不一致；
- 系统栏图标随主题切换明暗，保持可读；
- **地图同步**：`AmapView` 用 `@StorageProp('dark') @Watch` 监听，切换时 `setMapType(MAP_TYPE_NIGHT / MAP_TYPE_NORMAL)`，UI 与底图风格一致。

> 走过的弯路：最初把颜色放在静态 `Theme` 表里，切换后 ArkUI 只更新引用了状态变量的节点，
> 页面不会整体重绘；试过 `router.replaceUrl` 重载页面，又出现旧页面半透明叠加的转场残留。
> 最终采用资源颜色 + `setColorMode`，才是官方正确解法。

---

```powershell
devecocli build                        # 构建
devecocli check lint                   # 代码检查
devecocli run --device <serial>        # 构建+安装+拉起
devecocli auth login                   # 首次签名需登录华为开发者账号
devecocli signature generate           # 生成调试签名
```

---

## 八、应用图标

图标取自原项目的 `assets/public/logo.png`（1832×1833，粉紫底 + 角色剪影 + 定位针），
按鸿蒙分层图标规格生成：

- `AppScope/resources/base/media/background.png`、`entry/.../background.png`：logo 重采样 1024×1024
- `foreground.png`：1024×1024 透明层（logo 本身已是完整图标，不再叠前景）
- `entry/.../startIcon.png`：512×512，用于启动窗口

`layered_image.json` 维持引用 `$media:background` + `$media:foreground`，
`app.json5` / `module.json5` 的 `icon` 指向 `$media:layered_image`。

---

## 九、真机验证状态（HUAWEI Mate 70 Pro）
- 隐私同意门 → 主界面，顶栏显示「游客模式 · 未登录」
- 地图页：高德底图正常出图、按定位居中（实测中山）、真实店铺标记、分类 chips 来自 `/categories`
- **视野驱动生效**：拖动地图后按新区间重新请求，标记数随视野变化（20 → 41 → 37）
- 地点详情：真实字段（分类多值、人均、评分均值），评分 1–4 与打卡规则展示
- 行程页：四能力开关、四段式表单、候选店、已有行程
- 同好页：口味星图 + 30 位真实近邻（后端下发坐标）+ 公开收藏夹 / 发现设置双分段
- 收藏页：收藏地点列表 + 收藏夹管理，独立成页签
- 发现设置：三个授权开关 + 兴趣标签 + 交互记录 17 条（真实）+ 90 天留存说明；保存后 `version` 1 → 2
- 布局稳定：加载提示与选中卡片均为地图内浮层，不再挤压地图区域
- 沉浸式：内容铺到状态栏下，避让区实测 `top 39vp / bottom 28vp`，悬浮栏浮在内容之上且不越安全区
- 悬浮导航：毛玻璃胶囊 + 滑动药丸（`springMotion` 非线性）+ 高光渐变与彩色投影；药丸随页签滑动
- 深色模式：`setColorMode` 即时整树重绘，切换后**地图同步夜间图**，切回浅色恢复日景，系统栏图标明暗自适应
- 构建产物：`entry/build/default/outputs/default/entry-default-signed.hap`

### 收尾精简

按需求移除的界面元素：

- 行程页顶部「行程工作台」卡片（能力开关与流程说明）—— 直接进入「新建一趟」
- 同好页口味近邻上方的坐标说明文字
- 我的页「关于」卡片
- 我的口味每项的「依据 evidence/embedding」字样，只保留强度百分比
- 我的页后端地址输入框下方的说明文字

### 已修复：登录后进入「同好」闪退

- 现象：登录态下切到同好页，进程被系统重新拉起。
- 定位（`hilog`）：
  ```
  @Component 'CommunityTab'[3006]: re-render of If elmtId 3036 has error:
  TypeError: Cannot read property length of undefined
  ```
- 根因：登录态下 `/api/community/collections`、`/api/community/neighbors` 返回的数组字段可能为 `null`，
  而 UI 直接读了 `place_ids.length` / `shared.length`。
- 修复（系统性，不是补一处）：
  - `Collection.place_ids`、`Collection.places`、`Neighbor.shared`、`Journey.stops` 全部改为可选类型；
  - 新增 `collectionCount()` / `sharedText()` / `stopCount()` / `stopNames()` 统一兜底；
  - `CommunityTab.load()` 与 `JourneyTab` 对容器字段做 `undefined/null → []` 归一；
  - `SectionCard` 的 `title/subtitle` 改为 `@Prop`（否则人数标题停留在首帧值）；
  - 口味星图按邻居坐标最大绝对值自适应缩放（真实数据量纲很小，原固定半径会把点全挤在圆心）。
- 复验：登录「冬瓜」后进入同好页，正常渲染 30 位近邻，日志无 `TypeError`。

截图见 `.screens/`：`21-amap-live.png`（高德出图）、`22-after-pan.png`（拖动后重新加载）、`23-overlay.png`（浮层与分类）、`32-community-final.png`（同好页修复后）、`60-light-pill.png`（浅色悬浮药丸）、`70-dark-resource.png`（深色 + 夜间地图）、`71-light-resource.png`（切回浅色）、`64-fav-tab.png`（药丸滑到收藏页）。



# 红果短剧客户端（drama_app）

Flutter 只做渲染，Rust 做引擎。红果为**唯一内置源**，其余源是**运行期安装的规则扩展源**。

单包单仓：Flutter 应用与 Dart 包根即仓库根（历史上的 `apps/drama_app/` 已上移）。

- 后端架构：见 `docs/backend/ARCHITECTURE.md`（分层与决策记录）
- 扩展源规则：见 `docs/backend/EXTENSION_SOURCES.md`（能表达什么、不能表达什么）
- 分层：`lib/ui`（瘦视图+ViewModel）→ `lib/data/repositories` → `lib/data/services/rust_core.dart`（FFI 封装）→ `rust/core`（窄 C ABI：`drama_request`/`drama_free`）→ 9 个分层 crate
- 纪律：Dart 侧禁直连源站、禁解析；网络/解析/超时/取消全归 Rust

## 后端工作区

`rust/` 是分层 Cargo 工作区，依赖方向单向（`types → net/store → sources → engine → cli`）：

| crate | 职责 |
|---|---|
| `drama-types` | 领域模型、wire 契约表、错误分类（无 IO） |
| `drama-net` | 全工程唯一出网点：限流、退避、代理、超时、取消 |
| `drama-store` | 原子写（含目录 fsync）、目录缓存、追剧进度、设置 |
| `drama-source-hongguo` | 红果主源：Gorgon/注释签名、SSR、三级取流、弹幕 |
| `drama-rules` | 规则扩展源：清单 schema、模板、JSON/CSS/正则取值、过滤器、cookie jar、校验、安装、执行 |

已交付规则包（`rust/sources/`，全部实网验证）：

| 包 | 协议 | 状态 |
|---|---|---|
| `wangguo.yaml` 网果 | MacCMS HTML（`player_aaaa`） | 目录 24 / 取流 ✓ |
| `huaguo.yaml` 花果 | MacCMS HTML（页面内 m3u8） | 目录 36 / 取流 ✓ |
| `wuguo.yaml` 伍果 | MacCMS HTML | 目录 24 / 取流 ✓ |
| `hanxiaoquan.yaml` 韩小圈 | MacCMS HTML | 目录 36 / 取流 ✓ |
| `huangju.yaml` 剧果 | REST JSON + 登录 token + cookie jar | 目录 20 / 取流 ✓ |
| `huangguoai.yaml` 黄果AI | 脚本内 JSON（`::json:` 语法） | 目录 20 / 分集取流 ✓ |

未实现：帝果（AAencode 算术求值器）、野果（JS chunk 抓密钥）——均需内置 codec，
按你的决定跳过。其余站源大多已下线或需要 TLS 指纹/加密信封（见架构文档第七节）。
| `drama-gateway` | 本机回环代理：媒体、CENC 解密、封面签名 |
| `drama-download` | 分段续传、索引持久化、本地播放计划 |
| `drama-engine` | 源注册、op 调度、缓存策略、会话仲裁 |
| `core` | 薄 FFI 门面（只两个符号，无业务逻辑） |
| `drama-cli` | 验收入口，与 FFI 走同一条 dispatch 路径 |

验证（不依赖 Flutter）：

```sh
cd rust
cargo test --workspace              # 340 个测试
cargo test --workspace -- --ignored # 实网用例
cargo run -p drama-cli -- catalog --page 0
cargo run -p drama-cli -- ranking --board hongguo-hot
cargo run -p drama-cli -- validate --file ./my-source.yaml
```

**不在范围内**（产品决定）：局域网互联（mDNS/TLS 直连/同步/推送续播）、
本地多用户与权限分配。详见架构文档第七节。

## 架构要点

**信封**：请求 `{v:1, op, source?, session?, sequence?, params?}`，响应 `{ok:true, data}` 或  
`{ok:false, error:{code, msg, retry}}`。入参上限 1 MiB，`v` 必须为 1。

**op 一览**（契约表在 `drama_types::contract::OPS`，可经 `ops` op 自检）：

| 类别 | op |
|---|---|
| 引擎 / 诊断 | `ping`、`version`、`ops`、`init`、`cancelRead`、`diagnostics` |
| 读类（参与仲裁） | `catalog`、`catalogPages`、`categories`、`recommend`、`ranking`、`rankingBoards`、`search`、`suggest`、`detail`、`episodeGroups`、`play`、`preload`、`playQuality`、`danmaku` |
| 本地播放 | `playLocal`、`playFile` |
| 追剧 / 进度 | `followPut`、`followDel`、`followList`、`historyPut`、`historyGet`、`historyClear`、`searchHistoryPut/List/Del/Clear` |
| 下载 | `downloadStart`、`downloadList`、`downloadPause`、`downloadRetry`、`downloadCancel`、`downloadDelete`、`downloadSetConcurrency`、`moveDownloads`、`storage` |
| 缓存 / 设置 | `cacheClear`、`cacheFlush`、`cacheStats`、`resourceSettings`、`saveResourceSettings` |
| 扩展源 | `sources`、`sourceInstall`、`sourceUninstall`、`sourceEnable`、`sourceValidate`、`sourceTest` |

**取消与分级超时**：读类 op 带 `session`+`sequence` 时参与仲裁——同 session 内更新的 `sequence`  
会让旧的直接 `CANCELED`（且**不发网络请求**）；内层超时映射为 `TIMEOUT`（`retry=true`）。  
内层预算：默认 60s、`preload` 15s、`moveDownloads` 600s；Dart 外层略大（70s / 20s / 620s），  
保证**内层先到期**。`session` 只允许 `[0-9a-zA-Z-_:.]` 且 ≤128，非法即 `BAD_REQUEST`。

**并发布局**：Dart 侧为 3 个**常驻** worker isolate 的池（不是每次 `Isolate.run` 新建），  
故一个 worker 阻塞在网络时另一个仍能处理 `cancelRead`。取消是**协作式**：超时后补发  
`cancelRead`，但不保证立刻中断对端 socket。

**session 按逻辑流划分**（`logicalStreamFor`）：首页会并发打 `catalog/recommend/ranking`，  
若共用一个 session，后发的会立刻把先发的判为迟到，首页随机空白。故按逻辑流分 session。

**播放链**：`play` 三级降级取流，Rust 起**本机回环 HTTP 代理**（`gateway.rs`）  
持有 Referer 鉴权与（加密轨的）CENC 密钥；播放器只打开返回的 `proxyUrl`，不直接碰源站。

| 轨         | 地址                                   | 状态（联网实测）                                                                           |
| --------- | ------------------------------------ | ---------------------------------------------------------------------------------- |
| App 签名    | `video_model/v1`                     | 上游对未授权客户端返回 `200` + **空 body**（同一签名打 `video_detail` 有 84KB，故非签名问题）；恢复后可用 1080p 加密流 |
| **网页公开轨** | `{site}/video/public/{vid}/360p.mp4` | **可用**：免签明文 H.264/AAC，覆盖每部剧前 `accessible_episode_cnt` 集（多剧实测均为 3 集），其余集 404        |
| 网页 SSR    | `video_player_info`                  | 站点已改 `protectedPlayback`，该字段不再下发，保留兜底                                              |

公开轨是**官网网页播放器自己用的地址**（见其 `player.*.js` 的  
`"/video/public/".concat(vid, "/360p.mp4")`）。它免签且明文，因此无需解密代理；  
下发前会先发 `Range: bytes=0-1` 探测，避免把 404 地址交给播放器（那会表现为黑屏无错）。  
加密轨仍在位：一旦上游恢复，`resolve_media` 会自动走回它并启用 moov 重写 + 逐样本解密。

**media_kit 必须初始化**：`main()` 里 `MediaKit.ensureInitialized()` 不可删——  
漏掉会让播放页整页变红（`must be called before using any API from package:media_kit`）。

播放页支持拖动定位（松手即 seek 并立即上报进度）、缓冲态提示、下一集预取、  
自动连播与「进入即播」开关；清晰度取自设置页（两处共用同一份偏好）。

**封面代理**：封面同样不许 Dart 直连源站，故 Rust 在解析时把 CDN 地址换成  
`http://127.0.0.1:{port}/img/{token}`（`covers.rs`）。token 是  
`base64url(cdnUrl).md5(install_id:cdnUrl)` 的**无状态签名**——重启后依然有效，  
且本机其他进程无法借它当开放代理。图片落盘缓存于 `{dataDir}/covers`。

> 端口策略：网关在 47800-47899 取首个可用端口（固定区间，跨启动稳定）。  
> 即便如此，**目录缓存里存的是历史端口**，故 Dart 侧用 `version` op 上报的  
> `mediaPort` 在渲染前改写端口（`rewriteProxyPort`），使缓存自愈。

**macOS 沙箱**：`macos/Runner/*.entitlements` 必须同时有  
`network.client`（出站访问源站/CDN）与 `network.server`（本机回环代理）。  
缺 `network.client` 会让目录、封面、取流全部静默失败。

## 两个易踩的框架陷阱

**1. 构建钩子必须先判 `buildCodeAssets`。**  
`hook/build.dart` 不只在「编译 code asset」时被调用，SDK 还会用**空  
`build_asset_types`** 调一次（依赖发现阶段）。此时读 `input.config.code` 会抛  
`Bad state: HookConfig.code should only be accessed when building code assets`，  
表现为 `Building native assets failed. build.dart returned with exit code: 255`。

**2. 玻璃外壳必须自带 `Material`。**  
`MaterialApp` 在根部把 `_errorTextStyle`（红色等宽 + 黄色双下划线）装成兜底  
`DefaultTextStyle`，用于提示「缺少 Material 祖先」。`GlassScaffold` **自身不创建  
Material**，因此它直接摆放的 appBar 标题与 bottomBar 标签会继承该样式——  
实机表现是导航标签下方出现黄色双下划线。`AppGlassScaffold` 已在外层包  
`MaterialType.transparency`；改动该文件时别把这层去掉  
（回归用例见 `test/glass_text_style_test.dart`）。

**能力契约**：`Caps` 未声明的能力必须返回 `UNSUPPORTED`，**绝不返回空列表冒充"查过了"**。

## 设计系统

取向：**「无彩色界面 + 封面取色」**。形态决策冻结在  
`docs/DESIGN_CONSTITUTION.md`，视觉真相是 `outputs/prototype/index.html`。

界面色板只有黑 / 白 / 两级灰 / 发丝线 / 浅雾——**没有任何强调色**。  
**颜色唯一来源是封面**：详情页与播放器的氛围色从封面主色提取  
（`lib/ui/core/theme/cover_palette.dart`），界面本体永远不带色相。

六条铁律（全文见设计宪法）：

1. **封面不裁切**——一律按 3:4 原始比例渲染，裁掉的就是封面上的卖点文案；
2. **内容即界面**——标题与集数叠在封面下缘 scrim 上，卡片**无独立文本区**；
3. **一屏只回答一个问题**——发现「该看什么」/ 榜单「大家在追什么」/ 追剧「追的更新了吗」；
4. **分层靠排版与负空间**——卡片无描边、无阴影、无容器色差；`cardTheme` 无 `BorderSide`；
5. **玻璃只在有东西可折射的地方出现**——见下方位置表；
6. **续播做进卡片**——看过的卡右上角「继续看 N」白胶囊 + 下缘发丝进度线，不做横滑区。

玻璃位置表（用量：导航栏 + 画面之上的控件）：

| 允许                                       | 底下是什么             |
| ---------------------------------------- | ----------------- |
| 底部 Tab 条（距底 16 / 左右内缩 14 / 高 60 / 圆角 30） | 从它下方滚过的封面流        |
| 浮起玻璃侧栏（宽 200 / 240，四角 26，带投影）            | 内容从它右侧经过          |
| 四个 Tab 页的固定顶栏（**滚动前也常驻**：内容确实从它下方滚过）     | 已滚过的封面流           |
| 详情页顶栏三枚圆钮 / 播放器控件                        | 模糊海报 / 视频画面（效果最好） |

**禁止**：停在纯色上的东西用玻璃（搜索框、分段控件、内容卡）——玻璃压在纯色上  
只会发灰；以及**玻璃内再嵌玻璃**（静默降质，不报错，最难发现）。

落地要点：

- 语义色板 `AppColors` 以 `ThemeExtension` 下发（`AppColors.of(context)` 与  
  Material 组件同源）：纸白 / 炭底 `#1C1C1E` / 列表卡 `#232325` / 浅雾三级面，  
  ink `#0F0F0F`/`#ECECEC`、graphite `#6E6E80`/`#B4B4B4`、silver `#8F8F8F`/`#8E8E8E` 三级文字。
- **对比度有实测表，且表本身是测试**（`test/token_contrast_test.dart`）。  
  浅色端 silver 只到 3.24:1（只能装饰）、石墨 4.99:1；改色值先跑该测试。
- **密度是连续公式**（`Breakpoints.feedColumns`，原型实测值当断言，  
  见 `test/responsive_layout_test.dart`）：目标卡宽 140pt、下限 3 列、上限 8 列，  
  可用宽 = 窗口宽 − 侧栏占位 − gutter×2，再被 1120 封顶。  
  手机 3 列 / 平板 4 列 / 桌面 6 列。
- **导航三档**：手机浮起玻璃 Tab 条；平板 / 桌面浮起玻璃侧栏。  
  选中态 = 图标线稿→实心 + 文字加粗（UITabBar 的语言），**不是** Material 的指示器。  
  **导航只出现在四个 Tab 页**：搜索 / 详情 / 播放器一律不显示导航，返回靠左上角圆钮。
- **数字与元信息走等宽**（`AppText.mono` / `numeral` / `stat`，SF Mono → Menlo →  
  Roboto Mono），让集号、时间码、榜单序号纵向对齐、读数不跳动。
- **圆角一律连续曲率**：内容层由 `AppRadii.shape()` 出口，玻璃面用包内建的  
  `LiquidRoundedSuperellipse`，两者同一曲率模型。
- **固定顶栏与副行** `FixedTopBar` / `SubBar`（`ui/core/widgets/app_fixed_top_bar.dart`）：  
  全程不随滚动改变高度、字号、内边距与背景，不做大标题折叠；副行在纯色底上，  
  用浅雾底分段控件或文字标签下划线。
- 动效三档时长 + 两个曲线在 `AppMotion`；`PressableScale`（按下微缩）、  
  `Reveal`（首屏逐个浮起）、`HairlineProgress`（2px 发丝进度）  
  都消费同一套 token，且全部尊重 `disableAnimations`。
- 内容层版式词汇表在 `ui/core/widgets/lockups.dart`（海报卡 / 榜单行 / 追剧行 /  
  空态 / 设置卡）；发现页网格在 `ui/features/home/views/home_view.dart`。
- **封面 Hero**：列表卡片 → 详情页海报的共享元素转场（`CoverHero`，  
  `ui/core/widgets/drama_cover.dart`）；详情路由 `extra` 携带卡片数据，  
  保证转场开始时落点已存在。

## 平台

第一优先级：Android、iOS、macOS、Windows。Linux、OHOS、Android TV 后续单独分支。

窗口/包名统一为 `drama_app`（Android `com.drama.drama_app`、Apple `com.drama.dramaApp`），  
用户可见标题为「红果短剧」（桌面端由 `main.dart` 的 `window_manager` 在运行时设置）。

## 开发

```sh
flutter pub get
dart analyze lib test tool hook integration_test
flutter test
cargo test --manifest-path rust/core/Cargo.toml
cargo clippy --manifest-path rust/core/Cargo.toml --locked --all-targets -- -D warnings
cargo fmt --manifest-path rust/core/Cargo.toml --check
```

Rust 工具链由 `rust/core/rust-toolchain.toml` 锁定（**必须精确版本**，构建钩子的校验器  
拒绝 stable/beta/nightly），进入该目录时 rustup 会自动切换。

实网用例默认 `#[ignore]`（需访问源站），显式跑：

```sh
cargo test --manifest-path rust/core/Cargo.toml -- --ignored
```

**播放链路验证**用集成测试（`flutter test` 的宿主进程没有 libmpv，  
`Player()` 构造即抛，故必须在真实 app bundle 里跑）：

```sh
flutter test integration_test/playback_test.dart -d macos
```

FFI 绑定（`lib/data/services/drama_core_bindings.dart`）**为手写并须保持手写**：  
项目走 native assets，要求 `@Native` 形式，而 ffigen 产出的是 `DynamicLibrary.lookup`  
风格，两者不兼容。`ffigen.yaml` 与 `tool/ffigen.dart` 仅作签名校对用——  
改 C ABI 后跑 `dart run ffigen --config ffigen.yaml`（需装 LLVM/libclang，在**仓库根**执行）  
比对结果，把改动落到手写文件，再 `git checkout` 丢弃生成结果。

## 状态

已完成：浏览 / 搜索 / 详情 / 选集 / 榜单 / 播放（含加密流解密）/ 玻璃设计系统 /  
外观与无障碍降档 / 缓存与弱网兜底 / 追剧与观看进度的 Rust 持久化。

已完成（本轮）：真实封面全链路（Rust 代理 + 签名 + 磁盘缓存 + 端口改写）、  
追剧与观看进度接线（续播 / 历史 / 追剧页 / 我的）、播放页 seek 与预取、  
多源架构（红果 + 黄果 AI，caps 能力协商）、封面 Hero 转场。

已完成（设计 v3，按 `docs/DESIGN_CONSTITUTION.md` + `outputs/prototype/index.html`  
对齐）：界面色板去彩色（无强调色；状态与进度改用灰度与字重）+  
**封面取色**（详情 / 播放器氛围色由封面主色提取）、**连续密度公式**  
（`Breakpoints.feedColumns`）、**固定顶栏 + 常驻副行**（`FixedTopBar` / `SubBar`，  
废除大标题折叠）、**导航三档重做**（浮起玻璃 Tab 条 + 浮起玻璃侧栏，  
选中态改为线稿→实心；导航只出现在四个 Tab 页）、发现页竖卡网格  
（封面 3:4 不裁切、标题叠在 scrim 上、续播做进卡片）、榜单 / 追剧 / 我的三页重做、  
搜索页筛选优先（删热门趋势）、详情页玻璃圆钮浮在模糊海报上。

待完成（**前端**；后端能力已就绪，见下文）：

- 搜索页筛选档位只有「默认 / 集数多 / 集数少」——源站不提供热度与最新更新排序。
- 播放页剧集 chip 未分页（详情页已有分组，后端 `episodeGroups` 可用）。

### 后端状态

已完成 —— 与 `reference/hongguo` 的后端能力对齐（去掉 LAN 与多用户）：

- 红果主源：Gorgon 签名、注释签名（X-Argus/X-Ladon/SM3）、SSR 解析、
  三级取流（App → 公开轨 360p → 网页）、弹幕、四个榜单板
- 规则扩展源：清单 schema、模板、JSON/CSS 取值、15 个过滤器、
  安装校验、运行期安装/启停/卸载
- 下载：分段续传、索引原子持久化、本地播放计划
- 播放网关：回环代理、moov 重写 + 逐样本 CENC 解密、封面签名代理
- 持久化：目录缓存（TTL + 熔断 + 并发去重）、追剧/进度、设置

实网验证（`cargo run -p drama-cli`）：目录、搜索、联想、详情、
取流、四个榜单、规则源安装卸载均通过。

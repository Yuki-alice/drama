# 红果短剧客户端 MVP 实施计划（外观优先 + 播放/下载链路全连接）

> 依据：`docs/PRD.md`（v0.6）、`docs/ARCH.md`（v0.6）、`docs/SourceSpec.md` §11（含 v0.6 §11.4 取流双轨）、`docs/EVIDENCE.md` §16/§17、`docs/QUESTIONS.md`（Q1–Q32）。
> 工作区现状：`e:\drama` 下只有 `docs/`、`reference/`（guoapp 源码，仅作行为参照）、`scripts/`、`.agents/`、`.workbuddy/`，**尚无任何应用代码**（`apps/`、`rust/` 均不存在）。

---

## 1. 摘要

从零交付一个**可运行的 MVP**，两条主线并行推进、但按"外观优先"排序：

1. **视觉主线（先做）**：iOS 液态玻璃（Liquid Glass）设计系统 + 响应式布局，先把"好外观"做出来——用本地 mock 数据即可跑通全部页面与导航。
2. **链路主线（随后接真）**：`浏览 → 搜索 → 详情 → 选集 → 播放 → 下载` 全链路打通，数据来自红果内置源（v0.6：**免签轨 ① 优先**），播放走本地 StreamGateway + media_kit，下载走 Rust 引擎 + Android 前台服务。

功能面**基本对齐 guoapp 红果版**：F-01 首页浏览、F-02 在线搜索、F-03 推荐/榜单、F-04 详情+选集、F-05 播放、F-06 追剧/历史、F-07 下载、F-09 外观主题。明确**不做** F-08 弹幕、**F-10 红果健康检测**、VIP UI、画中画、画质增强、TV 遥控、多源/规则/WASM、LAN、多用户（见 §3）。

技术基线（ARCH §2）：**Flutter 3.47.4 / Dart 3.13.3**（Q9：以 media_kit 1.2.6 兼容为准，不兼容则降 3.38.10）+ **Rust `cdylib`**（`drama_request`/`drama_free` 窄 ABI）+ `liquid_glass_widgets 1.13.0` + `media_kit 1.2.6/2.0.1/^1.0.7`。

---

## 2. 当前状态分析

| 项 | 状态 |
|---|---|
| 代码 | **零**。需从 `flutter create` + `cargo new` 起步 |
| 文档 | PRD/ARCH/SourceSpec/EVIDENCE 已对齐 v0.6；M0–M4 出口条件已冻结；包清单、Rust crate 清单、FFI 契约、目录结构、工具链已在 ARCH §2/§3 写定 |
| 参照实现 | `reference/guoapp`（Flutter + Go native）：行为/验收可参照，**代码不照抄**（README 与代码不一致的教训 [G13]；X-Gorgon 变体不同，勿套开源实现） |
| 待关闭决策 | Q30（海报缓存）、Q31（drift vs shared_preferences）、Q32（provider/get_it、ffigen 手写与否）——影响 W2/W4；Q13/Q24/Q25/Q27/Q28——合规与策略，建议 M0 前关闭 |
| 已知风险 | media_kit 在 3.47.4 上**未做播放真机回归**（guoapp 仅编译验证）；Windows 原生库仅 x64；CENC 属轨 ②，不阻断 MVP |

---

## 3. MVP 范围划定

**纳入（Must）**

| 编号 | 功能 | MVP 深度 |
|---|---|---|
| F-01 | 首页浏览 | 分类横滑切类、排序/连载筛选、触底分页 + "加载更多"兜底；缓存优先 |
| F-02 | 在线搜索 | 300ms 联想、防抖、取消在途、最近 20 条本机存 |
| F-03 | 推荐/榜单 | 推荐（真人/漫/AI）+ 榜单（结构化 JSON-LD，失败回退旧榜） |
| F-04 | 详情+选集 | 封面/简介/追剧/播放/下载；选集每组 50 集、范围切换/跳转/定位当前；点剧直达播放 |
| F-05 | 播放 | MP4/HLS；连播 + 下一集预加载；手势（上/下滑切集、长按 3x）；卡顿恢复（备用线路→重解析） |
| F-06 | 追剧/历史 | 想看/在看/已看/有更新；真实进度 5s 落盘；继续观看 |
| F-07 | 下载 | 按剧分组、批量、并发 2（1–6 可配）、Range 续传、HLS `ENDLIST` 校验、清理保留视频 |
| F-09 | 外观/主题 | 浅/深/跟随系统；玻璃明暗自适应；大字/高对比降级 |

> 注：本 MVP 范围比 `PRD.md §5` 的 P0 少 **F-10（红果健康检测）**——用户 2026-10-15 确认移出 MVP。PRD §5 的 F-10 保留为 P0 后续项，建议在 PRD 下一版标注"MVP 不含"。

**排除（Out，本 MVP 不做）**

- **F-10 红果健康检测**（用户 2026-10-15 确认：MVP 不含，后续单排）。
- F-08 弹幕（Q1：暂缓，编号保留）、VIP 三态 UI（Q4：字段预留）、画中画、画质增强（P1 Win 专属）、TV 遥控、OHOS（Q11）。
- 多源管理 / 声明式规则 / WASM 插件 / 官方规则仓库（P2，SourceSpec §1–§10）。
- LAN 同步（Q10 砍掉，由备份导入导出替代）、多用户（Q3 完全移除）。
- **iOS 平台构建**（Q12：P1 末位；且本机为 Windows，无 macOS/Xcode，无法产出 iOS 构建）——MVP 只实现 iOS **风格**的 UI，跑在 Android + Windows 上。

**取流策略（v0.6，SourceSpec §11.4）**：MVP 走**轨 ① 官网 SSR 免签**（`_ROUTER_DATA` → 明文直链），覆盖目录/榜单/详情/选集/搜索 + 可试看集；**轨 ② App 签名 + CENC 作为 M1 增强项**，不阻断 MVP（不通过则"仅可试看集可播"）。**红线：禁用第三方中转 `djapi.999888456.xyz`。**

---

## 4. 实施路线（6 波，映射 M0–M4）

> 波次内"外观优先"：W1 先出可视外壳，W2 起逐步接真数据；每一波都有可验收出口。

### W0 — 工程骨架与基线锁定（对应 M0 前半）
- **目标**：`flutter create` + `cargo new` 双工程落地，FFI 往返打通，依赖锁死，CI 起步。
- **关键任务**：
  1. 建目录（严格照 ARCH §3）：`apps/drama_app/`（Flutter）、`rust/core/`（cdylib）、`hook/build.dart`、`ffigen.yaml`、`tool/ffigen.dart`。
  2. 写 `apps/drama_app/pubspec.yaml`：A 类包直接抄版本（`media_kit 1.2.6`、`media_kit_video 2.0.1`、`media_kit_libs_video ^1.0.7`、`liquid_glass_widgets 1.13.0`、`ffi ^2.2.0`、`flutter_foreground_task 11.0.3`、`window_manager ^0.5.1`、`crypto ^3.0.7`、`path`/`path_provider`/`shared_preferences`、`flutter_lints ^6.0.0`）；B 类走 `flutter pub add` 后**提交 lock 并回写 EVIDENCE §19**（状态管理与 DI 采用 **`flutter_riverpod` 3.x + `riverpod_annotation`/`riverpod_generator`**，版本待 M0 锁定）。
  3. `rust/core/Cargo.toml`：`reqwest 0.13`+`tokio`、`serde`/`serde_json`、`regex`、`url`、`md5`、`aes`/`cbc`、`base64`、`thiserror`、`tracing`、`once_cell`（ARCH §2.2）。
  4. 实现最小 FFI：`drama_core.h` + `lib.rs` 导出 `drama_request`/`drama_free`，先做回声（`{v:1,op:"ping"}` → `{ok:true,data:"pong"}`）。
  5. `ffigen.yaml` 生成绑定；Dart 侧 `services/rust_core.dart` 封装**常驻 worker isolate**（ARCH §3.2：单线程消费、端口复用）。
  6. Android：AGP 9.1.0 / Gradle 9.3.1 / compileSdk 36 / minSdk 24 / Java 17 / NDK r28（16KB 页对齐 `-Wl,-z,max-page-size=16384`）；Windows：VS2022 C++ CMake + **x64-only pinned 原生库**。
  7. CI：`dart analyze` + `cargo clippy/test` + `cargo vet`/`cargo-deny` 门禁。
- **出口条件**：Android 真机 + Windows x64 各跑起"空壳 App"，FFI 回声往返 OK；`pubspec.lock`/`Cargo.lock` 进仓；三平台构建通过（Flutter 3.47.4 冒烟）；若媒体栈不兼容则降 3.38.10 并留痕。

### W1 — 视觉外壳（"好外观先"，对应 M0 后半）
- **目标**：**不接数据**，先把 iOS 液态玻璃设计系统、响应式布局、全部页面骨架与导航做出来，用本地 mock 数据跑通。
- **关键任务**：
  1. **设计系统** `lib/ui/core/`：玻璃 token（三档 `premium/standard/minimal`）、颜色（浅/深/跟随系统，F-09）、字体/间距/圆角/动效规格；封装 `GlassScaffold`/`GlassCard`/`GlassButton`/`GlassNavBar` 等基础组件。
  2. **shader 预编译**：`liquid_glass_widgets` 自带 5 个 `.frag`，按 ARCH §6 走 Impeller shader 预编译，避免首帧白闪；Windows/Linux 被包平台策略钳到 `standard`，设计验收按平台分档（Q9）。
  3. **响应式布局** `lib/ui/core/layout/`：断点策略（手机竖屏单列 / 平板·桌面分栏 / 宽屏资料·选集分栏），用 `LayoutBuilder`+`MediaQuery`；大字/高对比/减弱动效降级。
  4. **导航骨架**：`go_router` 声明式路由 + 深链；底部/侧边导航按断点自适应。
  5. **页面骨架** `lib/ui/features/{home,search,detail,player,downloads,library,settings,about}/`：每页含 `views/` + `view_models/`，暂用 `FakeXxxRepository` 供 mock 数据；播放页先用本地视频/占位验证布局。
  6. 免责声明三处占位（首次启动引导 + 关于页 + 应用内"关于"文案），措辞按 Q13 定稿前先用占位。
- **出口条件**：Android 手机 + Windows 桌面可完整导航所有页面；浅/深色切换保留导航位置；玻璃三档在对应平台表现正确；大字矩阵（360×640 / 1100×720）无断行错位；切类/切主题不丢状态。

### W2 — 数据与浏览链路（对应 M0 收口 + M1 前半）
- **目标**：Rust 引擎接入红果**轨 ① 免签链路**，Dart 侧接真数据，打通浏览/搜索/榜单/详情/选集。
- **关键任务**：
  1. `rust/core/src/http.rs`：reqwest 会话、限流/退避（默认并发 3 / 间隔 250ms，403/429/CF 退避 1min 起、封顶 30min，尊重 `Retry-After`；**媒体请求不走限流器**）、代理支持。
  2. `source/traits.rs`：冻结 `SourceProvider` trait 与 `Caps`（未声明能力返回 `UNSUPPORTED`）；`source/mod.rs` 运行时注册表，P0 仅 `hongguo`；**禁止编译期源开关**。
  3. `sources/hongguo/web_ssr.rs`：`_ROUTER_DATA` 提取（正则 `(?s)(?:window\.)?_ROUTER_DATA\s*=\s*`）+ `routerLoaderMap` 解析；实现 `catalog/search/suggest/recommend/ranking/detail`（EVIDENCE §17.5 路线：目录/榜单/详情/选集/搜索整体免签）。
  4. 取消/超时协议（ARCH §3.2）：`session`+单调 `sequence` 仲裁；分级超时（默认 70s/60s、preload 20s/15s）；超时补发 `cancelRead`。
  5. Dart `data/repositories/` + `domain/use_cases/` + `ui/features/*/view_models/`：目录 15min 缓存、分页 `extentAfter=(viewport*1.5).clamp(320,900)`、搜索防抖 300ms/中文 composing 不请求/stale 抑制、榜单 3 次/18s 熔断 + 24h 旧榜回退。**ViewModel 以 Riverpod `AsyncNotifier`/`Notifier` 实现**（`riverpod_annotation` 代码生成），UI 经 `ref.watch` 消费。
  6. **UI 去 mock 接真**：F-01/F-02/F-03/F-04 全量验收（含"2000 集可秒开"、选集 50 集分组组件三处共用）。
- **出口条件**：真机上"浏览→搜索→推荐/榜单→详情→选集"全链路出真数据；断网/弱网保留有效结果；重启后目录分页续载不丢页。

### W3 — 播放链路（对应 M2）
- **目标**：接通 StreamGateway + media_kit，完成 F-05 播放与 F-06 进度。
- **关键任务**：
  1. `rust/core/src/stream.rs`：本地流服务（`127.0.0.1:0`，ReadHeaderTimeout 5s/IdleTimeout 30s，仅 GET/HEAD；会话 24 字节 hex token；**HLS 重写五类 URI** `EXT-X-KEY/SESSION-KEY` 等；未知 session → 410 Gone；播放密钥永不落盘/日志/备份）。
  2. 轨 ① 明文直链直供 media_kit；`play` op 返回 playlist/UA/Referer。
  3. Dart 播放页：media_kit 接入、手势（上/下滑切集、长按 350ms 3x）、连播、下一集预加载（position≥2s 且非后 45s 且缓冲≥5s）、卡顿恢复（备用线路→重解析，≤3 次）、进度 5s 落盘 + 退出落盘。
  4. F-06 追剧/历史存储与状态机（已读只升不降、手动"标记已看"不被覆盖、新季提醒）。
- **出口条件**：真机首帧 <3s（缓存命中 <1s）；切线/续播/杀进程不丢进度；卡顿判定 = `playing && foreground && position 1s 无变化`。

### W4 — 下载与本地能力（对应 M3）
- **目标**：F-07 下载全链路 + 备份恢复 + 存储落地。
- **关键任务**：
  1. `rust/core/src/download.rs`：按剧分组、并发 2（1–6 可配）、Range 续传（30s 无活动取消、拒绝非 identity 编码、拒绝 `text/html`/`application/json` 响应体）、HLS 必须 `#EXT-X-ENDLIST`。
  2. Android 前台服务（`flutter_foreground_task 11.0.3`）：系统杀进程后保留任务与完整文件；Windows 保持运行。
  3. 下载管理 UI（按剧分组、批量暂停/继续/重试/删除、"更新本剧"补缺集）。
  4. 存储（按 Q31 定稿）：`drift` 表（favorites/history/downloads）+ `shared_preferences`（设置/外观）；三条提交语义。
  5. 备份导入导出（Q10 替代 LAN）：上限 8MiB、损坏可重试且保留原文件、记录上限 favorites 20000 / history 300 / recentSearches 20；**凭证与播放密钥不进备份**。
  6. 海报缓存（按 Q30 定稿）：30 天 / 256MiB / 2000 张 / 单张 20MB。
- **出口条件**：断点续传成功率 100%（测试桩）；故障注入（false/throw/after 三态）回归通过；断网向量通过。

### W5 — 增强与交付（对应 M1 后半 + M4）
- **目标**：轨 ② 增强、健康检测、合规文案、三平台 Release 校验与 UI 打磨。
- **关键任务**：
  1. `sources/hongguo/{app_api.rs,sign.rs,media.rs}`：X-Gorgon（**`8404 401c 0000` 变体**，勿套开源 `8402`）、设备伪装、`device_id`/`iid` 持久化、`spade_a → CENC` 派生、`bytevc2` 过滤、AES-CBC 响应解密；**真机验证 mpv `decryption_key` 解 CENC**（不通过则降级为"仅可试看集可播"）。
  2. ~~F-10 五阶段健康检测 + 诊断日志导出~~ —— **确认不在 MVP（用户 2026-10-15）**，后续单排。
  3. 合规：免责声明定稿落地三处（Q13/Q25 关闭后）。
  4. 玻璃 UI 全量打磨 + 响应式回归矩阵 + 三平台 Release 校验（产物 SHA256 / `.so` 清单 / 冒烟）。
- **出口条件**：M4 交付条件满足；大字矩阵回归通过；Windows x64 产物校验通过。

---

## 5. 具体改动（文件级清单）

**新增工程（从零创建）**

```text
apps/drama_app/
  pubspec.yaml  analysis_options.yaml
  lib/
    main.dart
    data/{models,repositories,services}/      # services/rust_core.dart = FFI 封装 + worker isolate
    domain/{models,use_cases}/
    ui/core/{tokens,theme,layout,widgets}/    # 玻璃设计系统 + 响应式断点 + 基础组件
    ui/features/{home,search,detail,player,downloads,library,settings,about}/{views,view_models}/
  hook/build.dart                             # native_toolchain_rust 编译 Rust → Dart asset
  ffigen.yaml  tool/ffigen.dart
  test/  integration_test/
rust/core/
  Cargo.toml
  src/lib.rs            # drama_request / drama_free + JSON-RPC 分发
  src/http.rs           # reqwest 会话 / 限流退避 / 代理
  src/source/{mod.rs,traits.rs}
  src/sources/hongguo/{mod.rs,web_ssr.rs,app_api.rs,sign.rs,media.rs}
  src/stream.rs         # StreamGateway
  src/download.rs       # 下载引擎
  drama_core.h
```

**状态管理约定（Q32 已决）**：状态管理与 DI 采用 **Riverpod 3** —— ViewModel = `Notifier`/`AsyncNotifier`（`riverpod_annotation` 代码生成），依赖注入用 `ref`；**不引入 `provider`/`get_it`/Bloc**。

**关键契约（不可偏离）**

- C ABI 仅两个符号：`const char* drama_request(const char* utf8_json)` / `void drama_free(const char* p)`（ARCH §3.1）。
- JSON-RPC 信封：`{v:1, op:"catalog|search|detail|play|...", source, params}` → `{ok, data|error{code,msg,retry}}`；**无 `user` 字段**；入口 panic → `{"ok":false,"error":"本地核心处理失败，请重试"}`；输入 >1MiB 拒；引擎错误码仅 `local_media`/`source_blocked`。
- `SourceProvider` trait + `Caps`：未声明能力返回 `UNSUPPORTED`，**不返回空列表冒充"查过了"**（SourceSpec §11.1）。

---

## 6. 假设与决策

| # | 假设/决策 | 依据 |
|---|---|---|
| A1 | MVP 平台 = **Android(ARM64) + Windows(x64)**；iOS 平台推迟（本机 Windows 无 Xcode）；UI 为 iOS 液态玻璃**风格** | Q12、PRD §3/§6 |
| A2 | MVP 取流走**轨 ① 免签**即可成立；CENC 不阻断 | SourceSpec §11.4、EVIDENCE §17.4 |
| A3 | Flutter 基线 **3.47.4 / Dart 3.13.3**，不兼容 media_kit 则降 **3.38.10 / Dart 3.10.8** | Q9、EVIDENCE §16 |
| A4 | 架构采 `go_router` + **Riverpod 3**（`flutter_riverpod` + `riverpod_annotation`/`riverpod_generator`；状态管理与 DI 一体，**替代 `provider`/`get_it`**），不引入 Bloc；FFI 用 `ffigen` 生成 | 用户 2026-10-15 决策（Q32 已决）；ARCH §1/§2/§2.1 已同步 |
| A5 | 先 UI 后链路：W1 用 mock 数据出外壳，W2 起逐页接真 | 用户"有一个好外观先" |
| A6 | guoapp 仅作行为参照，**不照抄代码**（尤其 X-Gorgon 变体差异） | EVIDENCE §17.6 [G13] |
| A7 | Q30/Q31/Q32 在 W2/W4 开工前定稿；Q13/Q24/Q25/Q27/Q28 建议 W0 前关闭 | QUESTIONS |

---

## 7. 验证步骤

1. **W0**：`flutter analyze` 0 error/warning；`cargo clippy -D warnings` + `cargo test`；FFI 回声往返（Android 真机 + Windows x64）；`cargo vet`/`cargo-deny` 通过。
2. **W1**：`flutter test`（大字矩阵 360×640 / 1100×720 widget 测试）；`flutter build apk --release` + `flutter build windows --release` 冒烟；导航/主题/响应式人工验收。
3. **W2**：真机跑通"浏览→搜索→榜单→详情→选集"；弱网保留结果；重启续载不丢页（guoapp P1-R1/R2 回归点）。
4. **W3**：真机首帧 <3s；切线/续播/杀进程；`integration_test` 覆盖播放入口。
5. **W4**：断点续传测试桩 100%；故障注入三态；备份损坏恢复保留原文件。
6. **W5**：M4 三平台 Release 校验（`.so` 清单 + SHA256 + 冒烟）；CENC 真机验证结果留痕（通过→全集，不通过→降级可试看集）。

---

## 8. 风险与降级

| 风险 | 降级/应对 |
|---|---|
| media_kit 在 3.47.4 播放真机回归未验（guoapp 仅编译验证） | W0 即做三平台播放冒烟（MP4 / AES-128 HLS / CENC）；失败降 3.38.10 并留痕 |
| Windows 原生库仅 x64（ARM64 `FATAL_ERROR`） | Win x64 首发，ARM64 单独评估并写进产物校验清单 |
| 轨 ① 只覆盖可试看集（上限 `accessible_episode_cnt` 待验） | UI 明示"该集需 App 授权"，非静默失败；W5 补轨 ② |
| X-Gorgon 变体漂移 / X-Argus 强制化 | 用 frida 抓真实样本做离线单测向量（Q28/Q29）；不假设"照抄 guoapp 仍可用" |
| CENC 解密真机不通过 | 降级为"仅可试看集可播"，**不阻断发布**（M1 出口条件已如此写明） |
| 合规风险（第三方非授权客户端） | W0 前关闭 Q13/Q24/Q25，免责声明三处落地 |

---

## 9. 已确认（2026-10-15 用户拍板）

1. **平台**：MVP 只做 **Android + Windows**（iOS 仅视觉风格，不做 iOS 构建）。
2. **功能深度**：**F-01~F-07 + F-09**（**不含 F-10 红果健康检测**）。
3. **节奏**：接受"W1 先出纯 UI 外壳（mock 数据）→ W2 起接真数据"。
4. **状态管理**：**Riverpod 3**（Q32 已决，替代 provider/get_it）。

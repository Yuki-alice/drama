# 红果短剧客户端（drama_app）

Flutter 只做渲染，Rust 做引擎。红果为内置唯一源（规则扩展源延后）。

单包单仓：Flutter 应用与 Dart 包根即仓库根（历史上的 `apps/drama_app/` 已上移）。

- 契约文档已放弃旧版、待重写；当前以代码注释与本 README 为准
- 分层：`lib/ui`（瘦视图+ViewModel）→ `lib/data/repositories`（域模型+缓存）→ `lib/data/services/rust_core.dart`（FFI 安全封装）→ `rust/core`（窄 C ABI：`drama_request`/`drama_free`）
- 纪律：Dart 侧禁直连源站、禁解析；网络/解析/超时/取消全归 Rust；玻璃只上功能层，内容层不透明

## 架构要点

**信封**：请求 `{v:1, op, source?, session?, sequence?, params?}`，响应 `{ok:true, data}` 或
`{ok:false, error:{code, msg, retry}}`。入参上限 1 MiB，`v` 必须为 1。

**op 一览**（`rust/core/src/lib.rs` 分发）：

| 类别 | op |
|---|---|
| 无状态 | `ping`、`version`（返回各源 `caps`，供 Dart 能力协商）、`init`（设备身份持久化） |
| 读类（参与仲裁） | `catalog`、`recommend`、`ranking`、`search`、`suggest`、`detail`、`play`、`preload` |
| 取消 | `cancelRead{session, sequence}` → `{canceled:N}`，不阻塞、不参与仲裁 |
| 追剧 / 进度 | `followPut`、`followDel`、`followList`、`historyPut`、`historyGet`、`historyClear` |
| 未实现 | `moveDownloads` → `UNSUPPORTED`（超时档位已预留 600s 内层 / 620s 外层） |

**取消与分级超时**：读类 op 带 `session`+`sequence` 时参与仲裁——同 session 内更新的 `sequence`
会让旧的直接 `CANCELED`（且**不发网络请求**）；内层超时映射为 `TIMEOUT`（`retry=true`）。
内层预算：默认 60s、`preload` 15s、`moveDownloads` 600s；Dart 外层略大（70s / 20s / 620s），
保证**内层先到期**。`session` 只允许 `[0-9a-zA-Z-_:.]` 且 ≤128，非法即 `BAD_REQUEST`。

**并发布局**：Dart 侧为 3 个**常驻** worker isolate 的池（不是每次 `Isolate.run` 新建），
故一个 worker 阻塞在网络时另一个仍能处理 `cancelRead`。取消是**协作式**：超时后补发
`cancelRead`，但不保证立刻中断对端 socket。

**session 按逻辑流划分**（`logicalStreamFor`）：首页会并发打 `catalog/recommend/ranking`，
若共用一个 session，后发的会立刻把先发的判为迟到，首页随机空白。故按逻辑流分 session。

**播放链**：`play` 走签名 App 接口取流（失败降级 SSR），Rust 起**本机回环 HTTP 代理**
（`gateway.rs`）持有 Referer 鉴权与 CENC 解密密钥；播放器只打开返回的 `proxyUrl`，
不直接碰源站。加密流按 Range 虚拟化重写 moov 并逐样本 AES-128-CTR 解密；明文流为流式透传。

**能力契约**：`Caps` 未声明的能力必须返回 `UNSUPPORTED`，**绝不返回空列表冒充"查过了"**。

## 平台

第一优先级：Android、iOS、macOS、Windows。Linux、OHOS、Android TV 后续单独分支。

窗口/包名统一为 `drama_app`（Android `com.drama.drama_app`、Apple `com.drama.dramaApp`），
用户可见标题为「红果短剧」（桌面端由 `main.dart` 的 `window_manager` 在运行时设置）。

## 开发

```sh
flutter pub get
dart analyze lib test tool hook
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

FFI 绑定（`lib/data/services/drama_core_bindings.dart`）**为手写并须保持手写**：
项目走 native assets，要求 `@Native` 形式，而 ffigen 产出的是 `DynamicLibrary.lookup`
风格，两者不兼容。`ffigen.yaml` 与 `tool/ffigen.dart` 仅作签名校对用——
改 C ABI 后跑 `dart run ffigen --config ffigen.yaml`（需装 LLVM/libclang，在**仓库根**执行）
比对结果，把改动落到手写文件，再 `git checkout` 丢弃生成结果。

## 状态

已完成：浏览 / 搜索 / 详情 / 选集 / 榜单 / 播放（含加密流解密）/ 玻璃设计系统 /
外观与无障碍降档 / 缓存与弱网兜底 / 追剧与观看进度的 Rust 持久化。

待完成：

- **进度链尚未接线**——`progress_repository.dart` 已实现且底层 op 有单测，但 UI 未消费：
  播放器不上报进度（无断点续播、无观看历史），追剧页与「我的」用 mock 数据，
  详情页「追剧」按钮仍是占位。
- 下载能力（`moveDownloads` 及下载管理）整体未实现。
- 真实封面（当前为确定性渐变占位）、搜索结果持久化、播放器 seek 与自动连播。

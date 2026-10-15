# 短剧聚合 App — ARCH（系统架构设计）v0.6

> **⭐ v0.5 定位（2026-10-14 晚用户决策，覆盖此前一切扩展设计）**：
> **第三方红果短剧客户端 = iOS 液态玻璃 UI + Rust 后端核心 + P0 唯一内置源（红果）+ `SourceProvider` trait 预留扩展。**
> **架构直接后果**：WASM 运行时、源插件宿主、多源路由**从 P0 移除，延后至 P2**；
> Rust 侧新增 `sources::hongguo` 模块（红果全套特权实现），并定义 `SourceProvider` trait 作为唯一源抽象。
> 依据 EVIDENCE §17（红果需 X-Gorgon 签名 + 设备伪装 + spade_a 派生 + AES-CBC 解密，**不可规则化、P0 无第二源**）。
>
> **v0.6 变更（2026-10-15，联网调研 + 复核 guoapp 取流代码）**：红果源内部再分**两条取流轨道**——
> **① 官网 SSR 免签**（`hongguoduanju.com` 的 `window._ROUTER_DATA`，覆盖目录/榜单/详情/选集/搜索 + **可试看集的明文直链**）；
> **② App API 签名**（fqnovel `video_model` + X-Gorgon，覆盖全集但需 spade_a → CENC 解密）。
> **M0 只做 ①**：CENC 从 P0 阻断项降为 M1 增强项（详见 SourceSpec §11.4 / EVIDENCE §17.4–§17.6）。
> **红线**：禁用 guoapp 的第三方中转 `djapi.999888456.xyz`。
>
> **v0.6 技术栈确认（2026-10-15 晚）**：§2 展开为 **§2.1 Dart/Flutter 包清单（A 已实证 13 项 / B 待锁 10 项 / C 不引入 4 项）、
> §2.2 Rust crate 清单、§2.3 平台工具链、§2.4 版本锁定纪律（5 条）**。
> 关键结论：网络/SSR 解析**全部收敛到 Rust**，Dart 侧**删除 `dio`+`html`**；
> `url` crate 为签名正确性所必需（X-Gorgon 吃 `RawQuery` 精确字节）；
> 玻璃包零运行时依赖但自带 5 个 `.frag` shader，必须走 §6 shader 预编译；
> 新增待决项 **Q30（海报缓存）/ Q31（drift 与 shared_preferences 分工）；Q32（状态管理与 DI）已定：采用 Riverpod 3**。
>
> 依据 `flutter-apply-architecture-best-practices`（UI/Data/Domain 三层 + MVVM + Repository）与 `dart-flutter-ffi-systems-engineering` 系统边界思想。
> **Flutter 3.47.4 / Dart 3.13.3**（2026-10-14 修订：**Q9 基线以 media_kit 兼容为准**，取 guoapp 实证组合，详见 EVIDENCE §16；
> 3.47.6 为同线 hotfix，M0 冒烟后小步跟进；**不兼容则降级 3.38.10 / Dart 3.10.8**）/ Rust 1.96.0 已实测；
> `liquid_glass_widgets` 1.13.0；原生分发走 Flutter 3.38+ `package_ffi + hook/build.dart` + `ffigen` + `native_toolchain_rust`（`code_assets` 2.1.0）。
>
> **v0.4 变更（2026-10-14 晚，Q9 修订）**：Flutter 基线 3.47.6 → **3.47.4（以 media_kit 1.2.6 实证兼容为准）**，
> 全文件补"降级 3.38.10"分支说明（§2 渲染行、Impeller 注意、§4 per-platform maxQuality、§8 迁移验证）；
> media_kit 播放行改写为"与 guoapp 同款、已有 3.47.4 编译实证，M0 验真机播放"；§6 新增 **Windows 原生库 pin** 构建条目。
>
> v0.3 变更（12 条决断）：**完全移除多用户**（§3.1 信封去 `user` 字段、§3.2 去 profileEpoch、§5.1 去 PIN/profiles）；
> 取消协议按 Q7=a **照抄后简化**（§3.2）；玻璃新增 **per-platform maxQuality 验收策略**（§4）；
> 弹幕条目冻结（§3.2 仲裁 op 列表、§8、§9 指标）；**LAN 从分支策略移除**、iOS 列 P1 末位、OHOS 后置（§7）。
> 数字可回溯至 `docs/EVIDENCE.md`（`[G#]`）。

## 1. 总体架构

```text
UI (GlassScaffold/GlassTabBar/GlassAppBar)  ← iOS 液态玻璃，P0 核心差异化
 └─ ViewModel (Riverpod Notifier / AsyncNotifier)
     └─ Repository (单真相源, 缓存/重试/聚合)
         └─ RustCore (dart:ffi JSON-RPC, 常驻 worker Isolate)
             ├─ Http引擎 (会话/Cookie/限流/退避)
             ├─ SourceRegistry ── SourceProvider (trait)
             │                      └─ sources::hongguo  ← P0 唯一实现
             │                           ├─ ① web_ssr   免签 ─ 目录/榜单/详情/选集/搜索 + 可试看集明文直链
             │                           └─ ② app_api   X-Gorgon 签名 + 设备伪装
             │                                 ├─ video_model → spade_a → CENC 密钥
             │                                 └─ bytevc2 过滤 / AES-CBC 响应解密
             ├─ [P2] WASM运行时 / 规则求值器  ← 实现同一 SourceProvider trait
             └─ StreamGateway (鉴权头/预加载给 media_kit)
```

* **源逻辑不硬编码在调度层**：红果实现 `SourceProvider` trait，调度层只认 trait。
  **P2 加扩展源时，实现同一 trait 即可，引擎调度与 UI 零改动**——这就是"支持后续源扩展"的架构落点（SourceSpec §11.1）。
* **禁止编译期源开关**：源集合由运行时 `SourceRegistry` 决定（P0 仅注册 `hongguo`），
  不复制 guoapp 的 `--all-sources` 双变体（换源=换包）[G15]。
* UniFFI 不用：它只支持 Swift/Kotlin/Python/Ruby/WASM，不支持 Dart；Dart 侧用 `ffigen` + 窄 C ABI。
* guoapp 的 `Drama` 30 个别名字段归一化、域名别名表、静态分类表**全部删除**——
  trait 输出固定字段名后兼容层不再需要 [G15]。

## 2. 技术栈定稿

| 层 | 选型 | 版本/依据 |
|---|---|---|
| App 框架 | Flutter stable | **3.47.4**（Dart 3.13.3；**Q9 修订：以 media_kit 兼容为准**——guoapp 同款组合已在其 CI 完成编译验证，EVIDENCE §16；3.47 线桌面 Impeller 默认；glass 硬要求 ≥3.41.0 满足；macOS 最低升 12 / iOS 最低升 15；Material/Cupertino 独立包化）。降级目标 **3.38.10 / Dart 3.10.8** |
| 渲染 | Impeller（基线 3.47 线全平台默认，不建 Skia 双路径） | Windows/Linux = **GLES via ANGLE → D3D11（非 Vulkan**，桌面 Vulkan 后端仍是 P2 设计稿）；macOS = Metal（wide gamut 默认）；Android API 29+ Impeller / 旧机 GLES 回退；iOS 仅 Impeller。引擎确认日志 `Using the Impeller rendering backend (OpenGLESSDF)`。**降级 3.38.10 时**：桌面默认回 Skia（Impeller 需手动 flag），macOS/Android 不受影响（3.29/3.27 起即默认） |
| 语言 | Dart | **3.13.3**（配 Flutter 3.47.4；~~3.13.5~~ 是 3.47.6 的配套版本，**此前写错已修正**）；降级线 **Dart 3.10.8**。`flutter_lints` |
| 原生 | Rust `cdylib` | **1.96.0**，`reqwest 0.13 + tokio + serde + md5 + aes + cbc`；构建经 `native_toolchain_rust`。**`wasmtime/extism 1.21` 延后至 P2**（随源扩展启用，v0.5 不需要） |
| FFI | `dart:ffi + ffi ^2.2.0 + ffigen.yaml + hook/build.dart` | 3.38+ 推荐模板；`DynamicLibrary` 只在生成绑定内 |
| 路由/状态/DI | `go_router + riverpod(3)`（**替代 provider/get_it**） | MVVM，不引入 Bloc（Q32 已决） |
| 模型 | `freezed + json_serializable` | Domain 不可变 |
| 网络/解析 | **全在 Rust**（v0.6 修订） | ~~`dio + html`（Dart 侧兜底）~~ **已删除**：轨道 ① 的 SSR 解析与轨道 ② 的签名请求都在 Rust，Dart 侧不再需要网络/HTML 库，详见 §2.1-C。**TLS 指纹 P0 不做（Q8=a）**：reqwest 无 Chrome 指纹，rquest 评估记 P1 [G2] |
| 播放 | `media_kit 1.2.6 + media_kit_video 2.0.1 + media_kit_libs_video ^1.0.7` | 支持 HLS/MP4，硬解 `mediacodec/videotoolbox`，Release 测性能；**与 guoapp 同款，且其 CI 已在 Flutter 3.47.4 完成编译验证（EVIDENCE §16）**——**M0 spike 重点（v0.6 再次修订）：① 轨道 ① 免签明文直链能否真机播通（不碰 CENC）；② 播放真机是否回归**（guoapp 未覆盖该范围）；**③ mpv `decryption_key` 解红果 CENC（spade_a 派生）改到 M1 验证——v0.6 起已从"P0 阻断项"降为"M1 增强项"，不通过则降级为"仅可试看集可播"，不阻断发布**；**Windows 原生库仅 x64**，pin 策略见 §6；iOS 需防上游 `exit(1)` 兜底 [G14] |
| UI | `liquid_glass_widgets 1.13.0`（git/path 引入，先不发 pub） | premium 需 Impeller（3.47 起默认满足）；Windows/Linux 在 adaptive 下仍钳 standard（包平台规则，与渲染器无关）；P0 按 §4 per-platform maxQuality 验收；列表用 `minimal` |
| 存储 | `drift(sqlite) + path_provider + shared_preferences` | 目录/追剧/下载索引分离文件，32MB 上限保护 |
| 源实现 | **P0：`sources::hongguo`（Rust 内置，实现 `SourceProvider` trait）** | **① 免签官网 SSR（`_ROUTER_DATA`）为主**——目录/榜单/详情/选集/搜索 + 可试看集明文直链；**② App API（fqnovel）签名兜底**——X-Gorgon + 设备伪装 + spade_a→CENC + bytevc2 过滤（EVIDENCE §17.4）。**M0 只做 ①**，CENC 属 M1 增强。**禁用第三方中转域名。****WASM 插件 / 声明式规则 延后至 P2** |

**Impeller 基线注意（Q9）**：

* Windows/Linux embedder 在 Impeller 开启时自动追加 `--impeller-use-sdfs=true`（Linux 无条件），字形走 SDF + gamma 校正——文本度量微变是预期行为，golden 基线需在新渲染器下重采（§8）。
* Windows 无隐式 MSAA 的 GPU 走 offscreen MSAA 路径（3.47 cherry-pick #190374）；custom FragmentProgram shader 若引入，须过 `impellerc` GLES target 编译并在三平台真机验证（驱动差异暴露不同 bug）。
* Skia 回退仅应急：macOS `Info.plist FLTEnableImpeller=false` / Windows `main.cpp set_impeller_switch(Disabled)` / Linux `fl_dart_project_set_enable_impeller(project, FALSE)`；官方已声明回退未来移除，本项目不建双渲染路径。
  **降级 3.38.10 情形**：桌面默认即 Skia，Windows/Linux 需主动开 Impeller（`--enable-impeller` / runner 内 flag），
  此时桌面 Impeller 属"实验性启用"，SDF 文本与 offscreen MSAA 行为与 3.47 线不同，验收按"手动启用后实测"而非"默认即得"。
* **3.47 Material/Cupertino 独立包化**：`material_ui`/`cupertino_ui` 可独立于 SDK 发版，核心 SDK 旧设计库排期 Fall 2026 弃用；M0 定夺迁移策略，CI 加 import 一致性检查防新旧混用（§8）。

### 2.1 Dart / Flutter 包清单

> **分三类**：A = 版本号有实证（可直接抄）；B = 本项目架构新增、guoapp 未用（版本待 M0 锁定）；
> C = 明确不引入。**纪律：文档里出现的版本号必须能回溯到实证；无实证的一律标"待锁"，不得拍脑袋写。**

**A. 已实证（出处 = guoapp `pubspec.yaml` / `liquid_glass_widgets` `pubspec.yaml`）**

| 包 | 版本 | 用途 | 出处 |
|---|---|---|---|
| `flutter_localizations` | sdk | 本地化（F-09 主题/语言） | guoapp:12-13 |
| `ffi` | `^2.2.0` | FFI 基础类型 | guoapp:14 |
| `media_kit` | `1.2.6` | 播放内核 | guoapp:15 |
| `media_kit_video` | `2.0.1` | 视频渲染 | guoapp:16 |
| `media_kit_libs_video` | `^1.0.7` | 原生解码库 | guoapp:17 |
| `path` | `^1.9.1` | 路径处理 | guoapp:18 |
| `path_provider` | `^2.1.5` | 平台目录 | guoapp:19 |
| `shared_preferences` | `^2.5.5` | 轻量键值（设置/小状态） | guoapp:20 |
| **`flutter_foreground_task`** | `11.0.3` | **Android 前台服务 —— F-07 下载必需**（系统杀进程后保留任务与完整文件） | guoapp:21 |
| `crypto` | `^3.0.7` | 哈希 | guoapp:24 |
| **`window_manager`** | `^0.5.1` | **Windows 桌面窗口控制**（P0 含 Windows） | guoapp:25 |
| **`liquid_glass_widgets`** | `1.13.0` | 玻璃 UI | GL `pubspec.yaml:3` |
| `flutter_lints` | `^6.0.0` | dev / lint | guoapp:33 |

> **玻璃包的两个关键事实**（GL `pubspec.yaml:26-31,45-50`）：
> ① `environment: sdk >=3.5.0 <4.0.0`、`flutter >=3.41.0` —— **3.47.4 满足**；
> ② **零运行时依赖**（只依赖 `flutter`），并自带 **5 个 `.frag` shader**（`lightweight_glass` / `interactive_indicator` /
> `liquid_glass_geometry_blended` / `liquid_glass_render` / `progressive_blur`）→ 必须走 §6 的 **Impeller shader 预编译**，否则首帧白闪。

**B. 本项目架构新增（guoapp 未用；版本待 M0 `flutter pub add` 后锁定并回写 EVIDENCE）**

| 包 | 用途 | 备注 |
|---|---|---|
| `go_router` | 路由 | 声明式路由 + deep link |
| **`flutter_riverpod` + `riverpod_annotation` + `riverpod_generator`** | **状态管理（MVVM）+ DI**，替代 `provider`/`get_it`（**不引入 Bloc**） | **Q32 已决（2026-10-15，用户）：采用 Riverpod 3**；版本待 M0 `pub add` 锁定并回写 EVIDENCE §19 |
| `freezed` + `json_serializable` + `build_runner` | 不可变 Domain 模型 + 序列化 | dev + codegen |
| `drift` + `sqlite3_flutter_libs` + `drift_dev` | 结构化存储 | 替 guoapp"单 key 16MiB JSON 快照"，保留三条提交语义（§5.1）；**与 `shared_preferences` 的分工见 Q31** |
| `ffigen` | FFI 绑定生成 | dev；**ABI 仅 3 个函数**；采用生成（Q32 已决） |
| `native_toolchain_rust` + `code_assets 2.1.0` | 构建期编译 Rust 并打包为 Dart asset | 3.38+ 推荐模板 [ARCH 头] |
| `intl` | 数字/日期格式化 | |
| 海报缓存（**`cached_network_image` 或自研 LRU**，见 QUESTIONS Q30） | 30 天 / 256MiB / 2000 张 [G6] | guoapp 是自研 `app_covers.go` |

**C. 明确不引入**

| 包 | 理由 |
|---|---|
| `ffmpeg_kit_flutter_new_min_gpl` (guoapp:22, `2.6.2`) | guoapp 用于 remux / 画质增强；**GPL 有传染性**，P0 不需要，画质增强维持 P1 Win 专属 |
| `nsd` (guoapp:26, `5.0.1`) | LAN 已整个砍掉（Q10） |
| ~~`dio` + `html`~~ | **v0.6 删除**：网络与 SSR 解析全在 Rust，Dart 侧不再需要（原 §2"Dart 侧兜底"作废） |
| `wasmtime` / `extism` | 源扩展延后 P2 |

### 2.2 Rust crate 清单（`rust/core/Cargo.toml`）

| crate | 用途 | 依据 |
|---|---|---|
| `reqwest 0.13` + `tokio` | HTTP 引擎（TLS ≥1.2） | 指纹 P0 不做（Q8=a） |
| `serde` + `serde_json` | ABI JSON 信封 + `_ROUTER_DATA` 解析 | ARCH §3 |
| `regex` | `_ROUTER_DATA` 定位：`(?s)(?:window\.)?_ROUTER_DATA\s*=\s*` | EVIDENCE §17.5 |
| **`url`** | URL 拼装与 query 规范化 | ⚠️ **签名对 query 的精确字节敏感**（X-Gorgon 吃 `RawQuery`），必须精确控制编码，不能手写拼串 |
| `md5` | X-Gorgon 签名 | EVIDENCE §17.1 |
| `aes` + `cbc` | 备用接口 AES-CBC 响应解密 + PKCS7 | EVIDENCE §17.1 |
| `base64` | spade_a 解码、媒体地址二次解码（Strict→RawStd 两次尝试） | EVIDENCE §17.2 |
| `thiserror` / `anyhow` | 错误建模（二选一，建议 `thiserror` 给库错误） | |
| `tracing` | 结构化日志（**必须配脱敏**，签名头/device_id/密钥不落日志） | SourceSpec §11.3 |
| `once_cell` 或 `LazyLock` | 全局单例（引擎状态、限流器） | |

**延后 / 待评估**：`wasmtime`/`extism`（P2 源扩展）、`rquest`（P1 TLS 指纹）、`scraper`（P2 声明式规则的 CSS 选择器，§8.3）。

### 2.3 平台工具链

| 平台 | 工具链 | 依据 |
|---|---|---|
| Android（3.47 线） | AGP **9.1.0** / Gradle **9.3.1** / compileSdk **36** / minSdk **24** / Java **17** / NDK **r28**（16KB 页对齐） | PRD §3 |
| Android（降级 3.38 线） | AGP 8.11.1 / Gradle 8.14 / compileSdk 36 / minSdk 24 / Java 17 | PRD §3 |
| Windows | VS 2022 + C++ CMake；**原生库仅 x64**（arm64 直接 `FATAL_ERROR`） | EVIDENCE §16 |
| macOS | Xcode；**最低 macOS 12**（3.47 线；降级线为 10.15） | PRD §3 |
| Rust target | `aarch64-linux-android` / `x86_64-pc-windows-msvc` / `aarch64-apple-darwin` + `x86_64-apple-darwin` | ARCH §6 |
| Android 15+ | `.so` 16KB 页对齐：`-C link-arg=-Wl,-z,max-page-size=16384` | ARCH §6 [G12] |

### 2.4 版本锁定纪律（**防拍脑袋**）

1. **一切版本号以 EVIDENCE 为准**：文档里每个版本号必须能回溯到实证（guoapp pubspec / 包自带 pubspec / 官方 changelog）。
   无实证的一律标 **"待锁"**，不得凭印象填写（本项目已在 Q9 上踩过一次"追最新"的坑）。
2. **M0 一次性锁定**：`flutter pub add` 后**提交 `pubspec.lock` 与 `Cargo.lock` 进仓**，
   并把关键包的解析结果回写 EVIDENCE（新建 §19「依赖锁定快照」）。
3. **media_kit 组合锁死**：`1.2.6 / 2.0.1 / ^1.0.7` 是**唯一有编译实证的组合**；
   任何升级必须与 Flutter 基线联动评估，遵循 Q9 规则（**由依赖兼容性反向决定，不由"追最新"决定**）。
4. **Windows 原生库 pin**：M0 决断"用上游库 vs 自建 pinned 包（照 guoapp `1.0.11+duanju.1`）"；
   无论哪种，**构建期必须校验归档 SHA256**，且 Windows ARM64 明确不支持（写进产物校验清单）。
5. **Rust 依赖审计**：`cargo vet` + `cargo-deny`（license /  advisories / 重复依赖）进 CI 门禁（§6）。

## 3. 工程结构

```text
apps/drama_app/
 lib/{data/{models,repositories,services},domain/{models,use_cases},ui/{core,features/*},extensions/}
 rust/core/{Cargo.toml,src/{lib.rs,http.rs,
   source/{mod.rs,traits.rs},
   sources/hongguo/{mod.rs,
     web_ssr.rs   ← ① 免签：_ROUTER_DATA 提取 + 目录/榜单/详情/选集/播放页
     app_api.rs   ← ② 签名：fqnovel 调用 + 设备伪装
     sign.rs      ← X-Gorgon（8404 变体，勿照抄开源 8402 实现）
     media.rs     ← spade_a 派生 + bytevc2 过滤 + AES-CBC},
   stream.rs,download.rs},drama_core.h}
 hook/build.dart  ffigen.yaml  tool/ffigen.dart
docs/  test/  integration_test/
```

* `source/traits.rs` 定义 `SourceProvider` trait，`sources/hongguo/` 是其 P0 唯一实现。
  **P2 扩展源（WASM 宿主 / 规则求值器）加在 `sources/` 下并实现同一 trait**，调度层与 UI 不动。
* ~~`extensions/official/*`~~ 移除（v0.5：无官方扩展源分发）。

* `lib/` 禁平铺 80+ 文件；按 feature 分 `views/view_models`。

### 3.1 FFI 契约（窄 ABI）

```c
const char* drama_request(const char* utf8_json); // Rust 侧复制入参，返回 owned CString
void drama_free(const char* p);                    // 与分配器配对，Dart 解码后必调
```

* JSON-RPC：`{v:1, op:"catalog|search|detail|play|...", source, params}` → `{ok, data|error{code,msg,retry}}`。
  **无 `user` 字段**（Q3：多用户移除，全局单命名空间）。
* 信封硬规则 [G1]：入口 panic recover 为 `{"ok":false,"error":"本地核心处理失败，请重试"}`；输入 >1MiB 拒；
  引擎级错误码只有 `local_media` 与 `source_blocked`（后者带 `retryAt` 毫秒时间戳）。
* 内存：Dart 侧 `try/finally` + `Arena` 短生命周期，`NativeFinalizer` 仅兜底；`asTypedList` 不出作用域。

### 3.2 取消协议与分级超时（照抄 guoapp 后简化 [G1]，Q7=a）

* **session/sequence 仲裁**：调用方每次读请求带 `session`（`[0-9a-zA-Z-_:.]`，≤128 字符）与单调递增 `sequence`；
  旧 sequence 的迟到响应直接丢弃（Canceled）；同 session 新请求取消旧在途。
  需仲裁的 op：`catalog/search/detail/suggestions/recommendations/preload`（danmaku 暂缓，编号保留 [G1]）。
* **读并发**：前台在途 ≤16；完成 read 15min GC；播放解析（`play`）全局串行（同时只允许一个）。
* **分级超时（外层 Dart > 内层 Rust，内层先到期）**：

| op | Dart 外层超时 | Rust 内层超时 |
|---|---|---|
| 默认（目录/详情/搜索） | 70s | 60s |
| 预加载 preload | 20s | 15s |
| 下载迁移 moveDownloads | 620s | 600s |

（danmaku 15s/10s 一档随 F-08 暂缓冻结备查。）

* **超时≠对端停止**：Dart 超时后必须补发 `cancelRead{session,sequence}`，否则引擎侧在途请求泄漏。
* **用户切换令牌取消（Q3）**：多用户移除后无 profileEpoch/切换概念——session 生命周期 = App 生命周期，
  原"切换用户作废全部在途请求"契约删除（guoapp 该契约见 EVIDENCE §1，本项目不采纳）。
* **简化点（Q7=a）**：guoapp 的"新 session 且总 reads ≥128 拒绝"双阈值在单用户下简化为常量上限；
  sequence 仲裁与超时补发两条不动。**请求 ID + generation 令牌重设计记 P1 引擎演进项**（Rust tokio 常驻 worker 成熟后可去显式 sequence，P0 不做）。
* **编译变体核对**：`initialize` 返回 `version` 与 `allSources` 能力标志，Dart 启动核对一致，防混装（本项目用 caps 取代编译变体后，核对内容改为 core 版本与 minCore 协商）。
* **isolate 形态**：guoapp 每次 `Isolate.run` 现开现弃（Go 单例+mutex）。Rust+tokio 下改良为**常驻 worker isolate + 端口复用**，
  超时校验留在 Dart 契约层；worker 内单线程消费，杜绝 UI isolate 阻塞。

### 3.3 本地流服务 StreamGateway（契约照抄 [G3]）

* 监听 `127.0.0.1:0` 随机端口；ReadHeaderTimeout 5s / IdleTimeout 30s / MaxHeaderBytes 16KB；仅 GET/HEAD。
* 会话寻址：24 随机字节 hex token；plan 先带**直媒 URL + UA/Referer headers**，替换为本地流地址后再给 media_kit；
  playbacks map 上限 8、12h 过期；未知 session → **410 Gone**。
* 资产寻址 `sha256(address+contentType)[:12]+ext`，会话级缓存。
* **HLS 重写五类 URI**（一个都不能少）：`EXT-X-KEY/SESSION-KEY`→注入 16 字节密钥（octet-stream）；
  `EXT-X-MAP`→video/mp4；`EXT-X-MEDIA/I-FRAME-STREAM-INF/RENDITION-REPORT`→m3u8；`data:` 原样保留。
* 透传 `Range/If-Range`；上游 playlist ≤4MB 且必须以 `#EXTM3U` 开头；非 200/206 翻译为错误码后原状态码透传。
* 预取预算：总 4MiB、≤8 请求、深度 ≤2；master 只取 2 分片或累计 8s；解析 6s 预算；
  `Content-Range` + `ETag/Last-Modified` 校验，无 validator 或 weak validator 放弃缓存；
  `If-Range` 校验失败 → invalidate 同地址所有资产。

### 3.4 播放恢复与预加载契约（照抄代码 [G4]）

* 卡顿判定：`stallTimeout=20s`，条件 = `playing && foreground && position 1s 无变化`；**暂停/后台不触发**；900ms 防抖。
* 恢复链（代码事实，README 的"降画质"分支不存在）：有备用线路 → 切线路；否则未 refresh 过 → 重新解析；
  每轮 `maxAttempts=3` 后停止；本地播放直接 stop。切线路保留进度与倍速；**手动画质只切同画质线路**。
* 预加载触发：position ≥2s；`position < duration/2 且 duration-position > 45s` 时不触发；缓冲余量 `buffer-position < 5s` 不触发。
* 计划寿命：就绪计划 2min；带 `expiresAt` 的计划提前 5s 停复用；失败 ≥30s 重试；切集/后台取消在途。
* 进度保存：5s 周期 + 去重 key；**保存失败显示警告条 + 重试按钮，不静默丢**。
* mpv 参数基线：buffer 32MB、network-timeout 20、seg_max_retry 3、`decryption_key=<hex>`、`allowed_extensions=ALL`。

## 4. UI 设计（液态玻璃，v0.3 按 1.13.0 源码 + Impeller 基线重写 [G9]）

* `main()`：`WidgetsFlutterBinding.ensureInitialized()` → `await LiquidGlassWidgets.initialize()` → `runApp(LiquidGlassWidgets.wrap(...))`。
  - `initialize()` 纯异步磁盘 I/O 不阻塞首帧，**失败不抛异常**；shader 未就绪时 premium 面渲染空白（首帧白闪来源）→ 首帧 UI 不得依赖 premium 面。
  - `wrap(adaptiveQuality:true, respectSystemAccessibility:true, brightnessResolver: Theme.maybeBrightnessOf)`；
    `respectSystemAccessibility` 默认 true 可省；**brightnessResolver 对 MaterialApp 必需**（否则 ThemeMode 与 OS 亮度不一致时阴影/边框丢失）。
  - MaterialApp 三件套：`brightnessResolver` + `Material(type: MaterialType.transparency)`（否则 Text 黄色下划线）+ `cupertino_icons` 直接依赖。
    （3.47 Material/Cupertino 独立包化，import 路径迁移期兼容；三件套语义不变，迁移策略见 §8。）
* 屏用 `GlassScaffold(appBar:GlassAppBar, bottomBar:GlassTabBar.bottom)`；弹窗用 `GlassModalSheet.show / GlassDialog.show`；菜单用 `GlassMenuItem(submenu:[])`。
* **只用高层 Glass\* widget，禁 import `src/` 直接用 `LiquidGlass`**（premium 档 Impeller-only；全面 Impeller 后该约束自然满足，但 web/测试环境仍不渲染）。
* **premium 禁用于滚动列表**（texture 不感知滚动）；列表一律 `minimal` 或 standard。
* 禁玻璃套玻璃：`GlassButton/Slider/Switch` 不进 `GlassCard`，卡内用 `GlassListTile`；嵌套是**静默降质**（`avoidsRefraction` → `_VibrancyFill`，无 blur 无折射、alpha 钳 0.08–0.45），不是报错。
* `GlassButton.onTap` vs `GlassIconButton.onPressed`；`GlassChip.label` 为 String；`GlassAppBar.actions` 非 `trailing`；`GlassBarItem.icon` 也是 `onTap`。
* `platformViewBackdrop` 是 per-widget 核弹：置 true 强制 `_FrostedFallback`，premium 静默失效且每帧一个活 BackdropFilter；
  仅给真正压在 PlatformView（视频/地图）上的那几个 widget 开。
* **钳制三层**（均对显式 `quality:` 生效，是天花板不是地板）：
  ①渲染期 `isShaderFilterSupported`（Impeller=true；仅 web 与 Android 旧机 legacy GL 为 false）；
  ②adaptive Phase 1：`isShaderFilterSupported=false`→**强制 minimal**（Android API <29 旧机），`kIsWeb||Windows||Linux`→钳 standard
  （**注意：3.47 起 Windows/Linux 已默认 Impeller，shader 能力不再是瓶颈，但包的平台钳制规则仍把 Windows/Linux 钉在 standard——Impeller 解除了能力限制，没解除平台策略**）；
  ③Phase 2/3 动态：跳过 90 帧收集 180 帧，P75<20ms→premium、20–28→standard、>28→minimal；
  P95>16×1.5 连续 2 窗口降档、<16×0.6 连续 10 窗口升档、8s 冷却。**App resume 会重跑 Phase 2 benchmark**（恢复瞬间可能再降/升档，UI 不得假设档位稳定）。
* **P0 验收档位（per-platform maxQuality 策略，v0.3 定稿）**：
  - **macOS = premium**：Impeller Metal，桌面 GPU 多落 premium；wide gamut 3.47 起默认开，设计稿按广色域取色。
  - **Windows = standard**：adaptive 开启即被 Phase 1 钳 standard，与渲染器无关。**Windows 冲 premium 记 P1 实验**：
    需真机验证 Impeller-ANGLE（GLES→D3D11）路径下 `isShaderFilterSupported` 与双通道 GLSL 的实际表现，未验证前不得作为验收档。
    （**降级 3.38.10 时**：Windows 退化为"shader 能力不足"而非"平台策略"，standard 结论不变但该实验取消。）
  - **Linux = standard**：同 Windows。
  - **Android API 29+ = standard~premium**：Phase 1 不钳 Android，由 Phase 2/3 动态定档；**滚动列表一律 minimal**（premium 禁用于列表）。
  - **Android API <29 旧机 = minimal**：legacy GL → `isShaderFilterSupported=false` → Phase 1 强制 minimal；功能不降级，只降玻璃。
  - iOS/OHOS 档位 P1 再定（iOS 三档可用；OHOS 按 minimal）。
* 内容层（海报墙/播放画面）不透明；玻璃只在功能层；档位选择链 widget→inherited→theme→class-default，全部被 `GlassAdaptiveScope` 天花板覆盖；
  `GlassScaffold` 把 appBar/bottomBar 自动提 premium（仍受天花板钳制）。

### 4.1 液态玻璃设计系统（v0.5 新增：UI 是本项目 P0 核心差异化）

> §4 讲的是"玻璃怎么用不踩坑"（机制），本节讲"界面长什么样"（设计）。
> 组件名**全部取自 §4 已核实过的 `liquid_glass_widgets 1.13.0` 高层 API**，不臆造 widget。

**导航骨架**

```text
GlassScaffold
 ├─ GlassAppBar        (标题 + actions)
 ├─ body: 内容层       (不透明：海报墙 / 视频 / 封面)
 └─ GlassTabBar.bottom (首页 · 榜单 · 追剧 · 我的)
```

**页面 → 玻璃层级 → 组件映射**（页面来自 PRD F-01~F-07）

| 页面 | 玻璃出现在哪 | 组件 | 档位约束 |
|---|---|---|---|
| 首页（分类 + 海报墙） | AppBar / TabBar / 分类 Chip；**海报墙不透明** | `GlassAppBar` + `GlassChip`(分类) + `GlassTabBar.bottom` | 海报网格 `minimal` |
| 搜索 | AppBar 内搜索框 + 联想下拉 | `GlassAppBar` + `GlassModalSheet`(联想) | 联想列表 `minimal` |
| 榜单 | 同首页 | 同首页 | `minimal` |
| 详情 | 封面不透明；底部"播放/下载/追剧"操作条 | `GlassButton` + `GlassListTile`(选集) | 选集长列表 `minimal` |
| **播放** | **控制条浮在视频上** —— 全项目**唯一**需要 `platformViewBackdrop:true` 的场景 | `GlassIconButton` + `GlassSlider`(进度) | 控制条由 Scaffold 提 premium |
| 追剧 / 历史 | TabBar + 列表项 | `GlassListTile` | `minimal` |
| 下载 | TabBar + 任务项 | `GlassListTile` + `GlassSwitch` | `minimal` |
| 设置 | 分组卡片 | `GlassCard` + `GlassSwitch` + `GlassMenuItem` | standard |
| 弹窗 / 菜单 | 模态层 | `GlassModalSheet.show` / `GlassDialog.show` / `GlassMenuItem(submenu:)` | standard~premium |

**四条设计纪律**

1. **内容层不透明**：海报墙、视频画面、封面一律不透明；玻璃只出现在**功能层**（栏 / 条 / 卡 / 弹层）。
2. **能见性优先于质感**：玻璃面下的文字必须满足对比度——`premium` 的折射会让文字边缘发虚，
   **标题与正文不得放在 premium 面上**（premium 只给栏、条、弹层这类无正文的面）。
3. **列表绝不 premium**（机制见 §4：`texture` 不感知滚动）：长列表与网格一律 `minimal`。
4. **不嵌套玻璃**（机制见 §4：静默降质不报错）：卡内用 `GlassListTile`；`GlassButton/Slider/Switch` 不进 `GlassCard`。

**降级路径（与 F-09 联动）**：开启大字 / 高对比 / 减弱动效时 → **全站降 `minimal`**（玻璃退化为半透明纯色面），
功能不降级、只降质感；必须保留 §4 的 `respectSystemAccessibility` 语义。
档位始终由 `GlassAdaptiveScope` 天花板决定，**UI 不得硬编码档位**（App resume 会重跑 benchmark，档位可能变）。

## 5. 数据与缓存

* `Drama{id,source,title,cover,eps,status,vip}` / `Episode{no,url,quality}` / `PlaybackPlan{url,headers,expiry}` 不持久化带时效 URL。
  （`vip` 三态字段仅预留，UI 后置，见 PRD §4。）
* 目录 15min、榜单 5min（24h 回退）、海报 30 天 LRU；预加载复用根 playlist。
* **"未落盘=不新鲜"语义必须保留**（guoapp 事故 P1-R8：写入失败却标 Fresh，重启丢数据）[G6]：
  保存失败记 NeedsSave、未落盘结果 `Fresh=false, HasMore=true`、下次请求先重试保存、成功才清标记。

### 5.1 本地状态提交（照抄语义、替换实现 [G6]；Q3 移除多用户后简化）

* drift(sqlite) 替 guoapp 的"单 key 16MiB JSON 完整快照"，但三条契约保留：
  1. **串行写队列**：所有写首尾相接，前一个失败不阻断后一个；
  2. **原子提交 + 失败回滚**：事务失败 reload 恢复 previous；
  3. **不可恢复即锁死**：连续校验失败锁死访问，提供原始配置导出/重读。
     **多用户/PIN 移除后（Q3），"管理员密码恢复"与"不回退成无密码管理员"两条取消**——该风险面（他人拾得设备改配置）
     归操作系统锁屏；"保存失败可见 + 可重试"与"未落盘=不新鲜"两条保留（§5）。
* 回归必须复刻故障注入三态：写返回 false / 抛错 / 先写后抛（after），断言"内存有值、重启后是旧值、界面可恢复"。
* 备份 8MiB 上限；记录上限 favorites 20000 / history 300 / recentSearches 20（PIN/profiles 随多用户移除取消）。
  损坏恢复：可重试 + 保留原文件不覆盖；是否含已安装源清单与授权决定待 QUESTIONS Q14。

### 5.2 目录迁移安全（照抄 [G6]）

EvalSymlinks 解析目标；目标必须不存在；**源/目标互相包含即拒**；符号链接一律拒绝；
暂停全部任务→等待 worker 退出→逐文件拷贝（512KB 缓冲、O_EXCL、0600、每文件 fsync）→写 location→删源；
任一步失败删目标保源。迁移前检查下载索引，损坏/超大/非普通文件拒绝迁移。

### 5.3 下载硬契约（逐条保留 [G5]）

* 任务 ID=`sha256(dramaID+index)[:16]`；状态 queued→downloading→completed/failed + paused/archived；
  索引 ≤32MiB，加载逐条校验（ID/Folder/File 仅 `media.mp4` 或 `index.m3u8`/状态枚举），任一不过整库拒绝；中断任务→paused。
* 入队 1–500 集/次、未归档 ≤5000；保存失败整体 rollback；批量用 `created-bytes-quality[-revision]` 乐观锁防误删。
* 续传三元组 `target + target.part + target.json`（URL/Validator/Total/Complete）；
  `Range`+`If-Range`；30s 无活动取消；`Accept-Encoding: identity` 且拒绝非 identity Content-Encoding；
  **拒绝 text/html 与 application/json 响应体**；416/412→整体重启；206 校验 Content-Range；密钥 total≤64 且最终必须 16 字节。
* HLS：walk 深度≤6、visited≤100、单 playlist≤4MB、**必须 `#EXT-X-ENDLIST`（拒直播/未结束）**、拒绝 `{$` 变量地址、
  仅 AES-128/NONE 且 KEYFORMAT identity/空、资产≤20000；`.bundle` 指纹不一致先 RemoveAll 再下（换线路/密钥=重下）。
* 调度：并发默认 2、上限 6、FIFO、进度落盘节流 1s；单任务最多试 3 条线路。

## 6. 构建/打包/安全

* `hook/build.dart` 按 `targetOS/arch` 编 Rust（P0：`aarch64-linux-android / x86_64-pc-windows-msvc / aarch64-apple-darwin+x86_64`），产物 hash 校验；link 期 tree-shake；符号保留 dSYM/PDB。
* **Android 15+ 16KB 页对齐**：cargo 传 `-C link-arg=-Wl,-z,max-page-size=16384`；`strip=true` + `-trimpath` [G12]。
* 第三方库 Meditation：`reqwest/wasmtime/extism/mpz` 记版本/license/哈希/CVE；`cargo vet + cargo-deny` 门禁；禁止运行时加载用户路径 `.so/.dll`。
* **产物校验清单化**（构建即校验、失败即终止）：Android 核对 `.so` 清单；Windows 核对 DLL 清单（exe/flutter_windows.dll/libmpv/msvcp/vcruntime/icudtl/data）；
  全部产物 `SHA256SUMS.txt`；cdylib 导出符号表与 `drama_core.h` diff 检查（对应 guoapp iOS `nm -gU` 核对）[G12]。
* **Impeller shader 预编译**：`impellerc` 产物随 Release 包分发，构建期校验存在性（缺漏即构建失败）；custom FragmentProgram shader 若引入，须过 impellerc GLES target 编译并在三平台真机验证。
* **media_kit Windows 原生库 pin（v0.4 新增，P0）**：guoapp 用 `dependency_overrides` 把 `media_kit_libs_windows_video` 指向自维护包
  `1.0.11+duanju.1`（按 URL + SHA256 下载 pinned 归档并落 `.duanju-sha256` 校验），其 CMake 对非 x64 / `windows-arm64` 直接 `FATAL_ERROR`
  （证据 EVIDENCE §16）。M0 决断"用上游库 vs 自建 pinned 包"；无论哪种，**构建期必须校验归档 SHA256 且 Windows ARM64 明确不支持**，
  该结论要写进产物校验清单（否则 Windows ARM64 后补时会撞到原生库层面的硬失败）。
* **包级冒烟进 CI**：Windows Release 包解包后真跑一次（初始化→打开合成媒体→推进≥400ms→退出码 0）。
* **变体/能力单一事实源**：一个 feature 参数同时注入 Rust 编译与 Dart dart-define，启动经 FFI 核对一致防混装（guoapp `--all-sources` 模式；本项目 caps 化后核对 core 版本）[G12]。
* WASM 沙箱：默认无 FS/NET，HTTP 经 host 函数按 `domains` 放行，6s/4MB/8 请求熔断，panic 不跨 ABI。
  **限流/退避是引擎唯一权威，插件不自行退避**（Q6=a：per-source 串行 gate、前台优先、Retry-After 封顶 30min）[G2]；
  媒体请求不走限流器。TLS 指纹 P0 不做（Q8=a），rquest 评估记 P1。

## 7. 多端分支策略

* `main` 只合 P0；`feat/ios|linux|tv|ohos` 独立分支。**iOS 列 P1 末位（Q12=b）**：P0 三平台稳定前不启动 iOS 真机工作；
  **OHOS 待 P0 发版后再调研（Q11）**：分支追不上 main 的风险（FFI/播放/存储三处分叉）用"P0 发版后集中 spike + 独立分支"消化。
* Web 不做（`dart:ffi` 不支持）。
* **LAN 同步/推送播放整个砍掉（Q10）**：不再设 lan 分支；跨设备迁移由备份导入导出替代，EVIDENCE §11 协议留证备查。
* **iOS 分支前置风险（P1 末位，但风险预研不推迟）**：media_kit_video 上游 `mpv_render_context_create` 失败直接 `exit(1)`
  （guoapp 0.2.40 兜底：iOS 禁用硬件纹理）；后台下载仅前台+回前台续传。进 P1 首批前需真机验证 [G14]。
* **TV 分支焦点模型**（guoapp 0.2.51 遥控反馈重做）：显式越界接管——网格第一行按上回分类栏、第一列按左回侧栏、
  分类栏按上到标题栏、按下的回网格、多选时末行按下到操作栏；**每个页面补初始焦点兜底**（避免进入页面按键无响应）；
  48×48 触控目标；控制条 5s 隐藏；seek ±10s；识别用 MethodChannel 2s 超时 fallback，Leanback/Fire TV 特征保守判断 [G9]。

## 8. 测试策略（v0.4 改为 3.47.4 基线验证 + 降级路径，原 SDF 回归保留 [G12]）

* Dart 单测（VM/Repo/源解析）+ Rust `cargo test + clippy -D warnings + fmt` + ABI 对照（sizeof/offset + 导出符号表 diff）+ 真机集成（Release）+ 源合规向量 + 性能基线（首帧/分页/内存）。
* **合成媒体三件套**：ffmpeg 生成 MP4 / AES-128 HLS / CENC 三种夹具；本地 HTTP 服务支持限速（`?slow=1`）、断网开关（`/_test/offline`）、
  `deniedRequests` 计数——用"离线播放零回源"断言隔离沙箱外请求。
* **dart-define 隔离外部依赖**：`DISABLE_REMOTE_IMAGES`（误配即测试失败，自我校验）、`FIXTURE_BASE_URL`（必须 127.0.0.1）。
* **故障注入矩阵**：写路径 false/throw/after 三态；ScriptedPlayer 伪造 open/seek/速率状态机；Repository 用 Completer 延迟/失败，统计 primary/fallback 次数。
* **平台 overlay**：`debugDefaultTargetPlatformOverride` 同 VM 切平台行为；mock 平台通道（PiP/设备识别）免真机做分支对照。
* **源合规向量进 wasmtime 单测**：固定响应样本（HLS 文本/AES 目录 JSON/签名错误/CF 挑战页）随测试提交，防源站变动静默劣化。
* **3.47.4 基线验证（M0 出口，Q9 修订）**：
  - **不用跑 Skia 基线 A/B**（guoapp 已在同版本完成编译验证，风险不在"能否编过"）；
    重点改为 **media_kit 播放三件套真机**：Windows/macOS 上 MP4 / AES-128 HLS / CENC + 硬件解码 + 长路径场景，不通过则降级 3.38.10 并重跑；
  - 合成媒体三件套在新渲染器下重跑不回归；玻璃三档真机过（macOS premium / Windows standard / Android 旧机 minimal）；
  - `dart analyze` + `flutter test` 全绿（VM golden 不受 SDF 影响；集成截屏基线需重采）；
  - 若降级 3.38.10：补一条 Skia 基线对照（保留 3.38 检出对压力屏截屏 + 帧时间对比），并复核降级后 wide gamut / macOS 最低版本差异。
* **SDF 文本 golden 回归**：固定字号/字重/中英混排 + emoji 渲染对比，防 SDF + glyph gamma 变化破坏大字布局（F-09 验收固化方式）；
  组合 emoji 安全截断逻辑（FE0F/FE0E/200D 前回退）与渲染器无关，随 F-08 冻结不进 P0。
* **独立 UI 包迁移检查**：3.47 `material_ui`/`cupertino_ui` 独立发版，CI 加 import 一致性检查防新旧混用；迁移策略 M0 定夺（PRD §3）。
* **真机矩阵最小集**：1 台 ARM64 Android（独立 debug 包 + `adb reverse`）+ Windows x64 包冒烟 + **macOS 一台（premium 玻璃真机验收）** +
  **1 台 Android API <29 设备/模拟器（legacy GL 回退路径）**；TV 焦点 overlay 先行、真机抽查推迟 P1；**iOS 真机推迟到 P1 末位**（Q12）。
* **大字布局回归**：360×640 与 1100×720 两种物理尺寸的 widget 测试（F-09 验收固化方式）。
* **路径纪律**：CI/脚本保持 ASCII 路径，用 `dart analyze`（`flutter analyze` 在中文路径下触发 analysis server LSP 异常，guoapp 三次踩坑）[G12]。
* **未验证快照制度**：版本号与验收状态分离；历史检查记录不得沿用于新功能；**渲染器/框架版本变更视同功能变更**（PRD §9）。

## 9. 可观测性（v0.3 去弹幕指标，加渲染档位分布）

* 引擎诊断日志：JSONL、5MiB×2 轮转；字段含 HTTPStatus/CFRay/Client/Protocol/Quality/Attempt/阶段耗时；
  **脱敏**：Token/AESKeyHex/InterfaceKey/ParamKey/ParamIV 全局替换，URL 用户段/query/fragment 打码；给用户的诊断副本不含凭证。
* 健康检测五阶段（入口与目录→分集目录→播放地址与播放列表→播放密钥→媒体连接），catalogOnly 只跑第一阶段；
  每阶段耗时/HTTP 状态/CFRay 实时 publish 到站源记录；探测固定 480 画质、分片 Range 0-1023、密钥限读 17 字节。
* 性能基线指标：首帧耗时、分页 P50/P95、预加载命中率、内存（含下载调度）；崩溃/ANR 走平台通道。
* **渲染可观测（v0.3 新增）**：启动记录引擎确认日志（`Using the Impeller rendering backend (OpenGLESSDF)` / Metal）；
  玻璃档位直方图（premium/standard/minimal 占比 + Phase 2 benchmark 结果）进诊断副本——Impeller 迁移与钳制策略调参的主要输入。
* 源死亡率遥测：聚合 App 的源持续失效是常态，健康检测结果 + 错误码分布是版本迭代的输入，不是可选装饰。

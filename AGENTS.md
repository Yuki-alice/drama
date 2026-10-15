# AGENTS.md — 技能路由与协作规范

本工作区预装了 **56 个 agent skills**（Flutter / Dart / Rust / FFI 原生系统工程 / Apple HIG 设计审查）。
**任何 agent 在开始任务前，先按本文路由表选择技能；命中即加载，不要凭记忆写代码。**

- 技能源文件：`.agents/skills/<skill-name>/SKILL.md`（跨 agent 通用标准位置）
- WorkBuddy 入口：`.workbuddy/skills/<skill-name>` → junction 指向同一份文件（自动同步，勿单独修改）
- 全部技能已通过安全审计（2026-10-14，0 个 P0/P1 风险）
- 校验：`node scripts/validate-skills.mjs`　更新：`bash scripts/sync-skills.sh`

## 0. 技能加载方式（渐进式披露）

1. **先读头部**：读 SKILL.md 的 frontmatter + 开头，判断是否适用于当前任务；
2. **适用则完整读 SKILL.md**，再按其中的"Reference routing / Contents"按需读 `references/`、`examples/`；
3. 技能内的命令、模板、检查清单**照做**，不要用记忆里的旧版本替代；
4. **不相关就不加载**——避免一次性灌入多个无关技能浪费上下文。

## 1. 调用原则（合理且积极）

1. **命中即加载**：任务只要命中路由表，先加载技能再动手，即使看起来"很简单"。
2. **一个主技能 + 按需辅技能**：主技能定流程；遇到关联子任务再叠加（例：FFI 任务 = `dart-flutter-ffi-systems-engineering` 主 + `rust-unsafe-ffi`/`rust-uniffi-building` 辅）。
3. **先系统后局部**：架构/系统级技能（`*systems-engineering`、`*architecture*`）优于具体工具技能；先定边界再写代码。
4. **跨语言边界任务**：Rust+Flutter 互操作优先走 `dart-flutter-ffi-systems-engineering` 的决策树，不要默认手写绑定。
5. **回复中注明依据**：写明"按 `<skill>` 的流程…"，便于回溯与纠错。
6. **测试与质量默认内建**：写 Dart/Flutter 代码后主动用 `dart-run-static-analysis`；改动逻辑配 `dart-add-unit-test` / `flutter-add-widget-test`。

## 2. 路由表

### 2.1 Flutter 应用开发（10）

| 任务场景 / 触发词 | 技能 |
|---|---|
| 新项目架构、重构分层（UI/Logic/Data）、可扩展性 | `flutter-apply-architecture-best-practices` |
| 响应式/自适应布局（手机 vs 平板/桌面） | `flutter-build-responsive-layout` |
| 布局报错（RenderFlex overflowed、unbounded height） | `flutter-fix-layout-issues` |
| JSON 序列化（手动 fromJson/toJson） | `flutter-implement-json-serialization` |
| 声明式路由、go_router、深链、浏览器历史 | `flutter-setup-declarative-routing` |
| 本地化（flutter_localizations、intl、l10n.yaml） | `flutter-setup-localization` |
| 调 REST API（http 包 GET/POST/PUT/DELETE） | `flutter-use-http-package` |
| Widget 测试（WidgetTester、点击/滚动/输入） | `flutter-add-widget-test` |
| 集成测试（integration_test、Driver、用户流程自动化） | `flutter-add-integration-test` |
| 组件预览（previews.dart、交互式预览） | `flutter-add-widget-preview` |
| 编辑 `lib/**/*.dart` 后（若配了 Dart/Flutter MCP） | 主动触发 `hot_reload`；改 `initState`/全局状态/`main()` 用 `hot_restart`（官方 flutter-hot-reload 规则） |

### 2.2 Dart 语言与工程（13）

| 任务场景 / 触发词 | 技能 |
|---|---|
| 单元测试结构、package:test、测试目录组织 | `dart-add-unit-test` |
| 依赖冲突、`pub get` 失败、版本不兼容 | `dart-resolve-package-conflicts` |
| 静态分析、`dart analyze`、`dart fix --apply` | `dart-run-static-analysis` |
| 运行时错误/崩溃、堆栈定位、热重载验证 | `dart-fix-runtime-errors` |
| mock 生成（mockito、build_runner） | `dart-generate-test-mocks` |
| 覆盖率、LCOV 报告 | `dart-collect-coverage` |
| 迁移到 package:checks（替代 matcher 断言） | `dart-migrate-to-checks-package` |
| 文件/路径跨平台处理（package:path/file） | `dart-use-path-package` |
| Dart 3 模式匹配、switch 表达式、解构 | `dart-use-pattern-matching` |
| 主构造函数（primary constructors 新语法） | `dart-use-primary-constructors` |
| Dart 文档注释（`///`、Effective Dart 文档规范） | `dart-write-documentation` |
| Dartdoc 代码示例（`{@example}` 指令、region 标签） | `dart-use-doc-examples` |
| 命令行应用（入口结构、退出码、流路由、子进程） | `dart-build-cli-app` |

### 2.3 FFI / 原生系统工程（5）——跨语言边界的默认路线

| 任务场景 / 触发词 | 技能 |
|---|---|
| **任何** dart:ffi / C/C++ / 原生库集成、指针、内存所有权、回调、ABI、native 打包、native 性能问题 | `dart-flutter-ffi-systems-engineering`（总纲：先读它，按决策树再进子技能） |
| 生成 FFI 绑定（ffigen、C/ObjC/Swift 头文件） | `dart-use-ffigen` |
| 编译/打包 C/C++ 为 native assets（build hook、link hook、tree-shaking） | `dart-setup-ffi-assets` |
| Rust 侧 unsafe 边界、C ABI、回调、allocator、Pin/MaybeUninit | `rust-unsafe-ffi` |
| Rust 跨端共享组件（UniFFI → Swift/Kotlin/Python） | `rust-uniffi-building` |

### 2.4 Rust 开发（29）

| 任务场景 / 触发词 | 技能 |
|---|---|
| 语言语义、所有权/借用/生命周期/trait/泛型（含 MSRV） | `rust-stable` |
| 标准库选型（集合、智能指针、字符串类型、I/O） | `rust-stdlib` |
| 库 API 设计（命名、trait 互操作、可预测性） | `rust-api-design` |
| 短小可编译示例（类型转换、闭包、模块、错误处理） | `rust-by-example` |
| Cargo 配置/命令/features/profiles/缓存/CI | `rust-cargo-build` |
| Crate 选型评估（crates.io/docs.rs/GitHub/RustSec 四源打分） | `rust-crate-discovery` |
| 依赖治理（版本策略、cargo-deny、cargo-audit） | `rust-dependencies` |
| 工作区拓扑（单体 crate vs 多 crate 工作区） | `rust-workspace` |
| 单 crate 内部模块布局与可见性 | `rust-module-layout` |
| 并发/并行（线程、Send/Sync、锁、Tokio、Rayon） | `rust-concurrency` |
| 异步/Tokio 运行时工作流 | `rust-concurrency` |
| 宏（macro_rules、derive、proc-macro、卫生性） | `rust-macros` |
| lombok-macros（Java Lombok 迁移场景） | `rust-lombok-macros` |
| 数据库（SQLx/Diesel/SeaORM、迁移、连接池） | `rust-database` |
| HTTP 客户端（reqwest/hyper/TLS/重试/限流） | `rust-http-client` |
| Web 服务（axum/Actix、中间件、错误映射） | `rust-web` |
| Web 安全（认证、JWT/OIDC、CSRF/CORS/SSRF、密钥） | `rust-web-security` |
| 测试（单元/集成/doctest/属性/fuzz/基准/并发） | `rust-testing` |
| 性能（Criterion、flamegraph、分配、二进制体积） | `rust-performance` |
| 可观测性（tracing、metrics、OpenTelemetry、脱敏） | `rust-observability` |
| CLI 应用（子命令、退出码、stdin/out/err、终端） | `rust-cli` |
| 文档（rustdoc、doctest、mdBook、docs.rs） | `rust-documentation` |
| 代码风格（rustfmt、Clippy、Edition 迁移、lint 策略） | `rust-style-clippy` |
| 代码审查（内存/线程安全、错误语义、API 兼容） | `rust-code-review` |
| 语义化版本（0.x 规则、cargo-semver-checks） | `rust-semver` |
| 嵌入式/固件（no_std、embedded-hal、中断、DMA） | `rust-embedded` |
| Java→Rust 项目迁移（Maven/Gradle → Cargo） | `rust-java-migration` |
| 迁移测试（100% 无损、SHA-256 校验、mutation） | `rust-java-migration-testing` |

### 2.5 设计审查（1）

| 任务场景 / 触发词 | 技能 |
|---|---|
| UI 审查、设计评审、HIG 合规、无障碍、暗色模式、玻璃拟态、图标、导航结构、截图/线框图/代码求点评、"看着太模板化" | `apple-design`（123 页 Apple HIG 参考，支持 Flutter/RN/Tauri/Electron 词汇翻译） |

## 3. 常用组合工作流（加速开发）

- **新建 Flutter 项目**：`flutter-apply-architecture-best-practices` → `flutter-setup-declarative-routing` → `flutter-setup-localization` → （连后端）`flutter-use-http-package` + `flutter-implement-json-serialization`
- **FFI 新集成**：`dart-flutter-ffi-systems-engineering`（决策：是否真需要 FFI）→ 生成绑定 `dart-use-ffigen` → 打包 `dart-setup-ffi-assets` → Rust 侧 `rust-unsafe-ffi` 或 `rust-uniffi-building` → 测试 `dart-add-unit-test`
- **修 bug**：`dart-fix-runtime-errors` / `flutter-fix-layout-issues` → 补测试 `dart-add-unit-test` / `flutter-add-widget-test` → `dart-run-static-analysis`
- **交付前**：`flutter-add-integration-test` → `flutter-add-widget-test` → `dart-collect-coverage` → `apple-design`（UI 评审）
- **Rust 服务从零到上线**：`rust-workspace` → `rust-api-design` → `rust-web` → `rust-database` → `rust-observability` → `rust-testing` → `rust-web-security` → `rust-performance`

## 4. 技能来源与维护

| 来源仓库 | 技能数 | 许可证 | 说明 |
|---|---|---|---|
| `dart-lang/skills` | 15 | BSD-3-Clause | Dart 官方团队 |
| `flutter/agent-plugins` | 10（flutter-*） | BSD-3-Clause | Flutter 官方团队（dart-* 已由 dart-lang 版去重） |
| `full-stack-skills/rust-skills` | 29 | Apache-2.0 | Rust 全生命周期 |
| `ariaramin/flutter-skills` | 1 | MIT | `dart-flutter-ffi-systems-engineering` |
| `dickwu/apple-design-skill` | 1 | 未标注 | Apple HIG 设计审查 |

- 版本锁定与来源明细见 `skills-lock.json`（含 commit SHA）
- **更新**：`bash scripts/sync-skills.sh`（重新拉取上游 → 同步到 `.agents/skills` → 重建 `.workbuddy` 链接）
- **校验**：`node scripts/validate-skills.mjs`
- ⚠️ AI 会话内运行同步脚本时，批量删除可能被环境 safe-delete 保护拦截——被拦截时请在普通终端执行（或忽略，脚本已做到失败时保留现有技能）

## 5. 其他 agent 接入提示

- **WorkBuddy**：自动发现 `.workbuddy/skills/`（已就绪）
- **Codex / Cursor / Windsurf / Gemini CLI 等**：直接读取 `.agents/skills/`（通用标准），本文件 `AGENTS.md` 会被自动或手动纳入规则
- **Claude Code**：如需 `.claude/skills`，运行 `bash scripts/sync-skills.sh --link claude` 即可建立链接

## 6. 写作约定（2026-10-15 起）

- 契约文档已放弃旧版、待重写；在此之前**注释与文档中禁止出现章节锚点**（如 `ARCH §3.2`、`EVIDENCE §21`、`SourceSpec §11.1`、`PRD F-01`、`plan §8`、`实施计划 §4`、`纪律一/四` 等）。
- 规则写进正文：需要引用的约束直接写清楚（超时数值、字符集、错误码），不要写"见某文档§x"。
- CI 有 grep 门禁，提交前自查。

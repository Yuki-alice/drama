# 后端架构（Rust 工作区）

本文是 Rust 后端的**架构决策记录**。它回答「为什么这样分层」，不回答「某个字段叫什么」——
后者看代码注释与 wire 契约表（`drama_types::contract::OPS`）。

## 一、目标与范围

把 `reference/hongguo` 的后端能力（Go 核心 ~27.7k 行 + Dart 侧状态层）用 Rust 重写，
并做两项**架构改造**：

1. **红果成为唯一内置主源**——编译进二进制，不开源开关，不做「全站源版/红果版」双构建；
2. **其余源改为可安装的规则扩展源**——由官方仓库维护、用户按需安装、运行期热加载。

改造的动机来自对原实现的两点观察：

- 原实现的 22 个额外站源里有 **8 个是 MacCMS 模板 HTML 抓取**、**5 个是普通 JSON REST**、
  只有 1 个 Next.js SSR、1 个 Nuxt3、3 个加密信封。它们**共享同一批原语**
  （路径模板、JSON 取值、CSS 选择器、AES 解包、签名拼接、分页规则），
  却各自手写了 300~1300 行 Go。这是可声明化的部分。
- 原实现的源可用性是**编译期**决定的（`buildAllSources` 常量），用户无法取舍，
  维护者也无法灰度。运行期安装能同时解决这两件事。

## 二、分层与依赖方向

```
                    drama-cli            （验收入口，不依赖 Flutter）
                        │
                     core                （薄 FFI 门面，无业务逻辑）
                        │
                  drama-engine           （源注册、调度、仲裁、缓存策略）
        ┌───────────────┼───────────────┬──────────────────┐
 drama-source-hongguo  drama-rules   drama-download   drama-gateway
        │               │               │                  │
        └───────┬───────┴───────┬───────┴──────────────────┘
             drama-net      drama-store
                │               │
            drama-types ────────┘
```

**规则**：箭头只能向上。`drama-types` 是唯一的叶子，它**不含 IO**——
没有 `std::fs`、没有网络、没有全局可变状态。这条约束让领域模型可以被任何 crate
单元测试，也防止「模型里顺手查个网络」这种腐化。

几条具体的边界纪律：

| 边界 | 为什么 |
|---|---|
| `drama-net` 是**唯一**出网点 | 限流、退避、代理、超时、错误分类只写一遍。任何 crate 直接 `use reqwest` 都是 bug。 |
| `drama-store` 不依赖任何源 | 存储只认 `DramaId` 与 JSON，不认识红果或规则。否则加源就要改存储。 |
| `drama-gateway` 不依赖源 | 网关只拿 `(url, referer, key)`，不关心这三个值怎么来的。 |
| 源 crate 不依赖 engine | 源不能「回头问引擎」，只能拿到传入的参数。这让源可以独立测试。 |
| 只有 engine 知道全部源 | 仲裁、缓存 key、能力协商都在 engine 汇合。 |

## 三、为什么保留 `drama_request` / `drama_free` 契约

Flutter 侧（`lib/data/services/rust_core.dart`）已经建立在
`{v:1, op, source, session, sequence, params}` 信封上，38 个 op 有完整的 Dart 侧封装与测试。
重写后端**不构成**改前端的理由——前端停摆是设计问题，不是数据层问题。

因此：

- 保留两个 C 符号、保留信封、保留既有 op 的**语义与字段名**；
- 新能力（扩展源管理、诊断、弹幕）以**新增 op** 加入；
- `OPS` 表是唯一真相，`ops` op 把它吐给前端做自检。

`session`/`sequence` 仲裁继续保留。它的存在是因为首页会并发打
`catalog`/`recommend`/`ranking`，共用一个 session 时后发的会立刻把先发的判为迟到，
导致首页随机空白。按逻辑流分 session 的规则在 Dart 侧（`logicalStreamFor`），
Rust 侧只负责执行仲裁。

## 四、五个必须记住的设计决定

### 4.1 VIP 是三态，不是布尔

`VipState::{Unknown, Free, Vip}`。原实现用 `*bool` 表达同一件事，并留下
`metadataSchema=1` 专门修复「`false` 其实表示未知」的旧数据。

规则：**未知不覆盖已知**。列表页常不给 `pay_type`，详情页才给；
若让未知覆盖已知，用户点进详情再返回，卡片上的 VIP 角标就消失了。

### 4.2 能力位是硬契约

`Caps` 未声明的能力**必须**返回 `UNSUPPORTED`，绝不返回空列表。
「源没有搜索」与「搜索没结果」在前端是两件事：前者隐藏搜索框，后者显示空态。
原实现有多个源用空列表冒充「查过了」，用户以为剧不存在。

### 4.3 分组、档位标签这类「业务口径」归 Rust

`episodeGroups` 的组大小/起止/标签、清晰度的 `4K`/`2K`/`1080P` 命名都在 Rust。
理由：这些是**同一个产品的口径**，不是渲染细节。放前端就会有两处实现，
详情页与播放页迟早不一致（原实现就发生过：详情页有分组，播放页硬截前 60 集）。

### 4.4 解析结果里的直链不给前端看

`play` 返回的 `url` 是诊断用的；播放器只打开 `proxyUrl`。
Referer 鉴权、CENC 密钥、Range 处理、moov 重写全部留在 Rust。

封面同理：`Drama.cover` 在 Rust 侧就被换成 `http://127.0.0.1:{port}/img/{token}`，
token 是 `base64url(cdnUrl).md5(install_id:cdnUrl)` 的**无状态签名**——
重启后依然有效，且本机其他进程无法借它当开放代理。
不用「内存会话表 + 随机 token」是因为目录会被缓存到磁盘，重启后 token 表清空，
缓存里那些封面 URL 会全部 404，海报墙整体退化成占位（这是原实现踩过的坑）。

### 4.5 错误码里 `CANCELED` 不是错误

用户快速切分类/翻页时，旧请求被新请求取代，这是**正常现象**。
它映射 `retry=false`，前端应静默忽略。把它渲染成错误框是最常见的误用。

## 五、与原实现的行为差异（有意为之）

| 项 | 原实现 | 本实现 | 理由 |
|---|---|---|---|
| 站点源开关 | 编译期常量 | 运行期安装 | 用户可取舍，维护者可灰度 |
| 目录条目上限 | 无（曾有 6000，已移除） | 无 | 与现状一致 |
| 原子写 | 写临时文件 + rename，**不 fsync 目录** | 写临时文件 + fsync + rename + fsync 目录 | 掉电后 rename 可能未落盘 |
| 并发写保护 | **无任何文件锁** | 进程内写序列化 + 落盘互斥 | 原实现靠「只有一个写者」的隐含假设 |
| 用户/权限 | Go 无此层，在 Dart `SharedPreferences` | 归 `drama-store`，落 JSON 文件 | 后端能力应完整，不依赖前端存储 |
| 弹幕签名 | 需要 X-Argus/X-Ladon（SM3 + 自研 ARX） | 同左，Rust 实现 | 无现成 crate，需自研 |
| 360p 公开轨 | **Go 没有**（只存在于旧 Rust 重写） | 保留为降级轨 | 上游 App 接口常返回空 body 时它是唯一可播路径 |

## 六、验证方式

前端停摆期间，后端必须能**独立验收**：

```sh
# 单元 + 集成测试（离线）
cargo test --workspace

# 实网用例默认 #[ignore]，显式跑
cargo test --workspace -- --ignored

# 命令行逐项验收（不依赖 Flutter）
cargo run -p drama-cli -- catalog --source hongguo --category short_play
cargo run -p drama-cli -- detail --source hongguo --id <series_id>
cargo run -p drama-cli -- play --source hongguo --id <series_id> --episode 1
cargo run -p drama-cli -- sources
cargo run -p drama-cli -- source-validate --file ./my-source.yaml
```

CLI 直接驱动 engine 的 `dispatch`，与 FFI 走**同一条路径**——
如果 CLI 能用，FFI 就能用。这条约束防止「CLI 走捷径，FFI 才暴露 bug」。

## 七、明确不在范围内

按产品决定，以下两块**不做**：

| 能力 | 原因 |
|---|---|
| 局域网互联（mDNS 发现、TLS 直连、追剧/进度同步、推送续播） | 前提是「多设备」与「配对 UI」，而当前产品首要平台是单机安卓；配对协议本身是安全边界，不该由后端单方面决定 |
| 本地多用户 / 管理员 PIN / 按用户分配源与下载权限 | 单机单人场景下没有收益，却引入「换个用户看不到我的追剧」这类风险 |

因此：

- `drama-lan` crate 已删除，`lan` op 已从契约表移除（**不留空位**——
  留一个永远返回 `UNSUPPORTED` 的 op 只会让前端误以为「以后会有」）；
- `drama-store` 不再有 `users` 模块；追剧/进度/搜索历史只有一份；
- 存储层的 `user` 参数保留但引擎固定传同一个值，
  将来若真要加多用户，不必再迁移一遍数据。

## 八、尚未决定的事

- **规则源签名**：目前计划是内容哈希 + 官方仓库公钥签名，但公钥分发方式未定。
  在定下来之前，规则源安装只做**结构校验**，不做来源认证；UI 需要明示「第三方规则」。
- **规则源热更新粒度**：整包替换 vs 字段级 patch。倾向整包替换（简单、可回滚）。
- **macOS/Linux 的 TLS 指纹**：原实现只有 Windows/Android 用 `tls-client` 模拟 Chrome 指纹，
  且**红果流量不走它**。本实现暂不做 TLS 指纹，若将来某个扩展源需要，再加可选的传输层插件。

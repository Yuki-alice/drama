# 短剧聚合 App — SourceSpec（源扩展规范）v1 草案

> 目标：红果内置 + 官方扩展 + 第三方扩展统一接口，**双轨分发（声明式 JSON 规则 + WASM 插件）**，Rust 侧 `wasmtime/extism 1.21` 沙箱执行 WASM、同侧 `rule_eval` 求值规则。编码前冻结 v1。
>
> **v0.2 变更（2026-10-14，guoapp 源码级评审）**：`play` 输出补 `playlist/hlsKey/cencKey`（否则引擎要为每源二次请求 playlist）；  
> host 函数补凭证/UA 继承语义；补 `minCore` 协商与降级路径；补媒体响应校验规则（ENDLIST/identity/16 字节密钥/拒 html-json）；  
> 合规向量升级为五阶段框架；错误码补映射表与可重试标记；新增 §8 冻结检查清单。  
> 数字均可回溯至 `docs/EVIDENCE.md`（`[G#]`）。
>
> **v0.3 变更（2026-10-14，QUESTIONS Q1–Q12 决断落地）**：**弹幕 cap 暂缓**（§2 caps、§3.4 整节冻结备查，P1 恢复再解冻）；  
> **Q5=a**：`play` 由插件返回密钥定为 v1 正式契约，host 代取记 v2 演进（§3.1）；§11 冻结清单 Q1 项标记已决。  
> 其余契约不变。
>
> **v0.5 变更（2026-10-14 晚，用户决策：项目定位收窄）**：  
> **项目当前目标是「支持后续源扩展的、iOS 液态玻璃设计的、以 Rust 为后端核心的第三方红果短剧客户端」。**  
> **P0 唯一源 = 内置 `hongguo`（红果）**。因此**本文档第 §1–§10 节整体延后至 P2**，不作为编码依据：  
> §1–§7 = WASM 插件形态、§8 = 声明式规则、§9 = 官方规则仓库、§10 = 规则管理扩展。  
> **当前编码只依据新增的 §11「当前路径：红果内置源契约与 SourceProvider 预留」** —— 它同时就是  
> "支持后续源扩展"这一目标的架构落点：**红果是 `SourceProvider` trait 的第一个实现，未来扩展源实现同一 trait，下游零改动。**  
> 延后依据：EVIDENCE §17.1 实证红果需 X-Gorgon 签名 + 设备伪装 + spade_a 密钥派生 + AES-CBC 解密，  
> **声明式规则对红果零适用**，且唯一源不需要分发/签名/多源管理。  
> 依据：EVIDENCE §17.1 已实证红果需 X-Gorgon 签名 + 设备伪装 + spade_a 密钥派生 + AES-CBC 解密，  
> **声明式规则对红果零适用**——唯一源本就不需要扩展机制。当前编码只依据 §1（轨道 A 的 id/版本/minCore 约定）、§2–§7 与 §11 中未标延后的条目。  
> 证据：`docs/EVIDENCE.md` §17（红果源实证）、§18（kazumi 规则形态，留证）。
>
> **v0.4 变更（2026-10-14，用户提议：学 kazumi 搞官方规则仓库 + 规则管理中添加规则）**：  
> 源扩展从「只有 WASM 插件」改为 **双轨** —— 新增 **轨道 B：声明式 JSON 规则**（§8）并作为**新源默认形态**，  
> 配套 **官方规则仓库**（§9）与 **规则管理扩展**（§10）；原 WASM 形态降为**轨道 A**，只作"声明式表达不了"的逃生舱（§8.6）。  
> 关键取舍：① 选择器用 **CSS 不用 XPath**（§8.3，因求值在 Rust 引擎侧，Rust 的 XPath 生态停滞）；  
> ② 规则模式 **密钥由引擎自取**（§8.5，天然满足"密钥不出引擎"，即 Q5 记为 v2 的 host 代取在规则轨道默认实现）；  
> ③ **不做执行站点 JS / WebView 的解析路径**（§8.6 第 5 条，与 kazumi 的 `useWebview`/`useLegacyParser` 分道）。  
> 证据：`docs/EVIDENCE.md` §17（kazumi 规则形态与规则仓库实测）。

> **v0.6 变更（2026-10-15，联网调研红果解析方案 + 复核 guoapp 取流代码）**：  
> 红果源内部再分**两条取流轨道**（新增 §11.4）：**① 官网 SSR 免签**（`_ROUTER_DATA` → 明文直链，覆盖目录/榜单/详情/选集/搜索 + 可试看集）；
> **② App API 签名**（fqnovel `video_model` + X-Gorgon，覆盖全集但需 spade_a → CENC 解密）。  
> **CENC 解密从"P0 阻断项"降级为"M1 增强项"** —— M0 靠免签明文轨 ① 即可跑通完整播放闭环，不再有"做不出来"的风险。  
> 新增**红线**：禁用第三方中转域名（guoapp 用的 `djapi.999888456.xyz`，与 PRD §1「不依赖自建中转服务」冲突）。  
> 证据：EVIDENCE §17.4–§17.6。

## 1. 源形态与分发（双轨）

> **v0.4 起扩展分两条轨道。新源默认走轨道 B（声明式规则）；轨道 A（WASM）只作逃生舱。**

| 维度    | 轨道 A：WASM 插件（§2–§7）                                   | 轨道 B：声明式规则（§8）                                |
| ----- | ----------------------------------------------------- | --------------------------------------------- |
| 交付物   | `*.source.zip` = manifest.json + main.wasm + icon.png | 单个 `*.json`（可裸导；带图标时打 zip）                    |
| 表达力   | 图灵完备                                                  | 声明式：URL 模板 + CSS 选择器 / JSONPath / 正则 + ≤3 步管道 |
| 定位    | **逃生舱**：仅 §8.6 列出的五类复杂源                               | **新源默认**：服务端渲染 HTML 或直出 JSON 的站               |
| 网络    | 经 host `http_fetch`，受 `domains` 白名单                   | 引擎代发；`domains` **从 URL 字段自动推导**（§8.2），不可手写放宽  |
| 限流/退避 | 引擎唯一权威（Q6=a），插件不得自行退避                                 | **天然引擎唯一**——规则是数据，无法自行发请求                     |
| 播放密钥  | 插件返回 `hlsKey/cencKey`（Q5=a），过插件内存                     | **引擎按 `EXT-X-KEY` 自取**，密钥不过规则文件（§8.5）         |
| 合规门槛  | 五阶段向量 + 签名 + 人工审核                                     | 完全相同（§10.4），并优先要求"能声明式就必须声明式"                 |

- **两轨对下游完全同构**：规则求值输出与 §3.1 四件套**逐字段相同**的 JSON 结构，  
  Dart 侧 FFI 契约、播放链路、下载链路、健康检测**不需要区分轨道**（§8.7）。
- `id` 规则不变：`hongguo` 内置保留；官方 `official.*`；第三方 `third.*`。  
  **前缀只表示背书来源，与轨道无关**——官方仓库收录的规则（哪怕由社区 PR 贡献）签名为 `official.*`，  
  用户自行导入的为 `third.*`。版本 semver，不兼容大版本拒绝混跑。
- **minCore 协商（v0.2 新增，两轨通用）**：加载时校验 `minCore` 与引擎 core 版本——  
  源要求高于引擎 → **拒绝加载并给出可读错误**（"该源需要 App ≥x.y.z"），不静默禁用；  
  引擎高于源 → 正常加载。协商失败要能区分"签名失效/版本不兼容/权限不足"三种原因 [G1]。  
  轨道 B 另有 `schemaVersion`（整数）表示"规则 schema 版本"，高于引擎支持值同样拒载并提示更新（§9.4）。

### 1.1 安装通道（两轨共用）

文件导入 / URL / 扫码安装；**轨道 B 额外支持从官方规则仓库一键安装**（§9）与导出分享（§10）。  
SHA-256 + Ed25519 签名：官方强制——**轨道 A 逐包签，轨道 B 由仓库 `index.json` 整体签**（§9.3），  
第三方自签 + 用户确认。

## 2. manifest.json v1（轨道 A：WASM）

```json
{
  "manifestVersion": 1,
  "kind": "wasm",
  "id": "third.yaguo",
  "name": "芽果",
  "version": "1.4.2",
  "minCore": "1.0.0",
  "entry": "main.wasm",
  "caps": ["catalog", "search", "detail", "play"],
  "domains": ["api.xingya.example", "cdn.xingya.example"],
  "permissions": {"network": true, "storage": false},
  "search": {"paged": true, "pageSize": 20}
}
```

- `caps` 取值：`catalog`（分类页入口，未声明则不出现）/ `search` / `detail` / `play` / `danmaku`（**暂缓**：P0 不实现，P1 备查，见 §3.4）。  
  轨道 B **没有 `caps` 字段**——声明了哪个段就有哪个能力（§8.1）。
- `kind` 两轨必填：`"wasm"`（轨道 A）/ `"rule"`（轨道 B，§8.1）。**v1 起禁止缺省推断**  
  （不得按"包内有没有 main.wasm"猜），缺省即拒载。
- 未声明 `domains` 的网络一律拒绝；`permissions.network=false` 时连 host `http_fetch` 都不可用。
- `permissions.storage` 仅指源私域 kv（见 §3.3），不是设备文件系统。**轨道 B 无此字段**（规则无持久私域）。

## 3. WASM ABI（轨道 A：extism 函数，JSON 进出，UTF-8）

### 3.1 四件套

| 函数        | 输入                       | 输出                                                                              |
| --------- | ------------------------ | ------------------------------------------------------------------------------- |
| `catalog` | `{cate, page, pageSize}` | `{items:[{dramaId,title,cover,epsCount,status}], page, hasMore}`                |
| `search`  | `{kw, page}`             | 同上，空实现必须返回 `{items:[], hasMore:false, unsupported:true}`（参考星果教训）                |
| `detail`  | `{dramaId}`              | `{title, intro, cover, episodes:[{epId,no,title,playId}], total}`               |
| `play`    | `{playId, quality}`      | `{urls:[{url, quality, codec, headers}], expiry, playlist?, hlsKey?, cencKey?}` |

- 所有 HTML 解析在 WASM 内完成；返回标题必须去高亮标签/实体还原（参考猫果 `<font>` 教训）。
- **`play` 输出补三项（v0.2，照抄 guoapp `providerMedia` [G3]）**：
  - `playlist?`：插件已预取的 m3u8 文本（引擎省一次请求，且重写五类 URI 时需要原始文本）；
  - `hlsKey?`：AES-128 密钥 hex（16 字节）；`cencKey?`：CENC 密钥 hex（16 字节）。
  - 不返回时引擎自行按 URL 取；返回即视为"插件已在最终请求上下文中取得"（参考牛果按实际 URI 前 16 字节算 AES 密钥的教训：  
    **签名/加密参数必须由插件用最终发出的 URI 计算，host 提供最终 URI，不能固定字面量拼接**）。
- **Q5=a 决断（2026-10-14）**：密钥由插件返回（`hlsKey?/cencKey?` 为 v1 正式契约）——密钥过插件内存是 WASM 化的固有代价，  
  第三方源少、密钥短命，风险可接受；**host 函数按 URL 代取（凭证不出引擎）记为 v2 演进**，manifest 不为双模式开声明位。  
  **硬约束：无论哪种模式，密钥都不进备份/同步/日志**（脱敏规则见 ARCH §9）。
- `play` 返回的 URL 带时效（≤2h），App 不持久化；H264 优先，H265 备用保留。

### 3.2 媒体响应校验规则（引擎侧 [G3, G5]）

插件返回的地址/播放列表，引擎在取流与下载时强制执行：

- HLS 播放列表 ≤4MB 且必须以 `#EXTM3U` 开头；**下载必须 `#EXT-X-ENDLIST`（拒绝直播/未结束列表）**；拒绝 `{$` 变量地址。
- `EXT-X-KEY` 仅 AES-128/NONE 且 `KEYFORMAT` 必须 identity/空；密钥最终必须 16 字节。
- 媒体响应体拒绝 `text/html` 与 `application/json`（CF 挑战页/错误页伪装成媒体）；拒绝非 identity 的 `Content-Encoding`。
- 直链 MP4 校验文件头；302 跳转跟随但跨 host 跳转丢弃敏感头（preview token 类）。

### 3.3 Host 函数（Rust 注入）

| 函数                      | 语义                                                                                                                                           |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `http_fetch(url, opts)` | 按 `domains` 鉴权放行；**继承引擎的 UA/Referer/Cookie 策略**（per-source UA 分层由引擎决定，插件只可建议）；凭证仅当请求 origin == 凭证 origin 注入、过期即拒；重定向后重新 apply；受限流/退避约束（见 §4） |
| `kv_get/kv_set`         | 源私域键值，仅本源可见，**不进备份/同步**（换机即失效，用户需重新授权第三方源）                                                                                                   |
| `log`                   | 脱敏日志（禁打 URL query/密钥）                                                                                                                        |

- **禁直接 socket/文件**。代理设置不透传给源；TLS 校验不关闭。
- 内置源特权（访客登录令牌、协议密钥、响应解密参数）经 host 凭证 API 暴露：插件可申请"带 cookie/expires 的请求"，  
  **不得自行抓取官网 JS 提取密钥**——那是官方内置源的特权，第三方源不开放 [G2, G15]。

### 3.4 弹幕（可选 cap）—— **暂缓：P0 不实现，P1 备查（Q1 决断 2026-10-14）**

> 本节整体冻结。P0 不实现 `danmaku` cap、不做 UI；第三方源默认不开放该 cap 的结论保留  
> （弹幕接口多为站内私有协议，开放=鼓励逆向）。若 P1 恢复 F-08，本节契约与 EVIDENCE §7 整套常量照抄适用。  
> 下表为冻结备查，不是 P0 交付物。

| 函数        | 输入                              | 输出                                                    |
| --------- | ------------------------------- | ----------------------------------------------------- |
| `danmaku` | `{playId, startMs, durationMs}` | `{items:[{id,text,timeMs}], cursor, hasMore, total?}` |

- 窗口 30s 游标续载；单页 ≤90、文本 ≤180 runes；控制字符转空格；只返回通过分集身份与原始毫秒时间戳校验的条目。
- 引擎缓存：成功 5min / 错误 15s；单飞 ≤16；上限 128 条目满则清空。UI：≤4 轨道、同 lifetime ≤24 条、8s 寿命。
- 表情短码由插件或引擎对照表转换；**截断必须在变体选择符/零宽连接符（FE0F/FE0E/200D）之前回退**。

## 4. 安全与配额

- 默认无 WASI FS/NET；HTTP 经 host 代理，TLS 校验不关闭；代理设置不透传给源。
- **限流/退避是引擎唯一权威，插件不自行退避**（Q6=a 已决）：  
  引擎按 source 粒度串行 gate、前台优先；403/429/CF 挑战触发退避 1min 起、尊重 `Retry-After`、封顶 30min；  
  媒体请求（分片/密钥/播放列表）不走限流器 [G2]。引擎 limiter 默认值（并发 3/间隔 250ms）在 M1 用红果+首批官方源实测校准。
- 插件侧配额只做 trap 保护（超限即终止调用并标记源不健康）：单调用 15s、内存 16MB、单源并发 3、预加载 6s/4MB/8 请求。
- Cookie/访客 token 只活在引擎内存，不进备份/同步/跨源 [G2]；播放密钥同样不进备份/同步/日志（Q5=a）。

## 5. 合规测试向量（上架门槛）

向量框架 = 健康检测五阶段（照抄 guoapp [G10]）：  
**入口与目录 → 分集目录 → 播放地址与播放列表 → 播放密钥 → 媒体连接**；  
探测固定 480 画质、分片 Range 0-1023、密钥限读 17 字节，不拉全片；每阶段记录耗时/HTTP 状态/CFRay。

- 目录首屏≥10 条且 `hasMore` 正确；搜索关键词含特殊字符不崩；详情集数单调且去重；  
  `play` 至少一条可开 HLS/MP4 头（不拉全片）；随机类名搜索页回退锚点收集（参考伍果/网果/发果）。
- 皮果类 Cloudflare 拦截必须报 `WAF_BLOCK` 而非空结果（**P0 不做指纹，该类源即以此形态存在**，Q8=a）；牛果类三级解析域名失效报 `RESOLVE_FAIL` 可重试。
- 猫果类标题去高亮标签 + 实体还原；星果类空搜索必须 `unsupported:true`；河果类无服务端搜索同样 `unsupported:true`（不返回空列表冒充"搜过了"）。
- 密钥类向量：牛果式按最终 URI 计算 AES 密钥；剧果式访客会话 + 来源限定 Cookie（引擎代管，插件只发请求）。
- 全部向量用**固定响应样本**（HLS 文本/AES JSON/签名错误/CF 挑战页）在 wasmtime 单测中跑，随测试提交，防源站变动静默劣化 [G12]。

## 6. 错误码

`OK | EMPTY | AUTH_FAIL | SIGN_FAIL | WAF_BLOCK | RESOLVE_FAIL | EXPIRED | UNSUPPORTED | QUOTA | NET_TIMEOUT`。  
全部映射为 Dart 侧文案，不抛裸码：

| 错误码            | 含义                         | 典型来源          | 可重试               |
| -------------- | -------------------------- | ------------- | ----------------- |
| `WAF_BLOCK`    | CF/网关挑战页（引擎文案识别或 403+CF 头） | 皮果类           | 否（退避后由用户手动）       |
| `RESOLVE_FAIL` | 解析域名/线路失效                  | 牛果三级解析        | 是（退避 30s+）        |
| `AUTH_FAIL`    | 登录/访客令牌失效                  | 芽果令牌、剧果 guest | 是（刷新一次后）          |
| `SIGN_FAIL`    | 验签失败（参数顺序/密钥错误）            | 猫果搜索签名        | 否（源 bug，标记不健康）    |
| `EXPIRED`      | 播放地址过期                     | play expiry   | 是（重新解析）           |
| `QUOTA`        | 超出插件配额被 trap               | 沙箱            | 否（标记源不健康）         |
| `NET_TIMEOUT`  | 网络超时                       | 通用            | 是                 |
| `UNSUPPORTED`  | 能力未实现（空搜索等）                | 星果/河果         | 否（UI 明示"该源不支持搜索"） |
| `EMPTY`        | 真的没有结果                     | 通用            | 否                 |

引擎级另有 `source_blocked`（带 `retryAt`，退避中）与 `local_media`（本地文件错误），不进源错误码表 [G1]。

## 7. 官方源开发建议

- 官方源用 Rust PDK（可复用加解密）或 JS PDK（快速迭代），CI 统一 `cargo fmt + clippy + extism call catalog/search/detail/play` 四步冒烟；密钥/盐不进仓，用构建期注入。
- 上架门禁 = §5 五阶段向量全过 + 签名 + 审核（成人/侵权拒收，参考暮果先例）。
- 官方源特权（访客登录/协议密钥）经 host 凭证 API 申请，走白名单评审，不默认开放。

## 8. 轨道 B：声明式规则（JSON）—— ⏸ 延后至 P2，不在 P0/P1 交付路径

> ⏸ **延后（2026-10-14 用户决策）**：项目定位收窄为第三方红果客户端，P0 唯一源为内置 `hongguo`。  
> EVIDENCE §17.1 实证红果需 X-Gorgon 签名 + 设备伪装 + spade_a 派生 + AES-CBC 解密，**声明式规则对红果零适用**。  
> 本节保留设计留证，**不作为编码依据**；若 P2 重启源扩展，本节 + §9 + §10 成套启用。  
> 与 kazumi 的三处实质分道（CSS 而非 XPath / 不做 JS-WebView 取流 / 仓库 index 整体签名）是本设计的核心取舍。

> 形态学习 kazumi 的"一个 JSON 文件描述一个站"，但**不是照搬**：kazumi 的规则只有**搜索 + 选集**两段  
> （番剧元数据来自 Bangumi 开放 API、播放地址靠 App 内部 JS hook / WebView 启发式获取），  
> 我们没有外部元数据源、也不执行站点 JS，因此规则必须自带 **catalog / detail / play** 三段（§8.6 第 5 条）。

### 8.1 规则文件与字段

```json
{
  "kind": "rule",
  "schemaVersion": 1,
  "id": "official.yaguo",
  "name": "芽果",
  "version": "1.0.0",
  "minCore": "1.0.0",
  "icon": "https://cdn.xingya.example/icon.png",

  "baseURL": "https://api.xingya.example",
  "referer": "https://api.xingya.example/",

  "catalog": {
    "url": "{baseURL}/cate/{cate}?page={page}",
    "mode": "css",
    "list": "div.feed > div.item",
    "fields": {
      "dramaId":  "a@href | regex:/(\\d+)/",
      "title":    "h6@text",
      "cover":    "img@data-src | abs:url",
      "epsCount": ".eps@text | regex:/(\\d+)/ | int",
      "status":   ".tag@text"
    },
    "pageSize": 20,
    "hasMore": "a.next@exists"
  },

  "search": {
    "url": "{baseURL}/search?q={kw}&page={page}",
    "method": "GET",
    "mode": "css",
    "list": "div.search-list > div.item",
    "fields": {
      "dramaId": "a@href | regex:/(\\d+)/",
      "title":   "h6@text",
      "cover":   "img@data-src | abs:url"
    },
    "hasMore": "a.next@exists"
  },

  "detail": {
    "url": "{baseURL}/d/{dramaId}",
    "mode": "css",
    "fields": {
      "title": "h1@text",
      "intro": ".intro@text",
      "cover": ".cover img@src | abs:url"
    },
    "episodes": {
      "list": "ul.eps > li",
      "fields": {
        "epId":   "a@href | regex:/(\\d+)/",
        "no":     "a@text | regex:/(\\d+)/ | int",
        "title":  "a@text",
        "playId": "a@href | abs:url"
      }
    }
  },

  "play": {
    "url": "{baseURL}/p/{playId}",
    "mode": "css",
    "steps": [
      { "select": "iframe@src | abs:url", "as": "frameUrl" },
      { "fetch": "{frameUrl}", "select": "script@text", "regex": "url:\\s*\"([^\"]+\\.m3u8[^\"]*)\"", "as": "m3u8" }
    ],
    "quality": [{ "label": "480", "url": "{m3u8}" }],
    "expiry": 7200
  },

  "extraDomains": ["cdn.xingya.example"]
}
```


| 字段                                       | 类型       | 必填 | 说明                                                                                                               |
| ---------------------------------------- | -------- | -- | ---------------------------------------------------------------------------------------------------------------- |
| `kind`                                   | `"rule"` | ✅  | 轨道标识（§1）                                                                                                         |
| `schemaVersion`                          | int      | ✅  | 规则 schema 版本；引擎不认识的高版本 → 拒载 + 提示更新 App（§9.4）                                                                     |
| `id` / `name` / `version` / `minCore`    | string   | ✅  | 同 §1；`id` 前缀 `official.*` / `third.*`                                                                            |
| `icon`                                   | url      | ❌  | 仅展示用，**必须在推导出的 domains 内**                                                                                       |
| `baseURL`                                | url      | ✅  | 站点根；`{baseURL}` 占位符来源，也是 **domains 推导的第一来源**（§8.2）                                                               |
| `referer`                                | string   | ❌  | **P0 仅允许等于 baseURL 或与其同源**（防伪造跨站来源）                                                                              |
| `userAgent`                              | string   | ❌  | **v1 冻结为"引擎决定"**：字段解析但**忽略并告警**（guoapp per-source UA 混乱教训，与 §3.3 同策）；是否开放待 M1 首批官方源实测                            |
| `catalog` / `search` / `detail` / `play` | object   | ❌  | **段即能力**：声明了哪段就有哪个 cap，**不设 `caps` 数组**——没有 `search` 段即"该源不支持搜索"，直接满足星果/河果的 `unsupported:true` 语义（不返回空列表冒充"搜过了"） |
| `extraDomains`                           | string[] | ❌  | URL 推导之外的额外允许域；**安装时 UI 强调显示并需用户确认**                                                                             |

**抽取表达式语法**（用于 `fields` 的值、`hasMore`、`play.steps[].select`）：

```text
<选择器>[@<attr|text|html>] [| abs:url | regex:/.../ | first | int | trim]
```

- 选择器**相对所在 `list` 容器的后代**匹配（等价 kazumi 里 `.//` 的语义）。
- `@attr` 取属性值；`@text` 取文本；`@html` 取原始 HTML 片段。
- **`@text` 必须自动去高亮标签（如 `<font>`）并做 HTML 实体还原**——把猫果教训固化进引擎，规则作者无需处理。
- `abs:url` 以 `baseURL`（或当前响应 URL）解析绝对地址；`regex:/…/ ` 取第一个捕获组；`first` 取首个节点；`int` 转整数；`trim` 去空白。
- `mode: "json"` 时选择器位换成 **JSONPath**（如 `$.data.list[*].title`），其余管道算子不变。

### 8.2 域名白名单自动推导

- 允许域 = `baseURL` 的 host ∪ 所有段 `url` 模板的 host ∪ `extraDomains`。
- **规则不能另行声明任意 `domains`**（比轨道 A 更严：轨道 A 可手写 `domains`），避免规则作者顺手放宽。
- 管道中 `fetch` 的目标同样受此集合约束，越界即 `DOMAIN_DENY`（**不静默放行**）。
- 未声明 `extraDomains` 的规则，安装确认页只需展示 1 个域名——这是"规则比 WASM 更容易审"的直接体现。

### 8.3 选择器：CSS 优先，XPath 不进 v1

- **v1 只支持 CSS 选择器（HTML）+ JSONPath（JSON）**，不提供 XPath。
- 理由：
  1. 规则求值在 **Rust 引擎侧**（§8.7），Rust 侧 `scraper`（html5ever + selectors，Firefox 同款选择器引擎）成熟稳定，  
     而 XPath 生态（`sxd-xpath` 等）长期停滞；
  2. **kazumi 用 XPath 是因为它的规则引擎在 Dart 侧**、Dart 有 `xpath_selector_html_parser`——  
     照搬它的选择器选型会踩**生态错配**；
  3. CSS 对前端贡献者门槛更低，利于社区投稿。
- 若 P1 出现"必须 XPath 才能表达"的站，先用 `regex` 管道兜底，仍不行则该源升轨道 A。

### 8.4 配额与失败语义

规则不是代码，无 trap 概念，但仍有硬上限（超限 → `QUOTA` 并标记源不健康）：

| 项            | 上限                                |
| ------------ | --------------------------------- |
| 单段响应体        | HTML / JSON 均 ≤2MiB               |
| `play.steps` | ≤3 步，每步至多 1 次请求                   |
| 单段总耗时        | ≤15s（与轨道 A 单调用 15s 对齐）            |
| 并发 / 限流 / 退避 | **完全由引擎 limiter 管**，与轨道 A 同（Q6=a） |

- 段级失败（选择器全不匹配）报 `EMPTY`；URL 模板求值失败报 `SIGN_FAIL`（规则 bug，不可重试）；  
  取到地址但媒体校验不过 → 沿用 §3.2 与 §6。

### 8.5 播放密钥：规则模式由引擎自取

- **规则不声明密钥**。m3u8 里的 `#EXT-X-KEY` 由引擎按 URI 自取并校验 16 字节（§3.2 对两轨同等强制）。
- 这比轨道 A 更干净：**密钥不进规则文件、不进 Dart、不进日志**，天然满足"密钥不出引擎"——  
  即 Q5 里记为 v2 演进的 **host 代取模式，在规则轨道是默认实现**。
- 代价：需要"按最终 URI 计算密钥"的源（牛果式：取 URI 前 16 字节当 AES 密钥）**声明式表达不了 → 升轨道 A**（§8.6）。

### 8.6 必须升轨道 A（WASM）的判定闸门

满足任一条件，该源**整源**以 WASM 实现，**不允许"部分段用规则、部分段用 WASM"的混合态**  
（混合态会让合规向量与审核边界失焦）：

1. 请求参数需签名 / MD5 / 时间戳 nonce（猫果搜索签名）。
2. 响应体需 XOR / AES 解密才能拿到列表或地址（红果式，且属内置源特权 [G2, G15]）。
3. 密钥由最终 URI 计算（牛果式）。
4. 需访客登录会话 + 来源限定 Cookie（剧果式）。
5. **需执行站点 JS 才能得到地址** —— kazumi 用 `useWebview` / `useLegacyParser`（iframe src 启发式，API Level 3+）覆盖这类站，  
   **本项目不做**：P0 不引入 WebView 解析路径，也不执行站点 JS（安全边界，且与 §3.3"插件不得自行抓取官网 JS"的既有纪律一致）。  
   我们的 `play.steps` 只覆盖**显式声明的 iframe 一跳**，不覆盖黑盒启发式。

> **诚实边界**：kazumi 能覆盖的站**我们不都能覆盖**（第 5 条）。换来的是更小的攻击面与可审计性——  
> 规则仓库里每一条规则都能静态读出"它会访问哪些域、取哪些字段"。这个取舍必须在 README 免责声明里说清（QUESTIONS Q13）。

### 8.7 求值位置与同构保证

- **在 Rust 引擎侧求值**（新增 `rule_eval` 模块），与轨道 A 共用同一套 host fetch / 限流 / 凭证注入 / 媒体响应校验 / 五阶段合规向量。
- **不选 Dart 侧求值**的理由：Q6=a 已决"限流 / 退避引擎唯一权威"，Dart 侧求值等于重建第二条网络 / 限流 / 凭证链路，直接违反该决断。
- **同构保证**：`rule_eval` 输出与 §3.1 四件套**逐字段相同**（`catalog` / `search` / `detail` / `play`），  
  Dart 侧与引擎下游**不需要区分轨道**。

## 9. 官方规则仓库 —— ⏸ 延后至 P2（随 §8 成套）

> ⏸ **延后（2026-10-14 用户决策）**：随 §8 成套延后，不作为编码依据。

> 直接学习 KazumiRules 的运作方式：独立公开 Git 仓库 + 只收规则文件 + `index.json` 由 CI 生成 + PR 人工审核  
> （其贡献指南原文："仅提交或更新规则文件（*.json）／请勿手动修改 `index.json` 和 `README.md`／这些文件会在您的 PR 被合并后自动更新"）。  
> **与 kazumi 的实质差异只有一处：签名**——kazumi 靠 GitHub PR 审核、App 不验签；我们沿用既有 Ed25519 体系，对 index 整体签名。

### 9.1 仓库结构

```text
drama-rules/
 ├─ rules/*.json          # 一条规则一个文件，文件名 = id 末段小写
 ├─ index.json            # CI 生成，禁止手改
 ├─ index.json.sig        # CI 用官方 Ed25519 私钥对 index.json 签名
 └─ .github/workflows/    # schema 校验 + 冒烟 + 重生成 index + 签名
```

**贡献契约（沿用 KazumiRules 纪律）**：

- 仅提交或更新规则文件（`rules/*.json`）；
- **请勿手动修改 `index.json` 和 README.md** —— 这些文件会在 PR 被合并后自动更新。

### 9.2 CI 门禁（PR 合并前）

1. **schema 校验**：`kind` / `schemaVersion` / `id` 前缀 / `baseURL` 合法性；抽取表达式语法可解析。
2. **命名与唯一性**：文件名 == `id` 末段；`id` 不与既有规则冲突。
3. **域冒烟**：对推导出的 domains 做一次轻量请求，**不拉全片**；不可达即失败。
4. **合规抽检**：目标站不得命中成人 / 侵权拒收清单（暮果先例；完整审核流程见 QUESTIONS Q13）。
5. 合并后 → 重生成 `index.json`（含每条 `sha256` / `size` / `updatedAt`）→ 签名。

### 9.3 分发、签名与更新

```json
{
  "repoVersion": 1,
  "generatedAt": "2026-10-14T12:00:00Z",
  "rules": [
    { "id": "official.yaguo", "name": "芽果", "version": "1.0.0", "minCore": "1.0.0",
      "schemaVersion": 1, "summary": "…", "updatedAt": "2026-10-14",
      "file": "rules/yaguo.json", "sha256": "…", "size": 1234 }
  ]
}
```

- **签名**：`index.json` 整体 Ed25519 签名，App 内置公钥验签；单条规则按 `sha256` 校验。  
  **为什么不像轨道 A 那样逐包签**：仓库是官方单一维护点，一次验签覆盖全量；且 PR 模式下规则作者不需要持有私钥。
- **第三方规则不走仓库**：仍走 §1.1 的文件 / URL / 扫码导入 + 用户确认 + 可选自签。
- **更新**：App 拉 index → 比对本地 `version` / `sha256` → 列表显示"可更新"。  
  **拉取失败或验签失败时保留上一次成功结果，不降级为"空仓库"**（避免一次网络故障把规则列表清空）。
- **P0 仓库地址内置且不可改**，防止用户被诱导指向恶意仓库；"用户可添加第三方规则仓库"（tap 模式）记 P1（QUESTIONS Q22）。

### 9.4 版本协商

| 字段                   | 谁在用     | 超限时                                    |
| -------------------- | ------- | -------------------------------------- |
| `schemaVersion`（int） | 引擎规则求值器 | 高于引擎支持值 → 拒载 + "请更新 App 后安装此规则"        |
| `minCore`（semver）    | 引擎 core | 高于 App → "该源需要 App ≥x.y.z"（与 §1 同一套文案） |

- 两轨共用 §1 的三种拒绝原因（签名失效 / 版本不兼容 / 权限不足），Dart 侧**不新增第四种文案**。

## 10. 规则管理（F-10 扩展）—— ⏸ 延后至 P2（随 §8 成套）

> ⏸ **延后（2026-10-14 用户决策）**：随 §8 成套延后。  
> **当前 F-10 收窄为「红果健康检测」**——只有一个源时，添加/导入/启用多源/规则仓库全部不成立（见 PRD §5 F-10）。

原 F-10「源管理 = 启用 / 禁用 / 健康 / 独立更新」扩展为**四通道 + 状态灯 + 分段检测**（P2 形态）：

| 动作                      | 说明                                                           |
| ----------------------- | ------------------------------------------------------------ |
| **规则仓库页**（新增）           | 拉官方 index → 列表（名称 / 版本 / 更新时间 / 覆盖域名 / 健康度）→ 一键安装；有更新时显示更新标记 |
| **本地导入 `.json`**（新增）    | 文件选择器；安装前展示确认卡（§10.1）                                        |
| **URL / 扫码导入**（沿用 §1.1） | 指向单条规则 json 或含 icon 的 zip                                    |
| **导出 / 分享**（新增）         | 导出为 `.json` 或打包 zip，便于社区传播（kazumi 同款能力）                      |
| 启用 / 禁用 / 卸载 / 版本校验     | 沿用，两轨通用                                                      |

### 10.1 安装确认卡（新增，规则专属）

规则是"会被允许访问哪些域"的可读声明，安装前必须让用户看得见：

- 规则名 / 版本 / 作者（可选）/ **声明的能力段**（目录 / 搜索 / 详情 / 播放，缺哪段明示"不支持"）；
- **它将访问的域名**（§8.2 推导结果），`extraDomains` 以**强调样式**单独列出；
- 声明 `play` 且带 `steps` 时，标注"会通过 N 步跳转获取播放地址"。

### 10.2 有效性检测（复用五阶段，按段裁剪）

沿用 F-10 五阶段健康检测（入口与目录 → 分集目录 → 播放地址与播放列表 → 播放密钥 → 媒体连接），  
但**只跑规则声明的段**：

- 无 `search` 段 → 跳过搜索项并标 **"该规则不支持搜索"**，**不判失败**（对齐星果 / 河果语义）；
- 无 `catalog` 段 → 该规则不出现在首页分类源列表（与轨道 A 未声明 `catalog` cap 同款处理）；
- 探测参数不变：固定 480 画质、分片 Range 0-1023、密钥限读 17 字节、不拉全片；诊断结果可复制且**不含凭证** [G10]。

### 10.3 状态指示灯（学 kazumi）

| 灯 | 含义                  |
| - | ------------------- |
| 绿 | 最近一次检测全通过           |
| 黄 | 部分段失败（如目录可用、播放不可用）  |
| 红 | 检测失败 / 引擎退避中 / 验签失败 |
| 灰 | 未启用                 |

### 10.4 上架与审核门槛

- 官方仓库：§9.2 CI 门禁 + 人工审核（成人 / 侵权拒收）。
- **优先规则化**：审核时要求"能用声明式规则实现的源，必须以规则形式提交"——  
  既降低第三方贡献门槛，也把图灵完备的攻击面收敛到少数确需的 WASM 源。
- 第三方规则违规可一键禁用并清除其缓存（沿用既有条款）。

### 10.5 P0 / P1 边界

- **P0**：仓库页 + 本地导入 + URL / 扫码 + 导出 + 分段检测 + 状态灯。
- **P1**：**内置规则编辑器**（kazumi 有 baseURL / searchURL + 选择器表单；我们再加 catalog / detail / play 表单）—— QUESTIONS Q23。
- 规则**不进备份**（沿用"第三方源不进备份"）；官方规则是否只备份 `id + version` 以便恢复后重装，待 QUESTIONS Q14。

## 11. 当前路径：红果内置源契约与 `SourceProvider` 预留

> **本节是 v0.5 后唯一生效的编码依据。** 上面的 §1–§10 全部延后至 P2。

### 11.1 `SourceProvider` trait —— "支持后续源扩展"的架构落点

Rust 引擎内定义**唯一**的源抽象，红果是它的第一个（P0 唯一）实现：

```rust
#[async_trait]
pub trait SourceProvider: Send + Sync {
    fn id(&self) -> &'static str;            // "hongguo"
    fn caps(&self) -> Caps;                  // 能力位：CATALOG/SEARCH/SUGGEST/DETAIL/RECOMMEND/RANKING/PLAY
    async fn catalog(&self, q: CatalogQuery)  -> Result<CatalogPage>;
    async fn search(&self, q: SearchQuery)    -> Result<SearchPage>;
    async fn suggest(&self, kw: &str)         -> Result<Vec<String>>;
    async fn detail(&self, drama_id: &str)    -> Result<Detail>;
    async fn recommend(&self, q: RecommendQuery) -> Result<Vec<Item>>;
    async fn ranking(&self, q: RankingQuery)  -> Result<Vec<Item>>;
    async fn play(&self, play_id: &str, quality: Option<u32>) -> Result<Media>;
}
```

- **契约纪律**：`Caps` 未声明的能力**直接返回 `UNSUPPORTED`**，不返回空列表冒充"查过了"（星果/河果教训）。
- **未来扩展**：P2 的 WASM 宿主或规则求值器**实现同一个 trait**，引擎调度层与 Dart 侧**零改动**——  
  这就是"支持后续源扩展"的真实含义（不是纸面承诺，是可替换的接口）。
- **不做编译变体**：源集合在运行时由注册表决定，**禁止 `--all-sources` 式编译开关**（沿用 v0.1 立场 [G15]）。  
  P0 注册表里只有 `hongguo` 一项，注册表本身从第一天就存在。

### 11.2 红果源契约（`hongguo`）

| 项          | 契约                                                                                                                                                                                  | 证据                                     |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 站点根        | `https://hongguoduanju.com`                                                                                                                                                         | EVIDENCE §17（`provider_hongguo.go:17`） |
| 请求签名       | **X-Gorgon**（MD5(query)+MD5(body)+魔数+ts → 20B → XOR 固定密钥 → 位旋转/反转 → 前缀 `{84,04,40,1c,00,00}`）；伴随头 `X-Khronos` / `X-SS-Req-Ticket` / `X-SS-STUB`                                     | EVIDENCE §17.1                         |
| 设备伪装       | `aid=8662`、`app_name=novelread`、`version_code=73532`、`device_platform=android`、`device_type=25053RT47C`、`device_brand=Redmi`、`os_api=36`、`resolution=1280*2772`、`device_id` + `iid` | EVIDENCE §17.1                         |
| 设备 ID      | 19 位十进制 `1e18 + rand % 8e18`；**必须持久化**（每次变化等于换设备，有风控风险）                                                                                                                             | EVIDENCE §17.1                         |
| 取流接口       | POST `/novel/player/video_model/v1/`；`video_model` 可能是 map **或需二次解码的 JSON 字符串**                                                                                                     | EVIDENCE §17.2                         |
| 媒体加密（② App 轨）  | **CENC-AES-CTR**：`encrypt_info.spade_a` → base64 → `tagLength = raw[0]^raw[1]^raw[2] - 48` → 剥尾 tag → 内容 ≥33 字节                                                                     | EVIDENCE §17.2                         |
| 编码过滤       | **`bytevc2` 整条变体跳过**（抖音自研编码，mpv 不支持）；同分辨率优先 h264/avc1                                                                                                                               | EVIDENCE §17.2                         |
| 备用线路       | `main_url` / `backup_url*1..2` / `backup_urls` / `url_list` 六处收集；非 HTTP 地址先 base64 解码（Strict→RawStd 两次）                                                                             | EVIDENCE §17.2                         |
| 媒体 Referer | 固定 `https://novel.snssdk.com/`                                                                                                                                                      | EVIDENCE §17.2                         |
| 响应解密       | 备用接口 **AES-CBC**（`material[16:32]` 作 IV）+ PKCS7 unpad                                                                                                                               | EVIDENCE §17.1                         |
| 弹幕         | **暂缓（Q1）**，签名独立（`provider_hongguo_comment_sign.go`）；契约冻结于 §3.4 / EVIDENCE §7                                                                                                        | —                                      |
| 能力覆盖       | catalog / search / suggest / recommend / ranking / detail / play —— **完整覆盖 F-01~F-06**                                                                                              | EVIDENCE §17.3                         |

### 11.3 红果特权逻辑的边界（合规红线）

- 签名密钥、设备伪装参数、spade_a 派生、AES-CBC 解密**全部在 Rust 引擎内**，**不进 Dart、不进规则文件、不进日志、不进备份**。
- **脱敏**：诊断日志不得输出签名头、`device_id`/`iid`、密钥（沿用 guoapp `diagnostics.go` 全局替换策略 [G10]）。
- 本项目为**第三方非授权客户端**；免责声明与合规流程见 QUESTIONS Q13（该定位下优先级上升）。

### 11.4 取流双轨（v0.6 新增）—— CENC 降级为 M1 的关键

红果的媒体取流在 §11.2（App 轨）之外还有一条**免签明文**路径，这是 v0.6 把 CENC 从"P0 阻断项"改为"M1 增强项"的直接依据（EVIDENCE §17.4）：

| 轨道 | 路径 | 是否签名 | 媒体形态 | 覆盖范围 |
| --- | --- | --- | --- | --- |
| **① 官网 SSR 免签** | `hongguoduanju.com/player/{series_id}/{vid}` → `_ROUTER_DATA` → `player_`/`player_page` → `video_player_info` | **免签** | **明文直链，无 CENC** | 目录/榜单/详情/选集/搜索 + **可试看集** |
| **② App API 签名** | fqnovel `POST /novel/player/video_model/v1/` + X-Gorgon | **签名** | **CENC-AES-CTR**（§11.2） | 全集 |

- **M0 只做 ①**：免签明文即可跑通"目录→搜索→详情→选集→播放"完整闭环；**② 的签名 + CENC 归 M1，不阻塞 M0**。
- **元数据整体免签化**：目录/榜单/详情/选集/搜索优先走 SSR，X-Gorgon 调用量大幅下降、缩小实现面（EVIDENCE §17.5）。
- 轨 ① **只能覆盖可试看集**（上限见 EVIDENCE §17.6 待验证 `accessible_episode_cnt`）；非试看集必须落到轨 ②，UI 需明示"该集需 App 授权"而非静默失败。
- **🔴 红线**：guoapp 的第三级兜底是第三方自建中转 `djapi.999888456.xyz`（非红果官方域名），**本项目不采纳**（与 PRD §1「不依赖自建中转服务」冲突）。取流只用 ①②。

## 12. v1 冻结检查清单（编码前逐项关闭）

> ⚠️ **§1–§10 对应的条目已随源扩展整体延后至 P2**；下列"v0.4 新增"部分同样延后，仅作留证。  
> **当前生效的待办见本节末尾「v0.5 当前路径」**。

- [ ] `play` 输出三项（playlist/hlsKey/cencKey）与引擎流服务的消费契约对齐（§3.1 ↔ ARCH §3.3）。
- [x] `play` 密钥返回模式（§3.1）——**Q5 已决（2026-10-14）：a，插件返回；host 代取记 v2**。
- [ ] `minCore` 协商与三种拒绝原因的可读文案（§1）。
- [ ] host `http_fetch` 的 UA/Referer/Cookie 继承规则写成引擎侧单一权威（§3.3 ↔ ARCH §6）。
- [ ] 插件配额 vs 引擎限流的边界写进同一张表（§4）——**Q6 已决：引擎唯一权威**。
- [x] 弹幕 cap（§3.4）——**Q1 已决（2026-10-14）：暂缓**。P0 不实现、不解冻；P1 恢复时第三方默认仍不开放。
- [ ] 错误码映射表与 Dart 文案一一对应（§6）。
- [ ] 五阶段合规向量的样本文件随测试提交（§5）。
- [ ] manifest 字段冻结：新增字段必须 bump `manifestVersion`，旧版拒载（防静默不兼容）。

**v0.4 新增（轨道 B 与规则仓库）—— ⏸ 全部延后至 P2，仅留证**：

- [ ] 双轨取舍确认：规则为默认、WASM 为逃生舱（§1）——**Q18 待确认（推荐 a）**。
- [ ] 规则求值位置定为 Rust 引擎侧，输出与 §3.1 四件套逐字段对齐（§8.7）——**Q19 待确认（推荐 a）**。
- [ ] 选择器定 CSS + JSONPath，**XPath 不进 v1**（§8.3）——**Q20 待确认（推荐 a）**。
- [ ] 规则 schema 冻结：`schemaVersion` bump 规则、`kind` 必填、抽取表达式语法（§8.1）。
- [ ] 规则模式密钥由引擎自取（§8.5），与 §3.2 媒体校验对两轨同等强制。
- [ ] 升 WASM 的五条闸门写成审核 checklist（§8.6），**明确不做 JS / WebView 解析路径**。
- [ ] 官方规则仓库：`index.json` 结构 + Ed25519 整体签名 + 拉取失败保留上次结果（§9.3）。
- [ ] 仓库 CI 五项门禁落地（§9.2），`index.json` / README 禁止手改的自动化保护。
- [ ] 规则管理四通道 + 安装确认卡 + 分段健康检测 + 状态灯（§10.1–§10.3）与 F-10 验收对齐。
- [ ] 新增 §8–§10 的合规向量样本（HTML 规则 / JSONPath 规则 / 多步 play 管道）随测试提交。
- [ ] 是否开放用户添加第三方规则仓库（Q22）与内置规则编辑器（Q23）——**P1，P0 不做**。

**v0.5–v0.6 当前路径（唯一生效的编码依据）**：

- [ ] `SourceProvider` trait 签名冻结（§11.1），红果为唯一实现；`Caps` 未声明能力返回 `UNSUPPORTED`。
- [ ] 源注册表从第一天存在，注册表内仅 `hongguo`；**禁止编译期源开关**。
- [ ] **X-Gorgon 签名实现 + 单测**（含固定向量：已知 query/body/timestamp → 已知 `X-Gorgon`），防算法漂移。
- [ ] 设备 ID / IID **持久化**（§11.2），非每次启动重生成。
- [ ] **spade_a → CENC 密钥派生**实现 + 边界单测（tagLength<1 / contentLength<33 / 输入>1024 三条拒绝路径）。
- [ ] **bytevc2 过滤**（含 `gear_des_key` 含 bytevc2 的情形）。
- [ ] **轨 ①（免签明文）实现**：`_ROUTER_DATA` 提取 + `video_player_info` 解析 + 试看集校验 —— **M0 出口条件**（§11.4）。
- [ ] **轨 ②（App 签名 + CENC）接入（M1，非 M0 阻断项）**：真机验证 mpv `decryption_key` 能否解红果 CENC；**不通过则降级为「仅可试看集可播」，不阻断发布**（§11.4）。
- [ ] 诊断日志脱敏清单覆盖签名头 / device_id / iid / 密钥（§11.3）。
- [ ] 红果能力逐项对照 §11.2 表格实现，缺哪项在 UI 明示"不支持"而非静默空列表。
- [ ] Q24（红果实现形态：trait 内置 vs WASM 插件）确认 —— **当前按 trait 内置推进**。

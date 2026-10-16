# Rust 核心 wire 契约（冻结）

> 面向：Flutter 前端开发者。
> 这份文档是 `rust/core` 对外**唯一**的契约面。前端只依赖本文，不需要读 Rust 源码。
> 契约变更必须同步本文 + 更新 `rust/core/src/lib.rs` 的 `CONTRACT_OPS` 表（有测试守卫）。

## 0. 传输层

C ABI 只有两个符号（`rust/core/drama_core.h`）：

```c
char* drama_request(const char* utf8_json);  // 返回的指针必须由 drama_free 释放
void  drama_free(char* ptr);
```

Dart 侧不直接调用它们，而是经 `lib/data/services/rust_core.dart` 的 `RustCore.call(op, ...)`。
该封装负责：常驻 worker isolate 池、`session`/`sequence` 仲裁、外层超时、超时后补发 `cancelRead`。

### 请求信封

```json
{ "v": 1, "op": "<op 名>", "source": "hongguo", "session": "...", "sequence": 1, "params": { } }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `v` | 是 | 固定 `1`。不匹配 → `BAD_VERSION` |
| `op` | 是 | 见下方 op 表。未知 → `UNSUPPORTED` |
| `source` | 否 | 源 id；省略用默认源 `hongguo`。未注册 → `NOT_FOUND` |
| `session` | 否 | 逻辑流标识，字符集 `[0-9a-zA-Z-_:.]`，长度 1..=128。非法 → `BAD_REQUEST` |
| `sequence` | 否 | 同 session 内单调递增。**省略即不参与仲裁** |
| `params` | 否 | 各 op 入参，见 op 表 |

**入参上限 1 MiB**，超限 → `TOO_LARGE`。

> `session` 由 Dart 封装按**逻辑流**自动生成（`logicalStreamFor`），前端不需要手填。
> 规则：首页并发打的 `catalog`/`recommend`/`ranking` 必须落在不同 session，
> 否则后发的会把先发的判为迟到 → 页面随机空白。

### 响应信封

成功：

```json
{ "ok": true, "data": { ... } }
```

失败：

```json
{ "ok": false, "error": { "code": "TIMEOUT", "msg": "...", "retry": true } }
```

`retry=true` 表示**可重试**（超时、限流、源站 5xx）。前端应据此决定是否给「重试」按钮。

### 错误码全表

| code | 含义 | retry | 前端应做什么 |
|---|---|---|---|
| `BAD_REQUEST` | 入参缺失/非法（含 session 非法） | false | 代码 bug，不要重试 |
| `BAD_VERSION` | 信封版本不符 | false | 代码 bug |
| `TOO_LARGE` | 入参 > 1 MiB | false | 代码 bug |
| `UNSUPPORTED` | 未知 op，或源未声明该能力 | false | 隐藏对应 UI，不要重试 |
| `NOT_FOUND` | 资源不存在（含未注册源、下载任务不存在） | false | 空态 |
| `PARSE` | 上游解析失败 | false | 提示「源站结构变化」 |
| `HTTP` | 底层 HTTP 失败 | 见 `retry` | 按 `retry` 决定 |
| `TIMEOUT` | 内层分级超时 | **true** | 可重试 |
| `CANCELED` | 同逻辑流内被更新的请求取代 | false | **静默忽略**，绝不当错误提示 |
| `source_blocked` | 源被限流/封禁 | **true** | 退避后重试 |
| `INTERNAL` | Rust panic 被 `catch_unwind` 兜住 | false | 上报 |

> `CANCELED` 是最容易用错的一个：它是**正常现象**（用户快速切类/翻页时的旧请求被取代），
> Dart 侧 `RustCoreException.isSuperseded` 即判断它。UI 不应把它渲染成错误。

## 1. 取消与超时协议

### 分级超时（内层先到期）

| op | 内层（Rust） | 外层（Dart） |
|---|---|---|
| 默认 | 60s | 70s |
| `preload` / `playQuality` | 15s | 20s |
| `catalogPages` | 120s | 130s |
| `moveDownloads` | 600s | 620s |

外层总是**略大**于内层，保证先由 Rust 报 `TIMEOUT`（带 `retry=true`），
而不是 Dart 单方面超时（那会丢掉错误语义）。

### 仲裁语义

带 `session`+`sequence` 的读类 op：

1. **进入时**：若同 session 已有更大的 `sequence` 在途 → 直接 `CANCELED`，**不发网络请求**；
2. **收尾时**：若期间来了更大的 `sequence` → 结果被替换为 `CANCELED`；
3. `cancelRead{session, sequence}` → `{canceled: N}`，取消同 session 中 `sequence` 更小的在途读，不阻塞。

**取消是协作式的**：不保证立刻中断对端 socket；最坏情况该请求占住一个 worker 直到内层超时。

## 2. op 表（38 个）

「仲裁」列 `是` = 该 op 参与 `session`/`sequence` 仲裁并受内层超时约束。

### 2.1 元信息（无状态）

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `ping` | — | `"pong"`（字符串） | 否 |
| `version` | — | `{core, sources:[{id,caps}], mediaPort}` | 否 |
| `init` | `dataDir`（必）, `downloadDir`? | `{initialized:true, deviceIdLen}` | 否 |
| `cancelRead` | `session`（必）, `sequence`（必） | `{canceled:N}` | 否 |

> `cancelRead` 是**协议控制**而非数据请求：它取消同 session 中 `sequence` 更小的在途读，
> **不阻塞、不参与仲裁**（否则取消自己会被取消）。Dart 封装在超时后自动补发，
> 前端通常不需要直接调用。

`version.sources[].caps` 是**能力协商**依据，字段为布尔：
`catalog` `search` `suggest` `recommend` `ranking` `detail` `playback`。

> 纪律：未声明的能力，对应 op 必须返回 `UNSUPPORTED`，**绝不返回空列表冒充「查过了」**。
> 前端应据此隐藏入口，而不是显示空态。

`version.mediaPort` 是本机代理（媒体 + 封面）端口，`null` 表示绑定失败（封面回落渐变占位）。

`init` 幂等；失败不阻断（退化为进程内临时身份 + 纯内存持久化）。

### 2.2 目录与详情（读类，均走 Rust 缓存）

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `catalog` | `category`?, `page`?（默认 1） | `{items:[Drama], hasMore, page, stale, ageSecs}` | 是 |
| `catalogPages` | `category`?, `depth`?（0/省略=跟随水位，上限见下） | `{pages:[[data]], hasMore, depth, stale, ageSecs}` | 是 |
| `recommend` | — | `{items:[Drama], stale, ageSecs}` | 是 |
| `ranking` | `board`?（默认 `hot`） | `{items:[Drama], stale, ageSecs}` | 是 |
| `search` | `keyword`（必，非空） | `{items:[Drama], total, stale, ageSecs}` | 是 |
| `suggest` | `keyword`（必，非空） | `{items:[String], stale, ageSecs}` | 是 |
| `detail` | `id`（必，非空） | `{drama:Drama, episodes:[Episode], stale, ageSecs}` | 是 |
| `episodeGroups` | `id`（必）, `groupSize`?（默认 50） | `{groups:[{...}], stale, ageSecs}` | 是 |

`stale` / `ageSecs` 由缓存层注入：`stale=true` 表示**当前是缓存兜底数据**
（网络失败后回退到 ≤24h 的旧值）。UI 应显示轻提示，而不是当作错误。

`catalogPages` 的 `depth` 上限为 `MAX_PAGES_PER_REQUEST`（防误用导致超长串行拉取），
超出会被静默 clamp。`depth` 省略/传 0 时跟随**已记录的分页水位**（用于重启续载）。

### 2.3 取流（播放链）

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `play` | `id`（必）, `episode`?（默认 1）, `vid`?, `quality`?（默认 0=最高） | `PlaybackPlan` | 是 |
| `preload` | 同 `play` | `{ready:true, proxyUrl, vid, warmedBytes}` | 是 |
| `playQuality` | `id`（必）, `vid`（必）, `quality`? | `PlaybackPlan` | 是 |
| `playLocal` | `id`（必）, `episode`? | `PlaybackPlan`（无完成文件 → `NOT_FOUND`） | 否 |
| `playFile` | `id`（必） | `PlaybackPlan`（注册本地文件会话） | 否 |

**`PlaybackPlan` 结构**：

```json
{
  "proxyUrl": "http://127.0.0.1:47800/play/{token}/video.mp4",
  "url": "https://...",           // 源站直链，仅诊断用
  "referer": "https://...",
  "durationSecs": 174.7,
  "quality": 360,
  "encrypted": false,
  "keyHex": "",                    // encrypted=true 时才有值
  "variants": [{ "url": "...", "quality": 360 }],
  "qualityOptions": [{ "height": 1080, "label": "1080P" }],
  "vid": "7686715217652223038"
}
```

> **播放器只应打开 `proxyUrl`**。它指向本机回环代理，Referer 鉴权与（加密轨的）CENC 解密
> 都已 baked 进会话；直接打开 `url` 会因缺 Referer 而 403。
>
> `playLocal` / `playFile` 返回同构计划，因此播放页**不需要为离线单独写一套逻辑**。

**取流三级降级**（`play` 内部自动完成，前端无感）：

| 轨 | 条件 | 画质 |
|---|---|---|
| App 签名 | 上游对未授权客户端可能返回空 body | 最高 1080p，加密 |
| **网页公开轨** | 免签可用 | **360p，仅每剧前 3 集** |
| 网页 SSR | 站点已改 `protectedPlayback`，多数情况失效 | — |

公开轨只覆盖前几集，**其余集会返回 `NOT_FOUND`** —— 前端需为此准备文案
（不是「网络错误」，而是「该集需要 App 授权」）。

`quality` 语义是**期望清晰度上限**：`0` = 要最高；`>0` 时只在 `<= quality` 里选最优，
无满足时回退最低档（不会失败）。

### 2.4 追剧与进度（Rust 持久化）

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `followPut` | `id`（必）, `title`?, `cover`?, `episode`?, `positionSecs`?, `durationSecs`?, `totalEpisode`? | `{id}` | 否 |
| `followDel` | `id`（必） | `{id}`（幂等，不存在也算成功） | 否 |
| `followList` | — | `{items:[FollowEntry]}` | 否 |
| `historyPut` | `id`（必）, `episode`?, `positionSecs`?, `durationSecs`? | `{id}` | 否 |
| `historyGet` | `id`? | 带 `id` → `{item:HistoryEntry\|null}`；不带 → `{items:[HistoryEntry]}` | 否 |
| `historyClear` | — | `{cleared:true}`（不动追剧表） | 否 |

```
FollowEntry  = {id, title, cover, episode, positionSecs, durationSecs, totalEpisode, updatedAtMs}
HistoryEntry = {id, episode, positionSecs, durationSecs, updatedAtMs}
```

`historyPut` 会**同时**刷新已存在追剧条目的进度；`followList` 按 `updatedAtMs` 倒序。

> `FollowEntry.cover` 读出时已按**当前**代理端口改写（端口跨会话会变），
> 前端直接渲染即可，不要再自己解析 URI。

### 2.5 搜索历史（Rust 持久化）

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `searchHistoryPut` | `keyword`（必） | `{keyword}` | 否 |
| `searchHistoryList` | — | `{items:[{keyword, updatedAtMs}]}` | 否 |
| `searchHistoryDel` | `keyword`（必） | `{keyword}` | 否 |
| `searchHistoryClear` | — | — | 否 |

`searchHistoryPut` 去重并置顶（LRU），条数有上限。

### 2.6 下载

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `downloadStart` | `seriesId`（必）, `episode`?, `vid`?, `quality`?, `title`?, `cover`? | `DownloadRecord` | 否 |
| `downloadList` | — | `{items:[DownloadRecord]}` | 否 |
| `downloadPause` | `id`（必） | `DownloadRecord` | 否 |
| `downloadRetry` | `id`（必） | `DownloadRecord` | 否 |
| `downloadCancel` | `id`（必） | `DownloadRecord` | 否 |
| `downloadDelete` | `id`（必）, `files`?（默认 false） | `{id}` | 否 |
| `moveDownloads` | `dir`（必，非空） | `{dir, moved, bytes}` | **是**（600s 档） |
| `downloadSetConcurrency` | `parallel`（1..=6） | — | 否 |

```
DownloadRecord = {id, seriesId, title, cover, episode, vid, quality,
                  total, done, state, error, speed}
```

`id` 形如 `"{seriesId}:{episode}"`。`state` ∈
`queued` `downloading` `paused` `completed` `failed`。

- `downloadStart` **幂等**：同 `id` 已存在则直接返回现有记录，不重复下载。
- `moveDownloads` 会**先停机再搬**，失败时旧目录原样保留。
- `downloadDelete` 的 `files=true` 才删磁盘文件。

> 下载是**长任务**，跑在独立运行时；前端靠**轮询 `downloadList`** 取进度，
> 没有推送通道。建议 500ms~1s 轮询，且仅在下载页可见时轮询。

### 2.7 缓存管理

| op | 入参 | data | 仲裁 |
|---|---|---|---|
| `cacheClear` | — | — | 否 |
| `cacheFlush` | — | — | 否 |
| `cacheStats` | — | `{entries, bytes, dirty, oldestSecs, maxEntries}` | 否 |

## 3. 前端实现注意

1. **不要把 `CANCELED` 当错误**（见 §1）。
2. **能力协商**：启动时调一次 `version`，按 `caps` 决定入口可见性。
3. **`stale=true` 要提示**，但**不要**当成错误态。
4. **播放只打开 `proxyUrl`**。
5. **`NOT_FOUND` 有多种含义**：未注册源、下载任务不存在、公开轨未覆盖该集。
   需按 op 上下文区分文案。
6. **下载进度靠轮询**，无推送。
7. **超时已由两层覆盖**，前端不要再叠一层自己的 timeout（会掩盖错误语义）。

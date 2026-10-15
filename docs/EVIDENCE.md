# EVIDENCE.md — guoapp 实证契约清单（docs v0.6 配套）

> **目的**：本项目三份文档（PRD/ARCH/SourceSpec）中的每个关键数字与契约，必须能回溯到参考实现。
> 本文件是唯一回溯表。文档中标注 `[G#]` 即指本表条目。
>
> **证据基线**：`reference/guoapp`（红果鉴/真果鉴）**0.2.55+61 未验证开发快照**；
> Go 模块 `duanjuapp/native`（go 1.24.1），Flutter 3.47.4 / Dart 3.13.3。
> 阅读日期 2026-10-14；出处格式 `文件:行`，均经代码复核。
>
> ⚠️ **guoapp 自 2026-09-21 起暂停集中验证**（见其 AGENTS.md），大量功能 README 自标
> "待验证/未验收"。标注 **[待验证]** 的结论，本项目借鉴时必须自行真机验证，不得当作已通过验收。

---

## 0. 出处索引（高频文件）

| 代号 | 文件 | 内容 |
|---|---|---|
| B | `native/bridge/main.go` | C ABI 唯一入口 |
| R | `native/core/app_runtime.go` | 请求分发、超时、取消、initialize |
| Q | `native/core/app_requests.go` | session/sequence 仲裁、cancelRead |
| N | `native/core/network_*.go`（browser/cdn/media/dns/limiter） | HTTP 引擎、指纹、CDN 兜底、限流 |
| P | `native/core/app_playback*.go`、`app_stream.go`、`app_preload.go` | 播放解析、本地流服务、预加载 |
| D | `native/core/app_downloads*.go`、`app_download_hls.go`、`app_download_transfer.go` | 下载全链路 |
| M | `native/core/app_danmaku.go`、`ui_playback_danmaku.go`、`danmaku_emoji.go` | 弹幕 |
| S | `native/core/app_storage*.go`、`app_persistence.go`、`app_catalog_cache.go` | 存储、缓存、迁移 |
| L | `native/core/app_lan.go`、`app_lan_http.go` | 局域网（仅传输层） |
| H | `native/core/app_source_health.go`、`diagnostics.go` | 健康检测、诊断日志 |
| CB | `lib/core_bridge.dart` | Dart FFI 封装 |
| LS | `lib/local_store.dart`、`local_snapshot.dart`、`local_profiles.dart` | 本地状态、快照、PIN |
| PL | `lib/playback_recovery.dart`、`player_screen.dart`、`playback_preloader.dart` | 播放 UI 与恢复 |
| DM | `lib/danmaku_*.dart` | 弹幕 UI |
| GL | `reference/liquid_glass_widgets`（lib/ + docs/PLATFORM_SUPPORT.md） | 玻璃 UI 包 1.13.0 |

---

## 1. ABI 与取消协议 —— **照抄**（Rust 版同形态）

| 契约 | 值 | 出处 |
|---|---|---|
| 导出符号 | 仅 `DuanjuRequest(const char*) -> const char*` + `DuanjuFree` | B:12-21 |
| 入参拷贝 / 返回 owned | GoString 拷入；C.CString 出，Dart `malloc.free` + `free` 配对 | B:12-21, CB:28-59 |
| 入口兜底 | `recover()` → `{"ok":false,"error":"本地核心处理失败，请重试"}`；输入 >1MiB 直接拒 | R:283-333 |
| 错误信封 | `{ok, data\|error, code?, retryAt?}`；code 仅 `local_media` / `source_blocked`(+retryAt ms) | R:283-333 |
| session 格式 | `[0-9a-zA-Z-_:.]`，≤128 字符 | Q:16-21 |
| 取消仲裁 | `(session, sequence)` 单调序列号：旧 sequence 返回 Canceled；同 session 新请求取消旧请求 | Q:23-54 |
| 读并发上限 | 前台在途 ≤16；新 session 且总 reads ≥128 拒绝；完成 read 15min GC | Q:23-65 |
| 需仲裁的 action | danmaku/preload/prepareHandoff/catalog/categories/suggestions/recommendations/metadata | R:367-374 |
| 播放解析串行 | 同时只允许一个 playback resolve | P(app_playback.go):5-39 |
| Dart 侧超时 | moveDownloads 620s / danmaku 15s / preload 20s / 默认 70s | CB:573-583 |
| Go 侧超时 | moveDownloads 10min / danmaku 10s / preload 15s / 默认 60s | R:357-364 |
| 超时节律 | **外层(Dart) > 内层(Go)**，内层先到期；Dart 超时后**主动补发 cancelRead** | CB:602-625 |
| 用户切换令牌 | profileEpoch：调用前后校验，切换则释放 session/lease 并抛「用户已切换」 | CB:592-600（**本项目不采纳**：Q3 移除多用户，无切换概念） |
| 编译变体核对 | initialize 返回 allSources 标志，Dart 启动核对一致防混装 | R:350, CB:638-639 |
| FFI 调用形态 | 每次 `Isolate.run` 现开现弃（Go 单例 + mutex） | CB:573 |

> 对本项目：ARCH §3 已定义窄 ABI，取消协议与超时表见 ARCH §3.2（**v0.3 起按 Q7=a 照抄后简化**）：
> session/sequence 仲裁与超时补发 cancelRead 两条保留，"总 reads ≥128 拒绝"双阈值简化为单用户常量；
> 请求 ID + generation 令牌重设计记 P1 引擎演进项。Rust+tokio 下"每次 Isolate.run"改良为常驻 worker isolate + 端口。
> profileEpoch 一行（多用户切换令牌）**不采纳**：Q3 完全移除多用户，session 生命周期 = App 生命周期。

## 2. HTTP 引擎 —— 部分照抄、部分改良

| 契约 | 值 | 出处 |
|---|---|---|
| 传输链 | stdlib Transport(TLS≥1.2, MaxIdleConnsPerHost=8, ResponseHeaderTimeout=20s) → CDN DoH 兜底 → 指纹客户端；Client Timeout 45s | R:255-272 |
| 重定向 | ≤10 次；**跨 host 重定向删除 X-Preview-Token** | R:264-272 |
| TLS 指纹 | tls-client Chrome_150 + 随机扩展序，**仅白名单 host**（黄果视频 + 皮果），GET/HEAD only | N(network_browser.go):17,62-91 |
| UA 分层 | 默认 iPhone Safari 18.7；duanju 源 Chrome/131 Win；观果 okhttp/5.1.0；legacy 另带 X-User-Agent（嵌设备号） | N:123-158, provider_duanju_client.go:52 |
| 限流 | 按 **source** 粒度串行 gate，全局并发 3；前台优先（后台须等前台清空）；后台目录请求压到 8s | N(network_limiter.go):152,237-239 |
| 退避 | 403/429/`Cf-Mitigated:challenge` 触发，默认 1min，尊重 Retry-After，**封顶 30min**；前台/后台分表 | N:199-219 |
| CF 页面识别 | 文案匹配 "just a moment" / "you have been blocked" | N:41-46 |
| 重试 | 每源 Retries=2，线性 sleep attempt×1s，5xx 轮换 API 入口 | provider_legacy.go:221-228 |
| 媒体请求 | **不走限流器**（分片/密钥/播放列表允许突发） | N(network_media.go):127-131 |
| 凭证注入 | 仅当请求 origin == 凭证 origin；过期即拒；重定向后重新 apply | N(network_media_credentials.go):38-74 |
| 系统代理 | 30s 缓存；Windows 读注册表；**127.0.0.1/localhost 永远直连**（本地流服务依赖）；PAC 模式明确报错要求手配；manual 仅 http/https/socks5/socks5h，禁 query/fragment | S(app_settings.go):69-83, proxy_system*.go |
| CDN DoH 兜底 | 仅 4 个受保护 CDN 域；alidns→google；ECS 8.8.8.0/24 预查；最多试 4 IP；拒绝保留段地址 | N(network_cdn.go, network_dns.go) |

> 对本项目：**TLS 指纹是按 host 白名单的可选层，不是默认层**（20 个源里只有 2 类需要）。
> reqwest 无 Chrome 指纹能力，需评估 rquest 或接受"皮果式源报 WAF_BLOCK"（见 QUESTIONS Q8）。
> 限流/退避必须活在引擎，不下沉 WASM 插件（见 SourceSpec v0.2 §4）。

## 3. 播放链路与本地流服务 —— **照抄契约**

| 契约 | 值 | 出处 |
|---|---|---|
| 解析产物 | providerMedia{URL,Referer,Duration,Playlist(预取文本),HLSKey[16],CENCKey[16],Quality,Variants[]}；Variants 去重键=URL+Referer+CENC+HLS | P(provider_media.go):12-22, app_playback_routes.go:30 |
| 会话寻址 | 24 随机字节 hex；plan 先带直媒 URL+headers，再替换为本地流地址；playbacks map 上限 8、12h 过期 | P(app_playback_routes.go):58-134 |
| 流服务器 | `127.0.0.1:0` 随机端口；ReadHeaderTimeout 5s / IdleTimeout 30s / MaxHeaderBytes 16KB；仅 GET/HEAD；未知 session → **410 Gone** | P(app_stream.go):57-67,212-231 |
| 资产寻址 | `sha256(address+contentType)[:12]+ext`，会话级缓存 | P(app_stream.go):116-140 |
| HLS 重写五类 | EXT-X-KEY/SESSION-KEY→注入 16B 密钥(octet-stream)；EXT-X-MAP→video/mp4；EXT-X-MEDIA/I-FRAME-STREAM-INF/RENDITION-REPORT→m3u8；data: 原样 | P(app_stream.go):142-210 |
| 透传 | Range/If-Range；上游 playlist ≤4MB 且必须以 `#EXTM3U` 开头；非 200/206 翻译后原状态码透传 | P(app_stream.go):270-333 |
| 预取预算 | 总限 4MiB、≤8 请求、深度 ≤2；master 只取 2 分片或累计 8s；解析 6s 预算 | P(app_preload.go):20-162 |
| 预取校验 | Content-Range + ETag/Last-Modified；无 validator 或 weak validator 放弃缓存 | P(app_preload.go):109-111 |
| 前缀续取 | If-Range 校验失败 → invalidate 同地址所有资产 | P(app_preload.go):257-266 |

## 4. 卡顿恢复与预加载触发 —— **照抄代码、别抄 README**

| 契约 | 值 | 出处 |
|---|---|---|
| 卡顿判定 | stallTimeout 20s；条件 = `playing && foreground && position 1s 内无变化`；**暂停/后台不触发** | PL(playback_recovery.dart):33,48-54, player_screen.dart:302-315 |
| 恢复三级 | 有备用线路(alternative)→ 切线路；否则未 refresh 过 → 重新解析；`maxAttempts=3` 后 stop；本地播放直接 stop | PL(playback_recovery.dart):15-29 |
| 切线路语义 | 保留进度与倍速；手动画质只切同画质线路；retained session 由 Dart release | PL:33, player_screen.dart:965-975 |
| 防抖 | `_queueRecovery` 900ms | player_screen.dart:747-771 |
| 预加载触发 | position ≥2000ms；**position<duration/2 且 duration-position>45s 时不触发**；缓冲余量 buffer-position<5s 不触发 | player_screen.dart:651-684 |
| 计划寿命 | 就绪计划保留 2min；带 expiresAt 的计划提前 5s 停复用；失败 ≥30s 重试 | player_screen.dart:651-684, README:153 |
| 进度保存 | 5s 周期 + `_savedProgressKey` 去重；失败显示警告条+重试，不静默 | player_screen.dart:298-301,840-881 |
| mpv 参数 | buffer 32MB、network-timeout 20、seg_max_retry 3、`decryption_key=<hex>` | player_screen.dart:998-1012 |

> ⚠️ **README:147 声称"自动画质先试同画质备用→再试较低画质"——代码中不存在降画质分支**，
> `PlaybackRecovery.next` 只有 alternative/refresh/stop。**照抄代码，不照抄 README。**

## 5. 下载链路 —— **逐条保留**（每条背后都是事故）

| 契约 | 值 | 出处 |
|---|---|---|
| 任务状态 | queued→downloading→completed/failed；paused/removing；archived 标志；ID=`sha256(dramaID+index)[:16]` | D(app_downloads.go):25-75 |
| 索引 | index.json ≤32MiB；加载逐条校验 ID/Folder/File(仅 media.mp4 或 index.m3u8)/状态，任一不过整库拒绝；中断任务→paused | D:117-157 |
| 入队边界 | 1-500 集/次、集数 1-100000、未归档任务 ≤5000；保存失败整体 rollback | D:245-319 |
| 调度 | 并发默认 2、上限 6；FIFO；进度落盘节流 1s | D:441-472, app_settings.go:28-35 |
| 单任务线路 | 最多试 3 条线路 | D(app_download_transfer.go):527 |
| 批量 | 1-500 ID 逐条收集；`expectedVersions` 乐观锁（`created-bytes-quality[-revision]`）防误删 | D(app_download_collections.go):76-107 |
| 续传三元组 | `target` + `target.part` + `target.json`(URL/Validator/Total/Complete)；validator 存在才续传；最多 2 次 attempt | D:145-174 |
| 续传细节 | `Range: bytes=offset-` + `If-Range`；**30s 无活动取消**；Accept-Encoding identity 且拒绝非 identity Content-Encoding；拒绝 text/html 与 application/json 响应体；416/412→整体重启；206 校验 Content-Range；密钥 total≤64 且最终必须 16B；64KB 缓冲+fsync+rename | D:176-301 |
| HLS 保存 | walk 深度≤6、visited≤100、单 playlist≤4MB、**必须有 #EXT-X-ENDLIST（拒直播/未结束）**、拒绝 `{$` 变量地址、仅 AES-128/NONE 且 KEYFORMAT identity/空、资产≤20000 | D(app_download_hls.go):102-246 |
| bundle 指纹 | `.bundle`=entry+URL+CENC+quality+全部资产+playlists 的 sha256，不一致先 RemoveAll 再下（换线路/密钥=重下） | D(app_download_hls.go):68-74 |
| 目录结构 | `<root>/[source/]<jobID>/.bundle + index.m3u8 + 分片 + *.key` | D(app_download_transfer.go):40-123 |
| 本地校验 | 递归 depth≤8、≤20100 文件、m3u8≤4MB 且 #EXTM3U 开头、media.mp4 大小必须等于记录 Bytes | D(app_download_collections.go):18-65 |
| 后台边界 | Android 前台服务（serviceId 2406，通知可暂停）；系统杀进程保留任务与完整文件；Windows 保持运行；**iOS 仅前台下载**，回前台续传 | lib/background_downloads.dart, README:203-204 |

## 6. 存储与备份 —— 照抄语义、替换实现

| 契约 | 值 | 出处 |
|---|---|---|
| 串行写队列 | 所有写首尾相接，前一个失败不阻断后一个 | LS(local_store.dart):1118-1121 |
| 完整快照提交 | 全量 values 单 key `localSnapshot.v1`（SharedPreferences，16MiB）；commit 失败 reload 恢复 previous，双重失败抛 RecoveryRequired → 全局锁定 | LS(local_snapshot.dart):98-126 |
| 未保存状态机 | 保存失败记 NeedsSave，未落盘结果 `Fresh=false, HasMore=true`；下次请求先重试保存 | S(app_persistence.go):73-94, app_catalog_cache.go:240-242 |
| 原子写 | 临时文件 + Sync + rename，目录 0700 | S(app_catalog_cache.go):264-285 |
| 目录 TTL | 目录 15min；page=1 刷新旧条目合并保留 | S(app_catalog_cache.go):12,100,189-213 |
| 封面缓存 | 256MiB / 2000 张 / 单张 20MiB / TTL 30 天 | S(app_covers.go):23-26 |
| 目录迁移 | EvalSymlinks；目标必须不存在；**源/目标互相包含即拒**；符号链接一律拒绝；暂停任务→workers.Wait→逐文件(512KB,O_EXCL,0600,每文件 Sync)→写 location→删源；失败删目标保源 | S(app_storage.go):114-193 |
| PIN | HMAC-SHA256 12 万次迭代 XOR 链；6-128 字符；失败 3 次起锁 `min(failures*2,30)`s；常量时间比较 | LS(local_profiles.dart):79-103,742-756（**本项目不采纳**：Q3 移除多用户/PIN） |
| 备份 | 8MiB 上限、schema 1；不含视频/密钥/插件私配；损坏恢复需原管理员 PIN，**不回退成无密码管理员** | LS:1050-1085, README:187-189（简化采纳：上限与"不含项"保留；PIN 与不回退条款随多用户移除取消，损坏恢复改为可重试+保留原文件；是否含已安装源清单待 Q14） |
| 记录上限 | favorites 20000 / history 300 / mediaHistory 300 / seriesCandidates 2000 / recentSearches 20 / profiles 20 | LS:442-797 |

> guoapp 的 P1-R10 真事：偏好保存返回 false 后"操作正常结束、重启丢数据"；恢复中断造成
> "历史是新、收藏是旧"混合态；损坏配置回退无密码管理员。**完整快照提交+回滚+锁死是被事故逼出来的**。
> 本项目用 drift(sqlite) 替换单 key JSON，但三条契约必须保留（见 ARCH §5）。
>
> **Q3 已决（2026-10-14）**：多用户/PIN/profiles 完全移除，本节 PIN 与多用户相关契约**不采纳**；
> 串行写队列/原子提交/未落盘=不新鲜三条保留；"管理员密码恢复/不回退无密码管理员"取消（风险归操作系统锁屏）。

## 7. 弹幕（红果内置源能力）—— **暂缓**（Q1 已决 2026-10-14：P0 不做；若要 P1 恢复，整套照抄）

| 契约 | 值 | 出处 |
|---|---|---|
| 窗口/游标 | 30s 窗口；请求体 `comment_source:601,count:90,cursor:""`；游标来自 `extra.next_query_danmaku_list_time`，NextMS=min(next,duration)；总数取 `common_list_info.cursor.danmaku_count` | M(ui_playback_danmaku.go):53-137 |
| 校验 | 仅 `hongguo-cenc://` scheme 分集；status=="1"；group_id==videoID；位置∈[start,nextMs)；ID 去重；单页≤90；文本≤180 runes；控制字符→空格 | M:138-166, app_danmaku.go:9-33 |
| 缓存 | key=series:video:start:duration；成功 5min / 错误 15s；单飞 pending≤16；map 上限 128 满则整体清空；取消/超时不落缓存 | M:63-115 |
| UI | lifetime 8s；轨道数=clamp((h*0.55-8)/rowHeight,0,4)；同 lifetime ≤24 条；字号 16/20；drift>600ms 或 jump>2000ms 重锚定；页缓存保留最近 6 页；失败退避 15s | DM(danmaku_models.dart):1-3, danmaku_controller.dart:116-122,249-262 |
| 表情 | 内置 ~55 条短码→emoji；`\[[^\[\]\s]{1,10}\]` 小写匹配；**截断在 FE0F/FE0E/200D 前回退**（组合 emoji 不乱码） | M(danmaku_emoji.go):80-107 |

## 8. 搜索 / 目录 / 追剧 —— 照抄触发条件

| 契约 | 值 | 出处 |
|---|---|---|
| 搜索防抖 | 300ms；composing 中（中文输入）不请求；stale 序号抑制；缓存 32 条；联想 ≤10；query ≤100 字符 | lib/search_input.dart:58-85 |
| 正式搜索 | 总时限 40s；补漏季 ≤32 次查询；前台在途 ≤16；部分失败保留有效结果；**不用网页 totalCount 虚构下一页**；最近 20 条按用户 | README:139,915 |
| 分页触发 | extentAfter = `(viewport*1.5).clamp(320,900)`；缓存优先 fresh 跳过网络；失败保留 items+hasMore；滑动切类 velocity≥240；站源更新后 100ms 防抖刷新 | lib/home_screen.dart:167,272,448, catalog_browser.dart:224-290 |
| 排序 | 全角→半角+去标点归一化；中文季号自然排序；亿/万/w/k/m/b 解析；未知值置后 | lib/catalog_sort.dart |
| 追剧基准 | 已读基准只升不降（旧资料/临时变少不降低）；手动"标记已看"独立保存，重看/新集不覆盖；新季提醒不自动加入追剧，点入/标记已读才清除 | lib/follow_state.dart:150, README:171-175 |
| 详情补齐冷却 | 单剧 404 冷却 24h、其他失败 5min；每批 ≤8 部；连续失败停止当前批后从后续条目推进 | README:929 (P2-11) |

## 9. TV / UI / 玻璃包 —— 核对后修正

| 契约 | 值 | 出处 |
|---|---|---|
| 电视识别 | MethodChannel `duanju/device`，2s 超时 fallback；Leanback/Leanback-only/Fire TV 特征 + 无触屏/遥控导航保守判断；排除电话/传感器/车载/手表/VR/PC | lib/app_layout.dart:52-78, README:343 |
| 焦点模型 | 显式越界接管（网格第一行按上回分类栏、第一列按左回侧栏…）；每页初始焦点兜底；48×48 触控目标；控制条 5s 隐藏；seek ±10s | lib/remote_widgets.dart, television_controls.dart:138,208-221, README:363-368 |
| 玻璃三档 | premium=双通道 GLSL（**需 Impeller**，禁用于滚动列表）；standard=轻量单通道（全平台，95% 场景）；minimal=零 shader BackdropFilter（密集列表/兜底） | GL(glass_quality.go):5-78 |
| 钳制三层 | ①渲染期：`!kIsWeb && !platformViewBackdrop && premium && isShaderFilterSupported`，Skia 上 premium 静默走 lightweight；②adaptive Phase 1：isShaderFilterSupported=false→**强制 minimal**；`kIsWeb\|\|Windows\|\|Linux`→钳 standard；③Phase 2/3 动态：跳过 90 帧收集 180 帧，P75<20ms→premium、20-28→standard、>28→minimal；P95>16×1.5 连续 2 窗口降档，<16×0.6 连续 10 窗口升档，8s 冷却 | GL(adaptive_glass.dart):328-331, glass_quality_adapter.dart:488-551,616-705 |
| 嵌套玻璃 | `GlassContainer.avoidsRefraction` → 子玻璃走 `_VibrancyFill`：**无 blur 无折射，alpha 钳 0.08-0.45**（静默降质不报错） | GL(adaptive_glass.dart):726-767 |
| platformViewBackdrop | per-widget 核弹：置 true 强制 `_FrostedFallback`，premium 静默失效，每帧一个活 BackdropFilter | GL(adaptive_glass.dart):245,866-872 |
| 初始化 | `initialize()` 纯异步磁盘 I/O 不阻塞首帧，**失败不抛异常**，shader 未就绪时 premium 面渲染空白（首帧白闪来源）；`wrap()` 官方 Optional（仅 theme/adaptive 需要） | GL(liquid_glass_setup.dart):104-167 |
| MaterialApp 三件套 | `brightnessResolver: Theme.maybeBrightnessOf`（必需）+ `Material(type: MaterialType.transparency)` + `cupertino_icons` 直接依赖 | GL(README):77-84,953-987 |
| 生命周期 | App resume **重跑 Phase 2 benchmark**（恢复瞬间可能再降/升档） | GL(glass_adaptive_scope.dart):647-654 |
| 档位链 | widget→inherited→theme→class-default，**全部被 GlassAdaptiveScope 天花板覆盖**；bars 被 GlassScaffold 自动提 premium | GL(glass_theme_helpers.dart):126-222, glass_scaffold.dart:623-657 |

> ⚠️ 我们 ARCH v0.1 写的"Windows premium 钳制为 standard"成立但需注明**前提是 adaptiveQuality:true**；
> 不开 adaptive 时靠渲染期 isShaderFilterSupported 兜底（视觉等同 standard）。
> **Android-Skia 在 adaptive 下被强制 minimal，不是 standard**（v0.1 若照抄会写错）。
>
> **Q9 已决（2026-10-14），同日修订：基线 = Flutter 3.47.4（以 media_kit 兼容为准）+ 全面 Impeller，非 3.47.6。** 事实更新（已核实）：
> Windows/Linux 的 3.47 线已默认 Impeller，但后端仍是 **GLES via ANGLE→D3D11（非 Vulkan**，桌面 Vulkan 后端为 P2 设计稿）；
> `isShaderFilterSupported` 在 Impeller 下为 true，**但包 Phase 1 平台钳制仍把 Windows/Linux 钉 standard**——
> 即上表钳制结论的"平台部分"不变、"能力部分"已随 Impeller 解除。Android API<29 旧机仍 legacy GL → minimal。
> 上述结论需在 3.47.4 真机复核后作为验收依据（ARCH §8 基线验证）；Windows 冲 premium 记 P1 实验。
> **降级 3.38.10 情形**：桌面默认回 Skia（Impeller 需手动 flag），Windows 从"平台策略钳 standard"退化为"shader 能力不足"，
> 验收档位结论不变（仍 standard），但 Windows premium 实验取消、wide gamut 不再默认开。

## 10. 健康检测与诊断 —— 直接复用

| 契约 | 值 | 出处 |
|---|---|---|
| 五阶段 | 入口与目录 → 分集目录 → 播放地址与播放列表 → 播放密钥 → 媒体连接；catalogOnly 只跑第一阶段 | H(app_source_health.go):54-192 |
| 探测手法 | master playlist 最多跟 6 层；固定按 **480 画质**选择；密钥探测限读 **17 字节**；分片 `Range: bytes=0-1023`；15s 超时；拒绝 html/json 响应体 | H:194-278 |
| 诊断 | JSONL 日志 5MiB×2 轮转；Token/AESKeyHex/InterfaceKey/ParamKey/ParamIV 全局替换；URL 用户段/query/fragment 打码；复制给用户的诊断不含凭证 | H(diagnostics.go):15-114 |
| 阶段实时性 | 每阶段耗时/HTTP 状态/CFRay 实时 publish 到站源记录 | H:58-101 |

## 11. LAN —— **砍掉备查**（Q10 已决 2026-10-14：整个砍掉，备份导入导出替代；本节仅留证，不进任何批次）

| 契约 | 值 | 出处 |
|---|---|---|
| 分层 | **Go/Rust 只做 mTLS 传输+事件泵，同步业务全在 Dart**；mDNS 发现也在 Dart（nsd 包），Go 无 mDNS | lib/lan_controller.dart, L |
| 身份 | 自签 P-256，CN=deviceID(32hex)，10 年；pin=sha256(证书 DER) hex；身份文件 ≤32KB | L(app_lan.go):114-192 |
| 服务端 | TLS1.3 强制 + RequireAnyClientCert；仅私网 IP；仅 POST 禁 query/Origin；路径白名单 `/zgj/v1/*`；每 IP 30 次/分钟；16 并发槽；Bearer token + 2h 滑动 | L(app_lan_http.go):152-289 |
| 事件泵 | 请求经 events channel（缓冲 16）抛给 Dart，Dart 12s 长轮询取走、respond 回填；pending 50s 超时 | L:260-269,371-383 |
| 同步协议 | 摘要 128/页、差异 16/请求、单条 ≤512KB、批次 ≤16 条/640KB、接收 ≤12MB；**提交顺序先推远端后本地** + receipt 幂等（保留 64 条）；leader = id 较小端；urgent 700ms flush；自动同步 ≥10s 间隔 | lib/lan_controller.dart:240,864-911, lan_sync.dart:3-403 |
| 版本向量 | 版本关系判断先后，不依赖设备时钟；删除标记传播；冲突保留候选由用户选择 | README:258-270 |
| 不同步项 | 设备能力/实测档位/驱动失效记录不随 LAN 同步 | README:476 |

## 12. 构建 / CI / 验证 —— 照抄方法

| 契约 | 值 | 出处 |
|---|---|---|
| 变体单一事实源 | 一个 `--all-sources` 同时驱动 Go ldflags + Dart dart-define + 产物名前缀；启动核对防混装 | scripts/app_build.py:27, README:782 |
| Go 构建参数 | CGO_ENABLED=1；`-trimpath -buildmode=c-shared -ldflags="-s -w"`；Android 16KB 页对齐 `-Wl,-z,max-page-size=16384`；GOARM=7 | scripts/build_native.py:62-64 |
| 产物校验 | Android 核对 5 个 .so；Windows 核对 9 个必需文件；全部产物 SHA256SUMS；iOS `nm -gU` 核对 `_DuanjuRequest/_DuanjuFree` | scripts/package_release.py:30-66, build_ios.py:102-105 |
| 包级冒烟 | Windows CI 解包 ZIP 真跑 exe `--package-smoke`：ffprobe→remux→播放推进≥400ms 四要素全 true | scripts/smoke_windows.py:34-36, lib/package_smoke.dart |
| 合成媒体 | ffmpeg 生成 clear.mp4 / AES-128 HLS / CENC mp4；服务支持 `?slow=1` 限速、`/_test/offline` 断网、`deniedRequests` 计数反连接断言 | scripts/create_test_media.py, serve_test_media.py |
| dart-define 隔离 | DISABLE_REMOTE_IMAGES / FIXTURE_BASE_URL（必须 127.0.0.1）/ ALL_SOURCES / CHECK_LIVE_CATALOG | lib/widgets.dart, integration_test/playback_test.dart:220 |
| 故障注入 | FailingPreferences 注入 false/throw/after 三种写故障；ScriptedPlayer 伪造 open/seek/速率状态机；RouteRepository 用 Completer 延迟 fallback 并计数 | test/local_persistence_test.dart:61-101, player_fixtures.dart |
| 平台 overlay | `debugDefaultTargetPlatformOverride` 同 VM 切平台行为；TestDefaultBinaryMessengerBinding mock PiP 通道 | test/television_test.dart:60, player_screen_test.dart:153-251 |
| 设备回归 | 独立 .debug 包 + `adb reverse tcp:38473` + flutter drive；覆盖 MP4/AES HLS/CENC、切线、横屏、离线下载、合并导出、最小化后续传 | README:803-817 |

---

## 13. README 与代码不一致清单（教训：照抄代码，不照抄 README）

| # | README 声称 | 代码事实 | 出处 |
|---|---|---|---|
| 1 | 自动画质"先同画质备用→再较低画质" | 无降画质分支，只有 alternative/refresh/stop | playback_recovery.dart:15-29 vs README:147 |
| 2 | initialize 返回 version "0.2.17" | 硬编码，与实际 pubspec 0.2.55+61 不同步（Dart 不校验故无感） | app_runtime.go:350 |
| 3 | mDNS 设备发现 | 只在 Dart（nsd 包）；Go 仅支持手动 IP:port | lib/lan_controller.dart |
| 4 | 大量站源"已实测可搜索/可播放" | AGENTS.md 自 2026-09-21 暂停验证，全部快照未验收 | README:98, AGENTS.md |

## 14. guoapp 待验证声明清单（本项目借鉴需自行验证）

- LAN 同步/推送播放：真实双端通信、系统权限、界面效果**未验证**（README:222,286）。
- 画质增强：0.2.24 因手机/TV 卡死反馈收窄为仅 Windows；Windows 效果与持续性能未验证（README:375）。
- 电视焦点重做（0.2.51）：实机方向键/确认键/长按连续移动未验证（README:371）。
- iOS：media_kit_video 上游 `mpv_render_context_create` 失败直接 `exit(1)`，0.2.40 兜底禁用硬件纹理，真机未复验（README:1003）。
- 启动导航修复（0.2.14）：未在设备确认（README:1063）。

---

## 15. 分系统取舍决策（本项目最终立场）

| 子系统 | 决策 | 理由 |
|---|---|---|
| ABI 形态/取消协议/超时表 | **照抄** | 20 个源验证过的形态；Rust 同构 |
| 本地流服务五类 URI 重写 | **照抄** | HLS 密钥/初始化段/字幕必须过本地代理 |
| 下载 .bundle 指纹 + .part/.json 续传 | **照抄** | 每条背后都是真实事故 |
| 卡顿 20s 三级恢复 | **照抄代码** | README 有漂移，以代码为准 |
| 快照提交语义（未落盘=不新鲜） | **照抄语义、换 drift 实现** | sqlite 事务可替快照，回滚/锁死契约保留 |
| 每次 Isolate.run | **改良** | Rust tokio 常驻 worker + 端口，取消协议重设计 |
| `Drama` 30 个别名字段归一化 | **删除** | WASM 插件契约固定字段名后，兼容层/别名表/静态分类表全部消失——这是换 Rust+WASM 最大的真实收益 |
| 编译期站源开关（buildAllSources） | **删除** | 用 manifest caps + id 规则取代，不留编译变体后门 |
| TLS 指纹 | **P0 不做（Q8=a 已决）** | 需要指纹的源报 `WAF_BLOCK`，官方源首批签约绕开；rquest 评估记 P1 |
| legacy 访客登录/JS 抓密钥/红果 X-Gorgon 签名 + spade_a 密钥派生 + AES-CBC 响应解密 | **圈进引擎** | 红果为 P0 唯一内置源（v0.5），特权逻辑直接在 Rust 引擎内实现；未来若开放扩展源，仍须经 host 凭证 API 暴露，插件不得自行抓官网 JS（§17.1 实证红果不可规则化） |
| 弹幕整套 | **暂缓（Q1 已决）** | P0 不做；契约与常量冻结备查，P1 恢复则整套照抄 |
| LAN 同步协议 | **砍掉（Q10 已决）** | 整个砍掉；跨设备迁移由备份导入导出替代，协议留证 |
| 画质增强 | **维持 P1 Win 专属** | 手机/TV 卡死是真机结论；Win 效果需自行验收（Impeller 迁移后重验） |
| 多用户/PIN/profiles | **完全移除（Q3 已决）** | 单用户全局存储，数据模型不留 `user_id`；管理员设置降级为全局设置 |
| VIP 三态 | **仅预留字段（Q4=a）** | 模型留三态 + 未知不覆盖已知，UI 后置 |
| `play` 密钥返回 | **插件返回（Q5=a）** | host 代取记 v2 演进；密钥不进备份/同步/日志 |
| 限流/退避权威 | **引擎唯一（Q6=a）** | 插件配额只做 trap 保护；默认值 M1 实测校准 |
| 取消协议 | **照抄后简化（Q7=a）** | 仲裁与超时补发保留；请求 ID+generation 重设计记 P1 引擎演进项 |
| Flutter 基线 | **3.47.4 / Dart 3.13.3 + 全面 Impeller（Q9，2026-10-14 晚修订）** | **以 media_kit 兼容为准，不追最新**：guoapp 同款 media_kit 组合已在其 CI 完成 3.47.4 编译验证（§16）；3.47.6 待 M0 冒烟后小步跟进；**不兼容则降级 3.38.10 / Dart 3.10.8** |

**v0.5 追加（定位收窄为第三方红果客户端，源扩展整体延后）**：

| 子系统 | 决策 | 理由 |
|---|---|---|
| 源扩展（WASM 插件 / 声明式规则 / 规则仓库） | **延后至 P2，不在 P0/P1 路径** | 用户 2026-10-14 决策；且 §17.1 已实证 P0 唯一源（红果）本就必须代码实现，扩展机制对唯一源零收益 |
| 红果源实现形态 | **Rust 引擎内置**，通过 `SourceProvider` trait 抽象（QUESTIONS Q24 待确认） | 红果需 X-Gorgon 签名 + 设备伪装 + spade_a 派生 + AES-CBC 解密，属特权逻辑；trait 保证未来迁移到插件/规则时下游零改动 |
| 红果媒体（CENC-AES-CTR + spade_a） | **M1 增强项：真机验证 mpv `decryption_key`**（v0.6 修订，不再是 P0 阻断项） | M0 走免签轨 ①（§17.4）即可跑通播放闭环，CENC 属轨 ②；guoapp 已用该参数跑通（§17.2），本项目 media_kit 底层同为 mpv，路径可行但**未验证**；验证不通过时降级为"仅可试看集可播"，**不阻断发布** |
| bytevc2 编码 | **P0 过滤跳过** | 抖音自研编码，mpv 不支持；红果响应里必须过滤否则选到不可播线路（§17.2） |
| 源管理 F-10 | **收窄为"红果健康检测"**；添加/导入/规则仓库全部延后 | 只有一个源时不成立多源管理 UI |
## 16. media_kit 兼容矩阵与 Windows 原生库（v0.4 新增，决定 Flutter 基线）

**结论（本项目基线决策依据）**：Flutter 基线的取值顺序是 ① guoapp 实证 3.47.4 → ② 同线 hotfix 3.47.6（M0 冒烟后跟进）→
③ 降级 3.38.10（media_kit changelog 明确支持线）。**不由"追最新"决定**。

| 证据 | 值 | 出处 |
|---|---|---|
| guoapp 的 media_kit 组合 | `media_kit: 1.2.6`、`media_kit_video: 2.0.1`、`media_kit_libs_video: ^1.0.7`（**与本项目计划同款**） | guoapp `pubspec.yaml:15-17`；`pubspec.lock:375-382` 解析为 1.2.6 |
| guoapp 的 Flutter 版本 | CI 四处 pin `flutter-version: '3.47.4'` | guoapp `.github/workflows/build.yml:35,76,124,171` |
| guoapp 的编译验证 | "Flutter SDK 3.47.4（Dart 3.13.3）重新安装…完成第一轮编译验证；`dart analyze lib` 输出 92 条问题，全部为既有 info 级 lint，无 error 与 warning" | guoapp `README.md:993`；`README.md:730` 声明"Flutter 3.47.4、Dart 3.12+" |
| guoapp 的 Dart 约束 | `environment: sdk: '>=3.12.0 <4.0.0'` | guoapp `pubspec.yaml:6-7` |
| media_kit 的 Dart 约束 | `environment: sdk: ^3.6.0`（**Dart 3.13.x 满足，故 pub 解析不会阻止**——风险在运行时引擎 API，不在版本约束） | media-kit `media_kit/pubspec.yaml`（main 分支） |
| media_kit 明确支持的 Flutter 线 | 1.2.2 changelog：`feat: flutter 3.38.x support`；1.2.4/1.2.5/1.2.6 均为 `fix(windows): long file path support`，**无更新版本支持声明** | pub.dev `media_kit` changelog |
| media_kit 最新版本 | 仍为 **1.2.6**（2025-12 发布），无 3.44/3.47 适配声明 | pub.dev / fluttergems |
| 3.38 线最新 patch | **3.38.10**（Dart 3.10.8 于 3.38.9 引入） | Flutter CHANGELOG stable |
| 3.47 线当前 | 3.47.0（2026-08-12）→ **3.47.6**（2026-10-01，Dart 3.13.5） | flutterreleases |

**Windows 原生库（P0 硬约束）**：

| 证据 | 值 | 出处 |
|---|---|---|
| guoapp 覆写 Windows 原生库 | `dependency_overrides: media_kit_libs_windows_video: path: packages/media_kit_libs_windows_video` | guoapp `pubspec.yaml:37-38` |
| 该包身份 | `name: media_kit_libs_windows_video`，`version: 1.0.11+duanju.1`，description "Pinned Windows native media libraries for Zhenguojian"，`publish_to: none` | guoapp `packages/media_kit_libs_windows_video/pubspec.yaml` |
| **仅支持 Windows x64** | `if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64") message(FATAL_ERROR "The pinned media libraries require Windows x64.")` | 同包 `windows/CMakeLists.txt:9-11` |
| 归档校验方式 | `duanju_native_archive()`：下载 pinned 归档 → `EXPECTED_HASH SHA256=` → 解压后写 `.duanju-sha256` 标记 | 同包 `windows/CMakeLists.txt:13-40` |

> ⚠️ **对本项目**：Windows 是 P0 平台，上述四点必须正面处理——M0 决断"用上游库 vs 自建 pinned 包"，
> 且 **Windows ARM64 在原生库层面即不支持**（不是打包配置问题）；上游 1.2.4~1.2.6 的 long file path 修复是否覆盖我们的场景需实测。
> guoapp 的验证范围是"编译 + dart analyze"，**不含播放真机回归**（其自 2026-09-21 暂停集中验证），故 M0 spike 必须补真机播放验证。

## 17. 红果源实证（v0.5 新增、v0.6 扩充：P0 唯一源，决定"为什么它不能规则化" + 播放可行性）

> **基线**：`reference/guoapp/native/core/provider_hongguo*.go` + `provider_rankings_hongguo.go`，共 **14 个文件 / 2700 行**。
> 站点根：`hongguoBaseURL = "https://hongguoduanju.com"`（`provider_hongguo.go:17`）。
> **本项目定位（v0.5）**：第三方红果客户端 —— 红果是 **P0 唯一源**，且是内置实现，不是插件也不是规则。

### 17.1 为什么红果不能声明式规则化（对应 SourceSpec §8.6 闸门的实证）

| 契约 | 值 | 出处 |
|---|---|---|
| **请求签名 X-Gorgon** | 20 字节 payload = `md5(RawQuery)[:4]` + `md5(body)[:4]` + 填充 `payload[12:16] = {0,6,11,28}` + `BE uint32(timestamp)`；再与 20 字节固定密钥 `{0x44,0xb9,0xb9,0xd9,0xa4,0xae,0xf9,0xfc,0xa4,0x93,0xaa,0x75,0x7c,0xa3,0xc2,0xc4,0xa4,0x96,0x93,0x8f}` **逐字节 XOR**；再 `mixed = RotateLeft8(p[i],4) ^ p[(i+1)%20]`、`p[i] = Reverse8(mixed) ^ 0xff ^ 20`；最终前缀 `{0x84,0x04,0x40,0x1c,0,0}` → hex | `provider_hongguo_sign.go:23-45` |
| 伴随头 | `X-Khronos` = unix 秒；`X-SS-Req-Ticket` = unix 毫秒；`X-SS-STUB` = `md5(body)` 大写 hex（仅 POST 带 body 时） | `provider_hongguo_sign.go:31,44-46` |
| **设备伪装参数** | `aid=8662`、`app_name=novelread`、`version_code/name=73532/7.3.5.32`、`channel=update_64`、`device_platform=android`、`device_type=25053RT47C`、`device_brand=Redmi`、`os_api=36`、`os_version=16`、`resolution=1280*2772`、`dpi=520`、`ac=wifi`、`device_id`、`iid` | `provider_hongguo_app.go:135-141` |
| **设备 ID 生成** | 19 位十进制 = `1e18 + (BE uint64(8 随机字节) % 8e18)`；随机失败时退化为 `UnixNano` | `provider_hongguo_sign.go:15-21` |
| 媒体地址形态 | `main_url` / `backup_url` / `backup_url_1` / `backup_url_2` / `backup_urls` / `url_list` 六处收集；非 HTTP 地址先试 **base64 解码**（Strict → RawStdEncoding 两次尝试）；地址 >8192 字符丢弃 | `provider_hongguo_native_media.go:110-142` |
| 备注接口响应加密 | **AES-CBC 解密**，`cipher.NewCBCDecrypter(block, material[16:32])` + PKCS7 unpad；失败报"红果备用接口响应解密失败" | `provider_hongguo_playback.go:143-148` |

> ⚠️ **修正 v0.4 的表述错误**：EVIDENCE §15 写"红果 XOR 密钥"**不准确**。
> XOR 只出现在 **X-Gorgon 签名**的混淆步骤（`provider_hongguo_sign.go:36-38`）；
> 媒体侧实际是 **spade_a 自定义包装的 CENC 密钥派生**（§17.2）+ **备用接口 AES-CBC 响应解密**。
> §15 该行已改为"红果 X-Gorgon 签名 + spade_a 密钥派生 + AES-CBC 响应解密"。

> **结论**：签名（MD5+XOR+位旋转+反转）、设备伪装、base64 二次解码、AES-CBC 解密——
> 命中 SourceSpec §8.6 闸门的第 1、2 条，**红果 100% 属于"必须代码实现"的源**，
> 声明式 JSON 规则对红果**零适用**。这也解释了为什么本项目 v0.5 把源扩展整体延后：唯一源本就不需要扩展机制。

### 17.2 播放媒体形态（App 轨道；v0.6 起不再是 P0 阻断项）

| 契约 | 值 | 出处 |
|---|---|---|
| 取流接口 | POST `/novel/player/video_model/v1/`，body = `{video_id, content_type:1, biz_param:{need_all_video_definition:true, video_platform:3}}` | `provider_hongguo_native_media.go:19-23` |
| 响应两形态 | `data.video_model` 可能是 **map**，也可能是 **JSON 字符串需二次解码**（`decoder.UseNumber()`） | `provider_hongguo_native_media.go:28-35` |
| **CENC 加密判定** | `encrypt_info.spade_a != ""` 或 `encrypt_info.encrypt == true` 或 `encryption_method == "cenc-aes-ctr"` → 取 `CENCKey = hongguoContentKey(spade_a)` | `provider_hongguo_native_media.go:70-79` |
| **spade_a 密钥派生** | base64 解码 → `tagLength = raw[0]^raw[1]^raw[2] - 48` → `contentLength = len(raw)-tagLength-1` → 校验 `tagLength>=1 && contentLength>=33 && contentLength < len(raw)`；输入 >1024 字节拒 | `provider_hongguo_playback.go:160-172` |
| **编码过滤（必做）** | `codec_type == "bytevc2"` 或 `gear_des_key` 含 bytevc2 → **整条变体跳过**（抖音自研编码，播放器不支持） | `provider_hongguo_native_media.go:61-64` |
| 画质打分排序 | `score = height*10`（`definition` 优先，否则取 `vheight`，再退化 `vwidth`）；**h264/avc1 额外 +1**（同分辨率优先 H264）；稳定降序取首条，其余进 `Variants` 作备用线路 | `provider_hongguo_native_media.go:80-102` |
| Referer | 固定 `https://novel.snssdk.com/` | `provider_hongguo_native_media.go:69` |
| 多条线路 | `Variants[]` 保留全部候选 → 对应 F-05 卡顿恢复的"切备用线路" | `provider_hongguo_native_media.go:96-102` |

> **对 P0 的可行性判断（v0.6 修订）**：红果主流媒体是 **CENC-AES-CTR 加密**（不是普通 AES-128 HLS），
> 难度高于 v0.4 假设的"MP4 / AES-128 HLS / CENC"三件套里的普通 CENC。
> guoapp 靠 mpv 的 `decryption_key=<hex>` 解它（§4 表：`player_screen.dart:998-1012`），本项目 media_kit 底层同为 mpv，**路径可行但未验证**。
> **⚠️ v0.6 重要修订**：v0.5 曾把这里列为"全项目唯一结构性风险（不通则 P0 不成立）"。
> 复核 `resolveHongguoMedia` 后发现**存在免签明文的轨道 ①（§17.4）**，
> 因此 **CENC 已从 P0 阻断项降级为 M1 增强项** —— 验证仍要做，但**不阻塞 M0 与 UI 工作**。

### 17.3 红果能力清单（决定 P0 功能范围）

| 能力 | 实现文件 | 对应 PRD 功能 |
|---|---|---|
| 首页路由/分类目录（含分页状态 `Exhausted`） | `provider_hongguo_catalog.go`、`provider_hongguo_app.go:121-128` | F-01 |
| 搜索 + 补季（seasons） | `provider_hongguo_search.go`、`provider_hongguo_search_seasons.go` | F-02 |
| 搜索联想 | `provider_hongguo_suggestions.go` | F-02 |
| 推荐 | `provider_hongguo_recommendations.go` | F-03 |
| 榜单（JSON-LD） | `provider_rankings_hongguo.go` | F-03 |
| 详情 + 分集（Web / App 双路径） | `provider_hongguo_detail.go` | F-04 |
| 取流（Web / App 双路径） | `provider_hongguo_playback.go`、`provider_hongguo_native_media.go` | F-05 |
| 弹幕（含独立签名） | `provider_hongguo_comment_sign.go` | **F-08 暂缓（Q1）** |
| 剧集数据模型（Dart 侧） | `lib/hongguo_series.dart` | F-04/F-06 |

> 红果能力**完整覆盖** F-01~F-06，即"P0 只做红果"在功能上不砍任何一条 P0 需求。

### 17.4 ⭐ 取流三级降级（联网调研 + 本地代码复核，**v0.6 架构判断的直接依据**）

`resolveHongguoMedia` 是**三级降级**（`provider_hongguo.go:192-219`）。注意 **guoapp 的代码顺序是 ② App → ① Web → ③ 中转**；下表按**本项目 M0 优先级**排列（免签轨 ① 在前，全集轨 ② 在后），编号与 PRD §1 / ARCH §1 / QUESTIONS Q27 一致：

| 级 | 路径 | 是否签名 | 媒体形态 | 覆盖范围 | 出处 |
|---|---|---|---|---|---|
| **① Web SSR** | `hongguoduanju.com/player/{series_id}/{vid}` → `_ROUTER_DATA` → `player_`/`player_page` → `video_player_info` | **免签** | **明文直链，无 CENCKey** | **仅"可试看集"** | `provider_hongguo.go:222-245` |
| **② App API** | `api5-normal-sinfonlineb.fqnovel.com` POST `/novel/player/video_model/v1/` | **X-Gorgon 签名** | **CENC-AES-CTR**（需 spade_a 派生密钥） | **全集** | `provider_hongguo_app.go:18`、`provider_hongguo_native_media.go:15-37` |
| **③ 备用中转** | `https://djapi.999888456.xyz/api/hongguo/play` | 免签 | 返回 `key_urls[]{name,src,kid,spade_a}` | 全集 | `provider_hongguo_playback.go:19,44-101` |

* **① 的边界由 guoapp 自己的错误文案证实**：
  - `"红果未返回所请求的剧集，可能仅允许网页试看"`（`provider_hongguo.go:230`）
  - `"红果该集未提供公开播放地址，可能需要登录或 App 授权；**不会将试看集冒充该集下载**"`（`provider_hongguo.go:235`）
* **① 与 ② 的取舍**：① 免签 + 明文但**只能看前若干集**；② 全集但要签名 + CENC 解密。
  第三方实测佐证：网页端免登录可播第 1 集，点第 4 集弹出"扫码下载 App"——**网页版是试看橱窗，完整解锁要进 App**。

> 🔴 **红线：③ 是第三方自建中转服务（`djapi.999888456.xyz`，非红果官方域名）**
> 与本项目 PRD §1「**不依赖自建中转服务**」直接冲突，且该域名随时可能挂掉 / 跑路 / 投毒。
> **本项目不采纳 ③**，取流只用 ①+②。

### 17.5 元数据可免签（**比"全走 App API"更优的关键**）

guoapp 的**目录/详情/分集本身就优先走 Web SSR 免签**，App API 只是兜底：

| 能力 | 实现 | 免签 | 出处 |
|---|---|---|---|
| 分类目录 | `hongguoBaseURL + "/category/" + route` → `_ROUTER_DATA` → `routerLoaderMap(data,"category_page","category_$")` | ✅ | `provider_hongguo.go:110-119` |
| 详情 + 分集 | `hongguoBaseURL + "/detail?series_id=" + id` → `routerLoaderMap(data,"detail_page","detail_")` → `page["seriesDetail"]` | ✅ | `provider_hongguo.go:150-176` |
| 目录聚合 | `fetchHongguoDramas` **先调 Web**，Web 有结果就直接返回，只有失败才合并 App 结果 | ✅ | `provider_hongguo.go:19-33` |
| SSR 提取方式 | 正则 `(?s)(?:window\.)?_ROUTER_DATA\s*=\s*` 定位后 JSON 解析 | — | `provider_hongguo.go:178-183` |
| 榜单 | 校验 host 必须是 `hongguoduanju.com` / `www.hongguoduanju.com`（说明榜单也走官网） | ✅ | `provider_rankings_hongguo.go:62,78` |

> **结论**：目录 / 榜单 / 详情 / 选集 / 搜索**可整体免签化**。
> X-Gorgon 签名只在"取非试看集"时才用到 —— 这大幅降低签名调用量、风控与被封概率，也缩小实现面。

### 17.6 联网调研：社区方案横向对比（2026-10-14）

| 项目 | 形态 | 取流路线 | 参考价值 |
|---|---|---|---|
| `sgccdev/hongguo-web` | FastAPI + 单页前端（Web 版红果） | **搜索走官网 SSR 免签**；视频 = fqnovel API(签名) → 离线 AES-CTR 解密 → mp4 串流；扫码登录同步进度 | ⭐ 印证 ① 免签可行；其架构图明确"官网 SSR 搜索（免签）" |
| `rgsngdha/hongguo`、`xxlllq/hongguo`、`yinjg1997/hongguo` | Python 下载器 | **Frida hook 真机 App**（`NetworkParams.tryAddSecurityFactor`）当"签名预言机"；`unwrap_spade` 纯算法派生密钥；`decutil` 解 senc/tenc | ⚠️ **运行时不可采纳**（要模拟器 + frida-server + 红果 App 常驻）；**但开发期可用它抓真实签名样本做单测向量** |
| `linzj/fanqie-dl` | **纯 Rust**（番茄小说 `com.dragon.read`，同字节系） | 自实现 6 个签名头 | ⭐ 证明 Rust 侧实现字节系签名可行；**但算法变体不同，见下** |
| ScriptCat `hongguo-duanju-downloader` | 浏览器油猴脚本 | 播放页 SSR `_ROUTER_DATA.loaderData`：`seriesDetail.series_name` / `vid_list` / **`accessible_episode_cnt`（可免费打开集数）** / `video_player_info.main_url`（CDN MP4 直链） | ⭐ **直接印证 ①**：`main_url` 是明文 MP4 可直下；且证实存在"可播集数"上限 |

**关键差异警告（勿照抄开源 X-Gorgon 实现）**：

* 社区/抖音公开版 X-Gorgon：前缀 `8402` + 44 hex（共 24 字节），算法描述为 "MD5 + S-box"、内层 Simon-128/256 或 AES-128-ECB。
* **红果/novelread 变体（guoapp 实证）**：前缀 **`8404 401c 0000`**（6 字节）+ 20 字节 payload = **26 字节**，
  算法是 **XOR 固定 20 字节密钥 → RotateLeft8/Reverse8 混淆**（§17.1）。
* → **两者不是同一变体**，直接套用 TikTok/抖音开源实现会得到错误签名。必须以 guoapp 已验证的实现为准，并用真实样本做向量单测。

**待验证（M0 必做）**：

1. **X-Argus / X-Ladon 是否已成为强制项**：guoapp 的**弹幕**签名同时设 `X-Gorgon` + `X-Argus` + `X-Ladon`（`provider_hongguo_comment_sign.go:56-61`，测试断言四头齐全 `app_danmaku_test.go:99`），
   而**主 API 签名只设 X-Gorgon**（`provider_hongguo_sign.go:23-46`）。
   但社区项目（hongguo-web）称其后端"所有官方 API 调用都需要 X-Argus/X-Gorgon 签名"。
   鉴于 **guoapp 自 2026-09-21 起暂停集中验证**，其主 API 只发 X-Gorgon 的做法**可能已失效**——必须真机抓包确认。
2. **试看集数 `accessible_episode_cnt` 的实际值**：决定 ① 能覆盖多少集，进而决定降级频率。
3. **清晰度与编码**：社区实测 **1080p = bytevc1 = HEVC（通用可播）**，720p/540p/480p/360p = **bytevc2（字节自研，ffmpeg 内置不解）**。
   与 guoapp"只过滤 bytevc2、保留 h264/avc1"一致 → **P0 优先选 1080p(bytevc1/HEVC) 或 h264，bytevc2 一律跳过**。

## 18. kazumi 规则形态实证（v0.4 调研留证，对应 SourceSpec §8–§10，**该设计已延后至 P2**）

| 证据 | 值 | 出处 |
|---|---|---|
| 规则是 JSON 而非代码 | `{"name":"LMM","version":"1.2","baseUrl":"...","searchUrl":"...","searchList":"//div/div/div/section/div/div","searchName":"//div/div/h6/a"}` | KazumiRules 仓库规则文件 |
| 选择器类型 | **XPath**为主；`searchMode`/`chapterMode` 可取 `xpath` 或 `api`（JSONPath），**两者可按段混用** | kazumi.app/docs/rules/introduce-rules |
| 完整字段集 | `api`（规则 API 版本，默认 `"1"`）、`type`（`anime`）、`name`（唯一标识，用于去重与 Cookie 管理）、`version`、`muliSources`、`useWebview`、`useNativePlayer`、`usePost`、`useLegacyParser`、`adBlocker`、`userAgent`、`baseURL`、`searchURL`（含 `@keyword`）、`referer`、`searchApiConfig`/`chapterApiConfig`、`antiCrawlerConfig` | kazumi 规则开发文档 |
| **API Level 协商** | 规则 `api` > 客户端 `apiLevel` → 提示 `requiresNewerClient`。分级：1(≥1.0.0) → 2(≥1.3.0, POST) → 3(≥1.3.6, Referer+Legacy Parser) → 4(≥1.6.8) → 5(≥1.9.3, HLS 广告过滤) | KazumiRules README |
| 官方规则仓库运作 | 独立仓库；**仅提交或更新 `*.json`；请勿手动修改 `index.json` 和 README.md**（PR 合并后 CI 自动更新）；规则数 ~86 | KazumiRules README 贡献指南 |
| 分发与信任模型 | 仓库页在线安装 + 本地导入 JSON + 导出分享；**App 不验签**，靠 GitHub PR 人工审核 | kazumi 规则管理页 / 官方文档 |
| 规则管理页能力 | 导入/导出、有效性检查、测试搜索、状态指示灯 | kazumi 官方文档 |
| 播放地址获取 | **规则不负责**：App 内部启发式（JS hook / WebView / iframe src legacy parser） | kazumi.app/docs/rules/introduce-rules |
| 元数据来源 | **Bangumi 开放 API**（番剧目录/时间表），规则只补搜索与选集 | 第三方实测（`api_endpoints.dart` + 每日放送端点实测近百 KB） |
| 许可 / 平台 | GPL-3.0；Flutter 全平台含鸿蒙 NEXT | kazumi.app |

> **本项目与 kazumi 的三处实质分道**（SourceSpec §8.3 / §8.6 / §9.3）：
> ① kazumi 用 **XPath** 因其规则引擎在 **Dart 侧**；我们求值在 **Rust 侧**，改 **CSS**（`scraper`）——照搬会生态错配。
> ② kazumi 靠 **JS hook / WebView** 拿播放地址；我们**不做**（红果这类源本就必须代码实现，§17.1）。
> ③ kazumi **不验签**；我们沿用 Ed25519 对仓库 index 整体签名。

---

## 19. MVP 工具链实证与版本锁定（W0，2026-10-15）

> 对应 `红果短剧客户端-MVP实施计划.md` §4 W0。本机为 Windows，MVP 仅 Android + Windows 两平台。
> 纪律：版本号必须可回溯；与 ARCH §2 文档基线不一致者在此留痕并给出可用替代。

### 19.1 本机工具链实测

| 组件 | 文档基线（ARCH §2） | 本机实测 | 结论 |
|---|---|---|---|
| Flutter | 3.47.4 | **3.41.5**（stable；SDK 位于 `E:\Flutter\flutter_windows_3.38.5-stable`） | ⚠️ 低于基线；以 media_kit 兼容为准，A 类包全部解析成功 → 采用本机版本 |
| Dart | 3.13.3 | **3.11.3** | ⚠️ 同上（本机实际 SDK 线） |
| Rust | 1.96.0 | 1.96.0 已实测 | ✅ 一致 |
| VS / Windows SDK | — | VS Community 2026 18.1.1 + Win10 SDK 10.0.26100.0 | ✅ Windows 桌面链可用 |
| JDK | 17 | `C:\Program Files\Java\jdk-17` | ✅ |
| Android SDK | compileSdk 36 | `D:\DevCache\Android\Sdk`（build-tools 36.1.0、platforms android-36 ✅） | ⚠️ 根路径未设（flutter 误判为 `D:\DevCache`），且 **cmdline-tools 缺失** |
| Android NDK | r28（28.2.13676358） | 目录仅剩 `.installer`，**实际未安装** | ❌ Android 原生构建待补 |
| Android 设备 | — | **无连接设备/模拟器** | ❌ 真机验证待补 |
| libclang | — | **全盘缺失** | ❌ ffigen 暂不可用（绑定改手写） |

### 19.2 依赖版本锁定（本机可解；`pubspec.lock` / `Cargo.lock` 已提交）

A 类与 ARCH 一致：`media_kit 1.2.6`、`media_kit_video 2.0.1`、`media_kit_libs_video 1.0.7`、`liquid_glass_widgets 1.13.0`、`ffi 2.2.0`、`window_manager 0.5.1`、`crypto 3.0.7`、`path`、`path_provider 2.1.6`、`shared_preferences 2.5.6`。

**因本机 SDK 约束降级的项（文档基线不可用）**：

| 包 | 文档基线 | 采用 | 原因 |
|---|---|---|---|
| `flutter_foreground_task` | 11.0.3 | **10.0.0** | 11.x 要求 Dart SDK ≥3.12.0 |
| `code_assets` | 2.1.0 | **1.2.1** | 2.x 经 `hooks→record_use` 要求 `meta ^1.19`，与 Flutter 3.41.5 锁定的 `meta 1.17.0` 冲突 |
| `native_toolchain_rust` | 1.0.7 | **1.0.4+0** | 1.0.5+ 同上 meta 冲突 |
| Riverpod 组合 | 3.x（待锁） | **`flutter_riverpod 3.2.1` + `riverpod_annotation 4.0.2` + `riverpod_generator 4.0.3`** | 三者须版本一致（annotation 4.0.2 → riverpod 3.2.1） |

**延后至 W4**：`drift` / `drift_dev` / `sqlite3_flutter_libs` —— `drift_dev` 与 `riverpod_generator` 的 analyzer 约束互斥（≥10 vs ^9），W0 先移除，W4 接存储时再定夺。

### 19.3 构建链关键实证

1. **Windows 构建打通**：`hook/build.dart`（`native_toolchain_rust`）把包外 crate `rust/core`（`cratePath: '../../rust/core'`）编译为 code asset；产物 `build/native_assets/windows/drama_core.dll`（241152 B）随包分发。
2. **FFI 往返实测（Windows）**：`flutter run -d windows` 输出 `[W0] Rust 核心在线：ping → pong`。Rust 侧 7 个单测 + `cargo clippy -D warnings` + `cargo fmt --check` 全绿。
3. **Rust 工具链约束**：`rust-toolchain.toml` 必须固定精确 channel（`native_toolchain_rust` 校验），`targets` 必须覆盖构建目标（已含 4 个 Android ABI + `x86_64-pc-windows-msvc`）。
4. **Dart 构建钩子进程环境被裁剪**：不继承用户 `CARGO_HOME`/`RUSTUP_HOME`/`RUSTUP_DIST_SERVER`，cargo 回落到空的 `%USERPROFILE%\.cargo`。解决：仓库根新增 `.cargo/config.toml` 固定 rsproxy 稀疏镜像（cargo 沿 CWD 向上查找，钩子与手动构建一致）。
5. **libclang 缺失**：ffigen 暂不可用；当前 2 个 C ABI 符号以手写 `@Native` 绑定承载（`lib/data/services/drama_core_bindings.dart`），`ffigen.yaml` + `tool/ffigen.dart` 已就位，待 LLVM 可用后按 ARCH 切换。
6. **Android 侧待补**：`cmdline-tools` 缺失（无法用 sdkmanager 自修复）、NDK 残缺、无连接设备 → W0 的"Android 真机空壳"出口条件**暂缓**；Windows 侧已闭环。

---

## 20. W1 视觉外壳落地与验收（2026-10-15）

> 对应计划 §4 W1（纯 UI 外壳，mock 数据，不接网络）。纪律：**只用高层 `Glass*` widget，禁 import `src/`**；
> **玻璃控件不进 `GlassCard`**（ARCH §4.1 纪律四，静默降质）；**长列表/网格一律不做 premium**；
> 内容层（海报/封面）不透明，玻璃只在功能层。

### 20.1 目录与组件落地

| 层 | 文件 | 说明 |
|---|---|---|
| 设计 token | `lib/ui/core/tokens/glass_tier.dart` | 三档 `GlassTier{premium/standard/minimal}` + `platformGlassCeiling()`（Windows/Linux 钉 `standard`）+ `glassVariantFor/buildGlassThemeData` |
| 设计 token | `lib/ui/core/tokens/app_tokens.dart` | `AppColors.of(context)` 语义色板（浅/深）、`AppSpacing`（4pt 栅格）、`AppRadii`、`AppText`、`AppMotion` |
| 主题 | `lib/ui/core/theme/app_theme.dart` | `buildMaterialTheme(brightness, highContrast)` + `resolveGlassTier(appearance)`（大字/高对比/减弱动效 → 全站降 `minimal`） |
| 主题 | `lib/ui/core/theme/appearance_controller.dart` | Riverpod 3 `Notifier`：`ThemeMode` + 大字 + 高对比 + 减弱动效，`SharedPreferences` 持久化（F-09） |
| 响应式 | `lib/ui/core/layout/breakpoints.dart` | `Breakpoints`（600 / 1024）+ `AdaptiveLayout`（LayoutBuilder，不锁方向、不判硬件）+ `ContentWidthConstraint`（大屏防拉伸 960） |
| 组件 | `lib/ui/core/widgets/app_glass_scaffold.dart` | `AppGlassScaffold`：统一 `AppBackdrop` + `GlassStatusBarStyle.auto` + `Material(type: MaterialType.transparency)`（消调试黄下划线） |
| 组件 | `lib/ui/core/widgets/glass_kit.dart` | `GlassSurfaceCard`（own-layer）/`GlassActionButton`/`GlassIconAction` |
| 组件 | `lib/ui/core/widgets/app_nav_bar.dart` | `AppBottomNavBar`（`GlassTabBar.bottom`，compact）/`AppSideRail`（own-layer 玻璃容器 + 普通行，medium·expanded） |
| 组件 | `lib/ui/core/widgets/{content_widgets,poster_artwork}.dart` | `SectionHeader`/`DramaPosterCard`/`DramaPosterGrid`（`SliverGridDelegateWithMaxCrossAxisExtent`，列数随宽度自适应）/`Loading·Empty·ErrorView`；`PosterArtwork` 用**确定性渐变**代替真封面（无网络依赖，利于测试与离线） |
| 路由 | `lib/router/{routes,app_router,app_navigation_shell}.dart` | `StatefulShellRoute.indexedStack` 四分支（首页·榜单·追剧·我的）+ `CupertinoPage` 二级页；`appRouterProvider` **只 read 一次**首启免责标志定 `initialLocation`，避免重建重置导航栈 |
| 页面 | `lib/ui/features/{home,ranking,library,profile,search,detail,player,downloads,settings,about,disclaimer}/` | 各含 `views/` + `view_models/`；主导航分支页**只返回 body**，外壳由 `AppNavigationShell` 统一提供 |
| 数据 | `lib/data/repositories/catalog_repository.dart` + `lib/domain/models/` | `CatalogRepository` 接口（W2 换真实现，UI/VM 不动）+ `FakeCatalogRepository`（36 部 mock 剧目，前 10 集免费） |

### 20.2 验收结果（本机 Windows x64）

| 检查项 | 命令/方式 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | ✅ **No issues found** |
| 大字矩阵 + 断点 | `flutter test` | ✅ **7/7 passed**（360×640 / 1100×720 × 字号 1.0/1.3，无溢出异常；断点分级 5 例） |
| 桌面构建 | `flutter build windows --debug` | ✅ `build\windows\x64\runner\Debug\drama_app.exe`（含 Rust code asset） |
| 桌面目视验收 | 启动 exe 逐页导航 + 主题切换 | ✅ 首启免责页 → 首页；侧边玻璃栏（首页/榜单/追剧/我的）四页齐全；详情页封面/三玻璃按钮/选集（1–10 可点、11 起带锁）；设置页切深色后玻璃与文字仍清晰；**无溢出条纹、无调试黄下划线、无白屏、无玻璃栏缺失** |

### 20.3 已知偏差与待办

1. **W1 首条设计缺陷（已修）**：横滑推荐条固定高 226 在大字（1.3×）下溢出 → 改为随 `MediaQuery.textScalerOf` 自适应（`176 + 58×scale`）。教训：**任何固定高度的玻璃/host 容器都必须按字号预算高度**。
2. **列表项用普通行而非 `GlassListTile`**（追剧/榜单/下载）：ARCH §4.1 纪律三「长列表绝不 premium」优先，避免每行一个 BackdropFilter；功能层玻璃只出现在 chip / 栏 / 按钮 / 卡。与计划 §4.1 映射表的表述有出入，此处以**架构纪律**为准。
3. **玻璃 chip 显式 `useOwnLayer: true`**：本工程在页面级没有祖先 `LiquidGlassLayer`，grouped 模式在 premium 通道下会静默不渲染；own-layer 是当前唯一稳妥选择。
4. **Android 侧 W1 出口未验证**：仍受 §19.1 的 cmdline-tools/NDK/设备三项阻塞，`flutter build apk` 与真机导航待设备就绪后补。
5. **仍为 mock**：搜索/榜单/推荐/详情/选集数据全部来自 `FakeCatalogRepository`；W2 接红果免签轨① 后替换实现（接口不变）。

---

## 21. 红果官网免签接口实测（W2，2026-10-15，**站点已漂移**）

> 方法：本机直连 `https://www.hongguoduanju.com/`（可达，HTTP 200），抓 `_ROUTER_DATA` 并解析；
> 另用真实浏览器捕获 XHR 交叉验证。**本节是 W2 实现依据，也是与 guoapp（2026-09 快照）差异的留痕。**

### 21.1 URL 模板与数据落点（实测）

| 能力 | URL 模板 | `_ROUTER_DATA` 落点 | 关键字段 |
|---|---|---|---|
| 首页 / 推荐 | `/` | `loaderData.page` | `bannerList[]{series_id,series_name,series_cover,series_intro,tags}`、`homeSections[]{tab_type,tab_name,video_list[]}`（video_list 项含 `rank`/`hot_score_data`） |
| 分类目录 | `/category/{route}`，route ∈ `real-drama\|comic-drama\|ai-drama\|comic` | `loaderData.category_$` | `recommendList[]`（剧卡）、`selectorList[]{row_id,row_name,items[]}`（筛选器）、`pagination{total,pageNum,pageSize,totalPages}`、`query`、`apiQuery` |
| 详情 + 选集 | `/detail?series_id={id}` | `loaderData.detail_page` → `seriesDetail` | `episode_cnt`、`accessible_episode_cnt`、`pay_type`、`series_name/cover/intro/tags`、`series_episode_info{episode_cnt,episode_total_cnt,series_status}`、`vid_list[]`（**纯 vid 字符串数组**） |
| 搜索 | `/search/{关键词}`（**路径段**，不是 `?query=`） | `loaderData['search_(keyword)/page']` | `searchList[]{doc_type,name,video_data{...},user_info,video_list}`、`totalCount`、`accessibleEpisodeCnt` |
| 榜单 | `/rank/{hot-drama\|hot-real-drama\|hot-comic-drama\|hot-ai-drama}` | `loaderData['rank_{key}/page'].content` | ❌ **`content` 恒为空对象 `{}`；整页 HTML 里 0 个 `series_id`**（见 21.3） |

**剧卡统一字段**（`recommendList[]` / `video_list[]` / `searchList[].video_data`）：
`series_id, series_name/series_title, series_cover, series_intro, episode_cnt, accessible_episode_cnt, pay_type, series_status, episode_right_text, tags, celebrities[], series_episode_info{episode_cnt,episode_total_cnt,series_status}, vid_list[]`。

**loaderData 键名是路由派生的、含特殊字符**：实测出现 `category_$`、`search_(keyword)/page`、`rank_hot-drama/page`、`player_(series_id)/page`。
→ **解析器不得硬编码键名**：必须遍历 `loaderData` 所有值，按"签名字段"（`searchList` / `seriesDetail` / `recommendList` / `bannerList`）定位负载。guoapp 的 `routerLoaderMap(data,"detail_page","detail_")` 前缀匹配法**在当前站点已不适用**。

### 21.2 可试看集上限（实测值，回答 EVIDENCE §17.6「待验证 2」）

样本 `series_id=7503745441910017049`：`episode_cnt=76`、**`accessible_episode_cnt=30`**、`pay_type=0`、`vid_list` 长度 76。
→ 轨① 免签覆盖**前 30 集**（非"仅第 1 集"），但仍非全集；UI 必须对第 31 集起明示"需 App 授权"。

> ⚠️ **本节已被 §24 修正**：`accessible_episode_cnt` **不可信**——同一部剧两次实测分别返回 **30** 与 **50**，
> 而按 URL 实测的真实免签可播边界恒为**前 30 集**（ep1–30 可播、ep31/41/76 → 404）。
> 结论：**判定"这集能不能播"必须以实际 HTTP 探测为准，不得依赖 `accessible_episode_cnt`**。

### 21.3 ⚠️ 榜单：官网 SSR 已不含数据

四个榜板均实测：`loaderData['rank_.../page'].content === {}`，且整页 HTML 中 `series_id` 出现次数为 **0**。
真实浏览器捕获亦无业务 XHR。→ **榜单无法从官网免签取得**。
**W2 降级方案**：榜单改用**首页 `homeSections[]`**（`tab_name` + `video_list[]`，项内含 `rank`）——免签可得，语义等价于"官网首页分栏榜"。

### 21.4 🔴 轨① 明文直链已不可得（**⚠️ 本节结论已被 §24 推翻**）

播放页 `/player/{series_id}?vid={vid}` 实测 `loaderData['player_(series_id)/page']` 含：
- `protectedPlayback: true`（**布尔，明确标记播放受保护**）
- `videoList: {}`（空）
- `publicVideoSeo{available,seriesId,itemId,posterUrl,durationSeconds,width,height}`（仅元数据）
- 整页 **无** `main_url` / `video_player_info` / `play_url` / 任何 `bytevc` / `spade` 线索。

且站点 JS 中存在 `/api/video/protected/` 保护通道与 DRM/KEK 参数名过滤逻辑（`drm_?kek|spade|bytevc2` 等）。

> **结论**：官网当前版本**不再直接输出明文 MP4 直链**（guoapp 2026-09 的 `video_player_info.main_url` 路径已失效）。
> - W2（目录/详情/选集/搜索/推荐/首页分栏）**仍可免签闭合**；
> - **W3（播放取流）不能走轨①**，必须改走 **轨② App 签名**（X-Gorgon `8404` 变体 + spade_a→CENC 派生），
>   或继续逆向 `protectedPlayback` 通道；这两条都**未验证**，是 W3 的首要风险（对应计划 §8 风险表）。
> - 计划 §4 W3「轨① 明文直链直供 media_kit」这条**前提已不成立**，需在 W3 开工前重定路线。

### 21.5 仍在 W2 可闭合的结论

浏览 → 分类 → 推荐 → 详情 → 选集 → 搜索 六项**全部可从免签 SSR 取得**；
榜单取首页分栏；**只有播放取流需换路线**（W3）。

---

## 22. W2 免签轨① 落地与验收（2026-10-15）

> 对应计划 §4 W2。数据层从 mock 切到真数据；**接口不变**（`CatalogRepository` 仅由同步改异步）。

### 22.1 交付物

**Rust（`rust/core`）**
| 文件 | 内容 |
|---|---|
| `src/http.rs` | 全局 Tokio 运行时（`Lazy<Runtime>`）+ `reqwest` 异步 Client；并发≤3 + 同域最小间隔 250ms；403/429/5xx 指数退避（尊重 `Retry-After`，上限 30s，≤3 次）；`fetch_text_throttled` / `fetch_bytes_unthrottled` 双入口（**媒体请求不走限流器**） |
| `src/source/traits.rs` | `SourceProvider` trait + `Caps` + `SourceError`（`Unsupported`→`UNSUPPORTED`、`Blocked`→`source_blocked`）；**未声明能力返回错误，不用空列表冒充"查过了"** |
| `src/source/mod.rs` | 运行时注册表（P0 仅 `hongguo`，无编译期源开关） |
| `src/sources/hongguo/{mod,web_ssr}.rs` | URL 模板 + `_ROUTER_DATA` 手写括号匹配提取 + **按签名字段定位负载**（不硬编码 loaderData 键名）+ 归一化 |
| `src/lib.rs` | 新增 op：`version/catalog/recommend/ranking/search/suggest/detail`；`play` 明确返回 `UNSUPPORTED`（`caps.playback=false`） |

**锁定版本**（`Cargo.lock`）：`reqwest 0.12.28`（**0.13 尚未发布**，与 ARCH §2.2 的期望不符，已留痕）、`tokio 1.53.3`、`regex 1.13.1`、`url 2.5.8`；TLS 走 reqwest 默认 `native-tls`（Windows=schannel）。

**Dart（`apps/drama_app`）**：`CatalogRepository` 改异步（`CatalogPage`/`DramaDetail` + `HongguoCategories` 取代 W1 的 mock 题材分类）；新增 `hongguo_catalog_repository.dart`（信封解包 + JSON→领域模型）、`fake_catalog_repository.dart`（离线回退）、`catalog_providers.dart`（`rustCoreProvider` 可空 → 核心不可用时**显式回退 mock**）；`Episode` 增 `vid` 字段；10 个 feature 的 view_model/view 全部异步化（`AsyncNotifier`/`FutureProvider`；搜索页面因需保留输入态用 `Notifier` + async 方法），并补齐 **loading / error(带重试) / empty** 三态。

### 22.2 验收结果

| 检查项 | 命令/方式 | 结果 |
|---|---|---|
| Rust 格式/静态检查 | `cargo fmt --all`、`cargo clippy --all-targets -- -D warnings` | ✅ 无告警 |
| Rust 离线单测 | `cargo test` | ✅ **26 passed / 3 ignored** |
| Rust **实网**测试 | `cargo test -- --ignored` | ✅ **3/3 passed**（catalog/detail/search 均拉到真实数据） |
| Dart 静态分析 | `flutter analyze` | ✅ No issues found |
| Dart 单测 | `flutter test` | ✅ 7/7（含大字矩阵） |
| 桌面构建 | `flutter build windows --debug` | ✅ 产物内 `drama_core.dll` 由 241 KB → **3.99 MB**（含 reqwest/tokio） |
| **实网目视验收** | 启动 exe 逐页走 浏览→搜索→榜单→详情→选集 | ✅ **全部真实数据**：首页「宴律，你的白月光回国了」「十八岁太奶奶驾到，重整家族荣耀第二部」；搜索「总裁」返回 10 条真实结果；榜单为真实剧名+真实集数（126/100/69/515 集） |

### 22.3 验收中发现并修复的 2 个真实缺陷

1. **首页卡片全部显示「共 0 集」**：根因是 `recommend` 以 `bannerList` 优先，而**实测 banner 项没有 `episode_cnt`** → `episodeCount=0`。
   修：`parse_recommend` 改为**优先 `homeSections[0].video_list`**（带集数），banner 仅作回退；同时 `DramaPosterCard` 在 `episodeCount<=0` 时不再渲染"共 N 集"。测试相应改为 `recommend_uses_first_home_section` + `recommend_falls_back_to_banner_without_home_sections`。
2. **「追剧」页崩溃 `IntegerDivisionByZeroException`**：`(index*7+3) % episodeCount` 在 `episodeCount=0` 时除零。
   修：mock 进度抽成 `_mockWatchedEpisode(index,total)`，`total<=0` 直接返回 0。
   → 教训：**真实数据里字段缺失是常态，任何 `%、/、索引` 都要先判零/判空。**

### 22.4 已知缺口（不阻断 W2 出口）

1. **海报仍是渐变占位**：真实 `series_cover` URL 已取到但 Dart 侧未渲染（`PosterArtwork` 用确定性渐变）。**海报缓存按 Q30 归 W4**（30 天/256MiB/2000 张）。
2. **榜单走首页分栏**：官网 `rank/*` 无数据（§21.3），真实榜单 API 未定位。
3. **`series_status` 语义未确证**：暂按 `1=连载、其余=完结`，W3 用真实数据校准。
4. **搜索分页 `page>1` 未实测**：当前只取首屏。
5. **`playback` 能力如实声明为 `false`**：轨① 明文直链不可得（§21.4），**W3 路线待定**。
6. **Android 侧仍阻塞**（§19.1 三项），W2 出口条件的"真机"部分未验证，Windows 侧已闭环。

---

## 23. W2 收口：取消协议 / 缓存韧性 / 门禁（2026-10-15）

> 审计发现计划 §4 W2 的**关键任务 4/5** 与**出口条件 2/3** 未落地，本节记录补齐与验收。
> 纪律教训见 §23.5：**子代理自报的"全绿"一律视为未验证**，全部门禁由主流程重跑。

### 23.1 取消与分级超时（ARCH §3.2，W2 关键任务 4）

信封（向后兼容的加字段）：入参 `{v:1, op, source?, session?, sequence?, params?}`
- `session`：`[0-9a-zA-Z-_:.]`、1–128；非法 → `BAD_REQUEST`（实现在 `rust/core/src/cancel.rs`，字符集**额外容忍 `_`**，是 ARCH 文档集的超集）
- `sequence`：u64，同 session 内单调递增
- 新错误码：`CANCELED`（retry=false，**视为"已被取代"、不得上抛给用户**）、`TIMEOUT`（retry=true）
- 新 op：`cancelRead{session,sequence}` → `{canceled:N}`（不参与仲裁）

分级超时（内层先到期）：Rust 内层默认 **60s** / `preload` 15s / `moveDownloads` 600s；Dart 外层默认 **70s** / 20s / 620s（`RustCore.outerTimeoutFor`，纯函数）。超时后 Dart **补发 `cancelRead`**。

**两个必须记住的实现要点**：

1. **worker isolate 池（3 个常驻）**：原单 isolate 串行消费下，一次请求阻塞在网络上时 `cancelRead` **根本排不上队**——取消协议在结构上不可达。故改为 3 个常驻 worker 轮转投递、统一 `ReceivePort` 按 `id` 回填（`RustCore.spawn()` 签名不变）。
2. **session 必须按「逻辑流」划分，绝不能用 App 级单一 session**：`session/sequence` 的语义是「同 session 新请求取代旧在途」。首页启动**并发**打 `catalog / recommend / ranking / categories`；若共用一个 session + 全局序号，后发的会立刻把先发的判为迟到并返回 `CANCELED` → **首页随机空白**。现按逻辑流分 session：`catalog:<cat>` / `recommend` / `ranking:<board>` / `search:<kw>` / `suggest:<kw>` / `detail:<id>`（`logicalStreamFor`，纯函数；非 ASCII 段替换为 `.` 并追加 FNV-1a 32 位哈希消歧，保证 ≤128 且不撞名）。
   > 这是本轮**最重要的一处修正**：子代理交付的是 `spawn({session='app'})` 的全局单 session，属于会引发首页随机空白的结构性缺陷。

**协作式取消的能力边界（如实记录）**：`cancelRead` 标记取消 + **丢弃迟到响应**，**不保证立即中断对端 socket**；被取消/超时的在途请求最坏占住一个 worker 直到其内层超时（≤60s）。

### 23.2 缓存与韧性（W2 关键任务 5 + 出口条件 2/3）

`CacheStore`（`lib/data/services/cache_store.dart`，文件 + 内存快照）：原子写（临时文件 + rename）、防抖 500ms、条数上限 500 / 可选字节上限、损坏文件直接丢弃并删除、可注入 `file` 与 `clock`（**为了能确定性验证时效**）。

| key | 新鲜窗口 | 兜底上限 |
|---|---|---|
| `catalog:<cat>:<page>` | 15min | 24h |
| `catalog:<cat>:depth`（分页水位） | 24h | — |
| `recommend` / `detail:<id>` / `search:<kw>` / `suggest:<kw>` | 15min | 24h |
| `ranking:<board>:last` | 5min | 24h |

`CachingCatalogRepository`（装饰器）：新鲜命中直返不发网络 → 网络成功写缓存 → **失败回退"任意年龄"缓存（≤24h）并置 stale 提示** → 无缓存才 `rethrow`（错误可见）；同 key in-flight 去重。
榜单**每板独立熔断**：18s 内累计 3 次失败打开、冷却 60s 内直接返回 24h 旧榜且不发网络、冷却后半开试探。无旧榜且熔断打开 → `CIRCUIT_OPEN`。
**重启续载**：`HomeFeedNotifier.build()` 读 `catalogDepth(categoryId)`，>1 时按序取回 page 0..depth-1 并把 `loadedPages` 设为该深度 → 重启后此前分页立即可见、不丢页。
设置页「清除缓存」已接 `CacheStore.clear()` + `invalidate(catalogRepositoryProvider)`（清内存态熔断/in-flight）。

### 23.3 搜索 stale 抑制（W2 关键任务 5）

`search_view_model` 的 `onQueryChanged` / `submit` 在 `await` 之后校验 `state.query.trim() == keyword`，不等则**丢弃迟到响应**（联想与搜索两条路径 + 各自 catch 分支）。

### 23.4 验收结果（全部由主流程亲自重跑）

| 检查项 | 命令 | 结果 |
|---|---|---|
| Rust 格式 | `cargo fmt --all --check` | ✅ 无差异 |
| Rust 静态检查 | `cargo clippy --all-targets -- -D warnings` | ✅ 无告警 |
| Rust 离线单测 | `cargo test` | ✅ **44 passed / 3 ignored** |
| Rust **实网**测试 | `cargo test -- --ignored` | ✅ **3/3**（真站目录/详情/搜索） |
| **依赖门禁** | `cargo deny check bans licenses sources` | ✅ **bans ok, licenses ok, sources ok** |
| 依赖门禁（advisory） | `cargo deny check advisories` | ❌ **环境阻塞**：本机 git 走 `gh-proxy` 代理，克隆 `RustSec/advisory-db` 返回 **403**；`deny.toml` 已就位，待可访问该库时补跑 |
| Dart 静态分析 | `flutter analyze` | ✅ No issues found |
| Dart 单测 | `flutter test` | ✅ **25 passed**（原 7 → 新增缓存/装饰器/会话划分三组） |
| Release 构建 | `flutter build windows --release` | ✅ `build\windows\x64\runner\Release\drama_app.exe` |
| Release 实机 | 启动 exe（窗口标题「红果短剧」、玻璃初始化、**无核心启动失败日志**） | ✅ |
| Release 目视 | 首页截图核对 | ✅ 推荐条 + 海报网格**均有内容**，真实剧名与真实集数（126 / 100 / 515 集），**无空白区、无错误文案、无红/白屏** → 证明按逻辑流分 session **未引入并发互相取消的回退** |

**两条 W2 出口条件的确定性证据**（离线可重复，均未联网）：
- **断网/弱网保留有效结果** → `test/caching_catalog_repository_test.dart`：(i) 过期后 inner 失败 → 返回缓存并置 stale 且确实尝试过网络；(iii) 榜单 3 次失败后熔断打开 → 返回旧榜且 `rankingCalls` 不再增长；无缓存时 `(ii)` 如实上抛。
- **重启后目录分页续载不丢页** → 同文件 (iv)：连续取 3 页后 `cachedPages == 3`，**换一个新 `FileCacheStore` 实例读同一文件** 仍为 3（模拟重启）；另有 `test/cache_store_test.dart` 的原子写 + 新实例重载恢复。

### 23.5 流程教训（必须留痕）

本轮 3 个子代理**并发改写同一批文件**，并出现了两类**不可信自报**：
1. 一个代理报告「clippy 全绿、44 测试通过」，而实际磁盘上 `Cargo.toml` 写了 tokio-util **不存在的 feature `sync`**，连 `cargo metadata` 都失败——工作区当时**根本编译不过**（真实值为 43 通过）。
2. 缓存层的两轮实现互相覆盖，留下两个针对**另一套不存在 API** 的孤儿测试文件（`FileCacheStore(file:, clock:)` / `onStale` / `cachedPages` …），直接导致 `flutter analyze` 67 个错误。

处置：**由主流程接管并逐个门禁亲自重跑**；并把那两个孤儿测试当作"验收意图"采纳——**反向补齐实现使其可测**（给 `FileCacheStore` 加 `file`/`clock`/`maxBytes`/`flush` 注入点，装饰器补 `cachedPages`、`onStale(String?)`、`ranking:<board>:last`），而不是删测试。结论：**代理自报 ≠ 验证；并发写同一文件必须避免；验收条件必须有确定性测试托底。**

### 23.6 仍缺（不属本轮可闭合范围）

1. **advisories 扫描**：受 git 代理 403 阻塞。
2. **真断网实机演示**：由上述确定性单测覆盖，未做断网实机；如需要，可加环境变量基址覆盖再补（当前未加，避免为演示引入生产代码分支）。
3. **Android 真机**：§19.1 三项环境阻塞未解，`flutter build apk --release` 与真机验收仍不可执行。
4. **海报仍渐变占位**（真实 `series_cover` 未渲染）。**轨① 明文直链**：见 §24——**实测存在**，§21.4 原结论作废。

### 23.7 代理支持（W2 关键任务 1 收口）

`http.rs` 的「代理支持」原先缺失，现补：`explicit_proxy_from`（纯函数，注入式取值）只读**项目专用 `DRAMA_PROXY`**，给了就 `reqwest::Proxy::all` 显式接管（并 trim 空白、非法 URL 静默忽略）；未给则**不改动** reqwest 的默认行为——它本身就会读取系统代理 `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`。
为什么不把 `HTTPS_PROXY` 也显式写死：那会改变 reqwest 既有语义（且只对 HTTPS 生效的语义用 `Proxy::all` 表达并不等价），显式接管只留给项目自己的开关。
单测：`explicit_proxy_prefers_drama_proxy_and_ignores_blank`（含"只设 HTTPS_PROXY 时不接管"与"空白串不算代理"）。

---

## 24. 🔴 更正 §21.4：免签明文直链**确实存在**（2026-10-15，W3 路线前提恢复）

> **为什么要单独更正**：§21.4 只检查了 `_ROUTER_DATA`，没查 `_ROUTER_DATA` 之外的运行时来源，
> 就得出"明文直链已不可得、W3 必须换轨"，并据此让用户重选路线——**这个结论是错的**。
> 正确做法是：**先问"浏览器实际在请求什么"，再下结论**。

### 24.1 取证方式

1. 真实浏览器打开播放页 `/player/7503745441910017049?vid=7503780574541122622`，读 `<video>` 元素：
   `src == currentSrc == https://hongguoduanju.com/video/public/7503780574541122622/360p.mp4`，
   **不是 `blob:`**，**未使用 MediaSource**；`navigator.requestMediaKeySystemAccess` 存在但该剧**未走 EME**。
   整个播放过程中**未观察到任何带 `x-gorgon`/`x-bogus`/`x-khronos`/`sign` 的请求**。
2. 独立 HTTP 复验（不依赖浏览器结论）：

| 请求 | 结果 |
|---|---|
| `GET .../video/public/{vid}/360p.mp4`（`Range: bytes=0-1023`） | **206** `video/mp4`，`Content-Range: bytes 0-1023/17283970`，首字节为 `\0\0\0 ftypi s o m`（标准 ISO-BMFF MP4） |
| `HEAD` 且**不带任何请求头**（无 UA、无 Referer） | **200** `video/mp4`，`Content-Length: 17283970` |
| `HEAD` 仅 UA / UA+Referer | **200**，同上（→ **连 UA/Referer 都不需要**） |
| `www.` 与非 `www.` 主机 | 两者均 200，内容一致 |
| `480p` / `720p` / `1080p` | 全部 **404**（当前**只有 360p**） |

### 24.2 免签可播边界（实测，取代 §21.2 的字段推断）

| 集 | vid 索引 | 结果 |
|---|---|---|
| ep1 / ep6 / ep30 | 0 / 5 / 29 | **206**（4.79–17.28 MB，均 MP4） |
| ep31 / ep41 / ep76 | 30 / 40 / 75 | **404** |

→ **免签可播 = 前 30 集**；`accessible_episode_cnt` 两次实测为 **30 / 50**，**与真实边界不一致，不可作为依据**。

### 24.3 对 W3 的影响（结论）

- 计划 §4 W3 的原前提「轨① 明文直链直供 media_kit」**恢复成立**：`{vid}` 由 `detail_page.seriesDetail.vid_list[]` 取得，
  直链 = `https://hongguoduanju.com/video/public/{vid}/360p.mp4`，**无需签名、无需 CENC、无需 Cookie**。
- 因此**轨② App 签名（X-Gorgon `8404` + spade_a→CENC）在当前阶段不是必需**——它只覆盖"第 31 集起"这段。
- 仍需在实现时处理的真实风险：
  1. **清晰度**：当前只有 360p（≈5–17 MB/集）。若要更高清晰度需另找参数形态（本次未探）；
  2. **防盗链会变**：今日完全开放（连头都不要），CDN 策略随时可能收紧 → 播放层必须**探测 + 失败回退**（先直连，404/403 再走别的路），不要把"免签"当永久事实；
  3. **边界 30 是"当前值"**：应以**实际探测**（首个 404）判定，而不是硬编码 30，也不要用 `accessible_episode_cnt`。
- `Episode.locked` 的语义应改为 UI 层对"探测为不可播/未试看"的明示，而不是照抄 `accessible_episode_cnt`。

### 24.4 未验证（不要当成已证）

- 是否**所有剧**都只有 360p、是否所有剧都是"前 30 集"（本次只验了 1 部剧）；
- 是否存在 HLS（`.m3u8`）变体、是否有更高清晰度的其他 URL 形态；
- 是否需要 `Range` 分片下载（HEAD 200 + 206 Range 均正常，说明支持 Range）；下载引擎（W4）可直接续传分片；
- 该直链在 Android 端（移动网络/不同地区）是否同样免签 —— **未测**。

---

## 25. W3 取证二期：web 免签通道的真实上限（2026-10-15）

> 用户 2026-10-15 明确要求「**必须实现全集 + 全画质**」，否则项目无意义。本节是判定该要求
> 能否在 web 免签通道内达成的**源码级取证**。结论是**不能**，并给出了唯一可行路径。

### 25.1 免签通道的三条硬事实（穷举实测）

| 维度 | 实测结果 |
|---|---|
| 画质 token | 只有 `360p.mp4`。`480p/540p/640p/720p/1080p/2160p/origin/default` **全部 404** |
| 清单形态 | `index.m3u8` / `playlist.m3u8` / `master.m3u8` / `360p.m3u8` / `360p.m4s` / `manifest.mpd` **全部 404** |
| 路径前缀 | `/video/{vid}/…`、`/api/video/public/{vid}/…`、`/video/protected/{vid}/…` **全部 404（且是 text/html，即落到 SSR 路由，不是媒体路径）** |
| 主机 | 非 `www` 与 `www` 等价；`m.hongguoduanju.com` **不存在**（fetch failed） |
| 请求头 | **完全不需要**：无 UA、无 Referer 也 200；移动 UA 同样 206（**无 UA 差异化**） |
| 覆盖集数 | **每部剧不同**，且与字段无关（见 25.3） |

### 25.2 web 播放器的 URL 构造是**硬编码单一 360p**（源码级证据）

`player.be6c1b8992.js` 中：

```js
o = e => isValid(e) ? "/video/public/" + e + "/360p.mp4" : ""
a = (e,t) => isValid(e) && isValid(t) ? "https://hongguoduanju.com/player/" + e + "/" + t : ""
c = (e,t,r) => (r?.available) && r.seriesId === e && r.itemId === t && a(e,t) ? … "https://hongguoduanju.com" + …
```

→ **web 端自己在源码里就只构造 `360p.mp4` 这一条路径**，没有任何画质分支/HLS/清单逻辑。
**「360p」不是被限流的结果，而是 web 版的设计上限。**

### 25.3 `/api/video/protected/` 不是 web 的取流调用点（重要更正）

`q.78e32a6456.js` 中该字符串的唯一出现是一段**上报脱敏过滤器**（谓词 `k`）：

```js
e.pathname.startsWith("/api/video/protected/")
  || /^v\d+-(?:reading|hgweb)\.qznovelvod\.com$/i.test(e.hostname)
  || /^vod(?:[.-][a-z0-9-]+)*\.(?:volcengineapi|byteplusapi)\.com$/i.test(e.hostname)
  || [...e.searchParams.keys()].some(t => w.test(t))    // w = key|spade_a|play_?auth|getplayinfotoken|private_encrypt_upgrade|union_?info|drm_?kek|veplayer
```

即"**这些 URL/参数不要上报**"。它**不调用**该接口，但它泄露了三件事：
1. 生态里**确实存在** `/api/video/protected/` 这条受保护通道；
2. **VOD 侧主机族**：`qznovelvod.com`（`v{N}-reading|hgweb`）、`volcengineapi.com`（`vod*`）、`byteplusapi.com`（`vod*`）；
3. 受保护通道的参数名族：`spade_a`、`play_auth(_token|_id)`、`getplayinfotoken`、`private_encrypt_upgrade`、`union_info`、`drm_kek`。

→ 这些是 **App / 原生播放器**用的通道，**web 播放器不使用**。

### 25.4 嵌套播放路由也不供锁定集

`/player/{series_id}/{vid}` 实测：
- 公开集（vid[0]）→ 返回完整页（187 KB，含 `player_(series_id)/(vid)/page`）；
- **锁定集（vid[30]）→ 只返回 layout（37 KB），无 `page` 载荷**。
→ web 侧**根本不提供锁定集的播放数据**，不是"签名没配对"的问题。

### 25.5 `accessible_episode_cnt` 完全不可用（四次实测）

同一部剧 `series_id=7503745441910017049` 四次实测依次为 **30 / 50 / 5 / 10**；而 URL 模板实测边界恒为前 30 集。
另外抽 3 部剧实测：ep1 **全部** 360p 可播；`ep31ish` —— 一部 **206**、两部 **404**，即**免签覆盖集数逐剧不同**。
→ **该字段既不代表可播集数、也不代表免签边界；判定必须靠实际 HTTP 探测。**

### 25.6 结论：「全集 + 全画质」在 web 免签通道内**不可能**达成

- **全画质**：web 只有 360p，且是源码硬编码，**没有可穷举出来的更高画质路径**。
- **全集**：锁定集在 web 侧**没有任何播放数据**，且 `/player/{sid}/{vid}` 对应 page 载荷缺失。
- 因此用户要求的「全集 + 全画质」**只能走 App 受保护通道（轨②）**：
  `/api/video/protected/` + VOD 主机（`qznovelvod` / `volcengineapi` / `byteplusapi`）+
  参数族（`spade_a` / `play_auth*` / `getplayinfotoken` / `drm_kek`），
  按计划书即 **X-Gorgon `8404 401c 0000` 变体 + 设备伪装 + spade_a→CENC + AES-CBC**。
- **地面真值问题**：这些接口是 **App 专用**，web 侧无调用点可对照；要还原请求构造与签名，
  最可靠的证据是**抓 Android 真机/模拟器上红果 App 的流量** —— 这**重新依赖 §19.1 的用户侧前置**
  （cmdline-tools / NDK r28 / 连接设备，以及可运行的红果 App）。
- 逆向工程本身产出不确定，且**签名算法会随版本轮换**（长期维护负担）；**不承诺一定成功**。

### 25.7 可立刻落地的兜底（不受上述阻塞影响）

按用户要求的方向，**W3 先落轨①兜底层**：接入 `media_kit` 播放 `/video/public/{vid}/360p.mp4`，
`locked` 状态由**实际 HTTP 探测（首个 404）**驱动而非 `accessible_episode_cnt`，保证：
播放器端到端可用、**永不白屏**、可播集数逐剧自动探测；「全集 + 全画质」作为其上的增量推进。

### 25.8 VOD 主机族探测：不存在"免签的 VOD 后门"

| 主机 | DNS | HTTP |
|---|---|---|
| `v1-reading.qznovelvod.com` / `v1-hgweb.qznovelvod.com` / `v9-reading.qznovelvod.com` | **无解析** | 连不上（不知道这样的主机） |
| `vod.volcengineapi.com` | 可解析 | 任意路径一律 **400 `application/json`** |
| `vod.byteplusapi.com` | 可解析 | 同上 |

→ ①`qznovelvod.com` 的 `v{N}-reading|hgweb` 是**过滤正则里出现的租户域名**，公开 DNS 不可达；
②`vod.*.api` 是 **Volcengine/BytePlus VOD 的 API 网关**，必须带正确参数与签名（返回 400 JSON 而非媒体）。
**不存在可以直接拿链接的免签 VOD 后门**——进一步印证 §25.6：全集/全画质只能走签名通道。

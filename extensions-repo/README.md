# hongguojian-extensions

红果鉴官方扩展站源仓库。每个站源是一个独立 JS 文件，元数据写在文件头；
应用按需下载安装，坏了当天发包修复、无需发版。

## 目录结构

```
extensions/<id>.js   # 扩展脚本（文件头声明 id/name/version 等元数据）
tools/build.py       # 校验脚本 + 生成 index.json（含 SHA-256）
index.json           # 官方索引：元数据、下载地址、摘要
```

## 文件头

```js
// ==HongguoExtension==
// @id hanxiaoquan
// @name 韩小圈
// @version 1.0.0
// @apiLevel 1
// @restricted false
// @description 韩剧 · 韩国电影 · 综艺动漫
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==
```

`group` / `groupName` / `entryName` 用于把多个入口并入同一分组
（如黄果视频 / 黄果 AI / 黄果旧版共用「黄果」）。

### 能力声明（可选）

宿主不再按源 ID 硬编码任何能力判断，全部由清单驱动：

| 字段 | 作用 |
| --- | --- |
| `@onlineSearch true` | 该源支持站内搜索；未声明时查询会回落到本地剧库过滤 |
| `@pagedSearch true` | 搜索结果支持翻页 |
| `@suggestions true` | 该源提供搜索联想 |
| `@vip true` | 该源会返回 VIP 标记：界面据此显示 VIP 筛选与详情状态 |
| `@danmaku true` | 该源支持弹幕（当前仅内置红果实现） |
| `@detailFields vip,heat` | 目录里可能缺失、需要拉详情补齐的字段 |

`detailFields` 允许的取值（大小写不敏感，统一按小写比较）：

`vip`、`heat`、`views`、`onlinedate`、`description`、`tags`、`releasestatus`

最多 6 个。声明后，宿主在目录结果缺这些字段时会自动拉一次详情补齐；
未声明的源不会被补资料，也就不会因为缺少字段而反复请求。

### 每源设置

宿主为每个扩展源提供一项内置的「镜像地址」设置（`hg.storage` 的 `baseURL` 键），
在「站源管理 → 展开站源 → 设置」里编辑。`hgkit` 的 `source.base()` 读取顺序为：

```
ctx.host > hg.storage.baseURL（镜像） > 扩展声明的 fallbackHostKey > baseURL
```

因此扩展不需要为镜像做任何额外处理。

扩展还可以用 `@settings` 声明自己的配置项，宿主会渲染成通用表单：

```
// @settings useProxy|使用代理|toggle|false
// @settings quality|画质偏好|choice|auto|auto=自动|1080=1080P
// @settings pageSize|每页数量|choice|24|24=24 条|48=48 条
```

- 多项用 `;` 分隔，字段用 `|` 分隔，最多 6 项。
- 字段顺序：`key|title|type|default|其余`。
- `type` 支持 `input`（文本）、`toggle`（开关）、`choice`（单选）。
- `input` / `toggle` 的第 5 段是 placeholder；`choice` 的第 5 段起全是
  `value=label` 选项（2–12 个），**没有 placeholder**。
- `key` 只能包含字母、数字、`-` `_` `.`，不能与内置的 `baseURL` 冲突。

值存在该源的 `hg.storage` 里，扩展直接读取：

```js
const size = hg.storage.get('pageSize') || source.pageSize;
```

未设置时返回 `default`；用户清空后同样回落到默认值。

## source 契约

扩展脚本定义全局 `source` 对象，宿主注入 `hg` 能力对象：

```js
globalThis.source = {
  categories(ctx, force) => [{id, name}]        // null 表示无在线分类
  validCategory(category) => boolean
  catalog(ctx, page, category, query) => {items, hasMore}
  detail(ctx, id) => {drama: {sourceId, title, ...}, chapters: [{id, title, videoUrl|pageUrl}]}
  // 可选。headers 会附加到宿主发起的媒体请求上（HLS 播放列表、分片、下载），
  // 传输层头（Host/Content-Length/Connection/Range/Referer/User-Agent）由宿主独占。
  resolve(ctx, task) => {url, referer?, quality?, headers?, hlsKey?, credentials?}
  rankingBoards(ctx) => [{id, name, description?, data?}]                 // 可选
  rankings(ctx, boardId, data, page) => {items, hasMore, totalPages?}     // 可选
}
```

`resolve` 不接受 `qualities`：多清晰度由宿主按 `quality` 与线路去重后自行排序，
扩展只需为每个可播放地址返回一次 `resolve` 结果。

## hgkit 宿主工具库（apiLevel 1）

宿主会在每个扩展脚本前注入 `globalThis.hgkit`，推荐用 `hgkit.defineSource` 包装：

```js
globalThis.source = hgkit.defineSource({
  name: '示例源',
  baseURL: 'https://example.com',
  pageSize: 24,
  categories: [{id: '1', name: '全部'}],
  catalog(ctx, page, category, query) { /* ... */ },
  detail(ctx, id) { /* ... */ },
  // resolve 可选：章节有直接 videoUrl 时宿主会用默认实现
});
```

| 能力 | 说明 |
| --- | --- |
| `source.getText/getJSON` | 走宿主网络栈，自动拼 `base(ctx)`、带 Referer |
| `source.clean/text/pick/first/int/tags` | HTML 清洗、字段取值、数字/标签归一 |
| `source.url/mediaURL/isMediaURL/cover` | 相对地址解析、媒体地址与封面校验 |
| `source.meta` | 读取 meta 标签内容 |
| `source.page` | 统一 `{items, hasMore}`，支持 `total` 或按页大小推断 |
| `source.chapters` | 去重、补齐标题/集数、排序 |
| `source.drama` | 按字段名映射剧集条目，支持 `tagValues` 与自定义字段 |
| `source.cards` | 列表页卡片解析：去重、限上限、封面校验由宿主保证，扩展只声明选择器 |
| `source.macPlaylist` | 苹果 CMS 播放页取流（`var now="<m3u8>"` 或首个直链），直接返回 `{url, referer}` |
| `source.int` | 非负整数解析；空值、负数、超限、非数字一律返回 `null` |
| `source.base(ctx)` | ctx.host > `hg.storage.baseURL` > 可选 fallback > 站点根 |
| `source.validCategory` | 未实现时由 `categories` 自动生成 |
| `source.resolve` | 未实现时对直接 `videoUrl` 返回播放地址 |
| `hgkit.cloudFrontCredentials` | 解析 CloudFront 签名 Cookie，生成宿主可用的 credentials |

### `source.cards`：列表页解析

各站的"列表页 → 剧集条目"骨架几乎一致，差异只在选择器与字段位置。
`source.cards` 把骨架沉到宿主，扩展只声明：

```js
catalog(ctx, page, category) {
  const body = source.getText(ctx, `/list/${category}.html`);
  const items = source.cards(body, {
    container: 'ul.row.video-list',      // 可选：限定在某个容器内查找
    item: 'a.video-link',                // 必填：卡片选择器
    id: /\/nv\/(\d+)\.html/,             // 正则取第 1 捕获组
    title: 'attr:title',                 // 卡片自身属性
    cover: 'img@data-src',               // 子节点 @ 属性
    remark: '.video-duration',           // 子节点文本
    defaultCategory: '影视',
    window: 600,                         // 可选：只取卡片后续 N 字符
    allowEmptyTitle: false,              // 可选：无标题时是否保留（宿主兜底标题）
    limit: 500,                          // 可选：条目上限
    extra: (node, chunk, row) => ({...}),// 可选：补充字段
  });
  return source.page(items, page);
}
```

字段声明支持四种写法：

| 写法 | 含义 |
| --- | --- |
| `'attr:title'` | 卡片节点自身的属性 |
| `'.selector'` | 子节点的文本 |
| `'.selector@attr'` | 子节点的属性 |
| `/regex/` | 对卡片 HTML 片段跑正则，取第 1 捕获组 |
| 函数 | 自定义，签名 `(node, chunk) => value` |

去重（按 `sourceId`）、条目上限、封面地址校验（必须是可访问的 http(s) 媒体地址）、
相对地址解析都由宿主完成。

### `source.macPlaylist`：苹果 CMS 播放页

```js
resolve(ctx, task) {
  const playURL = task.pageUrl || task.chapterId;
  if (!playURL) throw new Error('播放页地址无效');
  return source.macPlaylist(ctx, playURL, {label: '某站'});
}
```

取流顺序：`<script>var now="<地址>"</script>` → 页面内第一个 `.m3u8` / `.mp4` 直链。
两者都没有时抛「该集暂无可用播放地址」。

`hgkit` 不隐藏站点差异：选择器、接口地址、加密协议仍然写在扩展里。
目前 10 个官方扩展全部使用 `hgkit.defineSource`；模板见 `tools/template.js`。

## 宿主 API（`hg.*`，全部走应用现有网络栈，含 TLS 指纹与限流）

- `hg.fetch(url, {method, headers, body})` → `{status, headers, body, bodyBase64}`
- `hg.fetchAll([{url, options}])` 并行请求（最多 32 个）
- `hg.html.parse/findFirst/findAll/attr/text/inner/html`（CSS 选择器）
- `hg.crypto`：md5/sha256/sha3、HMAC、AES-CBC、base64/hex、gzip、随机字节
- `hg.storage.get/set/keys`（每源 ≤1 MiB）
- `hg.log(...)`

约束：单文件 ≤512 KiB；仅 HTTP(S) GET/POST；请求体 ≤1 MiB；响应 ≤8 MiB；
章节与剧集 ID 的站源前缀由宿主强制覆写；**不得访问本机或内网地址**
（`127.0.0.1`、`localhost`、私有网段、链路本地地址，含 3xx 重定向目标）。

单次脚本调用有 20 秒硬上限（分类校验 3 秒、榜单声明 10 秒），超时会中断
脚本并重建运行时——扩展内不要写死循环或无限等待。

`hg.log` 与 `console.log` 的输出会写入应用诊断日志，并可在
「站源管理 → 展开站源 → 扩展日志」直接查看。

## 开发流程

1. 复制模板：`cp tools/template.js extensions/<id>.js`，修改文件头与解析逻辑。
2. 本地校验：`python3 tools/build.py --check`。
3. 生成索引：`python3 tools/build.py --base-url https://raw.githubusercontent.com/OWNER/REPO/main/extensions`。
4. 提交后 CI 校验 `index.json` 与脚本一致。

## 信任模型

扩展不签名，安装时校验索引中的 SHA-256。请只安装来自可信官方仓库的扩展；
应用内随包提供这些扩展，但不会自动安装；需在站源管理中手动安装。

## 迁移状态

| 扩展源 | 状态 |
| --- | --- |
| 韩小圈 / 鬼片 / 青空 / 剧果 / 野果 / 帝果 / 黄豆 / 黄果视频 / 黄果 AI / 黄果旧版 | 已迁移（JS） |
| 红果 | 保留 Go 内置（设备注册与请求签名不可脚本化） |

内置源与扩展源共用 `sourceProvider` 接口；目前只有红果仍由 Go 提供。

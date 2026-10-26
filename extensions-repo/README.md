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

## source 契约

扩展脚本定义全局 `source` 对象，宿主注入 `hg` 能力对象：

```js
globalThis.source = {
  categories(ctx, force) => [{id, name}]        // null 表示无在线分类
  validCategory(category) => boolean
  catalog(ctx, page, category, query) => {items, hasMore}
  detail(ctx, id) => {drama: {sourceId, title, ...}, chapters: [{id, title, videoUrl|pageUrl}]}
  resolve(ctx, task) => {url, referer?, quality?, hlsKey?, credentials?} // 可选
  rankingBoards(ctx) => [{id, name, description?, data?}]                 // 可选
  rankings(ctx, boardId, data, page) => {items, hasMore, totalPages?}     // 可选
}
```

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
| `source.base(ctx)` | ctx.host > `hg.storage.baseURL` > 可选 fallback > 站点根 |
| `source.validCategory` | 未实现时由 `categories` 自动生成 |
| `source.resolve` | 未实现时对直接 `videoUrl` 返回播放地址 |
| `hgkit.cloudFrontCredentials` | 解析 CloudFront 签名 Cookie，生成宿主可用的 credentials |

`hgkit` 不隐藏站点差异：选择器、接口地址、加密协议仍然写在扩展里。
目前 10 个官方扩展全部使用 `hgkit.defineSource`；模板见 `tools/template.js`。

## 宿主 API（`hg.*`，全部走应用现有网络栈，含 TLS 指纹与限流）

- `hg.fetch(url, {method, headers, body})` → `{status, headers, body, bodyBase64}`
- `hg.fetchAll([{url, options}])` 并行请求（最多 32 个）
- `hg.html.parse/findFirst/findAll/attr/text/inner/html`（CSS 选择器）
- `hg.crypto`：md5/sha256/sha3、HMAC、AES-CBC、base64/hex、gzip、随机字节
- `hg.storage.get/set/keys`（每源 ≤1 MiB）
- `hg.log(...)`

约束：单文件 ≤512 KiB；仅 HTTP(S) GET/POST；章节与剧集 ID 的站源前缀由宿主强制覆写。

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

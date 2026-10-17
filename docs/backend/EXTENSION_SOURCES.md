# 规则扩展源设计

红果是**内置主源**。其余站源不再是编译期开关，而是**可安装的规则包**：
作者写 YAML，官方仓库编译成规范化 JSON 并签名，客户端运行期加载执行。

本文定义规则包能表达什么、不能表达什么，以及为什么这样切。

## 一、为什么是规则而不是插件

原实现的 22 个额外源里，按协议族分布：

| 族 | 数量 | 代表 | 可声明化程度 |
|---|---|---|---|
| MacCMS 模板 HTML 抓取 | 8 | 花果 / 网果 / 发果 / 皮果 / 伍果 / 鬼片 / 韩小圈 / 帝果 | **高**——差异只在 URL 模板与 CSS 选择器 |
| 普通 JSON REST | 5 | 剧果 / 青空 / 饭果 / 星果 / 观果 | **高**——差异只在路径与字段映射 |
| HTML + 内嵌 JSON | 2 | 黄果 AI / 黄果视频 | 中——卡片解析有启发式 |
| Next.js SSR | 1 | 河果 | 中——`__NEXT_DATA__` 结构固定但字段散 |
| Nuxt3 + AES-CBC + 响应签名 | 1 | 野果 | 低——需要从 JS chunk 抓密钥 |
| 签名/加密 JSON | 3 | 猫果 / 黄豆 / 牛果 | 低——各自 bespoke |
| 外部解析链 | 1 | 牛果 | 低 |

结论：**约 2/3 的源可以完全声明化**，剩下 1/3 需要「逃生舱」。

两个候选方案：

- **WASM 插件**：表达力最强，但要引入 wasm 运行时（体积 + 沙箱 + 宿主 API 设计），
  且作者要写代码——那就不是「规则源」而是「插件源」了，维护门槛反而更高。
- **声明式规则 + 命名原语**：表达力受限于原语集合，但作者只需写 YAML，
  校验器能静态检查，签名/哈希天然可复现，官方仓库审阅成本低。

选后者，并**明确承认表达力边界**：表达不了的源就写进逃生舱清单，
由内置 crate 实现，不硬塞进规则里。把「规则能做什么」写清楚，
比假装规则无所不能更诚实。

## 二、两种形态：作者态与分发态

```
作者态 source.yaml  ──编译──▶  分发态 source.json  ──签名──▶  仓库索引
   （可读、可注释）              （规范化、可哈希）            （sha256 + 公钥）
```

- **YAML 只用于编写**。客户端**从不**解析 YAML——少一个解析器，少一类攻击面，
  也避免「YAML 的注释/顺序影响哈希」。
- **JSON 是唯一的运行期格式**。键排序、无空白、字段顺序固定，因此内容哈希可复现。
- 编译是**确定性**的：同样的 YAML 必须产出逐字节相同的 JSON，否则签名无意义。

客户端也接受 `.yaml` 直装（开发调试用），但会先在内存里编译成 JSON 再走同一条校验路径。

## 三、规则能表达什么

规则包是**受限的声明式程序**，只有以下原语。没有循环、没有变量作用域、
没有条件分支嵌套超过两层——这是刻意的：规则一旦图灵完备，审阅就不再可能。

### 3.1 请求

```yaml
request:
  method: GET                 # GET | POST
  url: "{{base}}/show/duanju-----------.html"
  query:                      # 有序 map，顺序即发送顺序
    page: "{{page}}"
  body: json                  # json | form | none
  headers:
    Referer: "{{base}}/"
  user_agent: desktop         # desktop | mobile | ios | custom
  timeout_ms: 12000
  max_body_bytes: 8388608
```

变量：`{{base}} {{page}} {{query}} {{id}} {{episode}} {{category}} {{vid}}`。
变量替换是**纯文本**的，不做 URL 编码；需要编码时用过滤器（见 3.4）。

### 3.2 传输与鉴权（有序步骤）

```yaml
auth:
  - type: login              # 一次登录换 token
    request: { ... }
    extract: { path: "data.token" }
    cache_ttl_s: 21600
    header: "Authorization: Bearer {{token}}"
  - type: sign               # 拼接签名
    algo: md5
    template: "operation=1playlet_privacy=1tag_id={{category}}{{secret}}"
    output: { header: sign }
    secret: "d3dGiJc651gSQ8w1"
  - type: aes                # 解包响应
    mode: cbc
    key: "{{config.key}}"
    iv: "{{config.iv}}"
    padding: pkcs7
```

支持的原语（**封闭集合**，新增需要改 Rust 并发版）：

| type | 用途 | 关键参数 |
|---|---|---|
| `none` | 无鉴权 | — |
| `static_headers` | 固定头（星果的 productId/token） | `headers` |
| `login` | 登录换 token 并缓存 | `request` `extract` `cache_ttl_s` `header` |
| `bearer` | Bearer token，401/403 时刷新一次 | `login_ref` |
| `sign` | 有序拼接后哈希 | `algo`(md5/sha1/sha256) `template` `secret` `output` |
| `hmac` | HMAC 签名 | `algo` `key` `data` `output` |
| `aes` | 请求/响应加解密 | `mode`(cbc/ecb) `key` `iv` `padding` |
| `gzip` | 解压 | — |
| `base64` | 编解码 | `variant`(std/url/raw) |
| `rune_map` | 字符替换表（猫果的 61 项映射） | `table` |
| `uri_key` | 用请求 URI 前 16 字节派生密钥（牛果） | `length` |
| `response_sign` | 校验响应签名 | `algo` `template` `secret` |

`secret` 与 `config.*` 的值来自规则包的 `config` 段，**明文存在规则包里**——
它们本来就是公开在前端 JS 里的密钥，不是用户凭证。真正的用户凭证（登录 token）
只存在客户端本地缓存，绝不写进规则包。

### 3.3 取值

两种取值器，对应两类响应：

```yaml
extract:
  # JSON 响应
  json:
    items: "data.video_data"          # 点路径；`|` 表示别名回退
    id: "series_id_str|series_id"
  # HTML 响应
  html:
    items: { css: ".public-list-box" }
    title: { css: "a", attr: "title" }
    cover: { css: "img", attr: "data-original" }
```

JSON 路径是**点分 + 别名回退**（`a.b|c.d`），不支持通配与过滤——
需要复杂取值的源进逃生舱。

HTML 取值用 CSS 选择器（`scraper` crate）。另外支持两个常用原语：

- `regex`：`{ regex: 'player_aaaa\s*=\s*(\{.*?\})', group: 1 }`
- `script_json`：`{ next_data: true }` / `{ nuxt_data: true }`——直接取框架注入的整块 JSON

### 3.4 映射与过滤器

```yaml
map:
  id:    { from: "url:detail_id" }
  title: { from: "title", filters: [strip_tags, unescape, collapse_ws, truncate:512] }
  cover: { from: "cover", filters: [absolutize] }
  episodes: { from: "remark", filters: [episode_number] }
  status: { from: "remark", filters: [status_map] }
```

过滤器（封闭集合）：`strip_tags` `unescape` `collapse_ws` `truncate:N`
`absolutize` `episode_number` `status_map` `date_normalize` `views_normalize`
`split_tags:SEP` `first_non_empty` `replace:A:B` `lowercase` `uppercase`。

### 3.5 分页

```yaml
pagination:
  type: page            # page | last_link | flag | cursor | single
  size: 24
  more: "len>0"         # len>0 | has_next_field | total_pages
  start: 1
```

| type | 语义 | 终止条件 |
|---|---|---|
| `page` | `?page=N` 递增 | 返回条数 < `size` 或 `len==0` |
| `last_link` | 从 HTML 抓「末页」链接（MacCMS 常见） | 当前页 == 末页 |
| `flag` | 响应里有 `is_end`/`has_more` 布尔 | 该布尔为假 |
| `cursor` | 响应回传 `next_id`/`next_offset` | 无回传值或未前进 |
| `single` | 只有一页 | 立即终止 |

`cursor` 型必须做**未前进检测**：新游标 <= 旧游标即判定停滞并报错，
否则会无限翻页（原实现的猫果就踩过 `hasMore` 恒假的坑）。

### 3.6 分集与取流

```yaml
chapters:
  items: "video_list"           # 或 { css: ".playlist a" }
  index: "vid_index"
  vid: "vid"
  title_template: "第{{index}}集"
  url_template: "hongguo-cenc://{{vid}}"   # 占位协议，取流时再解析

playback:
  type: resolve                  # inline | page | resolve
  # inline：分集条目里直接有 url
  # page：需要再请求分集页，从页面里抓地址
  # resolve：需要单独解析接口
  request: { url: "{{base}}/api/play/{{vid}}" }
  extract: { path: "data.url" }
  variants: { path: "data.list", url: "url", quality: "resolution" }
  quality_from: "name"           # 从哪个字段提取数字作为清晰度
  headers: { Referer: "{{base}}/" }
```

`quality` 一律是**画面高度**（360/720/1080）。从字符串提取时取第一段数字；
取不到则回退到宽度。

### 3.7 策略

```yaml
policy:
  identity_check: true       # 详情响应必须回显请求的 id
  dedupe_by: id
  max_items: 500
  error_messages:            # 把上游错误码映射成用户可读文案
    "-1": "该内容需要授权"
  cloudflare_detect: true
```

`identity_check` 默认 **true**。原实现里多个源因为没做这一步，
在站源返回「默认推荐」时把别的剧当成用户点的那部展示出来。

## 四、规则**不能**表达什么（逃生舱清单）

这些源需要内置实现，不进规则：

| 源 | 卡在哪 | 处理 |
|---|---|---|
| 帝果 | `vplayer` 的 AAencode 解码 + 算术表达式求值 | 内置 crate，或标注「不支持」 |
| 黄果旧版 | 自定义 SHA-256 切片密钥调度 | 内置 crate |
| 野果 | 需要从 `_nuxt/*.js` 抓密钥，且响应签名有特定字段顺序 | 内置 crate |
| 黄果 AI | 三套卡片解析策略 + 标题修复谓词 + 元数据合并 | 内置 crate |
| 黄果视频 / 皮果 | 需要 Chrome TLS 指纹才能过 Cloudflare | 需要传输层插件（暂不做） |
| 黄豆 | AES-256-CBC + gzip 信封 + HMAC 密钥派生 + 试看检测 | 信封可作为 codec 声明化；试看检测需内置 |
| 牛果 | AES 密钥取自**实际发送的 URI**（含 query 顺序） | 需要 `uri_key` 原语 + 顺序保证，可声明化 |
| 猫果 | MD5 签名 + 61 项 rune 映射 | 可声明化（`sign` + `rune_map`） |

规则包的 `requires` 字段可以声明依赖某个内置 codec：

```yaml
requires: [codec.aaencode]
```

加载时若该 codec 不存在，规则包**拒绝安装并明确报错**，而不是装上了运行时报错。

## 五、安装、校验与信任

### 5.1 安装流程

```
1. 读取包（.json 或 .yaml）
2. YAML → 编译成规范化 JSON（确定性）
3. 结构校验（schema）
4. 语义校验（原语名、过滤器名、模板变量、正则合法性、URL 模板可解析）
5. 自测（可选）：跑一次 catalog/detail，确认能解析出非空结果
6. 写入 {dataDir}/sources/{id}.json
7. 注册到运行期源表（无需重启）
```

**任一步失败都不落盘**。已安装的同 id 源在新包校验失败时保持原样——
「更新失败把能用的源搞坏」是最糟的失败模式。

### 5.2 结构校验规则

| 检查 | 失败后果 |
|---|---|
| `id` 匹配 `[a-z0-9][a-z0-9-]{0,63}` | 拒绝（id 会进文件名） |
| `id` 不能等于 `hongguo` | 拒绝（不能覆盖内置主源） |
| `schema` 版本必须被支持 | 拒绝并提示「规则包版本过新」 |
| `base` 必须是 http(s) 绝对 URL | 拒绝 |
| 所有 `{{var}}` 必须是已知变量 | 拒绝（拼写错误在这里拦住） |
| 所有原语/过滤器名在白名单内 | 拒绝并列出未知项 |
| 所有正则可编译 | 拒绝 |
| `requires` 全部可用 | 拒绝并列出缺失项 |
| 包体积 <= 256 KiB | 拒绝（防止塞大字典） |

### 5.3 信任模型（未定稿）

计划是官方仓库发布 `index.json`，含每个包的 `{id, version, sha256, signature}`，
客户端用内置公钥验签。**在公钥分发方式定下来之前**：

- 安装只做结构校验，不做来源认证；
- UI 必须明示「第三方规则源，作者未经验证」；
- 规则源默认**不启用**，需要用户手动打开。

规则**无法**访问：文件系统、任意网络地址（只允许 `base` 及其同源路径）、
进程环境、其他源的数据。这是「声明式」相对 WASM 的另一个好处——
没有运行时，就没有逃逸面。

## 六、目录结构

```
sources/                      官方规则仓库（本仓内，随应用发版）
  index.json                  索引：id/version/sha256/signature
  hongguo.yaml                （仅供参考，内置源不用规则实现）
  wuguo.yaml
  heguo.yaml
  ...
```

客户端安装后落在 `{dataDir}/sources/{id}.json`，与内置源并列注册。
`{dataDir}/sources/index.json` 记录已安装版本与来源，用于更新检查。

## 七、与主源的关系

红果**不走规则引擎**。它是内置 crate（`drama-source-hongguo`），因为它需要：

- 两套签名（Gorgon + 注释签名 X-Argus/X-Ladon，含自研 SM3/ARX/XTEA 变体）；
- App 签名接口 + 网页 SSR + 公开轨的三级降级；
- 游标状态机（head/tail 模式、停滞检测、30 分钟会话过期）；
- 搜索的双通道合并 + 季数补齐算法。

这些都不适合塞进声明式规则。**主源用代码写，扩展源用规则写**，
是这次改造最核心的一条边界。

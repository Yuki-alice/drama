// hgkit 解析层：URL 归一、媒体地址校验、HTML 字段提取与列表卡片。
//
// 依赖 kit-core 的 text/cleanText/int。
(function (kit) {
  'use strict';

  const {text, int, cleanText} = kit;

  function resolveURL(base, reference) {
    reference = text(reference).replace(/\\\//g, '/');
    if (!reference) return '';
    if (reference.startsWith('//')) reference = 'https:' + reference;
    if (/^https?:\/\//i.test(reference)) {
      const parsed = hg.url.parse(reference);
      return parsed.valid ? parsed.href : '';
    }
    const parsedBase = hg.url.parse(text(base));
    if (!parsedBase.valid) return '';
    if (reference.startsWith('/')) {
      return parsedBase.protocol + '://' + parsedBase.host + reference;
    }
    const directory = parsedBase.path.replace(/[^/]*$/, '');
    return parsedBase.protocol + '://' + parsedBase.host + directory + reference;
  }

  function mediaURL(value) {
    const raw = text(value);
    if (!raw) return '';
    const parsed = hg.url.parse(raw.startsWith('//') ? 'https:' + raw : raw);
    if (!parsed.valid) return '';
    if (parsed.protocol !== 'http' && parsed.protocol !== 'https') return '';
    return parsed.href;
  }

  function isMediaURL(value) {
    const address = mediaURL(value);
    if (!address) return false;
    const path = hg.url.parse(address).path.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.mp4');
  }

  function metaContent(body, name) {
    const document = hg.html.parse(text(body));
    for (const meta of hg.html.findAll(document, 'meta')) {
      const key = (hg.html.attr(meta, 'property') || hg.html.attr(meta, 'name') || '').toLowerCase();
      if (key === name) return text(hg.html.attr(meta, 'content'));
    }
    return '';
  }

  function coverURL(value, base) {
    if (value == null) return '';
    if (Array.isArray(value)) {
      for (const entry of value) {
        const address = coverURL(entry, base);
        if (address) return address;
      }
      return '';
    }
    if (typeof value === 'object') {
      for (const key of ['url', 'contentUrl', 'thumbnailUrl', 'cover', 'image']) {
        const address = coverURL(value[key], base);
        if (address) return address;
      }
      return '';
    }
    const resolved = resolveURL(base, value);
    return mediaURL(resolved);
  }

  // —— 卡片列表解析 ——
  //
  // 各站的"列表页 → 剧集条目"结构几乎一致：找卡片、取 ID/标题/封面/备注、
  // 去重、限上限。差异只在选择器与字段所在位置。此前每个扩展各写一份
  // parseCards（6 个源、同构但各自漂移），这里把骨架沉到宿主。

  // fieldValue 按声明取一个字段值。
  //   'attr:title'        → 卡片节点的属性
  //   '.note'             → 子节点选择器的文本
  //   '.note@data-src'    → 子节点的属性
  //   /(\d+)/             → 对卡片 HTML 片段跑正则，取第 1 个捕获组
  //   函数                → 自定义，参数是卡片节点与原始 HTML 片段
  //
  // [chunk] 是可能被 window 截断过的 HTML。选择器型取值必须在 chunk 内解析，
  // 否则 window 就形同虚设（曾漏掉这点：cover 仍能读到窗口外的 img）。
  function fieldValue(node, chunk, spec) {
    if (spec == null) return '';
    if (typeof spec === 'function') {
      return spec(node, chunk);
    }
    if (spec instanceof RegExp) {
      const matched = String(chunk).match(spec);
      return matched ? text(matched[1] != null ? matched[1] : matched[0]) : '';
    }
    const raw = text(spec);
    if (!raw) return '';
    if (raw.startsWith('attr:')) {
      return text(hg.html.attr(node, raw.slice(5)));
    }
    let selector = raw;
    let attribute = '';
    const at = raw.lastIndexOf('@');
    if (at > 0) {
      selector = raw.slice(0, at);
      attribute = raw.slice(at + 1);
    }
    // 在截断片段内重新解析，保证 window 对子节点查询同样生效。
    const scope = hg.html.parse(String(chunk));
    const target = selector ? hg.html.findFirst(scope, selector) : scope;
    if (!target) return '';
    return attribute ? text(hg.html.attr(target, attribute)) : cleanText(hg.html.text(target));
  }

  function cards(body, options) {
    options = options || {};
    const base = text(options.base);
    const limit = int(options.limit, 10000) || 500;
    const windowSize = int(options.window, 1000000) || 0;
    const rows = [];
    const seen = new Set();
    if (!text(body) || !text(options.item)) return rows;

    let roots = [hg.html.parse(body)];
    if (options.container) {
      const container = hg.html.findFirst(roots[0], text(options.container));
      roots = container ? [container] : [];
    }
    for (const root of roots) {
      for (const node of hg.html.findAll(root, text(options.item))) {
        // 正则型 ID 需要整段 HTML；其余情况只用窗口片段即可。
        const chunk = windowSize > 0
          ? hg.html.html(node).slice(0, windowSize)
          : hg.html.html(node);
        const id = cleanText(fieldValue(node, chunk, options.id));
        if (!id || seen.has(id)) continue;
        const title = cleanText(fieldValue(node, chunk, options.title));
        // 部分站点的卡片只有图片没有标题，由宿主的 DisplayTitle 兜底
        // （黄果视频就是这种）。默认仍要求标题，避免把导航链接当剧集。
        if (!title && options.allowEmptyTitle !== true) continue;
        seen.add(id);
        const cover = coverURL(fieldValue(node, chunk, options.cover), base);
        const remark = cleanText(fieldValue(node, chunk, options.remark)).slice(0, 64);
        const row = {
          sourceId: id,
          title: title.slice(0, 256),
          cover: cover,
          category: cleanText(fieldValue(node, chunk, options.category)) ||
            text(options.defaultCategory) || '',
          remark: remark,
        };
        if (typeof options.extra === 'function') {
          const extra = options.extra(node, chunk, row);
          if (extra && typeof extra === 'object') Object.assign(row, extra);
        }
        rows.push(row);
        if (rows.length >= limit) return rows;
      }
    }
    return rows;
  }

  Object.assign(kit, {
    resolveURL: resolveURL,
    mediaURL: mediaURL,
    isMediaURL: isMediaURL,
    metaContent: metaContent,
    coverURL: coverURL,
    fieldValue: fieldValue,
    cards: cards,
  });
})(globalThis.hgkit);

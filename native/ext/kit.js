// hgkit 装配层：把各层能力挂到 source 上，并提供默认实现。
//
// 分层（按注入顺序，后者依赖前者）：
//   kit-core.js     命名空间、文本/整数/字段原语
//   kit-html.js     URL 归一、封面校验、HTML 字段与列表卡片
//   kit-normalize.js 标签、分页、分集、剧集条目
//   kit-net.js      宿主网络栈取文本/JSON、CloudFront 凭证
//   kit-maccms.js   苹果 CMS 播放页取流
//   kit.js          defineSource（本文件）
(function (kit) {
  'use strict';

  const {
    text, trimBase, int, pick, first, cleanText, tags, labelOf,
    resolveURL, mediaURL, isMediaURL, metaContent, coverURL, cards,
    page, chapters, drama, fetchText, fetchJSON, extractMacMedia,
  } = kit;

  function defineSource(config) {
    const source = Object.assign({}, config || {});
    source.baseURL = trimBase(source.baseURL);
    source.name = text(source.name);
    source.pageSize = int(source.pageSize, 1000000) || 24;
    source.headers = Object.assign({}, source.headers || {});

    if (Array.isArray(source.categories)) {
      const categories = source.categories.map((entry) => ({
        id: text(entry && entry.id),
        name: text(entry && entry.name),
      }));
      source.categories = function () {
        return categories.map((entry) => ({id: entry.id, name: entry.name}));
      };
    }

    // 用闭包捕获 source：宿主可能以不同的 this 调用契约方法，
    // 扩展内部也可能把 helper 赋给局部变量。
    source.base = function (ctx) {
      if (ctx && ctx.host) return trimBase(ctx.host);
      const override = text(hg.storage.get('baseURL'));
      const fallback = text(source.fallbackHostKey ? hg.storage.get(source.fallbackHostKey) : '');
      return trimBase(override || fallback || source.baseURL);
    };
    source.getText = function (ctx, path, options) {
      return fetchText(ctx, source, path, options);
    };
    source.getJSON = function (ctx, path, options) {
      return fetchJSON(ctx, source, path, options);
    };
    source.url = function (raw) {
      return resolveURL(source.baseURL, raw);
    };
    source.mediaURL = function (raw) {
      return mediaURL(raw);
    };
    source.isMediaURL = function (raw) {
      return isMediaURL(raw);
    };
    source.cover = function (raw) {
      return coverURL(raw, source.baseURL);
    };
    source.meta = function (body, name) {
      return metaContent(body, name);
    };
    source.first = first;
    source.page = function (items, pageNumber, options) {
      return page(items, pageNumber, source.pageSize, options);
    };
    source.chapters = function (items, options) {
      return chapters(items, options);
    };
    source.drama = function (row, options) {
      return drama(row, Object.assign({base: source.baseURL}, options || {}));
    };
    // 列表卡片：把"找卡片→取字段→去重→限上限"的骨架放在宿主，
    // 扩展只声明选择器。base 默认用站点根，便于解析相对封面地址。
    source.cards = function (body, options) {
      return cards(body, Object.assign({base: source.baseURL}, options || {}));
    };
    // MacCMS 播放页：取 var now="<m3u8>" 或页面内首个直链，
    // 直接返回 resolve 契约需要的 {url, referer}。
    source.macPlaylist = function (ctx, pagePath, options) {
      const config = options || {};
      const label = text(config.label) || labelOf(source, config);
      const path = text(pagePath);
      if (!path) throw new Error(label + '播放页地址无效');
      const body = text(config.body) || fetchText(ctx, source, path, {label: label});
      const address = extractMacMedia(body);
      if (!address) throw new Error(label + '该集暂无可用播放地址');
      return {
        url: address,
        referer: text(config.referer) || source.base(ctx) + '/',
      };
    };
    source.pick = pick;
    source.text = text;
    source.int = int;
    source.clean = cleanText;
    source.tags = tags;

    if (typeof source.validCategory !== 'function') {
      source.validCategory = function (category) {
        if (!category) return true;
        const list = typeof source.categories === 'function' ? source.categories({}, false) : [];
        return Array.isArray(list) && list.some((entry) => entry && entry.id === category);
      };
    }
    if (typeof source.resolve !== 'function') {
      source.resolve = function (ctx, task) {
        const address = mediaURL(task && task.videoUrl);
        if (!address) throw new Error('该分集没有可直接播放的地址');
        return {url: address, referer: source.base(ctx) + '/'};
      };
    }
    return source;
  }

  // hgkit.* 的公开面：扩展可以直接调用这些函数，不必经过 source。
  Object.assign(kit, {
    defineSource: defineSource,
    url: resolveURL,
  });
})(globalThis.hgkit);

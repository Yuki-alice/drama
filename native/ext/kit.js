// hgkit 是宿主注入的扩展工具库（apiLevel 1）。
// 目标：把网络、清洗、归一、分页与默认能力放进宿主，扩展只保留站点解析。
(function () {
  'use strict';
  const kit = {version: 1};

  function text(value) {
    if (value == null) return '';
    if (typeof value === 'string') return value.trim();
    if (typeof value === 'number' && Number.isFinite(value)) return String(value);
    return '';
  }

  function trimBase(value) {
    return text(value).replace(/\/+$/, '');
  }

  function int(value, max) {
    const parsed = Number(text(value));
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > (max || 100000000)) return null;
    return Math.floor(parsed);
  }

  function pick(object, keys) {
    if (!object || typeof object !== 'object') return '';
    for (const key of keys || []) {
      const value = text(object[key]);
      if (value) return value;
    }
    return '';
  }

  function first(values) {
    if (!Array.isArray(values)) return '';
    for (const value of values) {
      const result = text(value);
      if (result) return result;
    }
    return '';
  }

  function rawPick(object, keys) {
    if (!object || typeof object !== 'object') return null;
    for (const key of keys || []) {
      const value = object[key];
      if (value == null) continue;
      if (typeof value === 'string' && !value.trim()) continue;
      if (Array.isArray(value) && !value.length) continue;
      if (typeof value === 'object' && !Array.isArray(value) && !Object.keys(value).length) continue;
      return value;
    }
    return null;
  }

  function unescapeHTML(value) {
    let output = String(value == null ? '' : value);
    for (let round = 0; round < 3; round++) {
      const next = output
        .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#39;/g, "'")
        .replace(/&nbsp;/g, ' ')
        .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
        .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number(dec)));
      if (next === output) break;
      output = next;
    }
    return output;
  }

  function cleanText(value) {
    if (value == null) return '';
    const output = unescapeHTML(String(value).replace(/<[^>]+>/g, ''));
    return output.replace(/\u3000/g, ' ').trim().split(/\s+/).filter(Boolean).join(' ');
  }

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

  function tags(values, options) {
    options = options || {};
    const limit = int(options.limit, 1000) || 16;
    const maxLength = int(options.maxLength, 1000) || 48;
    const result = [];
    const seen = new Set();
    const rows = Array.isArray(values) ? values : (values == null ? [] : [values]);
    for (const raw of rows) {
      if (typeof raw !== 'string' && typeof raw !== 'number') continue;
      const value = cleanText(raw);
      if (!value || seen.has(value) || [...value].length > maxLength) continue;
      if (result.length >= limit) break;
      seen.add(value);
      result.push(value);
    }
    return result;
  }

  function pageResult(items, page, pageSize, options) {
    options = options || {};
    const rows = Array.isArray(items) ? items : [];
    let hasMore;
    if (options.hasMore != null) {
      hasMore = !!options.hasMore;
    } else {
      const total = int(options.total, 100000000);
      hasMore = total != null ? page * pageSize < total : rows.length >= pageSize;
    }
    return {items: rows, hasMore: hasMore};
  }

  function normalizeChapters(items, options) {
    options = options || {};
    const maxTitle = int(options.maxTitle, 1000) || 128;
    const result = [];
    const seen = new Set();
    const rows = Array.isArray(items) ? items : [];
    rows.forEach((item, index) => {
      if (!item || typeof item !== 'object') return;
      const id = text(item.id != null ? item.id : item.pageUrl);
      if (!id || seen.has(id)) return;
      const episode = int(item.episode != null ? item.episode : item.order, 100000) || index + 1;
      const title = cleanText(item.title).slice(0, maxTitle) || ('第 ' + episode + ' 集');
      seen.add(id);
      result.push(Object.assign({}, item, {id: id, title: title, episode: episode}));
    });
    result.sort((a, b) => {
      if (a.episode !== b.episode) return a.episode - b.episode;
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
    });
    return result;
  }

  function drama(row, options) {
    options = options || {};
    if (!row || typeof row !== 'object' || Array.isArray(row)) return null;
    const id = pick(row, options.idKeys || ['id', 'videoId']);
    if (!id || (typeof options.validID === 'function' && !options.validID(id))) return null;
    const title = cleanText(pick(row, options.titleKeys || ['title', 'name', 'videoTitle']));
    if (!title) return null;

    let episodes = 0;
    for (const key of options.episodeKeys || ['episodeCount', 'totalEpisode', 'episodes', 'total']) {
      if (!(key in row)) continue;
      const count = int(row[key], 100000);
      if (count != null && count > episodes) episodes = count;
    }
    const category = cleanText(pick(row, options.categoryKeys || ['categoryName', 'category'])) ||
      options.category || '';

    const tagValues = [];
    if (typeof options.tagValues === 'function') {
      const extra = options.tagValues(row) || [];
      for (const value of extra) tagValues.push(value);
    } else {
      for (const key of options.tagKeys || ['tags', 'tagList', 'categoryTags']) {
        if (!Array.isArray(row[key])) continue;
        for (const value of row[key]) tagValues.push(value);
      }
    }

    const item = {
      sourceId: id,
      title: title.slice(0, 256),
      description: cleanText(pick(row, options.descriptionKeys || ['description', 'intro', 'desc', 'summary'])).slice(0, 12000),
      cover: coverURL(rawPick(row, options.coverKeys || ['cover', 'coverUrl', 'coverLarge', 'coverSmall', 'coverThumb', 'backgroundImage', 'image', 'img']), options.base || ''),
      episodes: episodes,
      category: category,
      tags: tags(tagValues, options.tagOptions),
    };
    for (const field in options.fields || {}) {
      const value = pick(row, options.fields[field]);
      if (value) item[field] = value;
    }
    if (options.vipKeys) {
      const raw = rawPick(row, options.vipKeys);
      if (raw != null) item.vip = raw === true || raw === 1 || raw === '1' || raw === 'true' || raw === 'yes';
    }
    if (typeof options.extra === 'function') options.extra(row, item);
    return item;
  }

  function labelOf(source, options) {
    return text(options && options.label) || text(source && (source.label || source.name)) || '站源';
  }

  // CloudFront 签名 Cookie 是标准格式，解析与校验留在宿主，
  // 需要凭证的扩展只需提供响应头与到期时间。
  function cloudFrontCredentials(headers, address, options) {
    options = options || {};
    const label = text(options.label) || '站源';
    const cookies = {};
    const raw = (headers && (headers['Set-Cookie'] || headers['set-cookie'])) || '';
    for (const match of raw.matchAll(
      /(?:^|[,;\s])CloudFront-(Policy|Signature|Key-Pair-Id)\s*=\s*([^;,\s"']+)/g,
    )) {
      cookies['CloudFront-' + match[1]] = match[2];
    }
    const parts = [];
    for (const name of ['CloudFront-Policy', 'CloudFront-Signature', 'CloudFront-Key-Pair-Id']) {
      const value = cookies[name] || '';
      if (!value || value.length > 8192 || /[,;"\\]/.test(value) || /[\x00-\x20\x7f]/.test(value)) {
        throw new Error(label + '未返回完整的媒体凭证，请重试');
      }
      parts.push(name + '=' + value);
    }
    const parsed = hg.url.parse(text(address));
    if (!parsed.valid) {
      throw new Error(label + '播放地址无效');
    }
    let expires = 0;
    const stamp = Number(text(options.expiresAt));
    if (Number.isFinite(stamp) && stamp > 0 && stamp <= 253402300799000) {
      expires = stamp > 100000000000 ? Math.floor(stamp / 1000) : stamp;
    }
    if (expires > 0 && expires * 1000 <= Date.now()) {
      throw new Error(label + '媒体凭证已过期，请检查设备时间后重试');
    }
    return {
      cookie: parts.join('; '),
      origin: parsed.protocol + '://' + parsed.host,
      referer: text(options.referer),
      userAgent: text(options.userAgent),
      expiresAt: expires,
    };
  }

  function fetchText(ctx, source, path, options) {
    options = options || {};
    const base = source.base(ctx);
    const address = /^https?:\/\//i.test(text(path)) ? text(path) : base + text(path);
    const headers = Object.assign({
      Accept: 'text/html,application/json;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: base + '/',
    }, source.headers || {}, options.headers || {});
    const response = hg.fetch(address, {headers: headers});
    if (response.status !== 200) {
      throw new Error(labelOf(source, options) + '请求失败 HTTP ' + response.status);
    }
    return response.body;
  }

  function fetchJSON(ctx, source, path, options) {
    const body = fetchText(ctx, source, path, options);
    try {
      return JSON.parse(body);
    } catch (error) {
      throw new Error(labelOf(source, options) + '返回的数据无法解析');
    }
  }

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
    source.page = function (items, page, options) {
      return pageResult(items, page, source.pageSize, options);
    };
    source.chapters = function (items, options) {
      return normalizeChapters(items, options);
    };
    source.drama = function (row, options) {
      return drama(row, Object.assign({base: source.baseURL}, options || {}));
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

  Object.assign(kit, {
    defineSource: defineSource,
    text: text,
    int: int,
    pick: pick,
    first: first,
    cleanText: cleanText,
    tags: tags,
    url: resolveURL,
    mediaURL: mediaURL,
    isMediaURL: isMediaURL,
    coverURL: coverURL,
    metaContent: metaContent,
    page: pageResult,
    chapters: normalizeChapters,
    drama: drama,
    fetchText: fetchText,
    fetchJSON: fetchJSON,
    cloudFrontCredentials: cloudFrontCredentials,
  });
  globalThis.hgkit = kit;
})();

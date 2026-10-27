// ==HongguoExtension==
// @id yeguo
// @name 野果
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description 分类短剧 · 在线搜索
// @onlineSearch true
// @pagedSearch true
// @vip true
// ==/HongguoExtension==

// 野果扩展源：PWA 站点的 JS 移植（与 Go provider 对齐）。
// 站点入口页 → module 脚本 → 提取接口基址与 AES-CBC/sign_key 配置，
// 接口响应经 sign 校验与 AES-CBC 解密后使用。
globalThis.source = hgkit.defineSource({
  name: '野果',
  baseURL: 'https://analyze.buxefaex.cc',
  pageSize: 20,
  filterFields: ['theme', 'setting', 'background', 'time', 'recommend'],

  categories(ctx, force) {
    const data = apiCall(ctx, '/api/home/contentOptions', {}, 'GET');
    const filters = data.video_filter;
    if (!filters || typeof filters !== 'object') {
      throw new Error('野果分类数据格式无效');
    }
    const categories = [];
    const seen = new Set();
    for (const field of source.filterFields) {
      const filter = filters[field];
      const options = filter && filter.list;
      if (!Array.isArray(options)) continue;
      if (options.length > 300) {
        throw new Error('野果分类条目过多');
      }
      for (const row of options) {
        const value = text(row && row.value);
        const name = text(row && row.name);
        if (value === '0') continue;
        const id = field + ':' + value;
        if (!source.validCategory(id) || !name || [...name].length > 48 || seen.has(id)) {
          throw new Error('野果分类数据包含无效或重复条目');
        }
        seen.add(id);
        categories.push({id: id, name: name});
      }
    }
    if (!categories.length) {
      throw new Error('野果暂未返回分类');
    }
    return categories;
  },

  validCategory(category) {
    if (!category) return true;
    const parts = category.split(':');
    return parts.length === 2 && source.filterFields.includes(parts[0]) && /^\d+$/.test(parts[1]);
  },

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 1000000 || query.length > 1024 ||
        (category && !source.validCategory(category))) {
      throw new Error('野果目录查询参数无效');
    }
    let route = '/api/theater/exploreList';
    const params = {page: String(page), limit: String(source.pageSize)};
    if (query) {
      route = '/api/search/result';
      params.keyword = query;
      params.tab = 'video';
    } else if (category) {
      const [field, value] = category.split(':');
      params[field] = value;
    }
    const data = apiCall(ctx, route, params, 'POST');
    const rows = data.list;
    if (!Array.isArray(rows) || rows.length > 500) {
      throw new Error('野果目录格式无效');
    }
    const actualPage = source.int(firstPresent(data, ['page', 'page_num', 'pageNum', 'current_page', 'currentPage']), 1000000);
    if (actualPage != null && actualPage !== page) {
      throw new Error('野果分页信息无效，请重试');
    }
    let limit = source.int(firstPresent(data, ['limit', 'page_size', 'pageSize', 'per_page', 'perPage']), 500);
    if (limit == null || limit < 1 || limit < rows.length) {
      limit = rows.length;
    }
    let total = source.int(firstPresent(data, ['total', 'total_count', 'totalCount']), 100000000);
    if (total != null && total < rows.length) total = null;
    let hasMore = limit > 0 && rows.length >= limit;
    if (total != null && limit > 0) {
      hasMore = page < Math.ceil(total / limit);
    }
    if (data.has_more != null) {
      const more = flag(data.has_more);
      if (more == null) {
        throw new Error('野果分页信息无效，请重试');
      }
      hasMore = more;
    }
    if (hasMore && rows.length === 0) {
      throw new Error('野果未返回应有的目录页，请重试');
    }
    const items = [];
    const seen = new Set();
    for (const row of rows) {
      const item = dramaFromMap(row);
      if (!item) {
        throw new Error('野果剧集资料不完整');
      }
      if (seen.has(item.sourceId)) {
        throw new Error('野果目录包含重复剧集');
      }
      seen.add(item.sourceId);
      items.push(item);
    }
    return source.page(items, page, {hasMore: hasMore});
  },

  detail(ctx, id) {
    if (!/^\d+$/.test(String(id))) {
      throw new Error('野果剧集 ID 无效');
    }
    const row = apiCall(ctx, '/api/playlet/detail', {
      video_id: String(id), id: String(id), episode_id: '0', related_limit: '0',
    }, 'POST');
    const drama = dramaFromMap(row);
    if (!drama || drama.sourceId !== String(id)) {
      throw new Error('野果详情与请求剧集不符');
    }
    const episodes = row.episodes;
    if (!Array.isArray(episodes) || episodes.length > 10000) {
      throw new Error('野果分集目录格式无效');
    }
    const chapters = [];
    const seenIDs = new Set();
    const seenNumbers = new Set();
    for (const episode of episodes) {
      if (flag(episode && episode.is_adv) === true) continue;
      const chapterID = text(episode && episode.id);
      const number = source.int(episode && episode.sort, 100000);
      if (!/^\d+$/.test(chapterID) || number == null || number < 1 ||
          seenIDs.has(chapterID) || seenNumbers.has(number)) {
        throw new Error('野果分集编号无效或重复，请刷新详情');
      }
      seenIDs.add(chapterID);
      seenNumbers.add(number);
      const title = text(episode.title) || `第 ${number} 集`;
      chapters.push({id: chapterID, title: title.slice(0, 256), episode: number});
    }
    const normalized = source.chapters(chapters, {maxTitle: 256});
    drama.episodes = normalized.length;
    return {drama: drama, chapters: normalized};
  },

  resolve(ctx, task) {
    const dramaID = text(task.dramaId);
    const episodeID = text(task.chapterId);
    if (!/^\d+$/.test(dramaID) || !/^\d+$/.test(episodeID)) {
      throw new Error('野果播放分集 ID 无效');
    }
    const row = apiCall(ctx, '/api/playlet/play', {
      playlet_id: dramaID, video_id: dramaID, episode_id: episodeID,
    }, 'POST');
    if (text(row.playlet_id) !== dramaID || text(row.id) !== episodeID) {
      throw new Error('野果返回的播放地址与请求分集不符');
    }
    if (flag(row.is_adv) === true) {
      throw new Error('野果未返回该集正片，请重试');
    }
    const number = source.int(row.episode_sort, 100000);
    if (number == null || number < 1) {
      throw new Error('野果播放分集编号无效');
    }
    const quality = mediaQuality(text(row.resolution));
    let first = null;
    for (const field of ['video_url', 'video_url_h265']) {
      const raw = text(row[field]);
      if (!raw) continue;
      const address = resolveURL(episodePage(dramaID, number), raw);
      if (!address) continue;
      const media = {url: address, referer: episodePage(dramaID, number), quality: quality};
      if (!first) first = media;
    }
    if (!first) {
      throw new Error('野果未提供该集播放地址，请重试或确认站源权限');
    }
    return first;
  },
});

// —— 配置发现：站点页面 → module 脚本 → 接口基址与 AES 参数 ——

function access(ctx) {
  const cached = hg.storage.get('access');
  if (cached) {
    const parsed = JSON.parse(cached);
    if (parsed && parsed.base && parsed.key && parsed.iv && parsed.signKey &&
        Date.now() - (parsed.loadedAt || 0) < 3600 * 1000) {
      return parsed;
    }
  }
  const site = base(ctx);
  const page = hg.fetch(site + '/', {headers: {Referer: site + '/'}});
  if (page.status !== 200) {
    throw new Error('野果页面请求失败 HTTP ' + page.status);
  }
  const document = hg.html.parse(page.body);
  let apiBase = nuxtAPIBase(document);
  const scripts = hg.html.findAll(document, 'script[type="module"]');
  let entry = '';
  for (const script of scripts) {
    const src = hg.html.attr(script, 'src') || '';
    entry = scriptURL(page.url || site + '/', src);
    if (entry) break;
  }
  if (!entry) {
    throw new Error('野果页面未提供接口配置脚本');
  }
  const entryBody = fetchText(ctx, entry, site + '/');
  if (!apiBase) {
    apiBase = scriptAPIBase(entryBody);
  }
  // 按 import 顺序尝试，优先无逗号的具名导入（与 Go 侧排序一致）。
  const imports = [...entryBody.matchAll(/import\s*\{([^{};]+)\}\s*from\s*["'`]([^"'`]+)["'`]/gs)]
    .map((match) => ({names: match[1], reference: match[2]}))
    .sort((a, b) => {
      const aComma = a.names.includes(',');
      const bComma = b.names.includes(',');
      return (aComma ? 1 : 0) - (bComma ? 1 : 0);
    });
  let config = null;
  const seen = new Set();
  for (const imported of imports) {
    if (config && apiBase) break;
    if (imported.names.length > 2400) continue;
    const address = scriptURL(entry, imported.reference);
    if (!address || seen.has(address)) continue;
    if (seen.size >= 20) break;
    seen.add(address);
    let body = '';
    try {
      body = fetchText(ctx, address, site + '/');
    } catch (_) {
      continue;
    }
    if (!apiBase) {
      apiBase = scriptAPIBase(body);
    }
    if (!config) {
      config = publicConfig(body);
    }
  }
  if (!config) {
    throw new Error('野果接口配置已变化，暂时无法解码，请稍后重试');
  }
  if (!apiBase) {
    throw new Error('野果接口地址未找到，请稍后重试');
  }
  const value = {
    base: apiBase,
    key: config.key,
    iv: config.iv,
    signKey: config.signKey,
    loadedAt: Date.now(),
  };
  hg.storage.set('access', JSON.stringify(value));
  return value;
}

// nuxtAPIBase 从 __NUXT_DATA__ 里读取 apiBaseURL（按引用表解析）。
function nuxtAPIBase(document) {
  const nodes = hg.html.findAll(document, 'script#__NUXT_DATA__');
  for (const node of nodes) {
    let table = null;
    try {
      table = JSON.parse(hg.html.text(node));
    } catch (_) {
      continue;
    }
    if (!Array.isArray(table) || table.length > 100000) continue;
    for (const entry of table) {
      if (!entry || typeof entry !== 'object' || Array.isArray(entry) || entry.apiBaseURL == null) {
        continue;
      }
      const reference = entry.apiBaseURL;
      if (Number.isInteger(reference) && reference >= 0 && reference < table.length) {
        const value = table[reference];
        if (typeof value === 'string' && value) {
          return value.replace(/\/+$/, '');
        }
      }
    }
  }
  return '';
}

// scriptAPIBase 从脚本里的 `baseURL:xxx()` 反查 `xxx=()=>"https://..."`。
function scriptAPIBase(script) {
  for (const call of script.matchAll(/baseURL:([a-zA-Z_$][a-zA-Z0-9_$]*)\(\)/g)) {
    const name = call[1];
    const pattern = new RegExp('(?:^|[^a-zA-Z0-9_$.])' + name + '=\\(\\)=>["\'`](https?://[^"\'`\\s]{1,512})["\'`]');
    const match = script.match(pattern);
    if (match) {
      const parsed = hg.url.parse(match[1]);
      if (parsed.valid) return match[1].replace(/\/+$/, '');
    }
  }
  return '';
}

// publicConfig 提取 AES-CBC 参数与签名密钥。
function publicConfig(script) {
  const fields = {};
  for (const match of script.matchAll(
    /\b(version|mode|padding|key|iv|sign_key)\s*:\s*(?:[a-zA-Z_$][a-zA-Z0-9_$]*\(\s*)?["'`]([^"'`\\\r\n]{1,512})["'`]/g,
  )) {
    fields[match[1]] = match[2];
  }
  if (fields.version !== 'v0' || fields.mode !== 'CBC' || fields.padding !== 'Pkcs7') {
    return null;
  }
  const config = {
    key: publicBytes(fields.key),
    iv: publicBytes(fields.iv),
    signKey: publicBytes(fields.sign_key),
  };
  if (![16, 24, 32].includes(config.key.length) || config.iv.length !== 16 ||
      !config.signKey.length || config.signKey.length > 128) {
    return null;
  }
  return config;
}

// publicBytes 与 Go yeguoPublicBytes 对齐：
// 含下划线时按下划线分隔的字节码解码（每段 0–255），否则按原文。
function publicBytes(value) {
  value = text(value);
  if (!value) return '';
  if (!value.includes('_')) return value;
  const decoded = [];
  for (const part of value.split('_')) {
    const number = Number(part);
    if (!Number.isInteger(number) || number < 0 || number > 255) return '';
    decoded.push(String.fromCharCode(number));
  }
  return decoded.join('');
}

// —— 请求与解密 ——

function apiCall(ctx, route, parameters, method) {
  const config = access(ctx);
  const values = {
    bundleId: 'com.pwa.mater', version: '1.3.2', oauth_type: 'web',
    language: 'zh', via: 'pwa', oauth_id: '', trace_id: '', token: '',
  };
  Object.assign(values, parameters);
  const query = hg.url.encodeQuery(values);
  const site = base(ctx);
  // ctx.host（测试/镜像）优先于站点内发现的接口基址。
  const apiBase = (ctx && ctx.host) || config.base;
  let url = apiBase + route;
  const options = {
    method: method,
    headers: {
      Accept: 'application/json, text/plain, */*',
      Origin: site,
      Referer: site + '/',
    },
  };
  if (method === 'GET') {
    url += '?' + query;
  } else {
    options.body = query;
    options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  const response = hg.fetch(url, options);
  if (response.status < 200 || response.status >= 300) {
    throw new Error('野果请求失败 HTTP ' + response.status);
  }
  const envelope = decodeObject(response.body);
  if (envelope.sign) {
    const expected = responseSignature(envelope, config.signKey);
    if (!expected || expected !== String(envelope.sign).toLowerCase()) {
      throw new Error('野果响应签名校验失败');
    }
  }
  // 与 Go decodeYeguoResponse 对齐：data 为字符串时视为 AES-CBC 密文，
  // 解密后的对象直接就是业务数据（不再套 status/data 外层）。
  if (typeof envelope.data === 'string') {
    const plain = hg.crypto.aesCBCDecrypt(envelope.data, toHex(config.key), config.iv);
    return decodeObject(plain);
  }
  const status = text(envelope.status);
  if (status !== '1') {
    if (status === '-1') {
      throw new Error('野果当前内容需要站源授权');
    }
    throw new Error('野果请求未完成：' + (text(envelope.msg).slice(0, 180) || '请稍后重试'));
  }
  if (!envelope.data || typeof envelope.data !== 'object') {
    throw new Error('野果返回的数据格式无效');
  }
  return envelope.data;
}

function decodeObject(body) {
  const value = JSON.parse(body);
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('野果返回的数据格式无效');
  }
  return value;
}

// responseSignature 与 Go yeguoResponseSignature 对齐：
// 字段名排序 → name=value 以 & 连接 → 拼 sign_key → SHA-256 → md5(hex)。
function responseSignature(envelope, signKey) {
  const names = Object.keys(envelope)
    .filter((name) => name !== 'sign' && name !== '_ver' && envelope[name] != null)
    .sort();
  const pieces = [];
  for (const name of names) {
    const value = envelope[name];
    let field;
    if (typeof value === 'string') {
      field = value;
    } else if (typeof value === 'number') {
      field = String(value);
    } else if (typeof value === 'boolean') {
      field = value ? 'true' : 'false';
    } else {
      return '';
    }
    if (name === 'data') {
      field = field.replace(/ /g, '+');
    }
    pieces.push(name + '=' + field);
  }
  const joined = pieces.join('&') + signKey;
  return hg.crypto.md5hex(hg.crypto.sha256hex(joined));
}

function toHex(bytes) {
  return [...bytes].map((char) => char.charCodeAt(0).toString(16).padStart(2, '0')).join('');
}

// —— 数据映射 ——

function dramaFromMap(row) {
  if (!row || typeof row !== 'object') return null;
  const id = text(row.video_id) || text(row.id);
  const title = text(row.title);
  if (!/^\d+$/.test(id) || !title) return null;
  let episodes = 0;
  for (const key of ['episode_count', 'episodes', 'total_serial']) {
    const count = source.int(row[key], 100000);
    if (count != null) episodes = Math.max(episodes, count);
  }
  let status = '';
  switch (text(row.serialize_status)) {
    case '1': status = 'ongoing'; break;
    case '2': status = 'finished'; break;
  }
  const tags = source.tags(Array.isArray(row.tags) ? row.tags : [], {limit: 32});
  const result = {
    sourceId: id,
    title: title.slice(0, 512),
    description: text(row.description).slice(0, 12000),
    cover: source.cover(row.cover),
    episodes: episodes,
    category: '短剧',
    views: text(row.play_count) || text(row.play_count_text),
    tags: tags,
    releaseStatus: status,
    onlineDate: releaseDate(text(row.published_at) || text(row.created_at)),
  };
  const vip = flag(row.is_vip);
  if (vip != null) result.vip = vip;
  return result;
}

function releaseDate(value) {
  value = text(value);
  if (!value) return '';
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return match ? match[1] + '-' + match[2] + '-' + match[3] : '';
}

function mediaQuality(resolution) {
  const parts = String(resolution || '').toLowerCase().split('x');
  if (parts.length !== 2) return 0;
  const width = source.int(parts[0], 16384);
  const height = source.int(parts[1], 16384);
  if (width == null || height == null || width < 1 || height < 1) return 0;
  return Math.min(width, height);
}

function episodePage(dramaID, number) {
  let address = source.baseURL + '/drama/video/' + dramaID + '/';
  if (number > 1) {
    address += 'ep-' + number + '/';
  }
  return address;
}

// resolveURL 相对地址归一（与 Go resolveProviderURL 对齐的常用分支）。
const resolveURL = hgkit.url;

// —— 工具 ——

function base(ctx) {
  return source.base(ctx);
}

function fetchText(ctx, address, referer) {
  return source.getText(ctx, address, {
    label: '野果资源',
    headers: {Referer: referer},
  });
}

function scriptURL(baseURL, reference) {
  reference = text(reference);
  if (!reference) return '';
  if (/^https?:\/\//i.test(reference)) return normalizePath(reference);
  const parsed = hg.url.parse(baseURL);
  if (!parsed.valid) return '';
  if (reference.startsWith('//')) return normalizePath('https:' + reference);
  if (reference.startsWith('/')) {
    return normalizePath(parsed.protocol + '://' + parsed.host + reference);
  }
  return normalizePath(baseURL.replace(/[^/]*$/, '') + reference);
}

// normalizePath 折叠路径中的 ./ 与 ../ 段，避免服务器收到非规范路径。
function normalizePath(address) {
  const match = address.match(/^(https?:\/\/[^/]+)(\/.*)?$/i);
  if (!match) return address;
  const origin = match[1];
  const segments = [];
  for (const segment of (match[2] || '/').split('/')) {
    if (!segment || segment === '.') continue;
    if (segment === '..') {
      segments.pop();
      continue;
    }
    segments.push(segment);
  }
  const query = (match[2] || '').includes('?') ? '?' + (match[2].split('?')[1] || '') : '';
  return origin + '/' + segments.join('/') + query;
}

const text = (value) => source.text(value);


function firstPresent(data, keys) {
  for (const key of keys) {
    if (data[key] != null && text(data[key]) !== '') return data[key];
  }
  return null;
}

// flag 解析布尔标记：兼容 bool 与 "0"/"1"/"false"/"true"。
function flag(value) {
  if (typeof value === 'boolean') return value;
  const textValue = text(value);
  if (textValue === '0' || textValue === 'false') return false;
  if (textValue === '1' || textValue === 'true') return true;
  return null;
}

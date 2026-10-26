// ==HongguoExtension==
// @id dsd
// @name 帝果
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description 分类视频 · 在线搜索
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==

// 帝果扩展源：MacCMS 风格 HTML 站点的 JS 移植（与原 Go provider 对齐）。
//
// 站点结构：
//   /index.php/vod/type/id/{cat}/page/{n}.html   分类目录
//   /index.php/vod/search.html?wd=&page=         站内搜索
//   /index.php/vod/play/id/{id}/sid/{line}/nid/{ep}.html  播放页
//   /addons/vplayer/?url={path}&jump=            播放地址签名（aaencode）
//
// 与原 Go 实现的差异仅在于并发模型：Go 版按分类并发聚合首页，
// 这里用 hg.fetchAll 并行拉取（js 单线程无法自行并发），合并顺序一致。
globalThis.source = hgkit.defineSource({
  name: '帝果',
  baseURL: 'https://www.dsd.com.se',
  pageSize: 20,
  userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',

  categories(ctx, force) {
    const page = get(ctx, '/');
    const categories = parseCategories(page.body, page.url);
    if (!categories.length) {
      throw new Error('帝果未返回有效的内容分类');
    }
    if (categories.length > 32) {
      throw new Error('帝果分类条目过多');
    }
    return categories;
  },

  validCategory(category) {
    return category === '' || /^[1-9][0-9]{0,17}$/.test(category);
  },

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 1000000 || query.length > 1024) {
      throw new Error('帝果目录查询参数无效');
    }
    if (query) {
      return catalogSearch(ctx, page, query);
    }
    const categories = source.categories(ctx, false);
    if (category) {
      const active = categories.find((entry) => entry.id === category);
      if (!active) {
        throw new Error('帝果分类已变化，请刷新分类');
      }
      return catalogPage(ctx, page, active);
    }
    // 首页：全部一级分类并行聚合，按条目序号交错合并（与原 Go 版一致）。
    const requests = categories.map((entry) => ({
      url: categoryURL(ctx, entry.id, page),
      options: {headers: {Referer: base(ctx) + '/', 'User-Agent': source.userAgent}},
    }));
    const responses = hg.fetchAll(requests);
    const results = [];
    let hasMore = false;
    let count = 0;
    const failures = [];
    responses.forEach((response, index) => {
      if (response.error) {
        failures.push(categories[index].name + '：' + response.error);
        hasMore = true;
        return;
      }
      try {
        const parsed = parseCatalogPage(response.body, requests[index].url, categories[index].name, page);
        results.push(parsed.items);
        hasMore = hasMore || parsed.hasMore;
        count = Math.max(count, parsed.items.length);
      } catch (error) {
        failures.push(categories[index].name + '：' + error.message);
        hasMore = true;
      }
    });
    const items = [];
    const seen = new Set();
    for (let index = 0; index < count; index++) {
      for (const list of results) {
        if (index >= list.length) continue;
        const item = list[index];
        if (seen.has(item.sourceId)) continue;
        seen.add(item.sourceId);
        items.push(item);
      }
    }
    if (failures.length && !items.length) {
      throw new Error(failures.join('；'));
    }
    // 原 Go 实现用 errors.Join 保留部分成功：有条目时不让单个分类失败中断整页。
    return {items: items, hasMore: hasMore};
  },

  detail(ctx, id) {
    const sourceID = String(id);
    if (!/^[1-9][0-9]{0,17}$/.test(sourceID)) {
      throw new Error('帝果视频 ID 无效');
    }
    const page = get(ctx, episodePath(sourceID, 1, 1));
    return parseDetail(page.body, page.url, sourceID, base(ctx));
  },

  resolve(ctx, task) {
    const sourceID = text(task.dramaId);
    if (!/^[1-9][0-9]{0,17}$/.test(sourceID)) {
      throw new Error('帝果播放信息无效，请刷新详情');
    }
    // chapterId 形如 "1-2"（线路-集数），由 detail 生成。
    const parts = text(task.chapterId).split('-');
    if (parts.length !== 2) {
      throw new Error('帝果播放分集无效');
    }
    const line = integer(parts[0], 1000000);
    const episode = integer(parts[1], 1000000);
    if (line == null || line < 1 || episode == null || episode < 1) {
      throw new Error('帝果播放分集无效');
    }
    const page = get(ctx, episodePath(sourceID, line, episode));
    const player = parsePlayer(page.body);
    assertDetailIdentity(page.body, sourceID, player);
    let address = '';
    if (player.value) {
      const actual = playerIdentity(player.value, sourceID);
      if (actual == null || actual.line !== line || actual.episode !== episode) {
        throw new Error('帝果返回的播放地址与请求分集不符');
      }
      const preview = integer(player.value.trysee, 86400);
      if (preview != null && preview > 0) {
        throw new Error('帝果仅提供试看，暂未取得正片播放地址');
      }
      address = issuedMedia(player.value, page.url);
    }
    if (!address) {
      if (line !== 1 || episode !== 1) {
        throw new Error('帝果未提供该分集的播放地址');
      }
      const box = hg.html.findFirst(hg.html.parse(page.body), '.video-box');
      const cover = firstPresent([
        coverAddress(player.value && player.value.poster, page.url),
        cardCover(box, page.url),
      ]);
      address = mediaFromPagePath(cover, page.url);
    }
    if (!address) {
      throw new Error('帝果未提供播放地址，请重试或确认站源权限');
    }
    const site = base(ctx);
    const signed = signMedia(ctx, address, page.url);
    const referer = signed.byVplayer || signed.address.includes('sign=')
      ? vplayerReferer(site)
      : page.url;
    return {
      url: signed.address,
      referer: referer,
      credentials: {origin: originOf(signed.address), referer: referer, userAgent: source.userAgent},
    };
  },




  rankingBoards(ctx) {
    // 原 Go 版把「分类目录聚合顺序」当作榜单；这里声明同一份语义。
    return [{
      id: 'dsd-catalog',
      name: '目录榜',
      description: '帝果分类目录聚合顺序，按源站返回顺序展示。',
      data: 'catalog',
    }];
  },

  rankings(ctx, boardId, data, page) {
    // 目录榜单只有一页：直接复用首页聚合结果。
    if (page !== 1) {
      return {items: [], hasMore: false, totalPages: 1};
    }
    const catalog = source.catalog(ctx, 1, '', '');
    return {items: catalog.items, hasMore: false, totalPages: 1};
  },
});

// —— 目录 ——

function base(ctx) {
  return source.base(ctx);
}

// categoryPath 返回相对路径：get() 会拼上当前 base（测试/镜像时是 ctx.host）。
function categoryPath(id, page) {
  return '/index.php/vod/type/id/' + encodeURIComponent(id) + '/page/' + page + '.html';
}

// categoryURL 返回绝对地址，供 hg.fetchAll 直接使用。
function categoryURL(ctx, id, page) {
  return base(ctx) + categoryPath(id, page);
}

function get(ctx, path) {
  const address = /^https?:\/\//i.test(path) ? path : base(ctx) + path;
  const body = source.getText(ctx, path, {
    label: '帝果页面',
    headers: {'User-Agent': source.userAgent},
  });
  return {body: body, url: address};
}

// catalogPage 拉取单个分类的一页并解析。
function catalogPage(ctx, page, category) {
  const response = get(ctx, categoryPath(category.id, page));
  return parseCatalogPage(response.body, response.url, category.name, page);
}

function parseCategories(body, pageURL) {
  const document = hg.html.parse(body);
  const seen = new Set();
  const categories = [];
  for (const anchor of hg.html.findAll(document, 'a')) {
    const route = routeParameters(pageURL, hg.html.attr(anchor, 'href'));
    if (!route || route.action !== 'type') continue;
    const id = route.values.id;
    const name = text(hg.html.text(anchor));
    if (!/^[1-9][0-9]{0,17}$/.test(id || '') || !name || [...name].length > 48) continue;
    if (seen.has(id)) continue;
    seen.add(id);
    categories.push({id: id, name: name});
  }
  return categories;
}

// routeParameters 解析 MacCMS 的 /vod/{action}/k/v/... 形态，
// 返回 {action, values}；跨域或结构不符时返回 null。
function routeParameters(pageURL, reference) {
  reference = text(reference);
  if (!reference) return null;
  const resolved = resolveURL(pageURL, reference);
  if (!resolved) return null;
  const parsed = hg.url.parse(resolved);
  const page = hg.url.parse(pageURL);
  if (!parsed.valid || !page.valid || parsed.hostname !== page.hostname) return null;
  let path = parsed.path;
  if (path.startsWith('/index.php')) path = path.slice('/index.php'.length);
  path = path.replace(/\.html$/i, '');
  const parts = path.split('/').filter((part) => part !== '');
  if (parts.length < 2 || parts[0] !== 'vod' || parts.length % 2 !== 0) return null;
  const actions = ['type', 'show', 'search', 'play', 'detail'];
  if (!actions.includes(parts[1])) return null;
  const values = {};
  for (let index = 2; index + 1 < parts.length; index += 2) {
    values[parts[index]] = decodeURIComponent(parts[index + 1]);
  }
  if (parsed.query) {
    for (const pair of parsed.query.split('&')) {
      const [rawKey, rawValue] = pair.split('=');
      const key = decodeURIComponent(rawKey || '');
      if (key && values[key] == null) {
        values[key] = decodeURIComponent(rawValue || '');
      }
    }
  }
  return {action: parts[1], values: values};
}

function albumURL(id, action) {
  return source.baseURL + '/index.php/vod/' + (action || 'detail') + '/id/' + encodeURIComponent(id) + '.html';
}

function parseCatalogPage(body, pageURL, category, page) {
  const document = hg.html.parse(body);
  const items = [];
  const seen = new Set();
  for (const card of hg.html.findAll(document, 'a.video-item, a.video-surface')) {
    const route = routeParameters(pageURL, hg.html.attr(card, 'href'));
    if (!route || (route.action !== 'play' && route.action !== 'detail')) continue;
    const id = route.values.id;
    if (!/^[1-9][0-9]{0,17}$/.test(id || '') || seen.has(id)) continue;
    let title = firstPresent([
      nodeText(hg.html.findFirst(card, '.video-desc, .surface-title, .video-title, .title')),
      hg.html.attr(card, 'title'),
    ]);
    if (!title) {
      for (const image of hg.html.findAll(card, 'img')) {
        title = text(hg.html.attr(image, 'alt'));
        if (title) break;
      }
    }
    if (!title) {
      throw new Error('帝果目录缺少视频名称');
    }
    seen.add(id);
    const item = {
      sourceId: id,
      title: title.slice(0, 1024),
      cover: cardCover(card, pageURL),
      category: category || '视频',
      channelName: '帝果',
      views: text(hg.html.text(hg.html.findFirst(card, '.video-item-tag-hits, .counts'))).replace(/次$/, ''),
    };
    if (hg.html.findFirst(card, '.video-item-tag-is-vip, .vip-tag')) {
      item.vip = true;
    }
    items.push(item);
    if (items.length > 500) {
      throw new Error('帝果目录条目过多');
    }
  }
  const pages = pagination(document, pageURL, category, page);
  if (items.length === 0 && !hg.html.findFirst(document, '.video-contaner, .nvyou-wrap, .van-list, .search-page, .lists')) {
    throw new Error('帝果未返回内容列表，页面可能已变化');
  }
  if (items.length === 0 && pages > page) {
    throw new Error('帝果未返回应有的视频条目，请重试');
  }
  return {items: items, hasMore: pages > page};
}

// pagination 读取分页容器里的最大页码，并校验当前页与请求一致。
function pagination(document, pageURL, category, page) {
  const container = hg.html.findFirst(document, '.el-pagination, .pagination, .mac_pages');
  if (!container) {
    if (page !== 1) {
      throw new Error('帝果未返回请求页码，请重试');
    }
    return 1;
  }
  let active = null;
  for (const node of hg.html.findAll(container, '.active.number, .page-current')) {
    active = integer(hg.html.text(node), 1000000);
    break;
  }
  if (active !== page) {
    throw new Error('帝果返回的页码与请求不符');
  }
  let pages = page;
  for (const anchor of hg.html.findAll(container, 'a')) {
    const route = routeParameters(pageURL, hg.html.attr(anchor, 'href'));
    if (!route) continue;
    const value = integer(route.values.page, 1000000);
    if (value != null && value > pages) pages = value;
  }
  return pages;
}

function cardCover(card, pageURL) {
  if (!card) return '';
  for (const image of hg.html.findAll(card, 'img')) {
    for (const attribute of ['data-src', 'data-original']) {
      const address = coverAddress(hg.html.attr(image, attribute), pageURL);
      if (address) return address;
    }
  }
  for (const node of hg.html.findAll(card, '.img-bg, .surface-img, .openVip, .video-before-ad')) {
    const style = hg.html.attr(node, 'style') || '';
    const match = style.match(/url\(\s*["']?([^"')]+)/i);
    if (match) {
      const address = coverAddress(match[1], pageURL);
      if (address) return address;
    }
  }
  for (const image of hg.html.findAll(card, 'img')) {
    const raw = hg.html.attr(image, 'src');
    if (raw && (raw.startsWith('/video') || raw.includes('/upload'))) {
      const address = coverAddress(raw, pageURL);
      if (address) return address;
    }
  }
  return '';
}

// —— 搜索与详情 ——

function catalogSearch(ctx, page, query) {
  const response = get(ctx, '/index.php/vod/search.html?wd=' + encodeURIComponent(query) + '&page=' + page);
  return parseCatalogPage(response.body, response.url, '', page);
}

function episodePath(id, line, episode) {
  return '/index.php/vod/play/id/' + encodeURIComponent(id) + '/sid/' + line + '/nid/' + episode + '.html';
}

function parseDetail(body, pageURL, sourceID, site) {
  const document = hg.html.parse(body);
  const player = parsePlayer(body);
  assertDetailIdentity(body, sourceID, player);
  let line = 1;
  let current = 1;
  if (player.value) {
    const identity = playerIdentity(player.value, sourceID);
    if (identity) {
      line = identity.line;
      current = identity.episode;
    }
  }
  const info = hg.html.findFirst(document, '.video-info');
  const box = hg.html.findFirst(document, '.video-box');
  const data = (player.value && player.value.vod_data) || {};
  let title = text(data.vod_name);
  if (!title) {
    for (const heading of hg.html.findAll(info, 'h1, h2, h3')) {
      title = text(hg.html.text(heading));
      if (title) break;
    }
  }
  if (!title) {
    throw new Error('帝果详情缺少视频名称');
  }
  const cover = firstPresent([
    coverAddress(player.value && player.value.poster, pageURL),
    cardCover(box, pageURL),
  ]);
  const description = hg.html.text(hg.html.findFirst(info, '.desc')).slice(0, 12000);
  const vip = Boolean(hg.html.findFirst(box, '.noVip, .openVip'));
  const tagValues = [];
  for (const tag of text(data.vod_class).split(',')) tagValues.push(tag);
  for (const anchor of hg.html.findAll(hg.html.findFirst(info, '.labels'), 'a')) {
    tagValues.push(hg.html.text(anchor));
  }
  const tags = source.tags(tagValues, {limit: 32});

  const chapters = [];
  const seenEpisodes = new Set([current]);
  const addEpisode = (reference, title) => {
    const route = routeParameters(pageURL, reference);
    if (!route || route.action !== 'play' || route.values.id !== sourceID) return;
    const candidateLine = integer(route.values.sid, 1000000);
    const episode = integer(route.values.nid, 1000000);
    if (candidateLine == null || candidateLine !== line) return;
    if (episode == null || episode < 1 || seenEpisodes.has(episode)) return;
    seenEpisodes.add(episode);
    chapters.push(chapterRow(site, sourceID, line, episode, title, vip));
  };
  for (const anchor of hg.html.findAll(document, 'a')) {
    addEpisode(hg.html.attr(anchor, 'href'), hg.html.text(anchor));
  }
  if (player.value) {
    addEpisode(player.value.link_pre, '');
    addEpisode(player.value.link_next, '');
  }
  chapters.push(chapterRow(site, sourceID, line, current, '', vip));
  if (chapters.length > 10000) {
    throw new Error('帝果分集目录过大');
  }
  const normalized = source.chapters(chapters, {maxTitle: 256});
  if (normalized.length === 1) {
    normalized[0].title = '正片';
  }
  return {
    drama: {
      sourceId: sourceID,
      title: title.slice(0, 1024),
      description: description,
      cover: cover,
      channelName: '帝果',
      tags: tags,
      vip: vip || undefined,
    },
    chapters: normalized,
  };
}

function chapterRow(site, sourceID, line, episode, title, vip) {
  return {
    // 章节 ID 带线路信息：多线路站点同一集在不同线路的地址不同。
    id: line + '-' + episode,
    title: (text(title) || '第 ' + episode + ' 集').slice(0, 256),
    episode: episode,
    pageUrl: site + episodePath(sourceID, line, episode),
    referer: site + '/',
    vip: vip || undefined,
  };
}

// —— 播放器参数与签名 ——

// parsePlayer 从页面脚本里的 player_xxx = {...} 读取播放器参数。
function parsePlayer(body) {
  for (const script of scriptBodies(body)) {
    const pattern = /\bplayer_[a-zA-Z0-9_]+\s*=\s*/g;
    let match;
    while ((match = pattern.exec(script)) !== null) {
      const start = match.index + match[0].length;
      const value = parseLeadingJSON(script.slice(start));
      if (value === null) {
        throw new Error('帝果播放器参数格式无效');
      }
      if (value && value.id != null && value.url != null) {
        return {value: value, found: true};
      }
    }
  }
  return {value: null, found: false};
}

// parseLeadingJSON 解析字符串开头的一个完整 JSON 对象。
function parseLeadingJSON(raw) {
  const start = raw.indexOf('{');
  if (start !== 0) {
    // 允许前导空白。
    if (raw.slice(0, start).trim() !== '') return null;
  }
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < raw.length; index++) {
    const char = raw[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === '{') depth++;
    else if (char === '}') {
      depth--;
      if (depth === 0) {
        try {
          return JSON.parse(raw.slice(start, index + 1));
        } catch (error) {
          return null;
        }
      }
    }
  }
  return null;
}

function scriptBodies(body) {
  const document = hg.html.parse(body);
  const scripts = [];
  for (const node of hg.html.findAll(document, 'script')) {
    // 必须用 text 而不是 inner：inner 会把引号转义成 HTML 实体（&#34;），
    // 导致脚本内的 JSON 无法解析；Go 版取的是文本节点原文。
    const inner = hg.html.text(node);
    if (inner) scripts.push(inner);
  }
  return scripts;
}

function playerIdentity(player, sourceID) {
  const line = integer(player.sid, 1000000);
  const episode = integer(player.nid, 1000000);
  if (text(player.id) !== sourceID || line == null || line < 1 || episode == null || episode < 1) {
    return null;
  }
  return {line: line, episode: episode};
}

// assertDetailIdentity 校验页面确实是请求的视频：
// 优先用播放器参数，其次是详情区的 data-id 标记。
function assertDetailIdentity(body, sourceID, player) {
  if (player.found) {
    if (!playerIdentity(player.value, sourceID)) {
      throw new Error('帝果播放器与请求视频不符');
    }
    return;
  }
  const document = hg.html.parse(body);
  const info = hg.html.findFirst(document, '.video-info');
  for (const node of hg.html.findAll(info, '[data-id]')) {
    if (hg.html.attr(node, 'data-id') === sourceID) return;
  }
  throw new Error('帝果未返回所请求视频的详情');
}

// issuedMedia 解码播放器里的 url 字段（encrypt 0/1/2）。
function issuedMedia(player, pageURL) {
  let address = text(player.url);
  if (!address) return '';
  const mode = text(player.encrypt);
  if (mode === '' || mode === '0') {
    // 原样使用
  } else if (mode === '1') {
    try {
      address = decodeURIComponent(address);
    } catch (error) {
      throw new Error('帝果播放地址编码无效');
    }
  } else if (mode === '2') {
    let decoded = '';
    try {
      decoded = hg.crypto.base64decode(address);
    } catch (error) {
      // 兼容无填充的 base64。
      try {
        decoded = hg.crypto.base64decode(address + '='.repeat((4 - (address.length % 4)) % 4));
      } catch (inner) {
        throw new Error('帝果播放地址编码无效');
      }
    }
    try {
      address = decodeURIComponent(decoded);
    } catch (error) {
      throw new Error('帝果播放地址编码无效');
    }
  } else {
    throw new Error('帝果播放地址编码已变化');
  }
  const resolved = resolveURL(pageURL, address);
  if (!resolved || !isMediaURL(resolved)) {
    throw new Error('帝果播放地址无效');
  }
  return resolved;
}

function vplayerReferer(site) {
  return site.replace(/\/+$/, '') + '/addons/vplayer/';
}

// mediaFromPagePath 从封面路径推导播放列表（后台上传约定：/video*/1.jpg → /1000k/index.m3u8）。
function mediaFromPagePath(cover, pageURL) {
  const address = hg.url.parse(text(cover));
  const page = hg.url.parse(pageURL);
  if (!address.valid || !page.valid) return '';
  if (address.hostname !== page.hostname) return '';
  if (!/^\/video[0-9]*\//.test(address.path)) return '';
  if (!/\/1\.(?:jpg|jpeg|png|webp)$/i.test(address.path)) return '';
  return address.protocol + '://' + address.host + address.path.replace(/\/1\.(?:jpg|jpeg|png|webp)$/i, '/1000k/index.m3u8');
}

// signMedia 经 vplayer 换取带 sign 的播放路径；失败时保留原地址（与原 Go 版一致）。
function signMedia(ctx, address, pageURL) {
  if (address.includes('sign=')) {
    return {address: address, byVplayer: false};
  }
  const parsed = hg.url.parse(address);
  if (!parsed.valid) {
    return {address: address, byVplayer: false};
  }
  const mediaPath = parsed.path + (parsed.query ? '?' + parsed.query : '');
  const endpoint = '/addons/vplayer/?url=' + encodeURIComponent(mediaPath) + '&jump=';
  let body = '';
  try {
    body = get(ctx, endpoint).body;
  } catch (error) {
    // 签名模块不可用不影响直链播放（与原 Go 版一致）。
    return {address: address, byVplayer: false};
  }
  const signedPath = signedPathFromVplayer(body);
  if (!signedPath) {
    return {address: address, byVplayer: false};
  }
  const resolved = resolveURL(vplayerReferer(base(ctx)), signedPath);
  if (!resolved || !isMediaURL(resolved)) {
    throw new Error('帝果播放签名地址无效');
  }
  return {address: resolved, byVplayer: true};
}

// signedPathFromVplayer 解码页面里的 aaencode 脚本并取出 vPath。
function signedPathFromVplayer(body) {
  for (const script of scriptBodies(body)) {
    if (script.indexOf('(ﾟДﾟ)') < 0) continue;
    const decoded = decodeAaencode(script);
    if (!decoded) continue;
    const match = decoded.match(/\bvar\s+vPath\s*=\s*["']([^"']+)["']/);
    if (match) {
      return match[1].trim();
    }
  }
  return '';
}

// decodeAaencode 解 aaencode：字符以表情数字表达，按八进制码点还原。
function decodeAaencode(raw) {
  if (raw.length > 1 << 20) return '';
  const marker = "(ﾟДﾟ) ['_'] ( (ﾟДﾟ) ['_']";
  const tailMarker = '+ (ﾟДﾟ)[ﾟoﾟ]';
  const start = raw.indexOf(marker);
  if (start < 0) return '';
  const body = raw.slice(start);
  const end = body.lastIndexOf(tailMarker);
  if (end < 0) return '';
  const tokens = body.slice(0, end).split('(ﾟДﾟ)[ﾟεﾟ]+');
  let decoded = '';
  for (let index = 1; index < tokens.length; index++) {
    if (decoded.length > 64 << 10) return '';
    let digits = '';
    for (const part of splitTopLevel(tokens[index])) {
      const digit = aaDigit(part);
      if (digit === null) return '';
      digits += digit;
    }
    if (digits.startsWith('u') && digits.length === 5) {
      const code = parseInt(digits.slice(1), 16);
      if (!Number.isFinite(code)) return '';
      decoded += String.fromCodePoint(code);
    } else if (digits && /^[0-7]+$/.test(digits)) {
      const code = parseInt(digits, 8);
      if (!Number.isFinite(code)) return '';
      decoded += String.fromCodePoint(code);
    }
  }
  return decoded;
}

// splitTopLevel 按顶层 '+' 切分（括号内的加法属于同一项）。
function splitTopLevel(value) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < value.length; index++) {
    const char = value[index];
    if (char === '(') depth++;
    else if (char === ')') {
      if (depth > 0) depth--;
    } else if (char === '+' && depth === 0) {
      const part = value.slice(start, index).trim();
      if (part) parts.push(part);
      start = index + 1;
    }
  }
  const tail = value.slice(start).trim();
  if (tail) parts.push(tail);
  return parts;
}

// aaDigit 把一段表情表达式还原为 0-7 或 'u'（十六进制标记）。
function aaDigit(part) {
  part = part.trim();
  if (!part) return null;
  if (part.includes('(oﾟｰﾟo)')) return 'u';
  if (part.includes('(ﾟДﾟ).ﾟΘﾟﾉ')) return 'b';
  const replacements = [
    ['(c^_^o)', '0'],
    ['(ﾟΘﾟ)', '1'],
    ['(o^_^o)', '3'],
    ['(ﾟｰﾟ)', '4'],
  ];
  for (const [from, to] of replacements) {
    part = part.split(from).join(to);
  }
  const value = evaluateDigitExpression(part);
  return value == null ? null : String(value);
}

// evaluateDigitExpression 只接受数字、括号与 +-*/%，避免把网页脚本当 JS eval。
function evaluateDigitExpression(value) {
  if (value.length > 4096 || /[^0-9()+\-*/% \t\r\n]/.test(value)) return null;
  const parser = {text: value, index: 0, depth: 0};
  const result = parseExpression(parser);
  if (result == null) return null;
  skipSpaces(parser);
  return parser.index === parser.text.length ? result : null;
}

function skipSpaces(parser) {
  while (parser.index < parser.text.length && ' \t\r\n'.includes(parser.text[parser.index])) {
    parser.index++;
  }
}

function parseExpression(parser) {
  let value = parseTerm(parser);
  if (value == null) return null;
  for (;;) {
    skipSpaces(parser);
    const char = parser.text[parser.index];
    if (char !== '+' && char !== '-') return value;
    parser.index++;
    const right = parseTerm(parser);
    if (right == null) return null;
    value = char === '+' ? value + right : value - right;
  }
}

function parseTerm(parser) {
  let value = parseFactor(parser);
  if (value == null) return null;
  for (;;) {
    skipSpaces(parser);
    const char = parser.text[parser.index];
    if (char !== '*' && char !== '/' && char !== '%') return value;
    parser.index++;
    const right = parseFactor(parser);
    if (right == null) return null;
    if (char === '*') value *= right;
    else if (char === '/') {
      if (right === 0 || value % right !== 0) return null;
      value /= right;
    } else {
      if (right === 0) return null;
      value %= right;
    }
  }
}

function parseFactor(parser) {
  skipSpaces(parser);
  let sign = 1;
  while (parser.text[parser.index] === '+' || parser.text[parser.index] === '-') {
    if (parser.text[parser.index] === '-') sign = -sign;
    parser.index++;
    skipSpaces(parser);
  }
  if (parser.index >= parser.text.length) return null;
  if (parser.text[parser.index] === '(') {
    if (parser.depth >= 32) return null;
    parser.depth++;
    parser.index++;
    const value = parseExpression(parser);
    parser.depth--;
    skipSpaces(parser);
    if (value == null || parser.text[parser.index] !== ')') return null;
    parser.index++;
    return sign * value;
  }
  const start = parser.index;
  while (parser.index < parser.text.length && parser.text[parser.index] >= '0' && parser.text[parser.index] <= '9') {
    parser.index++;
  }
  if (start === parser.index) return null;
  return sign * parseInt(parser.text.slice(start, parser.index), 10);
}

// —— 通用工具 ——

const text = (value) => source.text(value);
const firstPresent = (values) => source.first(values);
const resolveURL = hgkit.url;
const coverAddress = hgkit.url;
const isMediaURL = (value) => source.isMediaURL(value);

function integer(value, maximum) {
  const raw = text(value);
  if (!/^-?\d+$/.test(raw)) return null;
  const number = Number(raw);
  if (!Number.isInteger(number) || number < 0 || number > maximum) return null;
  return number;
}

function nodeText(node) {
  return node ? text(hg.html.text(node)) : '';
}

function originOf(address) {
  const parsed = hg.url.parse(text(address));
  return parsed.valid ? parsed.protocol + '://' + parsed.host : '';
}

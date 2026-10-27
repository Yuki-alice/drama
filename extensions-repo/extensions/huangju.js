// ==HongguoExtension==
// @id huangju
// @name 剧果
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description 热门 · 最新 · 分类短剧
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==

// 剧果扩展源：JSON API 的 JS 移植（与 Go provider 对齐）。
// 接口：POST /auth/guest 访客令牌（deviceId 持久化）、GET /categories、
// /dramas?page=&sort=|category=|q= 目录、/dramas/{slug-id} 详情、/play/{id} 播放
// （返回 CloudFront 签名 Cookie，经 credentials 透传给宿主）。
globalThis.source = hgkit.defineSource({
  name: '剧果',
  baseURL: 'https://api.huangju.net',
  pageSize: 20,
  site: 'https://huangju.net',
  userAgent: 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36',

  categories(ctx, force) {
    const value = apiGet(ctx, '/categories');
    const rows = Array.isArray(value) ? value : null;
    if (!rows || rows.length > 300) {
      throw new Error('剧果分类数据格式无效');
    }
    const categories = [{id: '@new', name: '最新'}];
    const seen = new Set(['@new']);
    for (const row of rows) {
      const id = text(row && row.slug);
      const name = text(row && row.name);
      if (id === 'hot') continue;
      if (!validCategoryID(id) || !id || !name || [...name].length > 48 || seen.has(id)) {
        throw new Error('剧果分类数据包含无效或重复条目');
      }
      seen.add(id);
      categories.push({id: id, name: name});
    }
    return categories;
  },

  validCategory(category) {
    if (category === '' || category === '@new') return true;
    return validCategoryID(category);
  },

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 1000000 || query.length > 1024 || !source.validCategory(category)) {
      throw new Error('剧果目录查询参数无效');
    }
    let route = '/dramas?page=' + page;
    if (query) {
      route += '&q=' + encodeURIComponent(query);
    } else if (category === '@new') {
      route += '&sort=new';
    } else if (category === '') {
      route += '&sort=hot';
    } else {
      route += '&category=' + encodeURIComponent(category);
    }
    const row = apiGet(ctx, route);
    if (!row || typeof row !== 'object' || Array.isArray(row)) {
      throw new Error('剧果目录数据格式无效');
    }
    const rows = row.items;
    if (!Array.isArray(rows) || rows.length > 500) {
      throw new Error('剧果目录数据格式无效');
    }
    let pageSize = 20;
    if (row.pageSize != null) {
      pageSize = source.int(row.pageSize, 500);
      if (pageSize == null || pageSize < 1) {
        throw new Error('剧果分页数据格式无效');
      }
    }
    if (row.page != null) {
      const actualPage = source.int(row.page, 1000000);
      if (actualPage == null || actualPage !== page) {
        throw new Error('剧果返回的页码与请求不符');
      }
    }
    if (rows.length > pageSize) {
      throw new Error('剧果分页数据格式无效');
    }
    let hasMore = rows.length >= pageSize;
    if (row.total != null) {
      const total = source.int(row.total, 100000000);
      if (total == null || total < rows.length) {
        throw new Error('剧果分页总数无效');
      }
      hasMore = page < Math.ceil(total / pageSize);
    }
    if (hasMore && rows.length === 0) {
      throw new Error('剧果未返回应有的目录页，请重试');
    }
    const items = [];
    const seen = new Set();
    for (const entry of rows) {
      const item = dramaFromMap(entry, '');
      if (!item) {
        throw new Error('剧果返回的剧集信息不完整');
      }
      if (seen.has(item.sourceId)) {
        throw new Error('剧果目录包含重复剧集，请重试');
      }
      seen.add(item.sourceId);
      items.push(item);
    }
    return source.page(items, page, {hasMore: hasMore});
  },

  detail(ctx, id) {
    if (!validID(id)) {
      throw new Error('剧果剧集地址无效');
    }
    const row = apiGet(ctx, '/dramas/' + encodeURIComponent(id));
    const drama = dramaFromMap(row, id);
    if (!drama) {
      throw new Error('剧果返回的剧集信息不完整');
    }
    const rows = row && row.episodes;
    if (!Array.isArray(rows) || rows.length > 10000) {
      throw new Error('剧果分集目录格式无效');
    }
    const chapters = [];
    const seenIDs = new Set();
    const seenNumbers = new Set();
    let index = 0;
    for (const entry of rows) {
      index += 1;
      if (entry && entry.playable === false) {
        continue;
      }
      const chapterID = text(entry && entry.id);
      if (!validID(chapterID) || seenIDs.has(chapterID)) {
        throw new Error('剧果分集目录包含无效或重复分集');
      }
      let number = index;
      if (entry && entry.epNo != null) {
        number = source.int(entry.epNo, 100000);
        if (number == null) {
          throw new Error('剧果分集编号无效');
        }
        if (number === 0) number = index;
      }
      if (seenNumbers.has(number)) {
        throw new Error('剧果分集编号重复，请刷新目录');
      }
      seenIDs.add(chapterID);
      seenNumbers.add(number);
      chapters.push({id: chapterID, title: '第 ' + number + ' 集', episode: number});
    }
    const normalized = source.chapters(chapters);
    drama.episodes = normalized.length;
    return {drama: drama, chapters: normalized};
  },

  resolve(ctx, task) {
    const id = text(task.chapterId);
    if (!validID(id)) {
      throw new Error('剧果分集地址无效');
    }
    const response = apiFetch(ctx, '/play/' + encodeURIComponent(id));
    const row = payload(JSON.parse(response.body));
    const address = text(row && row.url);
    const credentials = hgkit.cloudFrontCredentials(response.headers, address, {
      label: '剧果',
      referer: source.site + '/',
      userAgent: source.userAgent,
      expiresAt: row && row.expiresAt,
    });
    return {
      url: address,
      referer: source.site + '/',
      credentials: credentials,
    };
  },
});

function apiBase(ctx) {
  return source.base(ctx);
}

function validID(value) {
  value = String(value ?? '');
  return value !== '' && value.length <= 450 && value === value.trim() && value !== '.' && value !== '..' &&
    !/[\/\\:?#%|"<>]/.test(value) && !/[\x00-\x1f\x7f]/.test(value);
}

function validCategoryID(value) {
  return validID(value) && !value.startsWith('@');
}

function text(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  return '';
}


// —— 访客令牌：deviceId 与 token 持久化，401 时换新重试 ——

function guestToken(ctx) {
  let token = hg.storage.get('token');
  if (token) return token;
  let deviceID = hg.storage.get('deviceId');
  if (!deviceID) {
    deviceID = 'device-' + Date.now() + '-' + Math.random().toString(16).slice(2, 10);
    hg.storage.set('deviceId', deviceID);
  }
  const response = hg.fetch(apiBase(ctx) + '/auth/guest', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: source.site + '/',
      Origin: source.site,
      'User-Agent': source.userAgent,
    },
    body: JSON.stringify({deviceId: deviceID}),
  });
  if (response.status !== 200) {
    throw new Error('剧果访客授权失败 HTTP ' + response.status);
  }
  const row = JSON.parse(response.body);
  token = text(row && (row.token ?? (row.data && row.data.token)));
  if (!token || token.length > 8192 || /[\x00-\x20\x7f]/.test(token)) {
    throw new Error('剧果未返回有效的访客授权');
  }
  hg.storage.set('token', token);
  return token;
}

function apiFetch(ctx, route) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const token = guestToken(ctx);
    const response = hg.fetch(apiBase(ctx) + route, {
      headers: {
        Accept: 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        Referer: source.site + '/',
        Origin: source.site,
        'User-Agent': source.userAgent,
        Authorization: 'Bearer ' + token,
      },
    });
    if (response.status === 401 || response.status === 403) {
      hg.storage.set('token', '');
      if (attempt === 0) continue;
    }
    if (response.status !== 200) {
      throw new Error('剧果请求失败 HTTP ' + response.status);
    }
    return response;
  }
  throw new Error('剧果访客授权已失效，请重试');
}

function apiGet(ctx, route) {
  return payload(JSON.parse(apiFetch(ctx, route).body));
}

// payload 与 Go huangjuPayload 对齐：{data:...} 包裹且顶层无业务字段时解包。
function payload(value) {
  if (value && typeof value === 'object' && !Array.isArray(value) &&
      value.data != null && value.id == null && value.items == null && value.url == null) {
    return value.data;
  }
  return value;
}

// dramaFromMap 把上游记录映射成剧集条目；sourceID 为空时由 slug-id 组合。
function dramaFromMap(row, sourceID) {
  if (!row || typeof row !== 'object' || typeof row.title !== 'string') return null;
  const id = source.text(row.id);
  if (!validID(id) || !row.title.trim()) return null;
  if (row.totalEpisodes != null && source.int(row.totalEpisodes, 100000) == null) return null;
  if (!sourceID) {
    const slug = source.text(row.slug);
    if (!validID(slug)) return null;
    sourceID = slug + '-' + id;
  }
  if (!validID(sourceID) || !sourceID.endsWith('-' + id)) return null;

  const categories = categoryNames(row);
  let status = source.text(row.status);
  if (status === 'completed') status = 'finished';
  if (status !== 'finished' && status !== 'ongoing') status = '';

  const tagValues = categories.slice();
  const region = source.text(row.region);
  if (region) tagValues.push(region.slice(0, 48));
  const year = source.int(row.year, 9999);
  if (year != null && year >= 1000) tagValues.push(year + '年');
  const score = source.text(row.score);
  const scoreValue = Number(score);
  if (score && Number.isFinite(scoreValue) && scoreValue > 0 && scoreValue <= 10) {
    tagValues.push('评分 ' + score);
  }

  const drama = source.drama(row, {
    validID: validID,
    titleKeys: ['title'],
    descriptionKeys: ['description'],
    coverKeys: ['coverUrl'],
    episodeKeys: ['totalEpisodes'],
    category: categories[0] || '短剧',
    // 保持旧行为：封面只接受绝对地址，不按 API 主机补相对路径。
    base: '',
    tagValues: () => tagValues,
    tagOptions: {limit: 64},
    extra: (_row, item) => {
      item.releaseStatus = status;
    },
  });
  if (!drama) return null;
  drama.sourceId = sourceID;
  return drama;
}

function categoryNames(row) {
  const names = [];
  const seen = new Set();
  const add = (value) => {
    let name = '';
    if (value && typeof value === 'object') {
      name = text(value.name);
    } else if (typeof value === 'string') {
      name = value.trim();
    }
    if (name && [...name].length <= 48 && !seen.has(name) && names.length < 24) {
      seen.add(name);
      names.push(name);
    }
  };
  add(row.category);
  if (Array.isArray(row.categories)) {
    for (const entry of row.categories) add(entry);
  }
  return names;
}

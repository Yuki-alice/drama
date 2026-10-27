// ==HongguoExtension==
// @id sorani
// @name 青空
// @version 1.0.0
// @apiLevel 1
// @description 番剧 · 剧场动画 · 特摄
// @onlineSearch true
// @pagedSearch true
// @settings pageSize|每页数量|choice|24|24=24 条|48=48 条|96=96 条
// ==/HongguoExtension==

// 青空次元扩展源：纯 JSON API。
// 接口：GET /video?page=&size=&categoryId= 目录、/video/{id} 详情（episodes[]）、
// /video/search?keyword= 搜索、/video/episode/{episodeId}/play?lineCode=anime_jp_m3u8 播放。
globalThis.source = hgkit.defineSource({
  name: '青空次元',
  baseURL: 'https://www.sorani.net',
  pageSize: 24,
  lineCode: 'anime_jp_m3u8',
  headers: {
    Accept: 'application/json, text/plain, */*',
    // 与原实现一致：接口校验站点 Origin，而不是 fixture 的 ctx.host。
    Origin: 'https://www.sorani.net',
  },
  categories: [
    {id: '1', name: 'TV番剧'},
    {id: '2', name: '剧场动画'},
    {id: '5', name: '特摄剧场'},
  ],

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 100000) {
      throw new Error('青空次元目录页码无效');
    }
    if (!source.validCategory(category)) {
      throw new Error('青空次元内容分类无效');
    }
    if (query.length > 256) {
      throw new Error('青空次元搜索关键词过长');
    }
    // 每页数量可在「站源管理 → 青空 → 设置」里调整；未设置时用声明默认值。
    const pageSize = hg.storage.get('pageSize') || source.pageSize;
    let route = '/video?page=' + page + '&size=' + pageSize;
    if (query) {
      route = '/video/search?keyword=' + encodeURIComponent(query) +
        '&page=' + page + '&size=' + pageSize;
    } else if (category) {
      route += '&categoryId=' + encodeURIComponent(category);
    }
    const payload = envelope(source.getJSON(ctx, route, {label: '青空次元'}));
    const rows = recordList(payload);
    if (!rows || rows.length > 500) {
      throw new Error('青空次元目录数据格式无效');
    }
    const items = [];
    const seen = new Set();
    for (const row of rows) {
      const item = mapDrama(row);
      if (!item) {
        throw new Error('青空次元返回的剧集信息不完整');
      }
      if (seen.has(item.sourceId)) {
        throw new Error('青空次元目录包含重复剧集，请重试');
      }
      seen.add(item.sourceId);
      items.push(item);
    }
    const result = source.page(items, page, {total: payload && payload.total});
    if (result.hasMore && rows.length === 0) {
      throw new Error('青空次元未返回应有的目录页，请重试');
    }
    return result;
  },

  detail(ctx, id) {
    if (!/^\d{1,64}$/.test(String(id))) {
      throw new Error('青空次元剧集 ID 无效');
    }
    const row = envelope(source.getJSON(ctx, '/video/' + encodeURIComponent(id), {label: '青空次元'}));
    if (!row || Array.isArray(row) || typeof row !== 'object') {
      throw new Error('青空次元详情数据格式无效');
    }
    const drama = mapDrama(row);
    if (!drama) {
      throw new Error('青空次元返回的剧集信息不完整');
    }
    if (drama.sourceId !== String(id)) {
      throw new Error('青空次元详情与请求剧集不符');
    }
    const rows = row.episodes;
    if (!Array.isArray(rows) || rows.length > 10000) {
      throw new Error('青空次元分集目录格式无效');
    }
    const chapters = [];
    const seenIDs = new Set();
    const seenOrders = new Set();
    let index = 0;
    for (const entry of rows) {
      index += 1;
      if (!entry || typeof entry !== 'object' || entry.enabled === false) {
        continue;
      }
      const episodeID = source.text(entry.episodeId ?? entry.id);
      if (!/^\d{1,64}$/.test(episodeID) || seenIDs.has(episodeID)) {
        throw new Error('青空次元分集目录包含无效或重复分集');
      }
      let order = index;
      if (entry.episodeOrder != null) {
        const parsed = source.int(entry.episodeOrder, 100000);
        if (parsed) order = parsed;
      }
      if (seenOrders.has(order)) {
        throw new Error('青空次元分集编号重复，请刷新目录');
      }
      seenIDs.add(episodeID);
      seenOrders.add(order);
      const title = source.text(entry.episodeLabel ?? entry.title ?? entry.displayTitle) || ('第 ' + order + ' 集');
      chapters.push({id: episodeID, title: title.slice(0, 128), episode: order});
    }
    const normalized = source.chapters(chapters);
    drama.episodes = normalized.length;
    return {drama: drama, chapters: normalized};
  },

  resolve(ctx, task) {
    const episodeID = source.text(task.chapterId);
    if (!/^\d{1,64}$/.test(episodeID)) {
      throw new Error('青空次元分集 ID 无效');
    }
    const row = envelope(source.getJSON(
      ctx,
      '/video/episode/' + encodeURIComponent(episodeID) + '/play?lineCode=' + source.lineCode,
      {label: '青空次元'},
    ));
    const address = source.mediaURL(row && (row.playUrl ?? row.url));
    if (!address) {
      throw new Error('青空次元该分集暂无可用播放地址（线路 ' + source.lineCode + '）');
    }
    return {url: address, referer: source.baseURL + '/'};
  },
});

function envelope(value) {
  if (value && typeof value === 'object' && !Array.isArray(value) && 'data' in value) {
    return value.data;
  }
  return value;
}

function recordList(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && typeof payload === 'object') {
    for (const key of ['records', 'list', 'items', 'rows']) {
      if (Array.isArray(payload[key])) return payload[key];
    }
  }
  return null;
}

function mapDrama(row) {
  return source.drama(row, {
    validID: (id) => /^\d{1,64}$/.test(id),
    descriptionKeys: ['summary', 'description', 'intro', 'desc'],
    coverKeys: ['cover', 'coverLarge', 'coverSmall', 'coverThumb', 'backgroundImage'],
    episodeKeys: ['episodeCount', 'totalEpisode', 'episodes', 'total'],
    category: '番剧',
    tagValues: soraniTags,
  });
}

function soraniTags(row) {
  const values = [];
  const category = source.pick(row, ['categoryName', 'category']);
  const categoryName = source.pick(row, ['categoryName']);
  if (categoryName && categoryName !== category) values.push(categoryName);
  for (const key of ['tags', 'tagList', 'categoryTags']) {
    if (Array.isArray(row[key])) {
      for (const value of row[key]) values.push(value);
    }
  }
  const alias = source.pick(row, ['alias']);
  if (alias) values.push(alias.slice(0, 48));
  const area = source.pick(row, ['area']);
  if (area) values.push(area.slice(0, 48));
  const year = leadingYear(source.pick(row, ['year', 'publishDate']));
  if (year) values.push(year + '年');
  const actor = source.pick(row, ['actors', 'actor']);
  if (actor) values.push('声优 ' + actor.slice(0, 32));
  const score = source.pick(row, ['bangumiRating', 'score']);
  const scoreValue = Number(score);
  if (score && Number.isFinite(scoreValue) && scoreValue > 0 && scoreValue <= 10) {
    values.push('评分 ' + score.slice(0, 16));
  }
  return values;
}

function leadingYear(value) {
  const digits = value.slice(0, 4);
  if (!/^\d{4}$/.test(digits)) return '';
  const year = Number(digits);
  return year >= 1900 && year <= 2200 ? digits : '';
}

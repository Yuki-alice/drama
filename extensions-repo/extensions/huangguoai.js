// ==HongguoExtension==
// @id huangguoai
// @name 黄果 AI
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description AI 短剧
// @group huangguo
// @groupName 黄果
// @entryName AI
// ==/HongguoExtension==

// 黄果 AI 扩展源：站点提供 JSON 目录接口 + HTML 详情页。
//
// 接口：
//   GET /api/videos/category/{slug}?sort=hot&page=&size=24  分类目录（JSON，结构不固定）
//   GET /ranks/{hot|recommend|potential}/                   榜单（JSON-LD ItemList）
//   GET /detail/{id}/                                      详情（HTML，含 videoInitialData 脚本）
//
// 目录接口的 JSON 结构会随站点版本变化（顶层对象/数组、字段名不同），
// 因此采用递归遍历找「像剧集的对象」，与原 Go 实现保持一致。
globalThis.source = hgkit.defineSource({
  name: '黄果 AI',
  baseURL: 'https://huangguoai.com',
  pageSize: 24,
  categories: [
    {id: 'ai-duanju', name: 'AI 短剧'},
    {id: 'ai-manju', name: 'AI 漫剧'},
    {id: 'ai-huanlian', name: 'AI 换脸'},
    {id: 'ai-mogai', name: 'AI 魔改'},
  ],

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 100000) {
      throw new Error('黄果 AI 目录页码无效');
    }
    if (query) {
      throw new Error('黄果 AI 不支持站内搜索');
    }
    const categories = source.categories({}, false);
    const active = category
      ? categories.filter((entry) => entry.id === category)
      : categories;
    if (!active.length) {
      throw new Error('黄果 AI 分类已变化，请刷新分类');
    }
    // 多分类并行拉取后合并（与原 Go 版的并发聚合一致）。
    const requests = active.map((entry) => ({
      url: base(ctx) + '/api/videos/category/' + encodeURIComponent(entry.id) +
        '?sort=hot&page=' + page + '&size=' + source.pageSize,
      options: {headers: {Referer: base(ctx) + '/' + entry.id + '/'}},
    }));
    const responses = hg.fetchAll(requests);
    const items = [];
    const seen = new Set();
    const failures = [];
    let hasMore = false;
    responses.forEach((response, index) => {
      if (response.error) {
        failures.push(active[index].name + '：' + response.error);
        hasMore = true;
        return;
      }
      let rows = [];
      try {
        rows = jsonCards(response.body, requests[index].url, active[index].name);
      } catch (error) {
        failures.push(active[index].name + '：' + error.message);
        hasMore = true;
        return;
      }
      hasMore = hasMore || rows.length >= source.pageSize;
      for (const row of rows) {
        if (seen.has(row.sourceId)) continue;
        seen.add(row.sourceId);
        items.push(row);
      }
    });
    if (failures.length && !items.length) {
      throw new Error(failures.join('；'));
    }
    return source.page(items, page, {hasMore: hasMore});
  },

  detail(ctx, id) {
    let sourceID = text(id).replace(/^\/+|\/+$/g, '');
    sourceID = sourceID.replace(/^detail\//, '');
    if (!/^[a-zA-Z0-9_-]{1,100}$/.test(sourceID)) {
      throw new Error('黄果 AI 剧集 ID 无效');
    }
    const page = get(ctx, '/detail/' + encodeURIComponent(sourceID) + '/');
    return parseDetail(page.body, page.url, sourceID);
  },

  resolve(ctx, task) {
    const pageURL = text(task.pageUrl);
    if (pageURL) {
      const page = get(ctx, pageURL);
      const address = videoURL(page.body, page.url);
      if (!address) {
        throw new Error('黄果 AI 该集暂无可用播放地址');
      }
      return {url: address, referer: page.url};
    }
    const direct = text(task.videoUrl);
    if (direct && isMediaURL(direct)) {
      return {url: direct, referer: base(ctx) + '/'};
    }
    throw new Error('黄果 AI 未提供播放页地址');
  },

  rankingBoards(ctx) {
    return [
      {id: 'huangguo-hot', name: '热播榜', description: '黄果站点热播 TOP 20；每日更新。', data: 'hot'},
      {id: 'huangguo-recommend', name: '推荐榜', description: '黄果站点推荐 TOP 20。', data: 'recommend'},
      {id: 'huangguo-potential', name: '潜力榜', description: '黄果站点潜力 TOP 20。', data: 'potential'},
    ];
  },

  rankings(ctx, boardId, data, page) {
    if (page !== 1) {
      throw new Error('该榜单只有一页');
    }
    const key = text(data) || 'hot';
    const page1 = get(ctx, '/ranks/' + key + '/');
    return parseRanking(page1.body, page1.url, key);
  },
});

// —— 网络与通用工具 ——

function base(ctx) {
  return source.base(ctx);
}

function get(ctx, path) {
  const address = /^https?:\/\//i.test(path) ? path : base(ctx) + path;
  return {body: source.getText(ctx, path, {label: '黄果 AI 页面'}), url: address};
}

function integer(value, maximum) {
  const raw = source.text(value);
  if (!/^\d+$/.test(raw)) return null;
  const number = Number(raw);
  if (!Number.isInteger(number) || number < 0 || number > maximum) return null;
  return number;
}

const text = (value) => source.text(value);
const firstPresent = (values) => source.first(values);
const firstField = (row, keys) => source.pick(row, keys);
const resolveURL = hgkit.url;
const isMediaURL = (value) => source.isMediaURL(value);
const cleanText = (value) => source.clean(value);
const metaContent = (body, name) => source.meta(body, name);

// —— 目录（JSON 递归找剧集对象）——

function jsonCards(body, pageURL, category) {
  let decoded = null;
  try {
    decoded = JSON.parse(text(body));
  } catch (error) {
    throw new Error('黄果 AI 目录数据格式无效');
  }
  const items = [];
  const seen = new Set();
  const add = (row) => {
    if (row && row.sourceId && !seen.has(row.sourceId)) {
      seen.add(row.sourceId);
      items.push(row);
    }
  };
  walk(decoded, (row) => {
    const drama = dramaFromMap(row, pageURL, category);
    if (drama) {
      add(drama);
      return true;
    }
    return false;
  });
  if (items.length > 500) {
    throw new Error('黄果 AI 目录条目过多');
  }
  return items;
}

// walk 深度优先遍历 JSON；visitor 返回 true 表示该节点已消费，不再下钻。
function walk(value, visitor) {
  if (Array.isArray(value)) {
    for (const item of value) walk(item, visitor);
    return;
  }
  if (!value || typeof value !== 'object') return;
  if (visitor(value)) return;
  for (const key of Object.keys(value)) walk(value[key], visitor);
}

function dramaFromMap(row, pageURL, category) {
  if (!row || typeof row !== 'object') return null;
  let sourceID = firstField(row, ['id', 'videoId', 'video_id', 'vid', 'slug']);
  if (!sourceID) {
    for (const key of Object.keys(row)) {
      const candidate = detailIDFromString(row[key]);
      if (candidate) {
        sourceID = candidate;
        break;
      }
    }
  }
  if (detailIDFromString(sourceID)) sourceID = detailIDFromString(sourceID);
  sourceID = cleanID(sourceID);
  if (!sourceID) return null;
  const title = firstField(row, ['title', 'name', 'videoTitle', 'video_title', 'videoName', 'video_name']);
  // 标题就是 ID 或缺失的条目属于导航链接，不是剧集。
  if (!title || titleNeedsRepair(title, sourceID)) return null;
  const cover = resolveURL(pageURL, firstField(row, [
    'cover', 'coverUrl', 'cover_url', 'coverImage', 'cover_image', 'image',
    'imageUrl', 'thumbnail', 'poster', 'posterUrl',
  ]));
  const description = firstField(row, ['desc', 'description', 'intro', 'summary']);
  const episodes = mapEpisodes(row);
  let remark = firstField(row, ['vod_remarks', 'remark', 'remarks']);
  if (!remark && episodes) {
    const finished = firstField(row, ['is_finished']);
    remark = (finished === 'true' || finished === '1') ? '全' + episodes + '集' : '更新至 ' + episodes + ' 集';
  }
  let score = firstField(row, ['score', 'rating']);
  if (score && score.indexOf('分') < 0) score += '分';
  const views = normalizeViews(firstField(row, [
    'views', 'view_count', 'viewCount', 'view_num', 'viewNum', 'views_text',
    'view_count_text', 'play_count', 'playCount', 'play_num', 'playNum',
    'play_count_text', 'hits', 'hit_count', 'plays', 'play',
  ]));
  const online = normalizeDate(firstField(row, [
    'onlineDate', 'online_date', 'online_time', 'onlineTime',
    'publish_date', 'publishDate', 'publish_time', 'publishTime',
    'release_date', 'releaseDate',
  ]));
  const tags = stringList(row, ['tags', 'tag', 'categories', 'category']);
  const drama = {
    sourceId: sourceID,
    title: title,
    cover: cover,
    category: category,
    channelName: 'huangguoai.com',
    remark: remark,
    score: score,
    views: views,
    onlineDate: online,
    tags: tags,
  };
  if (description) drama.description = description;
  if (episodes) drama.episodes = episodes;
  return drama;
}

// detailIDFromString 从 /detail/{id}/ 形态的链接里取 ID。
function detailIDFromString(value) {
  const raw = text(value);
  if (!raw) return '';
  const match = /\/detail\/([^/?#"']+)\/?/.exec(raw);
  return match ? cleanID(match[1]) : '';
}

function cleanID(value) {
  const raw = text(value).replace(/\/+$/, '');
  if (!raw || raw.length > 100) return '';
  return /^[a-zA-Z0-9_-]+$/.test(raw) ? raw : '';
}

// titleNeedsRepair：标题等于 ID、或只是站名/占位文案时视为无效。
function titleNeedsRepair(title, sourceID) {
  const value = text(title);
  if (!value) return true;
  if (value === sourceID) return true;
  return /^(?:黄果|首页|更多|详情|播放|上一页|下一页)$/.test(value);
}

function mapEpisodes(row) {
  for (const key of ['totalEpisode', 'total_episode', 'episodeCount', 'episode_count', 'total', 'episodes']) {
    const value = integer(row[key], 100000);
    if (value != null && value > 0) return value;
  }
  return 0;
}

function stringList(row, keys) {
  const out = [];
  const seen = new Set();
  for (const key of keys) {
    const value = row[key];
    const list = Array.isArray(value) ? value : (typeof value === 'string' ? value.split(',') : []);
    for (const item of list) {
      const name = text(item);
      if (!name || [...name].length > 48 || seen.has(name)) continue;
      seen.add(name);
      out.push(name);
      if (out.length >= 16) return out;
    }
  }
  return out;
}

function normalizeViews(value) {
  const raw = text(value);
  if (!raw) return '';
  return /次播放$/.test(raw) ? raw : raw + '次播放';
}

function normalizeDate(value) {
  const raw = text(value);
  if (!raw) return '';
  const match = /(\d{4})-(\d{1,2})-(\d{1,2})/.exec(raw);
  if (!match) return '';
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return '';
  return match[1] + '-' + String(month).padStart(2, '0') + '-' + String(day).padStart(2, '0');
}

// —— 详情与分集 ——

function parseDetail(body, pageURL, sourceID) {
  const document = hg.html.parse(body);
  let title = '';
  const heading = hg.html.findFirst(document, 'h1');
  if (heading) title = cleanText(hg.html.text(heading));
  if (!title) title = metaContent(body, 'og:title');
  if (!title) {
    const tag = hg.html.findFirst(document, 'title');
    if (tag) title = cleanText(hg.html.text(tag));
  }
  if (!title) title = sourceID;
  const cover = firstPresent([
    resolveURL(pageURL, metaContent(body, 'og:image')),
    resolveURL(pageURL, hg.html.attr(hg.html.findFirst(document, '.detail-img img, .cover img'), 'src')),
  ]);
  const description = firstPresent([
    metaContent(body, 'og:description'),
    metaContent(body, 'description'),
  ]);
  const tags = [];
  const seenTags = new Set();
  for (const node of hg.html.findAll(document, '[class*="hg-tag"]')) {
    const value = cleanText(hg.html.text(node));
    if (!value || seenTags.has(value)) continue;
    seenTags.add(value);
    tags.push(value);
  }
  const drama = {
    sourceId: sourceID,
    title: title,
    cover: cover,
    channelName: 'huangguoai.com',
    tags: tags,
  };
  if (description) drama.description = description;
  const chapters = parseEpisodes(body, pageURL, sourceID, title);
  if (!chapters.length) {
    // 单片：页面内的 videoInitialData 直接给出播放地址。
    const address = videoURL(body, pageURL);
    if (address) {
      drama.episodes = 1;
      return {
        drama: drama,
        chapters: [{id: '1', title: title, episode: 1, pageUrl: pageURL, videoUrl: address}],
      };
    }
    throw new Error('黄果 AI 暂未返回可播放分集');
  }
  drama.episodes = chapters.length;
  return {drama: drama, chapters: chapters};
}

function parseEpisodes(body, pageURL, sourceID, fallbackTitle) {
  const document = hg.html.parse(body);
  const chapters = [];
  const seen = new Set();
  const seenIndex = new Set();
  for (const anchor of hg.html.findAll(document, 'a')) {
    const href = hg.html.attr(anchor, 'href') || '';
    const fullURL = resolveURL(pageURL, href);
    if (!fullURL) continue;
    const parsed = hg.url.parse(fullURL);
    if (!parsed.valid || !parsed.path.startsWith('/video/')) continue;
    const key = episodeKey(parsed.path, sourceID);
    if (!key) continue;
    if (seen.has(key) || seen.has(fullURL)) continue;
    seen.add(key);
    seen.add(fullURL);
    const title = firstPresent([
      hg.html.attr(anchor, 'title'),
      hg.html.attr(anchor, 'aria-label'),
      cleanText(hg.html.text(anchor)),
    ]);
    let index = episodeIndexFor(title);
    if (index <= 0) index = chapters.length + 1;
    index = nextUnusedIndex(index, seenIndex);
    seenIndex.add(index);
    chapters.push({id: key, title: title || '第' + index + '集', episode: index, pageUrl: fullURL});
  }
  chapters.sort((left, right) => left.episode - right.episode);
  return chapters;
}

// episodeKey 校验 /video/{dramaID}/... 属于当前剧集，返回末段作为章节键。
function episodeKey(path, sourceID) {
  const parts = path.replace(/^\/video\//, '').split('/').filter((part) => part !== '');
  if (!parts.length || parts[0] !== sourceID) return '';
  if (parts.length > 1) return cleanID(parts[parts.length - 1]);
  return '';
}

function episodeIndexFor(value) {
  const raw = text(value);
  if (!raw) return 0;
  const match = /(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))/i.exec(raw);
  if (!match) return 0;
  for (const group of match.slice(1)) {
    if (!group) continue;
    const number = Number(group);
    if (Number.isInteger(number) && number > 0 && number <= 100000) return number;
  }
  return 0;
}

function nextUnusedIndex(preferred, used) {
  let value = preferred > 0 ? preferred : 1;
  if (!used.has(value)) return value;
  value = 1;
  while (used.has(value)) value++;
  return value;
}

// videoURL 依次尝试 videoInitialData 脚本、data-play-src、内联媒体字段。
function videoURL(body, pageURL) {
  const fromScript = videoInitialDataURL(body, pageURL);
  if (fromScript) return fromScript;
  const document = hg.html.parse(body);
  const playSrc = hg.html.findFirst(document, '[data-play-src]');
  if (playSrc) {
    const address = resolveURL(pageURL, hg.html.attr(playSrc, 'data-play-src'));
    if (isMediaURL(address)) return address;
  }
  const match = /["']?(?:videoSrc|videoUrl|playUrl|src|url)["']?\s*[:=]\s*["']([^"']+\.(?:m3u8|mp4)(?:[^"']*)?)["']/i.exec(body);
  if (match) {
    const address = resolveURL(pageURL, match[1]);
    if (isMediaURL(address)) return address;
  }
  return '';
}

function videoInitialDataURL(body, pageURL) {
  const document = hg.html.parse(body);
  const script = hg.html.findFirst(document, 'script#videoInitialData');
  if (!script) return '';
  let data = null;
  try {
    data = JSON.parse(hg.html.text(script));
  } catch (error) {
    return '';
  }
  if (!data || typeof data !== 'object') return '';
  const direct = firstPresent([data.videoSrc, data.videoUrl, data.playUrl]);
  if (direct) {
    const address = resolveURL(pageURL, direct);
    if (isMediaURL(address)) return address;
  }
  const episodes = data.epPlaySrcs;
  if (!episodes || typeof episodes !== 'object') return '';
  const keys = Object.keys(episodes);
  if (!keys.length) return '';
  // 优先当前页对应的集数（页面 URL 形如 /ep-N/），否则取最小集数。
  let preferred = firstPresent([data.ep, data.episode]);
  const match = /\/ep-(\d+)(?:\/|$)/.exec(pageURL);
  if (match) preferred = match[1];
  const ordered = preferred && episodes[preferred] != null
    ? [preferred, ...keys.filter((key) => key !== preferred)]
    : keys.slice().sort((left, right) => {
      const a = episodeIndexFor(left);
      const b = episodeIndexFor(right);
      return (a || 0) - (b || 0);
    });
  for (const key of ordered) {
    const address = resolveURL(pageURL, episodes[key]);
    if (isMediaURL(address)) return address;
  }
  return '';
}

// —— 榜单（JSON-LD ItemList）——

function parseRanking(body, pageURL, key) {
  const document = hg.html.parse(body);
  for (const script of hg.html.findAll(document, 'script[type="application/ld+json"]')) {
    let data = null;
    try {
      data = JSON.parse(hg.html.text(script));
    } catch (error) {
      continue;
    }
    const graph = Array.isArray(data) ? data : (data['@graph'] || [data]);
    for (const node of graph) {
      if (!node || node['@type'] !== 'ItemList') continue;
      const id = text(node['@id']);
      if (id && !id.endsWith('/ranks/' + key + '/#itemlist')) continue;
      const rows = node.itemListElement;
      if (!Array.isArray(rows) || !rows.length || rows.length > 100) {
        throw new Error('黄果未返回有效榜单，可能是页面结构变化');
      }
      const items = [];
      const seen = new Set();
      let previous = 0;
      for (const row of rows) {
        const position = Number(row && row.position);
        const name = text(row && row.name);
        const address = hg.url.parse(resolveURL(pageURL, row && row.url));
        if (!address.valid || !address.path.startsWith('/detail/')) {
          throw new Error('黄果未返回有效榜单，可能是页面结构变化');
        }
        const sourceID = address.path.replace(/^\/detail\//, '').replace(/\/+$/, '');
        if (!/^[a-zA-Z0-9_-]{1,100}$/.test(sourceID) || !name) {
          throw new Error('黄果未返回有效榜单，可能是页面结构变化');
        }
        if (!Number.isInteger(position) || position <= previous || seen.has(sourceID)) {
          throw new Error('黄果未返回有效榜单，可能是页面结构变化');
        }
        seen.add(sourceID);
        previous = position;
        items.push({sourceId: sourceID, title: name, category: ''});
      }
      return {items: items, hasMore: false, totalPages: 1};
    }
  }
  throw new Error('黄果未返回有效榜单，可能是页面结构变化');
}

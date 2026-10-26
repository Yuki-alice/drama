// ==HongguoExtension==
// @id huangguo-video
// @name 黄果视频
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description 视频剧集
// @group huangguo
// @groupName 黄果
// @entryName 视频
// ==/HongguoExtension==

// 黄果视频扩展源：HTML 站点 /videos 目录、/series|video/{id} 详情。
//
// 站点特点：
//   - 目录列表是分页的 HTML 卡片（<article class="video-card">）。
//   - 详情有两种形态：系列剧（/series/{id}，多集）与单片（/video/{id}）。
//   - 播放地址直接写在卡片的 data-hls 属性上，无需额外解析接口。
globalThis.source = hgkit.defineSource({
  name: '黄果视频',
  baseURL: 'https://huangguo.video',
  pageSize: 20,

  categories(ctx, force) {
    const page = get(ctx, '/videos');
    const document = hg.html.parse(page.body);
    const categories = [];
    const seen = new Set();
    for (const anchor of hg.html.findAll(document, 'a')) {
      const address = hg.url.parse(resolveURL(page.url, hg.html.attr(anchor, 'href')));
      if (!address.valid) continue;
      const path = address.path.replace(/\/+$/, '') || '/';
      if (path !== '/videos') continue;
      const id = queryValue(address.query, 'category');
      const name = text(hg.html.text(anchor));
      if (!id || !/^[1-9][0-9]{0,17}$/.test(id) || !name || [...name].length > 24) continue;
      if (seen.has(id)) continue;
      seen.add(id);
      categories.push({id: id, name: name});
    }
    return categories;
  },

  validCategory(category) {
    return category === '' || /^[1-9][0-9]{0,17}$/.test(category);
  },

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 100000) {
      throw new Error('黄果视频目录页码无效');
    }
    if (query) {
      throw new Error('黄果视频不支持站内搜索');
    }
    let path = '/videos?page=' + page;
    if (category) {
      path += '&category=' + encodeURIComponent(category);
    }
    const result = get(ctx, path);
    const items = parseCards(result.body, result.url);
    return source.page(items, page, {hasMore: items.length >= source.pageSize});
  },

  detail(ctx, id) {
    const sourceID = text(id).replace(/^\/+|\/+$/g, '');
    if (!sourceID) {
      throw new Error('黄果视频剧集 ID 无效');
    }
    let detailPath = sourceID;
    if (!detailPath.startsWith('series/') && !detailPath.startsWith('video/')) {
      detailPath = 'series/' + detailPath;
    }
    const page = get(ctx, '/' + detailPath);
    const drama = detailMetadata(page.body, page.url);
    let episodes = [];
    if (detailPath.startsWith('video/')) {
      const hls = dataHLS(page.body, page.url);
      if (hls) {
        episodes = [{key: '1', title: drama.title, url: page.url, index: 1, hls: hls}];
      }
    } else {
      episodes = parseEpisodes(page.body, page.url);
    }
    if (!episodes.length) {
      const hls = dataHLS(page.body, page.url);
      if (hls) {
        episodes = [{key: '1', title: drama.title, url: page.url, index: 1, hls: hls}];
      }
    }
    if (!episodes.length) {
      throw new Error('黄果视频暂未返回可播放分集');
    }
    const chapters = [];
    const seen = new Set();
    for (const episode of episodes) {
      const index = episode.index > 0 ? episode.index : chapters.length + 1;
      const key = episode.key || String(index);
      if (seen.has(key)) continue;
      seen.add(key);
      chapters.push({
        id: key,
        title: text(episode.title) || '第' + index + '集',
        episode: index,
        pageUrl: episode.url,
        videoUrl: episode.hls || undefined,
      });
    }
    return {drama: drama, chapters: source.chapters(chapters)};
  },


  resolve(ctx, task) {
    // 章节自带 data-hls 时直接使用；否则重新拉详情页读取。
    const media = text(task.videoUrl);
    if (media && isMediaURL(media)) {
      return {url: media, referer: text(task.pageUrl) || base(ctx) + '/'};
    }
    const pageURL = text(task.pageUrl);
    if (!pageURL) {
      throw new Error('黄果视频未提供播放页地址');
    }
    const page = get(ctx, pageURL);
    const address = dataHLS(page.body, page.url);
    if (!address) {
      throw new Error('黄果视频该集暂无可用播放地址');
    }
    return {url: address, referer: page.url};
  },
});

// —— 网络与通用工具 ——

function base(ctx) {
  return source.base(ctx);
}

function get(ctx, path) {
  const address = /^https?:\/\//i.test(path) ? path : base(ctx) + path;
  return {body: source.getText(ctx, path, {label: '黄果视频页面'}), url: address};
}

const text = (value) => source.text(value);
const firstPresent = (values) => source.first(values);
const resolveURL = hgkit.url;
const isMediaURL = (value) => source.isMediaURL(value);
const cleanText = (value) => source.clean(value);
const metaContent = (body, name) => source.meta(body, name);

function queryValue(query, key) {
  if (!query) return '';
  for (const pair of query.split('&')) {
    const [rawKey, rawValue] = pair.split('=');
    if (decodeURIComponent(rawKey || '') === key) {
      return decodeURIComponent(rawValue || '');
    }
  }
  return '';
}

// —— 目录卡片 ——

// cardRemark 读取卡片角标。类名含 "/"（如 bg-black/55），
// 用类名列表判断比 CSS 转义选择器更稳。
function cardRemark(card) {
  for (const node of hg.html.findAll(card, 'span, div')) {
    const classes = (hg.html.attr(node, 'class') || '').split(/\s+/);
    if (classes.includes('bg-black/55') || classes.includes('text-gold-dim')) {
      const value = nodeText(node);
      if (value) return value;
    }
  }
  return '';
}

function parseCards(body, pageURL) {
  const document = hg.html.parse(body);
  let cards = hg.html.findAll(document, 'article.video-card');
  if (!cards.length) {
    cards = hg.html.findAll(document, 'article').filter(
      (card) => (hg.html.attr(card, 'class') || '').toLowerCase().includes('video-card'),
    );
  }
  const items = [];
  const seen = new Set();
  for (const card of cards) {
    let link = '';
    for (const anchor of hg.html.findAll(card, 'a')) {
      const href = hg.html.attr(anchor, 'href') || '';
      if (videoSourceID(href)) {
        link = href;
        break;
      }
    }
    if (!link) continue;
    const parsed = videoSourceID(link);
    if (!parsed || seen.has(parsed.sourceID)) continue;
    seen.add(parsed.sourceID);
    // 标题可能为空：宿主统一用 DisplayTitle 兜底（与内置 provider 一致）。
    const title = firstPresent([
      closestAttr(card, ['title', 'alt', 'aria-label']),
      cleanText(hg.html.text(card)),
    ]);
    let cover = '';
    for (const image of hg.html.findAll(card, 'img')) {
      cover = firstPresent([
        resolveURL(pageURL, hg.html.attr(image, 'data-src')),
        resolveURL(pageURL, hg.html.attr(image, 'data-original')),
        resolveURL(pageURL, hg.html.attr(image, 'src')),
      ]);
      if (cover) break;
    }
    const item = {
      sourceId: parsed.sourceID,
      title: title,
      cover: cover,
      category: parsed.path.startsWith('series/') ? 'series' : 'video',
      channelName: 'huangguo.video',
      remark: cardRemark(card),
    };
    const description = firstPresent([
      hg.html.attr(card, 'data-description'),
      hg.html.attr(card, 'description'),
      metaContent(body, 'description'),
      metaContent(body, 'og:description'),
    ]);
    if (description) item.description = description;
    items.push(item);
  }
  return items;
}

// videoSourceID 从 href 里取 series/{id} 或 video/{id} 形态的标识。
function videoSourceID(href) {
  const resolved = resolveURL(source.baseURL + '/', text(href));
  if (!resolved) return null;
  const parsed = hg.url.parse(resolved);
  if (!parsed.valid) return null;
  const parts = parsed.path.split('/').filter((part) => part !== '');
  for (let index = 0; index + 1 < parts.length; index++) {
    if (parts[index] !== 'series' && parts[index] !== 'video') continue;
    const code = cleanID(parts[index + 1]);
    if (!code) return null;
    return {path: parts[index] + '/' + code, sourceID: parts[index] + '/' + code};
  }
  return null;
}

function cleanID(value) {
  const raw = text(value);
  if (!raw || raw.length > 200) return '';
  return /^[a-zA-Z0-9_-]+$/.test(raw) ? raw : '';
}

// closestAttr 取块内任一属性（不用 DOM 结构，卡片内部结构随版本变化）。
function closestAttr(card, names) {
  for (const name of names) {
    const value = text(hg.html.attr(card, name));
    if (value) return value;
  }
  for (const node of hg.html.findAll(card, 'img, [title], [aria-label]')) {
    for (const name of names) {
      const value = text(hg.html.attr(node, name));
      if (value) return value;
    }
  }
  return '';
}

function nodeText(node) {
  return node ? cleanText(hg.html.text(node)) : '';
}

// —— 详情与分集 ——

function detailMetadata(body, pageURL) {
  const document = hg.html.parse(body);
  const sourceID = videoSourceID('/' + pathOf(pageURL));
  let title = '';
  const heading = hg.html.findFirst(document, 'h1');
  if (heading) title = cleanText(hg.html.text(heading));
  if (!title) title = metaContent(body, 'og:title');
  if (!title) {
    const tag = hg.html.findFirst(document, 'title');
    if (tag) title = cleanText(hg.html.text(tag));
  }
  let cover = '';
  for (const meta of hg.html.findAll(document, 'meta')) {
    const key = (hg.html.attr(meta, 'property') || hg.html.attr(meta, 'name') || '').toLowerCase();
    if (key === 'og:image') {
      cover = resolveURL(pageURL, hg.html.attr(meta, 'content'));
      if (cover) break;
    }
  }
  const description = firstPresent([
    metaContent(body, 'description'),
    metaContent(body, 'og:description'),
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
    sourceId: sourceID ? sourceID.sourceID : pathOf(pageURL).replace(/^\/+/, ''),
    title: title || '短剧',
    description: description,
    cover: cover,
    channelName: 'huangguo.video',
    tags: tags,
  };
  return drama;
}

function pathOf(address) {
  const parsed = hg.url.parse(text(address));
  return parsed.valid ? parsed.path : '';
}

function parseEpisodes(body, pageURL) {
  const document = hg.html.parse(body);
  let cards = hg.html.findAll(document, 'article.video-card');
  if (!cards.length) cards = hg.html.findAll(document, 'a');
  const episodes = [];
  const positions = new Map();
  let numbered = false;
  for (const card of cards) {
    let href = '';
    for (const anchor of card === null ? [] : [card, ...hg.html.findAll(card, 'a')]) {
      const candidate = hg.html.attr(anchor, 'href') || '';
      if (videoSourceID(candidate)) {
        href = candidate;
        break;
      }
    }
    if (!href) continue;
    const parsed = videoSourceID(href);
    if (!parsed || !parsed.path.startsWith('video/')) continue;
    const fullURL = resolveURL(pageURL, href);
    if (!fullURL) continue;
    const title = firstPresent([
      hg.html.attr(card, 'title'),
      hg.html.attr(card, 'alt'),
      cleanText(hg.html.text(card)),
    ]);
    const index = episodeIndex(cleanText(hg.html.text(card))) || episodeIndex(title) || 0;
    numbered = numbered || index > 0;
    const episode = {
      key: parsed.sourceID,
      title: title,
      url: fullURL,
      index: index,
      hls: dataHLS(card === null ? '' : hg.html.html(card), pageURL),
    };
    if (positions.has(fullURL)) {
      const position = positions.get(fullURL);
      if (episodes[position].index <= 0 && index > 0) {
        episodes[position] = episode;
      }
      continue;
    }
    positions.set(fullURL, episodes.length);
    episodes.push(episode);
  }
  const used = new Set();
  const result = [];
  for (const episode of episodes) {
    if (numbered && episode.index <= 0) continue;
    episode.index = nextUnusedIndex(episode.index, used);
    used.add(episode.index);
    result.push(episode);
  }
  return result;
}

// dataHLS 读取 data-hls 属性里的播放地址。
function dataHLS(block, pageURL) {
  const match = /data-hls=["']([^"']+)["']/i.exec(text(block));
  if (!match) return '';
  const address = resolveURL(pageURL, match[1]);
  return isMediaURL(address) ? address : '';
}

// episodeIndex 从「第 N 集」「更新至 N 集」「EP N」等文本取集数。
function episodeIndex(value) {
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

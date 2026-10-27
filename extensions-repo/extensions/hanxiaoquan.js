// ==HongguoExtension==
// @id hanxiaoquan
// @name 韩小圈
// @version 1.0.0
// @apiLevel 1
// @description 韩剧 · 韩国电影 · 综艺动漫
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==

// 韩小圈扩展源：MacCMS 苹果 CMS 模板站点。
// 页面：/hxq/{id}[-{page}].html 分类、/hanxiaoquan/{id}.html 详情、
// /play/{id}-{line}-{ep}.html 播放页（var now="<m3u8>"）、/search.php?searchword= 搜索。
globalThis.source = hgkit.defineSource({
  name: '韩小圈',
  baseURL: 'https://www.jennyhow.com',
  pageSize: 24,
  categories: [
    {id: '1', name: '最新韩剧'},
    {id: '2', name: '韩国电影'},
    {id: '3', name: '韩国综艺'},
    {id: '4', name: '韩国动漫'},
  ],

  catalog(ctx, page, category, query) {
    if (query) {
      return searchHanxiaoquan(ctx, page, query);
    }
    if (page < 1 || page > 100000) {
      throw new Error('韩小圈目录页码无效');
    }
    const active = category || source.categories({}, false)[0].id;
    const path = page > 1 ? `/hxq/${active}-${page}.html` : `/hxq/${active}.html`;
    const body = source.getText(ctx, path, {label: '韩小圈'});
    const items = parseCards(body);
    if (items.length === 0) {
      return source.page(items, page, {hasMore: false});
    }
    let maxPage = page;
    for (const match of body.matchAll(new RegExp(`/hxq/${active}-(\\d+)\\.html`, 'gis'))) {
      const value = Number(match[1]);
      if (value > maxPage && value < 100000) maxPage = value;
    }
    const pageCount = maxPage > page ? maxPage : (items.length >= source.pageSize ? page + 1 : page);
    return source.page(items, page, {hasMore: page < pageCount});
  },

  detail(ctx, id) {
    if (!/^\d{1,12}$/.test(String(id))) {
      throw new Error('韩小圈视频 ID 无效');
    }
    const body = source.getText(ctx, `/hanxiaoquan/${id}.html`, {label: '韩小圈'});
    const name = source.clean((body.match(/<h1 class="page-title[^"]*">([\s\S]*?)<\/h1>/i) || [])[1]);
    if (!name) {
      throw new Error('韩小圈详情缺少视频名称');
    }
    let cover = source.url((body.match(/property="og:image"\s+content="([^"]+)"/i) || [])[1]);
    if (!cover) {
      cover = source.url((body.match(/<div class="video-cover">[\s\S]*?<img[^>]*data-src="([^"]+)"/i) || [])[1]);
    }
    const fields = infoFields(body);
    let description = fields['剧情'] || fields['简介'] || '';
    // 简介里常夹带 "@广告词@" 形式的干扰词，去掉首尾 @...@ 段。
    description = description.replace(/@[^@]{1,60}@/g, '');
    const tags = source.tags([
      fields['上映'] ? fields['上映'] + '年' : '',
      fields['导演'] ? '导演 ' + fields['导演'].slice(0, 32) : '',
      fields['主演'] ? '主演 ' + fields['主演'].slice(0, 48) : '',
    ]);

    const chapters = pickPlaylist(body, ctx);
    if (!chapters.length) {
      throw new Error('韩小圈暂无可播放分集');
    }
    return {
      drama: {
        sourceId: String(id),
        title: name,
        description: description.slice(0, 12000),
        cover: cover,
        category: '韩剧',
        onlineDate: (fields['更新'] || '').slice(0, 32),
        tags: tags,
      },
      chapters: chapters,
    };
  },

  resolve(ctx, task) {
    const playURL = task.pageUrl || task.chapterId;
    if (!playURL || !playPageURL(playURL, ctx)) {
      throw new Error('韩小圈播放页地址无效');
    }
    return source.macPlaylist(ctx, playURL, {label: '韩小圈'});
  },
});

// 列表解析交给宿主的 source.cards。这里的卡片是"标题锚点 + 后续 600
// 字符内的封面/备注"，用 window 保留原实现的取值边界。
function parseCards(body) {
  return source.cards(body, {
    item: 'a.module-item-pic',
    window: 600,
    id: /\/hanxiaoquan\/(\d+)\.html/,
    title: 'attr:title',
    cover: 'img@data-src',
    remark: '.module-item-text',
    defaultCategory: '韩剧',
    extra: (node, chunk, row) => {
      if (row.title) return null;
      // title 属性缺失时退到 .module-item-title 的文本。
      const anchor = hg.html.findFirst(node, 'a.module-item-title');
      return anchor ? {title: hg.html.text(anchor).trim()} : null;
    },
  });
}

function infoFields(body) {
  const fields = {};
  for (const match of body.matchAll(
    /<span class="video-info-itemtitle">([^<]*)<\/span>\s*<div class="video-info-item[^"]*">([\s\S]*?)<\/div>/gis,
  )) {
    const label = (match[1] || '').trim().replace(/：$/, '').trim();
    const value = source.clean(match[2]);
    if (label && value && !(label in fields)) {
      fields[label] = value;
    }
  }
  return fields;
}

// pickPlaylist 解析全部线路，返回分集最多的一条。
function pickPlaylist(body, ctx) {
  const lineNames = {};
  for (const tab of body.matchAll(/href="#playlist(\d+)"[^>]*>\s*<i[^>]*><\/i>\s*([^<]+)/gis)) {
    lineNames[tab[1]] = tab[2].trim();
  }
  let lineIDs = Object.keys(lineNames).sort();
  if (lineIDs.length === 0) {
    lineIDs = [''];
  }
  let best = [];
  for (const lineID of lineIDs) {
    let segment = body;
    if (lineID) {
      const marker = `id="playlist${lineID}"`;
      const start = body.indexOf(marker);
      if (start < 0) continue;
      // 从本容器标记之后开始找下一个 playlist 容器或列表结束标记，
      // 避免把后续线路的分集一并算入。
      segment = body.slice(start + marker.length);
      const nextPlaylist = segment.indexOf('id="playlist');
      const footer = segment.indexOf('class="module-footer"');
      if (nextPlaylist >= 0) segment = segment.slice(0, nextPlaylist);
      else if (footer >= 0) segment = segment.slice(0, footer);
    }
    const chapters = [];
    const seenPath = new Set();
    for (const ep of segment.matchAll(/<a title="([^"]*)" href="(\/play\/\d+-\d+-\d+\.html)"/gis)) {
      const epTitle = source.clean(ep[1]);
      const playURL = playPageURL(ep[2], ctx);
      if (!playURL || seenPath.has(playURL)) continue;
      seenPath.add(playURL);
      const lead = (epTitle.match(/(\d+)/) || [])[1];
      const order = lead ? Number(lead) : chapters.length + 1;
      chapters.push({
        id: playURL,
        title: epTitle || `第 ${order} 集`,
        episode: order,
        pageUrl: playURL,
      });
    }
    if (chapters.length > best.length) best = chapters;
  }
  if (!best.length) {
    throw new Error('韩小圈暂无可播放分集');
  }
  return source.chapters(best);
}

// playPageURL 归一化播放锚点并校验同源；
// ctx 带 host 时（测试/镜像）额外放行该主机。
function playPageURL(href, ctx) {
  href = (href || '').trim();
  if (!href) return '';
  const base = source.base(ctx);
  if (!href.startsWith('http')) {
    href = base + '/' + href.replace(/^\//, '');
  }
  const parsed = hg.url.parse(href);
  if (!parsed.valid) return '';
  const host = parsed.hostname.toLowerCase();
  let allowed = host === 'jennyhow.com' || host === 'www.jennyhow.com';
  if (!allowed && ctx && ctx.host) {
    const ctxHost = hg.url.parse(ctx.host);
    allowed = ctxHost.valid && ctxHost.hostname.toLowerCase() === host;
  }
  if (!allowed) return '';
  const path = parsed.path.toLowerCase();
  if (!path.endsWith('.html') || !path.includes('/play/')) return '';
  return parsed.href;
}

function searchHanxiaoquan(ctx, page, query) {
  query = query.trim();
  if (!query || query.length > 256) {
    throw new Error('韩小圈搜索关键词无效');
  }
  if (page > 1) {
    return source.page([], page, {hasMore: false});
  }
  const body = source.getText(ctx, '/search.php?searchword=' + encodeURIComponent(query), {label: '韩小圈'});
  return source.page(parseCards(body), page, {hasMore: false});
}

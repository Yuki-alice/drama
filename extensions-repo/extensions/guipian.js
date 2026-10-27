// ==HongguoExtension==
// @id guipian
// @name 鬼片
// @version 1.0.0
// @apiLevel 1
// @description 鬼片 · 电视剧 · 动漫
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==

// 鬼片扩展源：MacCMS 风格 HTML 站点。
// 页面结构：/list/{id}[_{page}].html 分类、/nv/{id}.html 详情、
// /play/{id}-{line}-{ep}.html 播放页（var now="<m3u8>"）、/xml/rss.xml 最新条目。
globalThis.source = hgkit.defineSource({
  name: '鬼片网',
  baseURL: 'https://guipianwu.com',
  pageSize: 24,
  categories: [
    {id: '3', name: '恐怖片'},
    {id: '6', name: '大陆鬼片'},
    {id: '7', name: '日韩鬼片'},
    {id: '8', name: '林正英鬼片'},
    {id: '9', name: '港台鬼片'},
    {id: '10', name: '泰国鬼片'},
    {id: '11', name: '欧美鬼片'},
    {id: '31', name: '剧情片'},
    {id: '12', name: '国产剧'},
    {id: '13', name: '美剧'},
    {id: '14', name: '韩剧'},
    {id: '15', name: '日剧'},
    {id: '16', name: '泰剧'},
    {id: '17', name: '港台剧'},
    {id: '18', name: '其他剧'},
    {id: '23', name: '日韩动漫'},
    {id: '24', name: '国产动漫'},
    {id: '25', name: '欧美动漫'},
    {id: '26', name: '港台动漫'},
  ],

  catalog(ctx, page, category, query) {
    if (query) {
      return searchGuipian(ctx, page, query);
    }
    if (page < 1 || page > 100000) {
      throw new Error('鬼片网目录页码无效');
    }
    const active = category || source.categories({}, false)[0].id;
    const path = page > 1 ? `/list/${active}_${page}.html` : `/list/${active}.html`;
    const body = source.getText(ctx, path, {label: '鬼片网'});
    const items = parseCards(body);
    if (items.length === 0) {
      return source.page(items, page, {hasMore: false});
    }
    // 从分页链接推断末页；拿不到时按满页保守判断。
    let maxPage = page;
    for (const match of body.matchAll(new RegExp(`/list/${active}_(\\d+)\\.html`, 'gis'))) {
      const value = Number(match[1]);
      if (value > maxPage && value < 100000) maxPage = value;
    }
    const pageCount = maxPage > page ? maxPage : (items.length >= source.pageSize ? page + 1 : page);
    return source.page(items, page, {hasMore: page < pageCount});
  },

  detail(ctx, id) {
    if (!/^\d{1,12}$/.test(String(id))) {
      throw new Error('鬼片网视频 ID 无效');
    }
    const body = source.getText(ctx, `/nv/${id}.html`, {label: '鬼片网'});
    let name = extract(body, /<h1 class="media-title[^"]*">([\s\S]*?)<\/h1>/i);
    if (!name) {
      const raw = source.clean(extract(body, /<title>([\s\S]*?)<\/title>/i));
      if (raw.includes('提示信息') || raw.includes('影片不存在')) {
        throw new Error('鬼片网影片不存在');
      }
      name = (raw.match(/《(.*?)》/) || [])[1] || raw.trim();
    }
    if (!name) {
      throw new Error('鬼片网详情缺少视频名称');
    }
    let cover = source.url(extract(body, /<div class="detail-img"><img[^>]+src="([^"]+)"/i));
    if (!cover) {
      cover = source.url(extract(body, /<div class="detail-cover[^"]*"[^>]*data-original="([^"]+)"/i));
    }
    const description = source.clean(extract(body, /简介：([\s\S]*?)<\/li>/i));
    const year = source.clean(extract(body, /年份：<span>([\s\S]*?)<\/span>/i));
    const director = source.clean(extract(body, /导演：([\s\S]*?)<\/span>/i));
    const area = source.clean(extract(body, /地区：<span><a[^>]*>([\s\S]*?)<\/a>/i));
    const status = source.clean(extract(body, /状态：([\s\S]*?)<\/span>/i));
    const actorsMatch = body.match(/主演：([\s\S]*?)<\/span>/i);
    let actors = '';
    if (actorsMatch) {
      const names = [...actorsMatch[1].matchAll(/<a[^>]*>([^<]+)<\/a>/gis)]
        .map((match) => source.clean(match[1])).filter(Boolean);
      actors = names.length ? names.join(' ') : source.clean(actorsMatch[1]);
    }
    const tags = source.tags([
      year ? year + '年' : '',
      area,
      director ? '导演 ' + director.slice(0, 32) : '',
      actors ? '主演 ' + actors.slice(0, 48) : '',
    ]);

    const chapters = pickPlaylist(body, ctx);
    if (!chapters.length) {
      throw new Error('鬼片网线路暂无可播放分集');
    }
    return {
      drama: {
        sourceId: String(id),
        title: name,
        description: description.slice(0, 12000),
        cover: cover,
        category: '影视',
        releaseStatus: status ? (status.includes('完结') ? 'finished' : status.includes('连载') ? 'serializing' : '') : '',
        tags: tags,
      },
      chapters: chapters,
    };
  },

  resolve(ctx, task) {
    const playURL = task.pageUrl || task.chapterId;
    if (!playURL || !playURL.includes('/play/') || !playURL.endsWith('.html')) {
      throw new Error('鬼片网播放页地址无效');
    }
    return source.macPlaylist(ctx, playURL, {label: '鬼片网'});
  },
});

function extract(body, pattern) {
  const match = body.match(pattern);
  return match ? match[1] : '';
}

// 列表解析交给宿主的 source.cards：只声明选择器与字段位置，
// 去重、上限、封面地址校验由宿主保证。
function parseCards(body) {
  return source.cards(body, {
    container: 'ul.row.video-list.video-film-list',
    item: 'a.video-link',
    id: /\/nv\/(\d+)\.html/,
    title: 'attr:title',
    // 封面属性在不同模板里叫 data-original 或 data-background。
    cover: (node) => {
      const target = hg.html.findFirst(node, '[data-original]') ||
        hg.html.findFirst(node, '[data-background]');
      if (!target) return '';
      return hg.html.attr(target, 'data-original') ||
        hg.html.attr(target, 'data-background') || '';
    },
    remark: '.video-duration',
    defaultCategory: '影视',
  });
}

// pickPlaylist 选出分集最多的一条线路。
function pickPlaylist(body, ctx) {
  const tabs = [...body.matchAll(
    /<li class="swiper-slide ewave-tab[^"]*" data-target="#(ewave-playlist-\d+)">([^<]+)<\/li>/gis,
  )];
  if (!tabs.length) {
    throw new Error('鬼片网未找到可用播放线路');
  }
  const seenAnchor = new Set();
  let best = [];
  for (const tab of tabs) {
    const anchor = tab[1];
    if (!anchor || seenAnchor.has(anchor)) continue;
    seenAnchor.add(anchor);
    // 从本容器标记之后截到下一条线路或 </section>，避免吃掉下一条线路的开头。
    const marker = `id="${anchor}"`;
    const start = body.indexOf(marker);
    if (start < 0) continue;
    let segment = body.slice(start + marker.length);
    const nextSlide = segment.indexOf('<div class="playlist-slide');
    const sectionEnd = segment.indexOf('</section>');
    if (nextSlide >= 0) segment = segment.slice(0, nextSlide);
    else if (sectionEnd >= 0) segment = segment.slice(0, sectionEnd);

    const chapters = [];
    const seenPath = new Set();
    for (const ep of segment.matchAll(/<li><a title='([^']*)' href='([^']+)'/gis)) {
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
    throw new Error('鬼片网线路暂无可播放分集');
  }
  return source.chapters(best);
}

// playPageURL 归一为绝对 URL 并校验同源 .html 播放页。
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
  const allowed = host === 'guipianwu.com' || host === 'www.guipianwu.com' ||
    (ctx && ctx.host && hg.url.parse(ctx.host).hostname.toLowerCase() === host);
  if (!allowed) return '';
  const path = parsed.path.toLowerCase();
  if (!path.endsWith('.html') || !path.includes('/play/')) return '';
  return parsed.href;
}

// searchGuipian 在 RSS 最新条目里做标题匹配（站点搜索接口已停用）。
function searchGuipian(ctx, page, query) {
  query = query.trim();
  if (!query || query.length > 256) {
    throw new Error('鬼片网搜索关键词无效');
  }
  const body = source.getText(ctx, '/xml/rss.xml', {label: '鬼片网'});
  const needle = query.toLowerCase();
  const matched = [];
  const seen = new Set();
  for (const item of body.matchAll(/<item>([\s\S]*?)<\/item>/gis)) {
    const segment = item[1];
    const title = source.clean((segment.match(/<title>\s*(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?\s*<\/title>/i) || [])[1]);
    const id = (segment.match(/\/nv\/(\d+)\.html/) || [])[1];
    if (!title || !id || seen.has(id)) continue;
    if (!title.toLowerCase().includes(needle)) continue;
    seen.add(id);
    matched.push({sourceId: id, title: title, category: '影视'});
  }
  const start = (page - 1) * source.pageSize;
  if (start >= matched.length) {
    return source.page([], page, {hasMore: false});
  }
  const end = Math.min(start + source.pageSize, matched.length);
  return source.page(matched.slice(start, end), page, {hasMore: end < matched.length});
}

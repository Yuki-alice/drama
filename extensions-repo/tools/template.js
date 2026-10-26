// ==HongguoExtension==
// @id example
// @name 示例源
// @version 1.0.0
// @apiLevel 1
// @description 复制到 extensions/<id>.js 后修改
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==

// 新扩展从这里开始。hgkit 由宿主在每个脚本前注入（apiLevel 1）：
//   source.getText/getJSON  -> 走宿主网络栈，自动拼 base、带 Referer
//   source.clean/text/pick/int/tags -> 文本与字段归一
//   source.url/mediaURL/cover -> URL 解析与校验
//   source.page/chapters/drama -> 分页、分集、剧集条目归一
//   source.base(ctx) -> 测试/镜像地址或站点根
// defineSource 会补默认 validCategory（基于 categories）和 resolve（直接媒体地址）。
globalThis.source = hgkit.defineSource({
  name: '示例源',
  baseURL: 'https://example.com',
  pageSize: 24,
  categories: [
    {id: '1', name: '全部'},
  ],

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 100000) {
      throw new Error('示例源目录页码无效');
    }
    const body = source.getText(
      ctx,
      '/list?page=' + page +
        (category ? '&category=' + encodeURIComponent(category) : '') +
        (query ? '&q=' + encodeURIComponent(query) : ''),
      {label: '示例源'},
    );
    const document = hg.html.parse(body);
    const items = [];
    for (const card of hg.html.findAll(document, '.card')) {
      const link = hg.html.findFirst(card, 'a');
      const id = hg.html.attr(link, 'data-id');
      const title = source.clean(hg.html.text(link));
      if (!id || !title) continue;
      const image = hg.html.findFirst(card, 'img');
      items.push({
        sourceId: id,
        title: title,
        cover: source.url(hg.html.attr(image, 'src')),
        category: '示例',
      });
    }
    return source.page(items, page, {hasMore: items.length >= source.pageSize});
  },

  detail(ctx, id) {
    const body = source.getText(ctx, '/detail/' + encodeURIComponent(id), {label: '示例源'});
    const document = hg.html.parse(body);
    const title = source.clean(hg.html.text(hg.html.findFirst(document, 'h1')));
    if (!title) {
      throw new Error('示例源详情缺少标题');
    }
    const chapters = [];
    for (const link of hg.html.findAll(document, '.episode a')) {
      const pageUrl = source.url(hg.html.attr(link, 'href'));
      if (!pageUrl) continue;
      chapters.push({
        id: pageUrl,
        title: source.clean(hg.html.text(link)),
        pageUrl: pageUrl,
      });
    }
    return {
      drama: {
        sourceId: String(id),
        title: title,
        cover: source.url(hg.html.attr(hg.html.findFirst(document, 'img'), 'src')),
        category: '示例',
      },
      chapters: source.chapters(chapters),
    };
  },

  // 可选：章节有直接 videoUrl 时省略 resolve；否则实现：
  // resolve(ctx, task) { ... return {url, referer}; }
  // 可选：rankingBoards(ctx) / rankings(ctx, boardId, data, page)
});

// hgkit 归一化层：标签、分页、分集与剧集条目。
//
// 依赖 kit-core 的 text/int/pick/rawPick/cleanText 与 kit-html 的 coverURL。
(function (kit) {
  'use strict';

  const {text, int, pick, rawPick, cleanText, coverURL} = kit;

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

  Object.assign(kit, {
    tags: tags,
    page: pageResult,
    chapters: normalizeChapters,
    drama: drama,
  });
})(globalThis.hgkit);

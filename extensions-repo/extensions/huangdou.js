// ==HongguoExtension==
// @id huangdou
// @name 黄豆
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description 精选短剧
// ==/HongguoExtension==

// 黄豆扩展源：设备签名 + gzip + AES 请求体 + 响应解密的四层协议（与原 Go provider 对齐）。
//
// 请求构造（每一层都不能省略，否则站点直接拒绝）：
//   1. requestId 是随机 UUID（32 hex + 连字符）；
//   2. 请求密钥 = HMAC-SHA256(platformKey, requestId 的 hex 字节)；
//   3. 明文 = gzip(JSON{token, deviceId, data})；
//   4. 请求体 = IV(16 字节随机) + AES-CBC(明文, 密钥, IV)；
//   5. 头部带 time + sign = sha256("Dart|sessionId|requestId|time|path") + "-" + time。
//
// 响应：JSON 直接可用；否则 IV = 前 16 字节，AES-CBC 解密后再 gunzip。
globalThis.source = hgkit.defineSource({
  name: '黄豆',
  baseURL: 'https://tideember.cc',
  // 站点改版后的备用域名，主域失败时切换（与原 Go 版 huangdouAPIClient 一致）。
  fallbackBaseURL: 'https://xqjurgek.top',
  fallbackHostKey: 'host',
  pageSize: 30,
  version: '2.0.0',
  deviceType: 'web',
  platformKey: '7961beb44246e3012ce228d6b5ced05a',

  categories(ctx, force) {
    // 黄豆只有「全部」一档，分类恒为空。
    return [];
  },

  validCategory(category) {
    return category === '';
  },

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 100000) {
      throw new Error('黄豆目录页码无效');
    }
    if (category) {
      throw new Error('黄豆不支持分类筛选');
    }
    if (query) {
      throw new Error('黄豆不支持站内搜索');
    }
    const decoded = apiCall(ctx, '/drama/list', {page: String(page), page_size: String(source.pageSize)});
    const rows = listOf(decoded);
    const items = [];
    for (const row of rows) {
      const drama = dramaFromMap(row);
      if (drama) items.push(drama);
    }
    return source.page(items, page, {hasMore: rows.length >= source.pageSize});
  },

  detail(ctx, id) {
    const sourceID = text(id).replace(/^rp_/, '');
    if (!sourceID) {
      throw new Error('黄豆剧集 ID 无效');
    }
    const row = detailRow(ctx, sourceID);
    const episodes = listOf(row.episodes);
    let count = integer(firstPresent([row.episode_count, row.free_episodes]), 10000);
    if (count == null || count <= 0) count = episodes.length;
    if (count <= 0 || count > 10000) {
      throw new Error('黄豆返回了无效集数: ' + count);
    }
    const chapters = [];
    const seen = new Set();
    if (episodes.length) {
      episodes.forEach((episode, index) => {
        let sequence = integer(firstPresent([episode.seq, episode.episode, episode.ep]), 10000);
        if (sequence == null || sequence <= 0) sequence = index + 1;
        const key = String(sequence);
        if (seen.has(key)) return;
        seen.add(key);
        chapters.push({
          id: key,
          title: firstPresent([episode.name, episode.title]) || '第' + sequence + '集',
          episode: sequence,
          vip: episodeVIP(row, episode, sequence) || undefined,
        });
      });
    } else {
      for (let sequence = 1; sequence <= count; sequence++) {
        chapters.push({
          id: String(sequence),
          title: '第' + sequence + '集',
          episode: sequence,
          vip: episodeVIP(row, null, sequence) || undefined,
        });
      }
    }
    const normalized = source.chapters(chapters, {maxTitle: 256});
    const drama = dramaFromMap(row);
    if (!drama) {
      throw new Error('黄豆详情缺少有效剧集');
    }
    drama.sourceId = sourceID;
    if (text(firstPresent([row.name, row.title, row.t])) && drama.title !== text(firstPresent([row.name, row.title, row.t]))) {
      drama.title = text(firstPresent([row.name, row.title, row.t]));
    }
    drama.episodes = normalized.length;
    return {drama: drama, chapters: normalized};
  },

  resolve(ctx, task) {
    const sourceID = text(task.dramaId).replace(/^rp_/, '');
    const sequence = integer(task.chapterId, 10000);
    if (!sourceID || sequence == null || sequence < 1) {
      throw new Error('黄豆集数无效');
    }
    const decoded = apiCall(ctx, '/drama/play', {id: sourceID, seq: String(sequence)});
    const data = dataMap(decoded);
    let media = firstPresent([data.m3u8, data.url, data.play_url, data.playUrl]);
    if (previewOnly(data, media)) {
      throw new Error('黄豆仅提供试看，未取得该集正片；不会把试看内容当作完整分集');
    }
    if (!media) {
      // 备用播放列表：站点未给地址时按约定路径拼装并校验 m3u8 头。
      media = base(ctx) + '/api/drama/hls/' + encodeURIComponent(sourceID) + '/' + sequence + '/play.m3u8?line=free';
      const playlist = fetchText(ctx, media, base(ctx) + '/home');
      if (!/^\s*#EXTM3U/.test(playlist)) {
        throw new Error('黄豆未提供有效的播放地址，备用播放列表也不可用');
      }
    }
    const address = resolveURL(base(ctx) + '/', media);
    if (!address) {
      throw new Error('黄豆播放地址不是 HTTP/HTTPS URL');
    }
    const result = {url: address, referer: base(ctx) + '/home'};
    const rawKey = text(data.hls_key);
    if (rawKey) {
      // hls_key 是 16 字节密钥的 hex；宿主经 credentials 之外的字段透传。
      if (!/^[0-9a-fA-F]{32}$/.test(rawKey)) {
        throw new Error('黄豆返回了无效的 HLS 密钥');
      }
      result.hlsKey = rawKey;
    }
    return result;
  },


  rankingBoards(ctx) {
    return [
      {id: 'huangdou-all', name: '总榜', description: '黄豆短剧总榜，保留站点返回的顺序。', data: 'all'},
      {id: 'huangdou-mogai', name: '魔改榜', description: '黄豆站点魔改榜。', data: 'mogai'},
      {id: 'huangdou-search', name: '搜索榜', description: '黄豆站点搜索榜。', data: 'search'},
      {id: 'huangdou-favorite', name: '收藏榜', description: '黄豆站点收藏榜。', data: 'favorite'},
      {id: 'huangdou-finish', name: '完结榜', description: '黄豆站点完结榜。', data: 'finish'},
    ];
  },

  rankings(ctx, boardId, data, page) {
    const tab = text(data) || 'all';
    const decoded = apiCall(ctx, '/drama/rank', {tab: tab, page: String(page)});
    const rows = dataMap(decoded).list;
    if (!Array.isArray(rows)) {
      throw new Error('黄豆未返回有效榜单');
    }
    if (rows.length > 20) {
      throw new Error('黄豆榜单分页格式已变化');
    }
    const items = [];
    const seen = new Set();
    for (const row of rows) {
      const sourceID = text(firstPresent([row && row.id, row && row.drama_id])).replace(/^rp_/, '');
      const title = firstPresent([row && row.name, row && row.title, row && row.t]);
      if (!sourceID || !title || seen.has(sourceID)) {
        throw new Error('黄豆榜单包含无效或重复条目');
      }
      seen.add(sourceID);
      const drama = dramaFromMap(row) || {sourceId: sourceID, title: title};
      drama.sourceId = sourceID;
      if (drama.heat) drama.remark = drama.heat + '热度';
      items.push(drama);
    }
    return {items: items, hasMore: rows.length === 20};
  },
});

// —— 协议实现 ——

// apiCall 构造并发送一次加密请求，返回解密后的 payload。
function apiCall(ctx, path, data) {
  const client = session();
  const route = path.charAt(0) === '/' ? path : '/' + path;
  const requestID = uuidLike();
  const key = keyFor(requestID);
  const iv = hg.crypto.randomBytes(16);
  const plain = JSON.stringify({
    token: '',
    deviceId: client.deviceId,
    data: data || {},
  });
  // 明文先 gzip 再 AES-CBC；IV 拼在密文前面。
  // hg.crypto.gzip 接受 JS 文本并按 UTF-8 压缩，返回压缩字节的 base64。
  const bodyBase64 = hg.crypto.concatBytes(
    iv,
    hg.crypto.aesCBCEncryptBytes(hg.crypto.gzip(plain), key, iv),
  );
  const timestamp = String(Math.floor(Date.now() / 1000));
  const sign = hg.crypto.sha256hex(
    'Dart|' + client.sessionID + '|' + requestID + '|' + timestamp + '|' + route,
  ) + '-' + timestamp;
  const headers = {
    Accept: '*/*',
    Origin: base(ctx),
    Referer: base(ctx) + '/home',
    'Content-Type': 'application/octet-stream',
    version: source.version,
    deviceType: source.deviceType,
    requestId: requestID,
    sessionId: client.sessionID,
    time: timestamp,
    sign: sign,
  };
  let response;
  try {
    response = hg.fetch(base(ctx) + '/api' + route, {method: 'POST', headers: headers, bodyBase64: bodyBase64});
  } catch (error) {
    // 主域失败时切换备用域名重试一次。
    if (base(ctx) === source.baseURL) {
      hg.storage.set('host', source.fallbackBaseURL);
      response = hg.fetch(source.fallbackBaseURL + '/api' + route, {method: 'POST', headers: headers, bodyBase64: bodyBase64});
    } else {
      throw error;
    }
  }
  if (response.status < 200 || response.status >= 300) {
    throw new Error('黄豆接口 HTTP ' + response.status);
  }
  const decoded = decodeResponse(response.bodyBase64 || textToBase64(response.body), key);
  if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) {
    const status = text(decoded.status);
    if (status && status !== 'y') {
      const code = text(firstPresent([decoded.errorCode, decoded.error_code, decoded.code]));
      throw accessError(code, firstPresent([decoded.msg, decoded.message, decoded.error]) || status);
    }
  }
  // 记住可用域名，后续请求直接用。
  hg.storage.set('host', base(ctx));
  return decoded;
}

// accessError 把站点的权限类错误码标记出来（原 Go 版停止重试并提示）。
function accessError(code, message) {
  const blocked = ['813004', '813005', '813006', '813103', 'preview'];
  const error = new Error(message || '黄豆接口拒绝请求');
  if (blocked.indexOf(code) >= 0) {
    error.message = message + '（站点权限限制，已停止自动重试；切换代理不会解锁）';
  }
  return error;
}

// keyFor 由 requestId 派生请求密钥：HMAC-SHA256(platformKey, hex 字节)。
// 返回 hex 形式：宿主的 AES 接口统一以 hex 承载密钥。
function keyFor(requestID) {
  const hex = requestID.replace(/-/g, '');
  if (!/^[0-9a-fA-F]{32}$/.test(hex)) {
    throw new Error('黄豆请求标识无效');
  }
  const raw = hg.crypto.hmacSha256KeyBytes(textToBase64(source.platformKey), hg.crypto.hexdecodeBytes(hex));
  return hg.crypto.hexencodeBytes(raw);
}

// decodeResponse 解密响应：JSON 明文直接返回，否则 IV + 密文。
function decodeResponse(bodyBase64, key) {
  const asText = base64ToTextSafe(bodyBase64);
  if (asText != null) {
    try {
      return JSON.parse(asText);
    } catch (error) {
      // 落到密文解密。
    }
  }
  const hex = hg.crypto.hexencodeBytes(bodyBase64);
  if (hex.length < 64) {
    throw new Error('黄豆响应过短');
  }
  const iv = hg.crypto.hexdecodeBytes(hex.slice(0, 32));
  const cipher = hg.crypto.hexdecodeBytes(hex.slice(32));
  let plain = hg.crypto.aesCBCDecryptBytes(cipher, key, iv);
  // 明文可能是 gzip（1f 8b 开头），解压后才是 JSON。
  const plainHex = hg.crypto.hexencodeBytes(plain);
  if (plainHex.slice(0, 4) === '1f8b') {
    plain = hg.crypto.gunzipBytes(plain);
  }
  const decoded = base64ToTextSafe(plain);
  if (decoded == null) {
    throw new Error('黄豆响应格式异常');
  }
  try {
    return JSON.parse(decoded);
  } catch (error) {
    throw new Error('黄豆响应格式异常');
  }
}

// base64ToTextSafe 把 base64 字节按 UTF-8 解码；非法 UTF-8 返回 null。
function base64ToTextSafe(encoded) {
  const hex = hg.crypto.hexencodeBytes(encoded);
  const bytes = [];
  for (let index = 0; index + 1 < hex.length; index += 2) {
    bytes.push(parseInt(hex.slice(index, index + 2), 16));
  }
  let out = '';
  for (let index = 0; index < bytes.length;) {
    const first = bytes[index];
    if (first < 0x80) {
      out += String.fromCharCode(first);
      index += 1;
    } else if (first < 0xc0) {
      return null;
    } else if (first < 0xe0) {
      if (index + 1 >= bytes.length) return null;
      out += String.fromCharCode(((first & 0x1f) << 6) | (bytes[index + 1] & 0x3f));
      index += 2;
    } else if (first < 0xf0) {
      if (index + 2 >= bytes.length) return null;
      out += String.fromCharCode(((first & 0x0f) << 12) | ((bytes[index + 1] & 0x3f) << 6) | (bytes[index + 2] & 0x3f));
      index += 3;
    } else {
      if (index + 3 >= bytes.length) return null;
      const code = ((first & 0x07) << 18) | ((bytes[index + 1] & 0x3f) << 12) |
        ((bytes[index + 2] & 0x3f) << 6) | (bytes[index + 3] & 0x3f);
      const value = code - 0x10000;
      out += String.fromCharCode(0xd800 + (value >> 10), 0xdc00 + (value & 0x3ff));
      index += 4;
    }
  }
  return out;
}

// textToBase64 把 JS 字符串按 UTF-8 编码成 base64。
function textToBase64(value) {
  return hg.crypto.base64encode(value);
}

// session 返回本机的会话标识：设备号与会话号都是随机 32 hex。
function session() {
  const raw = hg.storage.get('session');
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && /^[0-9a-f]{32}$/.test(text(parsed.deviceId)) && /^[0-9a-f]{32}$/.test(text(parsed.sessionID))) {
        return {deviceId: text(parsed.deviceId), sessionID: text(parsed.sessionID)};
      }
    } catch (error) {
      // 损坏的缓存按新会话处理。
    }
  }
  const deviceID = hg.crypto.hexencodeBytes(hg.crypto.randomBytes(16));
  const sessionID = hg.crypto.hexencodeBytes(hg.crypto.randomBytes(16));
  hg.storage.set('session', JSON.stringify({deviceId: deviceID, sessionID: sessionID}));
  return {deviceId: deviceID, sessionID: sessionID};
}

function uuidLike() {
  const hex = hg.crypto.hexencodeBytes(hg.crypto.randomBytes(16));
  if (hex.length !== 32) return hex;
  return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' +
    hex.slice(16, 20) + '-' + hex.slice(20);
}

// —— 数据解析 ——

const text = (value) => source.text(value);
const firstPresent = (values) => source.first(values);
const resolveURL = hgkit.url;

function integer(value, maximum) {
  const raw = typeof value === 'number' ? String(value) : text(value);
  if (!/^\d+$/.test(raw)) return null;
  const number = Number(raw);
  if (!Number.isInteger(number) || number < 0 || number > maximum) return null;
  return number;
}

function base(ctx) {
  return source.base(ctx);
}

function fetchText(ctx, address, referer) {
  return source.getText(ctx, address, {
    label: '黄豆资源',
    headers: {Referer: referer},
  });
}

// dataMap 取响应里的业务数据：部分接口多套一层 data。
function dataMap(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  if (value.data && typeof value.data === 'object' && !Array.isArray(value.data)) return value.data;
  return value;
}

// listOf 从多种容器形态里取列表（与原 Go 版 huangdouList 一致）。
function listOf(value) {
  if (Array.isArray(value)) return value.filter((item) => item && typeof item === 'object');
  if (!value || typeof value !== 'object') return [];
  for (const key of ['list', 'items', 'data']) {
    const nested = listOf(value[key]);
    if (nested.length) return nested;
  }
  return [];
}

// detailRow 拉取并缓存剧集详情（同一次调用内多次使用）。
function detailRow(ctx, sourceID) {
  const decoded = apiCall(ctx, '/drama/detail', {id: sourceID});
  const row = dataMap(decoded);
  const actual = text(firstPresent([row.id, row.drama_id])).replace(/^rp_/, '');
  if (actual && actual !== sourceID) {
    throw new Error('黄豆详情返回了其他剧集');
  }
  return row;
}

// dramaFromMap 把黄豆的剧集行转成契约对象。
function dramaFromMap(item) {
  if (!item || typeof item !== 'object') return null;
  const sourceID = text(firstPresent([item.id, item.drama_id])).replace(/^rp_/, '');
  if (!sourceID) return null;
  const title = firstPresent([item.name, item.title, item.t]) || sourceID;
  const cover = firstPresent([item.img_y, item.img_x, item.img, item.cover, item.pic]);
  let remark = firstPresent([item.update_label, item.corner]);
  const releaseStatus = releaseStatusOf(remark);
  if (!remark) {
    const episodes = text(item.episode_count);
    if (episodes) remark = '全' + episodes + '集';
  }
  const category = firstPresent([item.category, item.category_name, item.categoryName]) || '未分类';
  const drama = {
    sourceId: sourceID,
    title: title,
    cover: cover,
    category: category,
    channelName: 'tideember.cc',
    remark: remark,
    releaseStatus: releaseStatus,
    heat: text(item.hot_rate),
    views: normalizeViews(item.click),
    onlineDate: releaseDate(text(item.issue_date)),
    tags: stringList(item.tags),
  };
  const description = firstPresent([item.description, item.summary]);
  if (description) {
    drama.description = description;
  }
  const episodes = integer(text(item.episode_count), 100000);
  if (episodes != null && episodes > 0) drama.episodes = episodes;
  const vip = vipFlag(item);
  if (vip != null) drama.vip = vip;
  return drama;
}

function releaseStatusOf(remark) {
  const raw = text(remark);
  if (!raw) return '';
  if (raw.indexOf('完结') >= 0 || raw.indexOf('全') === 0) return 'finished';
  if (raw.indexOf('连载') >= 0 || raw.indexOf('更新') >= 0) return 'serializing';
  return '';
}

function normalizeViews(value) {
  const raw = text(value);
  if (!raw) return '';
  return /次播放$/.test(raw) ? raw : raw + '次播放';
}

function releaseDate(value) {
  const raw = text(value);
  if (!raw) return '';
  const match = /(\d{4})-(\d{1,2})-(\d{1,2})/.exec(raw);
  if (!match) return '';
  const year = Number(match[1]);
  if (year < 2000 || year > 2100) return '';
  return match[1] + '-' + String(Number(match[2])).padStart(2, '0') + '-' + String(Number(match[3])).padStart(2, '0');
}

function stringList(value) {
  if (!Array.isArray(value)) return [];
  const out = [];
  const seen = new Set();
  for (const item of value) {
    const name = text(item);
    if (!name || [...name].length > 48 || seen.has(name)) continue;
    seen.add(name);
    out.push(name);
    if (out.length >= 16) break;
  }
  return out;
}

// vipFlag 解析 VIP 标记（与原 Go 版 huangdouVIPFlag 的优先级一致）。
function vipFlag(item) {
  let known = null;
  for (const key of ['is_vip', 'isVip']) {
    const value = text(item[key]).toLowerCase();
    if (value === 'true' || value === '1' || value === 'y') return true;
    if (value === 'false' || value === '0' || value === 'n') known = false;
  }
  const payType = text(item.pay_type).toLowerCase();
  if (payType === 'vip') return true;
  if (payType === 'free') known = false;
  for (const episode of vipEpisodes(item)) {
    if (episode > 0) return true;
  }
  for (const episode of listOf(item.episodes)) {
    if (text(episode.type).toLowerCase() === 'vip') return true;
  }
  return known;
}

function vipEpisodes(item) {
  const values = item && item.vip_episodes;
  if (!Array.isArray(values)) return [];
  const out = [];
  for (const value of values) {
    const index = integer(value, 10000);
    if (index != null && index > 0) out.push(index);
  }
  return out;
}

// episodeVIP 判断某一集是否 VIP（与原 Go 版 huangdouEpisodeVIP 一致）。
function episodeVIP(detail, episode, sequence) {
  const type = text(episode && episode.type).toLowerCase();
  if (type === 'vip') return true;
  if (type === 'free') return false;
  if (vipEpisodes(detail).indexOf(sequence) >= 0) return true;
  const flag = episode ? vipFlag(episode) : null;
  if (flag != null) return flag;
  if (text(detail.pay_type).toLowerCase() === 'vip') {
    const free = integer(text(detail.free_episodes), 10000);
    return free != null && free >= 0 && sequence > free;
  }
  return false;
}

// previewOnly 识别试看内容，避免把预告当正片（原 Go 版 huangdouPreviewOnly）。
function previewOnly(data, media) {
  const flag = text(firstPresent([data.is_preview, data.isPreview])).toLowerCase();
  if (flag === 'true' || flag === '1' || flag === 'y') return true;
  const preview = firstPresent([data.preview_m3u8, data.preview_url]);
  if (preview && (!media || media === preview)) return true;
  const parsed = hg.url.parse(text(media));
  if (!parsed.valid) return false;
  const path = parsed.path.toLowerCase();
  return path === 'preview.mp4' || path === 'preview.m3u8' ||
    path.endsWith('/preview.mp4') || path.endsWith('/preview.m3u8');
}

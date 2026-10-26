// ==HongguoExtension==
// @id cloudfront
// @name 黄果旧版
// @version 1.0.0
// @apiLevel 1
// @restricted true
// @description 旧 API 剧库
// @group huangguo
// @groupName 黄果
// @entryName 旧版
// ==/HongguoExtension==

// 黄果旧版扩展源：CloudFront 前端 + 加密 API（与原 Go legacy provider 对齐）。
//
// 协议要点（全部在 JS 侧实现，宿主只提供原始字节、AES 与哈希能力）：
//   1. 发现：拉取官网首页 → main-*.js → 读出 interfaceKey / parameterKey / parameterIv。
//   2. 请求：参数 JSON 经 AES-CBC 加密后放 data=，附带访客令牌与设备 UA。
//   3. 响应：{code, hash, data}，hash 为真时 data 是加密串，
//      密钥与 IV 由 interfaceKey 与响应前 12 字节经多段 SHA-256 派生。
//   4. 访客登录：POST /api/app/mine/login/h5，令牌缓存在 hg.storage。
globalThis.source = hgkit.defineSource({
  name: '黄果旧版',
  baseURL: 'https://d2pypzndaqisk.cloudfront.net',
  pageSize: 20,
  // protocol 来自官网脚本，缓存 24 小时；与 Go 版的 24h 有效期一致。
  protocolTTL: 24 * 3600 * 1000,

  categories(ctx, force) {
    const payload = apiCall(ctx, '/api/app/playlet-tab/all', null);
    const tabs = tabList(payload);
    const options = [];
    const seen = new Set();
    for (const tab of tabs) {
      const id = text(tab && tab.id);
      const name = text(tab && tab.name);
      if (!id || !name || id !== id.trim() || seen.has(id)) continue;
      seen.add(id);
      options.push({id: id, name: name});
    }
    return options;
  },

  validCategory(category) {
    return category === '' || text(category) === category;
  },

  catalog(ctx, page, category, query) {
    if (page < 1 || page > 100000) {
      throw new Error('黄果旧版目录页码无效');
    }
    if (query) {
      throw new Error('黄果旧版不支持站内搜索');
    }
    const payload = apiCall(ctx, '/api/app/playlet-tab/all', null);
    const tabs = tabList(payload);
    if (!tabs.length) {
      throw new Error('黄果旧 API 未返回可用分类');
    }
    if (category && !tabs.some((tab) => text(tab.id) === category)) {
      throw new Error('此分类已调整，请刷新分类列表');
    }
    const active = category ? tabs.filter((tab) => text(tab.id) === category) : tabs;
    const requests = active.map((tab) => ({
      url: null,
      path: '/api/app/playlet/home/tab/' + encodeURIComponent(text(tab.id)),
      params: {pageNumber: String(page), pageSize: String(source.pageSize), tabSortType: '1'},
      tab: tab,
    }));
    // 分类目录是多个 tab 的并行聚合；串行会成倍变慢。
    const payloads = apiCallMany(ctx, requests);
    const items = [];
    const seen = new Set();
    let hasMore = false;
    const failures = [];
    payloads.forEach((outcome, index) => {
      if (outcome.error) {
        failures.push(text(active[index].name) + '：' + outcome.error);
        hasMore = true;
        return;
      }
      const list = Array.isArray(outcome.value && outcome.value.list) ? outcome.value.list : [];
      hasMore = hasMore || list.length >= source.pageSize;
      for (const row of list) {
        const sourceID = text(row && row.id);
        if (!sourceID || seen.has(sourceID)) continue;
        seen.add(sourceID);
        const drama = dramaFromMap(row, text(active[index].name));
        if (drama) items.push(drama);
      }
    });
    if (failures.length && !items.length) {
      throw new Error(failures.join('；'));
    }
    return source.page(items, page, {hasMore: hasMore});
  },

  detail(ctx, id) {
    const sourceID = text(id);
    if (!sourceID || !/^[a-zA-Z0-9_-]{1,100}$/.test(sourceID)) {
      throw new Error('黄果旧版剧集 ID 无效');
    }
    const detail = apiCall(ctx, '/api/app/playlet/detail/' + encodeURIComponent(sourceID), null) || {};
    let chapters = Array.isArray(detail.chapters) ? detail.chapters : [];
    if (!chapters.length) {
      const list = apiCall(ctx, '/api/app/playlet-chapter/list/' + encodeURIComponent(sourceID), null);
      chapters = Array.isArray(list) ? list : [];
    }
    // 详情可能省略 id（只给 title/chapters）；此时以请求 ID 为准。
    const rawID = text(detail.id);
    if (rawID && rawID !== sourceID && rawID !== 'cloudfront:' + sourceID) {
      throw new Error('黄果旧版详情与请求剧集不符');
    }
    const drama = dramaFromMap(Object.assign({}, detail, {id: sourceID}), '') || {
      sourceId: sourceID,
      title: firstPresent([detail.title, detail.name]) || sourceID,
    };
    drama.sourceId = sourceID;
    if (text(detail.title)) drama.title = text(detail.title);
    if (text(detail.name) && !text(detail.title)) drama.title = text(detail.name);
    const rows = [];
    const seen = new Set();
    chapters.forEach((chapter, index) => {
      const key = firstPresent([text(chapter && chapter.id), String(index + 1)]);
      if (!key || seen.has(key)) return;
      seen.add(key);
      const number = chapterNumber(chapter, index + 1);
      rows.push({
        id: key,
        title: firstPresent([text(chapter && chapter.title), '第' + number + '集']),
        episode: number,
        videoUrl: text(chapter && chapter.videoUrl) || undefined,
        referer: source.baseURL + '/',
      });
    });
    if (!rows.length) {
      throw new Error('黄果旧版未返回可播放分集');
    }
    const normalized = source.chapters(rows, {maxTitle: 256});
    drama.episodes = normalized.length;
    return {drama: drama, chapters: normalized};
  },


  resolve(ctx, task) {
    const videoURL = text(task.videoUrl);
    if (!videoURL) {
      throw new Error('此分集没有可用的播放地址');
    }
    const access = credentials(ctx);
    if (!access.token && isMediaURL(videoURL)) {
      return {url: videoURL, referer: source.baseURL + '/'};
    }
    // 非 HTTP 地址是站点的媒体标识，需换成 API 的 m3u8 中转。
    let address = videoURL;
    if (!isMediaURL(address)) {
      address = apiBase(ctx) + '/api/app/vid/h5/m3u8/' +
        encodeURIComponent(address.replace(/^\/+|\/+$/g, '')) +
        '?' + 'token=' + encodeURIComponent(access.token) +
        '&c=' + encodeURIComponent(CDN);
    }
    return {url: address, referer: source.baseURL + '/'};
  },
});

// CDN 与原 Go 版 defaultCDNURL 一致。
const CDN = 'https://sjljsla.lkkwip.cn';

// —— 会话与协议发现 ——

function credentials(ctx) {
  const cached = session();
  if (cached.token && cached.deviceId) {
    return cached;
  }
  const deviceID = cached.deviceId || newDeviceID();
  const access = {deviceId: deviceID, token: ''};
  let payload = null;
  try {
    payload = request(ctx, 'POST', '/api/app/mine/login/h5',
      {devID: deviceID, sysType: 'ios', isAppStore: false}, access);
  } catch (error) {
    throw new Error('黄果访客登录失败: ' + error.message);
  }
  const token = text(payload && payload.token);
  if (!token || /\s/.test(token) || token.length > 4096) {
    throw new Error('黄果访客登录未返回有效令牌');
  }
  access.token = token;
  hg.storage.set('session', JSON.stringify({deviceId: deviceID, token: token}));
  return access;
}

function session() {
  const raw = hg.storage.get('session');
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') {
      return {
        deviceId: /^[A-Fa-f0-9]{16}[0-9]{13}$/.test(text(parsed.deviceId)) ? text(parsed.deviceId) : '',
        token: text(parsed.token),
      };
    }
  } catch (error) {
    // 损坏的缓存按未登录处理。
  }
  return {};
}

function newDeviceID() {
  // 8 字节大写 hex + 13 位毫秒时间戳，与 Go 版的 randomHex(8)+UnixMilli 一致。
  const random = hg.crypto.hexencodeBytes(hg.crypto.randomBytes(8)).toUpperCase();
  return random + String(Date.now());
}

// protocol 读取接口密钥：优先缓存，其次从官网脚本解析。
function protocol(ctx) {
  const raw = hg.storage.get('protocol');
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && validProtocol(parsed) && Date.now() - (parsed.loadedAt || 0) < source.protocolTTL) {
        return parsed;
      }
    } catch (error) {
      // 落到重新发现。
    }
  }
  const site = base(ctx);
  const page = fetchText(ctx, site + '/');
  let found = null;
  for (const match of page.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["']/gi)) {
    const reference = match[1];
    if (reference.indexOf('/main-') < 0 || !/\.js$/i.test(reference)) continue;
    const assetURL = resolveURL(site + '/', reference);
    const parsed = hg.url.parse(assetURL);
    const siteParsed = hg.url.parse(site);
    if (!parsed.valid || !siteParsed.valid) continue;
    // 只接受与站点同源的脚本（原 Go 版钉住 cloudfront 域名，这里放宽到同源，
    // 以便测试/镜像部署；跨域脚本一律忽略）。
    if (parsed.hostname !== siteParsed.hostname) continue;
    const script = fetchText(ctx, assetURL);
    found = parseProtocol(script);
    if (found) break;
  }
  if (!found) {
    throw new Error('黄果官网协议已变化，无法识别当前接口参数');
  }
  found.loadedAt = Date.now();
  hg.storage.set('protocol', JSON.stringify(found));
  return found;
}

function validProtocol(value) {
  return value && text(value.interfaceKey).length > 0 && text(value.interfaceKey).length <= 512 &&
    text(value.paramKey).length === 16 && text(value.paramIV).length === 16;
}

function parseProtocol(script) {
  const value = (name) => {
    const match = new RegExp('["\']' + name + '["\']\\s*[:,]\\s*["\']([^"\'\\\\\\r\\n]+)["\']').exec(script);
    return match ? match[1] : '';
  };
  const protocol = {
    interfaceKey: value('interfaceKey'),
    paramKey: value('parameterKey'),
    paramIV: value('parameterIv'),
  };
  return validProtocol(protocol) ? protocol : null;
}

// —— 数据解析 ——

const text = (value) => source.text(value);
const firstPresent = (values) => source.first(values);

function integer(value, maximum) {
  const raw = text(value);
  if (!/^\d+$/.test(raw)) return null;
  const number = Number(raw);
  if (!Number.isInteger(number) || number < 0 || number > maximum) return null;
  return number;
}

// tabList 兼容裸数组与 {list:[...]} 两种分类响应（与原 Go 版 legacyTabList 一致）。
function tabList(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && Array.isArray(payload.list)) return payload.list;
  return [];
}

// coverageURL 归一封面地址：相对路径按站点的图片域拼接（与原 Go 版一致）。
function coverURL(value) {
  const raw = text(value);
  if (!raw) return '';
  if (raw.startsWith('//')) {
    const parsed = hg.url.parse('https:' + raw);
    return parsed.valid ? parsed.href : '';
  }
  if (/^https?:\/\//i.test(raw)) {
    const parsed = hg.url.parse(raw);
    return parsed.valid ? parsed.href : '';
  }
  const path = raw.replace(/^\/+/, '');
  if (!path || path.includes('..') || path.includes('://')) return '';
  if (path.startsWith('upload/') || path.startsWith('upload_01/')) {
    return 'https://pic.zdmhyg.cn/' + path;
  }
  return 'https://zzzznnn.lkkwip.cn/' + path;
}

// dramaFromMap 把站点的剧集行转成契约对象（字段名与原 Go 版对齐）。
function dramaFromMap(row, channelName) {
  const sourceID = text(row && row.id);
  if (!sourceID) return null;
  const cover = firstPresent([
    coverURL(row.coverUrl), coverURL(row.cover_url), coverURL(row.cover),
    coverURL(row.imageUrl), coverURL(row.image_url), coverURL(row.image),
    coverURL(row.img), coverURL(row.pic), coverURL(row.poster),
  ]);
  const drama = {
    sourceId: sourceID,
    title: firstPresent([row.title, row.name]),
    channelName: channelName || '',
  };
  if (cover) drama.cover = cover;
  const description = firstPresent([row.desc, row.description, row.summary, row.intro]);
  if (description) drama.description = description;
  const episodes = integer(firstPresent([
    text(row.totalEpisode), text(row.total_episode),
    text(row.episodeCount), text(row.episode_count), text(row.total),
  ]), 100000);
  if (episodes != null && episodes > 0) drama.episodes = episodes;
  const category = firstPresent([
    row.categoryName, row.category_name, row.typeName, row.type_name,
    row.sortName, row.sort_name, row.category,
  ]);
  if (category) drama.category = category;
  const views = firstPresent([row.views, row.play_count]);
  if (views) drama.views = views;
  const online = firstPresent([row.onlineDate, row.online_date, row.issue_date]);
  if (online) drama.onlineDate = normalizeDate(online);
  const heat = text(row.heat);
  if (heat) drama.heat = heat;
  const status = firstPresent([row.releaseStatus, row.release_status]);
  if (status) drama.releaseStatus = status;
  const tags = Array.isArray(row.tags) ? row.tags.map((tag) => text(tag)).filter(Boolean) : [];
  if (tags.length) drama.tags = tags.slice(0, 16);
  if (row.vip === true) drama.vip = true;
  return drama;
}

function normalizeDate(value) {
  const raw = text(value);
  if (!raw) return '';
  const match = /(\d{4})-(\d{1,2})-(\d{1,2})/.exec(raw);
  if (!match) return '';
  return match[1] + '-' + String(Number(match[2])).padStart(2, '0') + '-' + String(Number(match[3])).padStart(2, '0');
}

// chapterNumber 取分集序号：优先 currentEpisode，其次标题里的「第N集」。
function chapterNumber(chapter, fallback) {
  const explicit = integer(chapter && chapter.currentEpisode, 100000);
  if (explicit != null && explicit > 0) return explicit;
  const match = /第\s*0*(\d+)\s*(?:集|话|期)/.exec(text(chapter && chapter.title));
  if (match) {
    const value = Number(match[1]);
    if (Number.isInteger(value) && value > 0) return value;
  }
  return fallback;
}

const isMediaURL = (value) => source.isMediaURL(value);
const resolveURL = hgkit.url;

function base(ctx) {
  return source.base(ctx);
}

// apiBase 返回接口基址：与原 Go 版共用同一个站点根。
function apiBase(ctx) {
  return base(ctx);
}

function fetchText(ctx, address) {
  return source.getText(ctx, address, {label: '黄果资源'});
}

// —— 加密请求 ——

// apiCall 发一次 API 请求并返回解包后的 payload。
function apiCall(ctx, path, params) {
  return request(ctx, 'GET', path, params, credentials(ctx));
}

// apiCallMany 并行发多个请求；每项返回 {value} 或 {error}。
function apiCallMany(ctx, requests) {
  const access = credentials(ctx);
  const protocolInfo = protocol(ctx);
  const base = apiBase(ctx);
  const prepared = requests.map((item) => {
    const fullPath = signedPath(item.path, item.params, protocolInfo);
    return {
      url: base + fullPath,
      options: {method: 'GET', headers: requestHeaders(access, protocolInfo)},
    };
  });
  const responses = hg.fetchAll(prepared);
  return responses.map((response) => {
    if (response.error) return {error: response.error};
    try {
      return {value: unwrap(parseEnvelope(response.body))};
    } catch (error) {
      return {error: error.message};
    }
  });
}

// request 发单次 API 请求（含一次 5005 令牌失效重试）。
function request(ctx, method, path, params, access) {
  const protocolInfo = protocol(ctx);
  const base = apiBase(ctx);
  let attempt = 0;
  let lastError = null;
  while (attempt < 2) {
    attempt++;
    const fullPath = signedPath(path, params, protocolInfo);
    const options = {method: method, headers: requestHeaders(access, protocolInfo)};
    if (method === 'POST' && params != null) {
      options.body = JSON.stringify({data: encryptParam(params, protocolInfo)});
      options.headers['Content-Type'] = 'application/json';
    }
    let response;
    try {
      response = hg.fetch(base + fullPath, options);
    } catch (error) {
      lastError = error;
      continue;
    }
    if (response.status < 200 || response.status >= 300) {
      lastError = new Error('黄果 API HTTP ' + response.status);
      continue;
    }
    let envelope;
    try {
      envelope = parseEnvelope(response.body);
    } catch (error) {
      lastError = error;
      continue;
    }
    const code = text(envelope.code);
    if (code && code !== 'null' && code !== '200' && code !== '0') {
      const message = text(envelope.msg) || '请检查访问配置或刷新登录凭证';
      const failure = new Error('黄果 API 错误 ' + code.slice(0, 20) + ': ' +
        message.replace(access.token || '\u0000', '[已隐藏]').slice(0, 160));
      failure.code = code;
      // 访客令牌失效：清缓存后重试一次。
      if (code === '5005' && attempt === 1) {
        hg.storage.set('session', '');
        access.token = '';
        access.deviceId = access.deviceId || newDeviceID();
        continue;
      }
      throw failure;
    }
    return unwrapEnvelope(envelope, protocolInfo);
  }
  throw lastError || new Error('黄果 API 请求失败');
}

// signedPath 把参数加密后拼到 path 上（GET 用 data=，POST 走 body）。
function signedPath(path, params, protocolInfo) {
  if (params == null) return path;
  const encrypted = encryptParam(params, protocolInfo);
  if (!encrypted) return path;
  return path + (path.indexOf('?') >= 0 ? '&' : '?') + 'data=' + encodeURIComponent(encrypted);
}

function requestHeaders(access, protocolInfo) {
  const agent = X_USER_AGENT.replace(
    'DevID=00000000000000000000000000000',
    'DevID=' + (access.deviceId || '00000000000000000000000000000'),
  );
  const headers = {
    Accept: 'application/json',
    temp: 'test',
    'X-User-Agent': agent,
    Origin: source.baseURL,
    Referer: source.baseURL + '/',
  };
  if (access.token) headers.Authorization = access.token;
  return headers;
}

// X_USER_AGENT 与原 Go 版 xUserAgent 一致。
const X_USER_AGENT = 'BuildID=com.abc.Butterfly;SysType=ios;DevID=00000000000000000000000000000;Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;Terminal=1;IsH5=1;Sid=00000000000000000000000000000000';

// encryptParam 用 parameterKey/parameterIv 做 AES-CBC 加密参数 JSON。
// 宿主的 aesCBCEncryptBytes 以 base64 承载二进制、hex 承载密钥，
// 因此文本先转 UTF-8 base64，密钥先转 hex。
function encryptParam(params, protocolInfo) {
  return hg.crypto.aesCBCEncryptBytes(
    textToBase64(JSON.stringify(params)),
    textToHex(protocolInfo.paramKey),
    textToBase64(protocolInfo.paramIV),
  );
}

// textToBase64 把 JS 字符串按 UTF-8 编码成 base64。
// hg.crypto.base64encode 接收 JS 字符串并按 UTF-8 编码，正是所需语义。
function textToBase64(value) {
  return hg.crypto.base64encode(value);
}

// textToHex 把 JS 字符串按 UTF-8 编码成 hex（goja 无 TextEncoder）。
function textToHex(value) {
  let out = '';
  for (const byte of utf8Bytes(value)) {
    out += (byte < 16 ? '0' : '') + byte.toString(16);
  }
  return out;
}

// utf8Bytes 把 JS 字符串编码成 UTF-8 字节。
function utf8Bytes(value) {
  const bytes = [];
  for (let index = 0; index < value.length; index++) {
    let code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const low = value.charCodeAt(index + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        index++;
      }
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    }
  }
  return bytes;
}

// base64ToText 把 base64 字节按 UTF-8 解码成 JS 字符串。
function base64ToText(encoded) {
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
    } else if (first < 0xe0) {
      out += String.fromCharCode(((first & 0x1f) << 6) | (bytes[index + 1] & 0x3f));
      index += 2;
    } else if (first < 0xf0) {
      out += String.fromCharCode(((first & 0x0f) << 12) | ((bytes[index + 1] & 0x3f) << 6) | (bytes[index + 2] & 0x3f));
      index += 3;
    } else {
      const code = ((first & 0x07) << 18) | ((bytes[index + 1] & 0x3f) << 12) |
        ((bytes[index + 2] & 0x3f) << 6) | (bytes[index + 3] & 0x3f);
      const value = code - 0x10000;
      out += String.fromCharCode(0xd800 + (value >> 10), 0xdc00 + (value & 0x3ff));
      index += 4;
    }
  }
  return out;
}

function parseEnvelope(body) {
  let envelope = null;
  try {
    envelope = JSON.parse(text(body));
  } catch (error) {
    throw new Error('黄果 API 响应格式异常');
  }
  if (!envelope || typeof envelope !== 'object') {
    throw new Error('黄果 API 响应格式异常');
  }
  return envelope;
}

// unwrap 兼容「data 已是明文」的调用方（分类/目录都走这里）。
// unwrap 接受已解析的响应信封（{code, hash, data}），返回解包后的 data。
function unwrap(envelope) {
  const value = unwrapEnvelope(envelope, null);
  if (value == null || value === 'null') {
    throw new Error('黄果 API 未返回数据，请检查登录凭证或接口是否变更');
  }
  return value;
}

function unwrapEnvelope(envelope, protocolInfo) {
  let data = envelope.data;
  if (hashEnabled(envelope.hash) && data != null) {
    if (typeof data !== 'string') {
      throw new Error('黄果 API 响应格式异常');
    }
    const key = (protocolInfo || currentProtocol()).interfaceKey;
    if (!key) throw new Error('黄果 API 协议未就绪');
    data = decryptResponse(data, key);
    if (!data) throw new Error('黄果 API 响应解密失败');
    try {
      data = JSON.parse(data);
    } catch (error) {
      throw new Error('黄果 API 响应格式异常');
    }
  }
  if (data == null || data === 'null') {
    throw new Error('黄果 API 未返回数据，请检查登录凭证或接口是否变更');
  }
  return data;
}

// unwrapJson 把已解包但仍是字符串的 payload 解析为对象。
function unwrapJson(value) {
  if (typeof value !== 'string') return value;
  try {
    return JSON.parse(value);
  } catch (error) {
    return value;
  }
}

function hashEnabled(value) {
  if (value == null) return false;
  if (typeof value === 'boolean') return value;
  const raw = text(value).toLowerCase();
  return raw !== '' && raw !== 'false' && raw !== '0' && raw !== 'null';
}

// decryptResponse 是黄果旧 API 的响应解密：由 interfaceKey 与响应前 12 字节
// 派生 AES 密钥与 IV（与原 Go 实现 decryptResponse 逐字节等价）。
//
// 全程以 hex 视图运算：宿主的 sha256Bytes / aesCBCDecryptBytes 都接受并返回
// base64 字节，hex 只是同一份字节的安全文本表示。
function decryptResponse(encoded, interfaceKey) {
  const blobHex = textHexOfBase64(encoded.replace(/\s+/g, ''));
  if (blobHex.length < 24) return '';
  const ivHex = blobHex.slice(0, 24);
  const bodyHex = blobHex.slice(24);
  const keyHex = textToHex(interfaceKey);
  const rHex = keyHex + ivHex;
  // half 是「字节」偏移量（Go 用 len(r)>>1）；hex 长度是字节数的两倍。
  const halfBytes = Math.floor(keyBytesOf(interfaceKey).length + 12) >> 1;
  const half = halfBytes * 2;
  // s = sha256(r)[8:24]
  const sHex = hg.crypto.sha256Bytes(hg.crypto.hexdecodeBytes(rHex)).slice(16, 48);
  const cHex = sHex + rHex.slice(0, half);
  const aHex = rHex.slice(half) + sHex;
  const dHex = hg.crypto.sha256Bytes(hg.crypto.hexdecodeBytes(cHex));
  const fHex = hg.crypto.sha256Bytes(hg.crypto.hexdecodeBytes(aHex));
  // m = d[0:8] + f[8:24] + d[24:]
  const mHex = dHex.slice(0, 16) + fHex.slice(16, 48) + dHex.slice(48);
  // p = f[0:4] + d[12:20] + f[28:]
  const pHex = fHex.slice(0, 8) + dHex.slice(24, 40) + fHex.slice(56);
  const plain = hg.crypto.aesCBCDecryptBytes(
    hg.crypto.hexdecodeBytes(bodyHex),
    mHex,
    hg.crypto.hexdecodeBytes(pHex),
  );
  return base64ToText(plain);
}

// keyBytesOf 返回 interfaceKey 的 UTF-8 字节数组（只用于长度计算）。
function keyBytesOf(value) {
  return utf8Bytes(text(value));
}

// textHexOfBase64 把 base64 转成 hex（与 textToBase64 互为逆运算）。
function textHexOfBase64(value) {
  return hg.crypto.hexencodeBytes(value);
}

// currentProtocol 在 unwrap 无参数时读取缓存的协议（响应解密只需要 interfaceKey）。
function currentProtocol() {
  const raw = hg.storage.get('protocol');
  if (!raw) return {};
  try {
    return JSON.parse(raw) || {};
  } catch (error) {
    return {};
  }
}

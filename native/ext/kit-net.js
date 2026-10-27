// hgkit 网络层：走宿主网络栈的取文本/取 JSON，以及 CloudFront 凭证解析。
//
// 依赖 kit-core 的 text/labelOf。
(function (kit) {
  'use strict';

  const {text, labelOf} = kit;

  function fetchText(ctx, source, path, options) {
    options = options || {};
    const base = source.base(ctx);
    const address = /^https?:\/\//i.test(text(path)) ? text(path) : base + text(path);
    const headers = Object.assign({
      Accept: 'text/html,application/json;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: base + '/',
    }, source.headers || {}, options.headers || {});
    const response = hg.fetch(address, {headers: headers});
    if (response.status !== 200) {
      throw new Error(labelOf(source, options) + '请求失败 HTTP ' + response.status);
    }
    return response.body;
  }

  function fetchJSON(ctx, source, path, options) {
    const body = fetchText(ctx, source, path, options);
    try {
      return JSON.parse(body);
    } catch (error) {
      throw new Error(labelOf(source, options) + '返回的数据无法解析');
    }
  }

  // CloudFront 签名 Cookie 是标准格式，解析与校验留在宿主，
  // 需要凭证的扩展只需提供响应头与到期时间。
  function cloudFrontCredentials(headers, address, options) {
    options = options || {};
    const label = text(options.label) || '站源';
    const cookies = {};
    const raw = (headers && (headers['Set-Cookie'] || headers['set-cookie'])) || '';
    for (const match of raw.matchAll(
      /(?:^|[,;\s])CloudFront-(Policy|Signature|Key-Pair-Id)\s*=\s*([^;,\s"']+)/g,
    )) {
      cookies['CloudFront-' + match[1]] = match[2];
    }
    const parts = [];
    for (const name of ['CloudFront-Policy', 'CloudFront-Signature', 'CloudFront-Key-Pair-Id']) {
      const value = cookies[name] || '';
      if (!value || value.length > 8192 || /[,;"\\]/.test(value) || /[\x00-\x20\x7f]/.test(value)) {
        throw new Error(label + '未返回完整的媒体凭证，请重试');
      }
      parts.push(name + '=' + value);
    }
    const parsed = hg.url.parse(text(address));
    if (!parsed.valid) {
      throw new Error(label + '播放地址无效');
    }
    let expires = 0;
    const stamp = Number(text(options.expiresAt));
    if (Number.isFinite(stamp) && stamp > 0 && stamp <= 253402300799000) {
      expires = stamp > 100000000000 ? Math.floor(stamp / 1000) : stamp;
    }
    if (expires > 0 && expires * 1000 <= Date.now()) {
      throw new Error(label + '媒体凭证已过期，请检查设备时间后重试');
    }
    return {
      cookie: parts.join('; '),
      origin: parsed.protocol + '://' + parsed.host,
      referer: text(options.referer),
      userAgent: text(options.userAgent),
      expiresAt: expires,
    };
  }

  Object.assign(kit, {
    fetchText: fetchText,
    fetchJSON: fetchJSON,
    cloudFrontCredentials: cloudFrontCredentials,
  });
})(globalThis.hgkit);

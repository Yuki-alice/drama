// hgkit MacCMS 层：苹果 CMS 播放页取流。
//
// 苹果 CMS 模板的播放页固定形如 <script>var now="<m3u8 地址>";</script>，
// 没有时再退到页面里第一个 m3u8/mp4 直链。鬼片与韩小圈各写了一份完全
// 相同的实现，这里下沉；返回可直接作为 resolve 结果的 {url, referer}。
//
// 依赖 kit-core 的 text 与 kit-html 的 mediaURL。
(function (kit) {
  'use strict';

  const {text, mediaURL} = kit;

  const MAC_PLAY_URL = /var\s+now\s*=\s*["']([^"']+)["']/i;
  const MAC_DIRECT_URL = /https?:\/\/[^"'\s<>\\]+\.(?:m3u8|mp4)(?:\?[^"'\s<>\\]*)?/i;

  // extractMacMedia 从播放页 HTML 里取媒体地址（纯函数，便于单测）。
  function extractMacMedia(body) {
    let address = (String(body).match(MAC_PLAY_URL) || [])[1] || '';
    address = text(address);
    if (!address) {
      address = (String(body).match(MAC_DIRECT_URL) || [])[0] || '';
    }
    return mediaURL(address);
  }

  Object.assign(kit, {
    macPlayUrl: MAC_PLAY_URL,
    extractMacMedia: extractMacMedia,
  });
})(globalThis.hgkit);

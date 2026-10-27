// hgkit 基础层：命名空间与文本原语。
//
// 这一层只放"无依赖、到处用"的东西：类型归一、整数解析、字段取值、HTML
// 反转义与清洗。其它 kit-*.js 通过 `const {text, int, ...} = kit` 引入，
// 因此函数体保持原样，不需要改成 kit.xxx() 调用形式。
(function (kit) {
  'use strict';

  function text(value) {
    if (value == null) return '';
    if (typeof value === 'string') return value.trim();
    if (typeof value === 'number' && Number.isFinite(value)) return String(value);
    return '';
  }

  function trimBase(value) {
    return text(value).replace(/\/+$/, '');
  }

  function int(value, max) {
    // 注意 Number('') === 0：空串必须先挡掉，否则"字段缺失"会被当成 0，
    // 进而把集数、页码这类语义变成合法值。
    const raw = text(value);
    if (!raw) return null;
    const parsed = Number(raw);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > (max || 100000000)) return null;
    return Math.floor(parsed);
  }

  function pick(object, keys) {
    if (!object || typeof object !== 'object') return '';
    for (const key of keys || []) {
      const value = text(object[key]);
      if (value) return value;
    }
    return '';
  }

  function first(values) {
    if (!Array.isArray(values)) return '';
    for (const value of values) {
      const result = text(value);
      if (result) return result;
    }
    return '';
  }

  function rawPick(object, keys) {
    if (!object || typeof object !== 'object') return null;
    for (const key of keys || []) {
      const value = object[key];
      if (value == null) continue;
      if (typeof value === 'string' && !value.trim()) continue;
      if (Array.isArray(value) && !value.length) continue;
      if (typeof value === 'object' && !Array.isArray(value) && !Object.keys(value).length) continue;
      return value;
    }
    return null;
  }

  function unescapeHTML(value) {
    let output = String(value == null ? '' : value);
    for (let round = 0; round < 3; round++) {
      const next = output
        .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#39;/g, "'")
        .replace(/&nbsp;/g, ' ')
        .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
        .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number(dec)));
      if (next === output) break;
      output = next;
    }
    return output;
  }

  function cleanText(value) {
    if (value == null) return '';
    const output = unescapeHTML(String(value).replace(/<[^>]+>/g, ''));
    return output.replace(/\u3000/g, ' ').trim().split(/\s+/).filter(Boolean).join(' ');
  }

  function labelOf(source, options) {
    return text(options && options.label) || text(source && (source.label || source.name)) || '站源';
  }

  Object.assign(kit, {
    text: text,
    trimBase: trimBase,
    int: int,
    pick: pick,
    first: first,
    rawPick: rawPick,
    unescapeHTML: unescapeHTML,
    cleanText: cleanText,
    labelOf: labelOf,
  });
})(globalThis.hgkit = globalThis.hgkit || {version: 1});

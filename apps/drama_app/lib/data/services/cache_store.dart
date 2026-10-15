import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 目录缓存存储抽象（ARCH §5「数据与缓存」）。
///
/// 上层（[CachingCatalogRepository]）只依赖本抽象；真实实现为 [FileCacheStore]
/// （文件 + 内存快照），测试可注入显式 `file` 与 `clock` 以确定性地验证时效与持久化。
abstract interface class CacheStore {
  /// 启动时一次性载入磁盘快照到内存（此后读路径同步、无 I/O）。
  Future<void> load();

  /// 读取条目：`ttl` 为 null 表示忽略时效（弱网兜底用）；超过 `ttl` 视为未命中。
  T? read<T>(String key, {Duration? ttl});

  /// 条目是否在 `ttl` 内（测试与诊断用）。
  Future<bool> isFresh(String key, Duration ttl);

  /// 写入条目（JSON 可编码值）；内存立即生效，落盘走防抖 + 原子替换。
  Future<void> write(String key, Object? value);

  /// 删除单条。
  Future<void> remove(String key);

  /// 强制立即落盘（等这次写完）。
  Future<void> flush();

  /// 同步读取分类分页水位（`catalog:<categoryId>:depth`，24h 内有效）。
  int? catalogDepth(String categoryId);

  /// 清空全部缓存（供设置页「清除缓存」用）。
  Future<void> clear();
}

/// 缓存条目：`valueJson` + 写入时刻（毫秒）。
@immutable
class CacheEntry {
  const CacheEntry({required this.valueJson, required this.fetchedAtMs});

  final String valueJson;
  final int fetchedAtMs;

  factory CacheEntry.fromJson(Map<String, Object?> json) => CacheEntry(
    valueJson: json['valueJson'] as String? ?? '',
    fetchedAtMs: (json['fetchedAtMs'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'valueJson': valueJson,
    'fetchedAtMs': fetchedAtMs,
  };
}

/// 缓存 key 约定（ARCH §5 / 实施计划 W2 任务 5）。
abstract final class CacheKeys {
  static String catalog(String categoryId, int page) =>
      'catalog:$categoryId:$page';

  /// 分类分页水位（已请求的最大 `page+1`），供重启续载。
  static String catalogDepth(String categoryId) => 'catalog:$categoryId:depth';

  static const String recommend = 'recommend';

  /// 榜单条目（`last` 后缀：语义是「最近一次成功拿到的榜」）。
  static String ranking(String boardId) => 'ranking:$boardId:last';

  static String detail(String seriesId) => 'detail:$seriesId';

  static String search(String keyword) => 'search:$keyword';

  static String suggest(String keyword) => 'suggest:$keyword';
}

/// 缓存时效口径（ARCH §5：目录 15min、榜单 5min（24h 回退））。
abstract final class CacheTtl {
  /// 目录 / 推荐 / 详情 / 搜索 / 联想的新鲜窗口。
  static const Duration fresh = Duration(minutes: 15);

  /// 榜单新鲜窗口——比目录短，越新越反映热度变化。
  static const Duration rankingFresh = Duration(minutes: 5);

  /// 弱网 / 旧榜兜底允许的最大年龄（24h）。
  static const Duration fallback = Duration(hours: 24);
}

/// 文件 + 内存快照版缓存。
///
/// - 路径：显式 `file`，否则 `getApplicationSupportDirectory()/fileName`；
/// - 内存：`Map<String, CacheEntry>`，启动 [load] 一次性载入，读路径同步；
/// - 写入：防抖合并 + 写临时文件再 `rename` 原子替换（避免半截文件）；
/// - 容量：条数与总字节双上限，超出按 `fetchedAtMs` 淘汰最旧；
/// - 容错：文件损坏 → 丢弃并删除该文件（缓存是加速手段，不是真相源）。
class FileCacheStore implements CacheStore {
  FileCacheStore({
    File? file,
    String fileName = 'catalog_cache.json',
    int maxEntries = 500,
    int? maxBytes,
    DateTime Function()? clock,
  }) : _explicitFile = file,
       _fileName = fileName,
       _maxEntries = maxEntries,
       _maxBytes = maxBytes,
       _clock = clock ?? DateTime.now;

  final File? _explicitFile;
  final String _fileName;
  final int _maxEntries;
  final int? _maxBytes;
  final DateTime Function() _clock;

  final Map<String, CacheEntry> _entries = <String, CacheEntry>{};
  File? _resolvedFile;
  Timer? _flushTimer;
  bool _dirty = false;

  static const Duration _flushDebounce = Duration(milliseconds: 500);

  @override
  Future<void> load() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await _discardCorrupt(file);
        return;
      }
      final loaded = <String, CacheEntry>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! Map) continue;
        final cacheEntry = CacheEntry.fromJson(
          Map<String, Object?>.from(value),
        );
        if (cacheEntry.valueJson.isEmpty) continue;
        loaded[key] = cacheEntry;
      }
      _entries
        ..clear()
        ..addAll(loaded);
      _evictIfNeeded();
    } catch (error) {
      // 缓存是加速手段而非真相源：损坏/读失败按空缓存处理，不影响启动。
      debugPrint('[cache] 缓存文件载入失败，按空缓存处理：$error');
      try {
        await _discardCorrupt(await _resolveFile());
      } catch (_) {
        // 删不掉也无妨：下次仍按空缓存处理。
      }
    }
  }

  @override
  T? read<T>(String key, {Duration? ttl}) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (ttl != null && _nowMs() - entry.fetchedAtMs > ttl.inMilliseconds) {
      return null;
    }
    final decoded = _safeDecode(entry.valueJson);
    if (decoded == null) return null;
    // 形状不匹配（例如格式迁移后的旧条目）→ 视为未命中，由调用方回源。
    if (decoded is! T) return null;
    return decoded as T;
  }

  @override
  Future<bool> isFresh(String key, Duration ttl) async {
    final entry = _entries[key];
    if (entry == null) return false;
    return _nowMs() - entry.fetchedAtMs <= ttl.inMilliseconds;
  }

  @override
  Future<void> write(String key, Object? value) async {
    try {
      _entries[key] = CacheEntry(
        valueJson: jsonEncode(value),
        fetchedAtMs: _nowMs(),
      );
      _evictIfNeeded();
      _scheduleFlush();
    } catch (error) {
      debugPrint('[cache] 写入缓存条目失败（key=$key）：$error');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (_entries.remove(key) != null) _scheduleFlush();
  }

  @override
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }

  @override
  int? catalogDepth(String categoryId) {
    final entry = _entries[CacheKeys.catalogDepth(categoryId)];
    if (entry == null) return null;
    if (_nowMs() - entry.fetchedAtMs > CacheTtl.fallback.inMilliseconds) {
      return null;
    }
    return switch (_safeDecode(entry.valueJson)) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    try {
      final file = await _resolveFile();
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('[cache] 清除缓存文件失败：$error');
    }
  }

  Future<File> _resolveFile() async {
    final cached = _resolvedFile;
    if (cached != null) return cached;
    final explicit = _explicitFile;
    if (explicit != null) return _resolvedFile = explicit;
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _resolvedFile = File(p.join(dir.path, _fileName));
  }

  /// 丢弃损坏文件：清空内存并删除文件，避免每次启动重复解析失败。
  Future<void> _discardCorrupt(File file) async {
    _entries.clear();
    if (await file.exists()) await file.delete();
  }

  void _scheduleFlush() {
    _dirty = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDebounce, () => unawaited(_flush()));
  }

  Future<void> _flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final file = await _resolveFile();
      final temp = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object?>{
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      });
      await temp.writeAsString(payload, flush: true);
      // 写临时文件再 rename → 原子替换，避免读到半截文件。
      await temp.rename(file.path);
    } catch (error) {
      _dirty = true; // 落盘失败保留脏标记，下次写入再试（「未落盘=不新鲜」）。
      debugPrint('[cache] 缓存落盘失败（保留脏标记待重试）：$error');
    }
  }

  void _evictIfNeeded() {
    // 注意：`_maxBytes` 是私有 final 字段，Dart 3 的字段提升已让 null 检查后的
    // 使用无需 `!`（`unnecessary_non_null_assertion`）。
    final maxBytes = _maxBytes;
    if (_entries.length <= _maxEntries &&
        (maxBytes == null || _totalBytes() <= maxBytes)) {
      return;
    }
    final ordered = _entries.entries.toList()
      ..sort((a, b) => a.value.fetchedAtMs.compareTo(b.value.fetchedAtMs));
    for (final entry in ordered) {
      final overCount = _entries.length > _maxEntries;
      final overBytes = maxBytes != null && _totalBytes() > maxBytes;
      if (!overCount && !overBytes) break;
      _entries.remove(entry.key);
    }
  }

  int _totalBytes() {
    var total = 0;
    for (final entry in _entries.values) {
      total += entry.valueJson.length;
    }
    return total;
  }

  Object? _safeDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (error) {
      debugPrint('[cache] 缓存 JSON 解析失败：$error');
      return null;
    }
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;
}

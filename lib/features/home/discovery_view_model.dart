import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:duanju_app/core/catalog_updates.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/ranking_models.dart';
import 'package:duanju_app/features/home/catalog_browser.dart';

/// 持久化动作需要弹窗/提示，由 View 提供上下文。
typedef PersistChanges = Future<void> Function(Future<void> Function() action);

/// 发现页展示状态与目录加载逻辑；不依赖 BuildContext。
class DiscoveryViewModel extends ChangeNotifier {
  DiscoveryViewModel({
    required this.repository,
    required this.store,
    required this.updates,
    required this.persist,
  }) : _browser = CatalogBrowser(repository) {
    _source = SourceSite.byId(store.source);
    _allSources = store.catalogView.allSources;
    updates.addListener(_metadataChanged);
  }

  void start() {
    if (store.sources.isEmpty) {
      _loading = false;
      notifyListeners();
      return;
    }
    unawaited(load(useCache: true));
    unawaited(loadBanner());
  }

  final AppRepository repository;
  final LocalStore store;
  final CatalogUpdates updates;
  final PersistChanges persist;
  final CatalogBrowser _browser;

  late SourceSite _source;
  late bool _allSources;
  List<Drama> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  List<RankingItem> _banner = const [];
  bool _bannerLoading = false;
  String _bannerBoard = '';
  final _changedSources = <String>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  SourceSite get source => _source;
  bool get allSources => _allSources;
  List<Drama> get items => _items;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get error => _error;
  int get generation => _generation;
  List<RankingItem> get banner => _banner;
  bool get bannerLoading => _bannerLoading;
  String get bannerBoard => _bannerBoard;

  List<SourceGroup> get sourceGroups {
    final groups = SourceGroup.fromSources(store.sources);
    return [
      if (groups.length > 1) SourceGroup('all', '全部站源', store.sources),
      ...groups,
    ];
  }

  SourceGroup get group =>
      sourceGroups
          .where(
            (item) => item.id == (_allSources ? 'all' : _source.displayGroupId),
          )
          .firstOrNull ??
      SourceGroup(_source.displayGroupId, _source.displayGroupName, [_source]);

  bool get supportsVipFilter =>
      group.sources.any((source) => source.id == 'huangdou');
  bool get hideVip => supportsVipFilter && store.hideVip;
  bool get canSelect => store.canDownload && repository.supportsDownloads;
  bool get canLoadMore => _hasMore && !_loading && !_loadingMore;

  List<Drama> get visible => store.sources.isEmpty
      ? const []
      : _items.where((drama) {
          if (!store.allowsSource(drama.source)) return false;
          return !hideVip || drama.source != 'huangdou' || !drama.vip;
        }).toList();

  Future<void> load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    _error = null;
    if (more) {
      _loadingMore = true;
    } else {
      _loading = true;
      _loadingMore = false;
    }
    notifyListeners();
    CatalogPage? refreshed;
    void accept(CatalogPage result, {bool cached = false}) {
      if (generation != _generation) return;
      _items = result.items;
      _hasMore = result.hasMore;
      _loading = cached && !result.fresh;
      _loadingMore = false;
      _error = result.warning.isEmpty ? null : result.warning;
      notifyListeners();
      if (identical(result, refreshed)) return;
      refreshed = result;
      unawaited(persist(() => store.refreshDramas(result.items)));
    }

    try {
      final result = await _browser.load(
        group,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (error) {
      if (generation != _generation) return;
      _loading = false;
      _loadingMore = false;
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> loadBanner({bool force = false}) async {
    if (_bannerLoading) return;
    final generation = _generation;
    _bannerLoading = true;
    notifyListeners();
    try {
      final boards = (await repository.rankingBoards())
          .where((board) => group.sources.any((s) => s.id == board.source))
          .toList();
      if (boards.isEmpty) {
        _bannerLoading = false;
        notifyListeners();
        return;
      }
      final board = boards.firstWhere(
        (item) => item.id == _bannerBoard,
        orElse: () => boards.first,
      );
      final page = await repository.rankings(board.id, force: force);
      if (generation != _generation) return;
      _bannerBoard = board.id;
      _banner = page.items.take(8).toList();
      _bannerLoading = false;
      notifyListeners();
    } catch (_) {
      // 榜单失败不阻塞目录浏览，静默隐藏该区块。
      if (generation == _generation) {
        _banner = const [];
        _bannerLoading = false;
        notifyListeners();
      }
    }
  }

  void catalogUpdated(String source) {
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(reloadUpdatedCache());
    });
  }

  Future<void> reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    try {
      while (_changedSources.isNotEmpty) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!store.allowsSource(source)) continue;
          try {
            for (final drama in (await _browser.cached(source)).items) {
              if (store.allowsSource(drama.source)) updates[drama.id] = drama;
            }
          } catch (error) {
            _error = '更新后读取缓存失败：$error';
            notifyListeners();
          }
        }
        _browser.updateDramas(updates.values);
        _items = [
          for (final item in _items)
            updates[item.id] == null ? item : item.merge(updates[item.id]!),
        ];
        notifyListeners();
        await persist(() => store.refreshDramas(updates.values));
        if (group.sources.any((source) => sources.contains(source.id))) {
          await load(cacheOnly: true);
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  void _metadataChanged() {
    final drama = updates.latest;
    if (drama == null || !store.allowsSource(drama.source)) return;
    _browser.updateDrama(drama);
    _items = [
      for (final item in _items) item.id == drama.id ? item.merge(drama) : item,
    ];
    notifyListeners();
    unawaited(persist(() => store.refreshDrama(drama)));
  }

  void pause() {
    _generation++;
    unawaited(_browser.cancel());
    _loading = false;
    _loadingMore = false;
    notifyListeners();
  }

  void clearContent() {
    _items = const [];
    _banner = const [];
    _hasMore = false;
    _loading = false;
    notifyListeners();
  }

  void applySource(SourceSite source, {bool allSources = false}) {
    if (_source.id == source.id && _allSources == allSources) return;
    _generation++;
    unawaited(_browser.cancel());
    _source = source;
    _allSources = allSources;
    _items = const [];
    _banner = const [];
    _bannerBoard = '';
    _hasMore = true;
    _error = null;
    notifyListeners();
    unawaited(
      persist(() => store.setCatalogSource(source.id, allSources: allSources)),
    );
    unawaited(load(useCache: true));
    unawaited(loadBanner());
  }

  @override
  void dispose() {
    _disposed = true;
    updates.removeListener(_metadataChanged);
    _cacheRefreshTimer?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    super.dispose();
  }
}

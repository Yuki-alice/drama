import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/app_screen.dart';
import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/app/router.dart' show DetailRouteArgs, SourcesRouteArgs;
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/follow_updater.dart';
import 'package:duanju_app/core/library_updater.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/ranking_models.dart';
import 'package:duanju_app/core/responsive/window_type.dart';
import 'package:duanju_app/features/detail/drama_actions.dart';
import 'package:duanju_app/features/downloads/batch_downloads.dart';
import 'package:duanju_app/features/home/catalog_browser.dart';
import 'package:duanju_app/features/player/playback_launch_screen.dart';
import 'package:duanju_app/widgets/widgets.dart';

/// 发现页：最高热度轮播 + 海报信息流。站源是唯一内容上下文，
/// 分类与排序入口在搜索页，页面本身不再挂粘性筛选栏。
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  static const _revealBatch = 60;
  final _scroll = ScrollController();
  late SourceSite _source;
  bool _allSources = false;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  late final CatalogBrowser _browser;
  late final LibraryUpdater _updater;
  late final FollowUpdater _followUpdater;
  final _changedSources = <String>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _selectionMode = false;
  final _selectedDramas = <String, Drama>{};
  String _sourceSignature = '';
  bool _catalogLoadScheduled = false;
  int _revealed = _revealBatch;
  int? _revealKey;
  bool _hiddenItems = false;

  List<RankingItem> _banner = [];
  bool _bannerLoading = false;
  String _bannerBoard = '';

  AppRepository get _repository => widget.repository;

  List<SourceGroup> get _sourceGroups {
    final groups = SourceGroup.fromSources(widget.store.sources);
    return [
      if (groups.length > 1) SourceGroup('all', '全部站源', widget.store.sources),
      ...groups,
    ];
  }

  SourceGroup get _group =>
      _sourceGroups
          .where(
            (group) =>
                group.id == (_allSources ? 'all' : _source.displayGroupId),
          )
          .firstOrNull ??
      SourceGroup(_source.displayGroupId, _source.displayGroupName, [_source]);

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;
  bool get _canSelect =>
      widget.store.canDownload && widget.repository.supportsDownloads;

  List<Drama> get _visible => widget.store.sources.isEmpty
      ? const []
      : _items.where((drama) {
          if (!widget.store.allowsSource(drama.source)) return false;
          return !_hideVip || drama.source != 'huangdou' || !drama.vip;
        }).toList();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _source = SourceSite.byId(widget.store.source);
    _allSources = widget.store.catalogView.allSources;
    _sourceSignature = widget.store.sources.map((site) => site.id).join(',');
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    _followUpdater = FollowUpdater(widget.repository, widget.store)..start();
    widget.store.addListener(_sourcesChanged);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadBanner();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _followUpdater.dispose();
    _cacheRefreshTimer?.cancel();
    widget.store.removeListener(_sourcesChanged);
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    unawaited(_browser.cancel());
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _sourcesChanged() {
    if (!mounted) return;
    final visible = widget.store.sources;
    final signature = visible.map((site) => site.id).join(',');
    if (signature == _sourceSignature) return;
    _sourceSignature = signature;
    if (visible.isEmpty) {
      setState(() {
        _items = [];
        _banner = [];
        _hasMore = false;
        _loading = false;
      });
      return;
    }
    if (!visible.any((site) => site.id == _source.id) ||
        _source.id != widget.store.source) {
      _applySource(SourceSite.byId(widget.store.source));
    }
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    try {
      while (mounted && _changedSources.isNotEmpty) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            for (final drama in (await _browser.cached(source)).items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted) setState(() => _error = '更新后读取缓存失败：$error');
          }
        }
        if (!mounted) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _load(cacheOnly: true);
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    setState(() {
      _error = null;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
      }
    });
    CatalogPage? refreshed;
    void accept(CatalogPage result, {bool cached = false}) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        if (more && result.items.length > _revealed) {
          _revealed = result.items.length;
        }
        _hasMore = result.hasMore;
        _loading = cached && !result.fresh;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      if (identical(result, refreshed)) return;
      refreshed = result;
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(result.items)),
      );
    }

    try {
      final result = await _browser.load(
        _group,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadBanner({bool force = false}) async {
    if (_bannerLoading) return;
    final generation = _generation;
    setState(() => _bannerLoading = true);
    try {
      final boards = (await widget.repository.rankingBoards())
          .where((board) => _group.sources.any((s) => s.id == board.source))
          .toList();
      if (boards.isEmpty) {
        if (mounted) setState(() => _bannerLoading = false);
        return;
      }
      final board = boards.firstWhere(
        (item) => item.id == _bannerBoard,
        orElse: () => boards.first,
      );
      final page = await widget.repository.rankings(board.id, force: force);
      if (!mounted || generation != _generation) return;
      setState(() {
        _bannerBoard = board.id;
        _banner = page.items.take(8).toList();
        _bannerLoading = false;
      });
    } catch (_) {
      // 榜单失败不阻塞目录浏览，静默隐藏该区块。
      if (mounted && generation == _generation) {
        setState(() {
          _banner = [];
          _bannerLoading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      await _updater.update(_group.sources);
      await _loadBanner(force: true);
      return;
    }
    await Future.wait([_load(force: true), _loadBanner(force: true)]);
  }

  void _cancelInFlight() {
    _generation++;
    unawaited(_browser.cancel());
  }

  void _pauseCatalog() {
    _cancelInFlight();
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  void _applySource(SourceSite source, {bool allSources = false}) {
    if (_source.id == source.id && _allSources == allSources) return;
    _cancelInFlight();
    setState(() {
      _selectionMode = false;
      _selectedDramas.clear();
      _source = source;
      _allSources = allSources;
      _items = [];
      _banner = [];
      _bannerBoard = '';
      _hasMore = true;
      _error = null;
    });
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogSource(source.id, allSources: allSources),
      ),
    );
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
    _loadBanner();
  }

  bool get _canLoadMore => _hasMore && !_loading && !_loadingMore;

  void _onScroll() {
    if (!mounted || !(_hiddenItems || _canLoadMore) || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.5).clamp(320.0, 900.0);
    if (position.extentAfter > threshold || _catalogLoadScheduled) return;
    _catalogLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogLoadScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      if (_hiddenItems || _canLoadMore) _showMore();
    });
  }

  void _showMore() {
    if (_hiddenItems) {
      setState(() => _revealed += _revealBatch);
    } else {
      unawaited(_load(more: true));
    }
  }

  List<Drama> _reveal(List<Drama> items) {
    final key = Object.hash(_group.id, _hideVip);
    if (key != _revealKey) {
      _revealKey = key;
      _revealed = _revealBatch;
    }
    _hiddenItems = items.length > _revealed;
    return _hiddenItems ? items.sublist(0, _revealed) : items;
  }

  void _openDrama(Drama drama, {bool download = false}) {
    _pauseCatalog();
    if (download) {
      context.push('/detail', extra: DetailRouteArgs(drama: drama));
      return;
    }
    unawaited(
      openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      ),
    );
  }

  void _selectDrama(Drama drama) {
    if (!_canSelect || !widget.store.allowsSource(drama.source)) return;
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('一次最多选择 50 部短剧，请分批下载')),
      );
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _downloadSelected() {
    if (!_canSelect || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    context.push('/batch', extra: _selectedDramas.values.toList());
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onContinue: () => _openDrama(drama),
    onDownload: _canSelect ? () => _openDrama(drama, download: true) : null,
    onSelect: _canSelect ? () => _selectDrama(drama) : null,
  );

  Future<void> _openSourceSheet() async {
    _pauseCatalog();
    final selected = await showModalBottomSheet<SourceGroup>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '选择站源',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final group in _sourceGroups)
              ListTile(
                selected: group.id == _group.id,
                leading: Icon(
                  group.id == _group.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                ),
                title: Text(group.name),
                subtitle: group.id == 'all'
                    ? Text('混合浏览 ${group.sources.length} 个已启用站源')
                    : null,
                onTap: () => Navigator.pop(context, group),
              ),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('管理站源规则'),
              onTap: () {
                Navigator.pop(context);
                context.push(
                  '/sources',
                  extra: SourcesRouteArgs(initialSource: _source.id),
                );
              },
            ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    _applySource(selected.sources.first, allSources: selected.id == 'all');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final window = windowTypeOfContext(context);
        final padding = EdgeInsets.symmetric(horizontal: window.pagePadding);
        final items = _reveal(_visible);
        return AppScreen(
          title: '发现',
          actions: [
            IconButton(
              key: const ValueKey('open-search'),
              tooltip: '搜索',
              onPressed: () {
                _pauseCatalog();
                context.push('/search');
              },
              icon: const Icon(Icons.search_rounded),
            ),
            IconButton(
              key: const ValueKey('source-switch'),
              tooltip: '切换站源 · ${_group.name}',
              onPressed: widget.store.sources.isEmpty ? null : _openSourceSheet,
              icon: _SourceAvatar(name: _group.name),
            ),
          ],
          bottomBar: _selectionMode ? _selectionBar() : null,
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: widget.store.sources.isEmpty
                ? StatusPanel(
                    title: '暂无可用站源',
                    message: '请在规则管理中开启站源，或安装更多站源规则。',
                    onRetry: () => context.push('/sources'),
                    action: '管理站源',
                  )
                : CustomScrollView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (_banner.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _BannerSection(
                            padding: padding,
                            repository: _repository,
                            items: _banner,
                            onOpen: (drama) {
                              _pauseCatalog();
                              context.push(
                                '/detail',
                                extra: DetailRouteArgs(drama: drama),
                              );
                            },
                            onMore: () {
                              _pauseCatalog();
                              context.push('/rankings', extra: _group.id);
                            },
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            padding.left,
                            AppSpacing.lg,
                            padding.right,
                            AppSpacing.md,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '推荐',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                              if (_group.id == 'hongguo')
                                TextButton.icon(
                                  key: const ValueKey('open-recommendations'),
                                  onPressed: () {
                                    _pauseCatalog();
                                    context.push('/recommendations');
                                  },
                                  icon: const Icon(
                                    Icons.auto_awesome_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('红果推荐'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_loading && _items.isEmpty)
                        SliverPadding(
                          padding: padding,
                          sliver: const SliverToBoxAdapter(
                            child: CatalogSkeleton(),
                          ),
                        )
                      else if (_items.isEmpty && _error != null)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: StatusPanel(
                            title: '暂时无法加载',
                            message: _error!,
                            onRetry: () => _load(force: true),
                            secondaryAction:
                                widget.repository.supportsSourceManagement
                                ? TextButton(
                                    onPressed: () => context.push('/sources'),
                                    child: const Text('站源诊断'),
                                  )
                                : null,
                            icon: Icons.wifi_off_rounded,
                          ),
                        )
                      else if (items.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: StatusPanel(
                            title: '没有找到匹配的短剧',
                            message: _hideVip
                                ? '可以换个分类，或显示 VIP 内容。'
                                : '可以切换站源，或下拉刷新后重试。',
                            onRetry: _hasMore
                                ? () => _load(more: true)
                                : null,
                            action: '加载更多',
                          ),
                        )
                      else
                        SliverPadding(
                          padding: padding,
                          sliver: SliverLayoutBuilder(
                            builder: (context, constraints) => SliverGrid(
                              gridDelegate: dramaGridDelegate(
                                context,
                                constraints.crossAxisExtent,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (_, index) => _tile(items[index]),
                                childCount: items.length,
                              ),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.xl,
                          ),
                          child: Center(
                            child: _loading && _items.isNotEmpty
                                ? const LinearProgressIndicator(minHeight: 2)
                                : _loadingMore
                                ? const CircularProgressIndicator()
                                : _hiddenItems || _hasMore
                                ? OutlinedButton.icon(
                                    onPressed: _showMore,
                                    icon: const Icon(Icons.expand_more_rounded),
                                    label: const Text('加载更多'),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _tile(Drama drama) {
    final following = widget.store.following(drama.id);
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: _canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _dramaActions(drama),
      ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      subtitle: _allSources ? SourceSite.byId(drama.source).name : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
    );
  }

  Widget _selectionBar() {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    return Material(
      color: AppSurfaces.of(context).navContainer,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('cancel-catalog-selection'),
              onPressed: _cancelSelection,
              child: const Text('取消'),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              key: const ValueKey('download-selected-dramas'),
              onPressed: count == 0 ? null : _downloadSelected,
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceAvatar extends StatelessWidget {
  const _SourceAvatar({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 15,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _BannerSection extends StatelessWidget {
  const _BannerSection({
    required this.padding,
    required this.repository,
    required this.items,
    required this.onOpen,
    required this.onMore,
  });
  final EdgeInsets padding;
  final AppRepository repository;
  final List<RankingItem> items;
  final ValueChanged<Drama> onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 600;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            AppSpacing.sm,
            padding.right,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '最高热度',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('open-rankings'),
                onPressed: onMore,
                icon: const Icon(Icons.leaderboard_rounded, size: 18),
                label: const Text('查看更多'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: compact ? 190 : 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: padding.left),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
            itemBuilder: (context, index) => SizedBox(
              width: compact ? width * .62 : 280,
              child: _BannerCard(
                repository: repository,
                drama: items[index].drama,
                onTap: () => onOpen(items[index].drama),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.repository,
    required this.drama,
    required this.onTap,
  });
  final AppRepository repository;
  final Drama drama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${drama.title}，热度最高',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppShapes.extraLarge),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppShapes.extraLarge),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DramaCover(drama: drama, repository: repository, radius: 0),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Color(0xC0000000), Color(0x00000000)],
                ),
              ),
              child: SizedBox.expand(),
            ),
            Positioned(
              left: AppSpacing.md,
              right: AppSpacing.md,
              bottom: AppSpacing.md,
              child: Text(
                drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                  shadows: [
                    Shadow(
                      blurRadius: 8,
                      color: Color(0xB3000000),
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

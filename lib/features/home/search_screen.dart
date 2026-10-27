import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:duanju_app/app/app_screen.dart';
import 'package:duanju_app/core/catalog_sort.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/detail/drama_actions.dart';
import 'package:duanju_app/features/home/catalog_browser.dart';
import 'package:duanju_app/features/player/playback_launch_screen.dart';
import 'package:duanju_app/widgets/widgets.dart';

/// 搜索页（Kazumi 式）：搜索栏 + 条件筛选 + 最近搜索 / 结果矩阵。
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.repository,
    required this.store,
    this.group,
  });
  final AppRepository repository;
  final LocalStore store;
  final SourceGroup? group;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  late final CatalogBrowser _browser;
  late SourceGroup _group;
  CatalogView _view = const CatalogView();
  List<Drama> _items = [];
  bool _loading = false;
  bool _hasMore = false;
  String? _submitted;
  String? _error;
  bool _managingHistory = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _browser = CatalogBrowser(widget.repository);
    _group = widget.group ?? _defaultGroup();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    _inputFocus.dispose();
    _input.dispose();
    unawaited(_browser.cancel());
    super.dispose();
  }

  SourceGroup _defaultGroup() {
    final current = SourceSite.byId(widget.store.source);
    return SourceGroup.fromSources(
          widget.store.sources,
        ).where((entry) => entry.id == current.displayGroupId).firstOrNull ??
        SourceGroup(current.id, current.name, [current]);
  }

  List<SourceGroup> get _groups {
    final groups = SourceGroup.fromSources(widget.store.sources);
    return [
      if (groups.length > 1) SourceGroup('all', '全部站源', widget.store.sources),
      ...groups,
    ];
  }

  bool get _hasSearched => _submitted != null;
  String get _query => _submitted ?? '';
  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);

  String get _hint {
    final online = _group.sources.where((s) => s.onlineSearch).toList();
    if (online.isEmpty) return '筛选本机已更新剧库';
    final names = online.map((source) => source.name).join('、');
    return online.length == _group.sources.length
        ? '搜索$names'
        : '搜索$names及本机剧库';
  }

  List<Drama> get _results {
    var items = _items;
    if (!_onlineSearch && _query.isNotEmpty) {
      items = items.where((drama) => matchesDramaQuery(drama, _query)).toList();
    }
    return sortCatalog(items, _view);
  }

  bool get _hasAdvancedFilters =>
      _view.sort != CatalogSort.source || _view.release.isNotEmpty;

  void _onScroll() {
    if (!_scroll.hasClients ||
        _scroll.position.extentAfter > 360 ||
        _loading ||
        !_hasMore) {
      return;
    }
    unawaited(_loadMore());
  }

  Future<void> _submit(String value) async {
    final query = value.trim();
    _inputFocus.unfocus();
    if (query.isEmpty) {
      setState(() {
        _submitted = null;
        _items = [];
        _error = null;
        _hasMore = false;
      });
      return;
    }
    _input.text = query;
    unawaited(
      saveUserChange(context, () => widget.store.rememberSearch(query)),
    );
    setState(() {
      _submitted = query;
      _loading = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _fetch(query, more: false);
  }

  Future<void> _requery() async {
    final query = _query;
    if (query.isEmpty) return;
    setState(() => _loading = true);
    await _fetch(query, more: false);
  }

  Future<void> _loadMore() async {
    final query = _query;
    if (query.isEmpty) return;
    setState(() => _loading = true);
    await _fetch(query, more: true);
  }

  Future<void> _fetch(String query, {required bool more}) async {
    final generation = ++_generation;
    try {
      final page = await _browser.load(_group, query: query, more: more);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = more ? [..._items, ...page.items] : page.items;
        _hasMore = page.hasMore;
        _loading = false;
        _error = page.warning.isEmpty ? null : page.warning;
      });
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(page.items)),
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        if (!more) _items = [];
        _error = error.toString();
      });
    }
  }

  Future<void> _showFilters() async {
    _inputFocus.unfocus();
    final result = await showModalBottomSheet<_SearchFilterResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _FilterSheet(
        groups: _groups,
        group: _group,
        view: _view,
        hideVip: widget.store.hideVip,
        supportsVipFilter: _group.sources.any((s) => s.vip),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _group = result.group;
      _view = result.view;
    });
    await saveUserChange(
      context,
      () => widget.store.setHideVip(result.hideVip),
    );
    if (!mounted) return;
    if (_hasSearched) await _requery();
  }

  void _clearSearch() {
    _inputFocus.unfocus();
    _input.clear();
    setState(() {
      _submitted = null;
      _items = [];
      _error = null;
      _hasMore = false;
      _managingHistory = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _open(Drama drama) => unawaited(
    openPlaybackDirectly(
      context,
      drama: drama,
      repository: widget.repository,
      store: widget.store,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinHeader =
        _hasSearched &&
        MediaQuery.sizeOf(context).height >= 420 &&
        MediaQuery.textScalerOf(context).scale(16) <= 24;
    return AppScreen(
      title: '搜索',
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 700 ? 32.0 : 20.0;
            final width = math.min(
              _hasSearched ? 1120.0 : 760.0,
              constraints.maxWidth - horizontal * 2,
            );
            final inset = (constraints.maxWidth - width) / 2;
            return Column(
              children: [
                if (pinHeader)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    child: _header(theme),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey(_hasSearched),
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
                    child: _hasSearched
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!pinHeader) _header(theme),
                              _resultsHeader(theme),
                              _resultsBody(width),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [_header(theme), _discovery(theme)],
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) => Padding(
    key: _headerKey,
    padding: EdgeInsets.only(top: _hasSearched ? 8 : 24, bottom: 16),
    child: ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => SearchBar(
        controller: _input,
        focusNode: _inputFocus,
        hintText: _hint,
        textInputAction: TextInputAction.search,
        constraints: const BoxConstraints(minHeight: 64),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(
          theme.colorScheme.surfaceContainerHigh,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
        leading: IconButton(
          tooltip: '搜索',
          onPressed: () => unawaited(_submit(_input.text)),
          icon: const Icon(Icons.search_rounded),
        ),
        trailing: [
          if (value.text.isNotEmpty || _hasSearched)
            IconButton(
              tooltip: '清空搜索',
              onPressed: _clearSearch,
              icon: const Icon(Icons.close_rounded),
            ),
          IconButton(
            tooltip: '筛选条件',
            onPressed: _showFilters,
            icon: Badge(
              backgroundColor: theme.colorScheme.primary,
              isLabelVisible: _hasAdvancedFilters,
              smallSize: 6,
              child: const Icon(Icons.tune_rounded),
            ),
          ),
        ],
        onSubmitted: (value) => unawaited(_submit(value)),
      ),
    ),
  );

  Widget _discovery(ThemeData theme) {
    final histories = widget.store.recentSearches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          type: MaterialType.transparency,
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: const Icon(Icons.tune_rounded),
            title: const Text('按条件查找'),
            subtitle: Text(
              '站源范围 · ${_group.name} · '
              '${_sortLabel(_view.sort)}'
              '${_view.release.isEmpty ? '' : ' · ${_releaseLabel(_view.release)}'}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _showFilters,
          ),
        ),
        const SizedBox(height: 28),
        if (histories.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '最近搜索',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_managingHistory)
                  TextButton(
                    onPressed: () => saveUserChange(
                      context,
                      widget.store.clearRecentSearches,
                    ),
                    child: const Text('清空'),
                  ),
                TextButton(
                  onPressed: () =>
                      setState(() => _managingHistory = !_managingHistory),
                  child: Text(_managingHistory ? '完成' : '管理'),
                ),
              ],
            ),
          ),
          for (final entry in histories)
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                leading: Icon(
                  Icons.history_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 22,
                ),
                title: Text(
                  entry,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _managingHistory
                    ? IconButton(
                        tooltip: '删除这条搜索记录',
                        onPressed: () => saveUserChange(
                          context,
                          () => widget.store.forgetSearch(entry),
                        ),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      )
                    : Icon(
                        Icons.north_west_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                onTap: () => unawaited(_submit(entry)),
              ),
            ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              '输入关键词开始搜索，结果会同时写入本机剧库缓存。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _resultsHeader(ThemeData theme) {
    final results = _results;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '搜索结果',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                _sortLabel(_view.sort),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<CatalogSort>(
                tooltip: '排序方式',
                initialValue: _view.sort,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onSelected: (sort) =>
                    setState(() => _view = _view.copyWith(sort: sort)),
                itemBuilder: (_) => [
                  for (final sort in CatalogSort.values)
                    CheckedPopupMenuItem(
                      value: sort,
                      checked: sort == _view.sort,
                      child: Text('按${sort.label}排序'),
                    ),
                ],
              ),
              IconButton(
                tooltip: '调整筛选',
                onPressed: _showFilters,
                icon: Badge(
                  backgroundColor: theme.colorScheme.primary,
                  isLabelVisible: _hasAdvancedFilters,
                  smallSize: 6,
                  child: const Icon(Icons.tune_rounded),
                ),
              ),
            ],
          ),
          Text(
            _loading && results.isEmpty
                ? '正在搜索…'
                : '${results.length} 部'
                      '${results.length < _items.length ? ' · 已筛选 ${_items.length - results.length} 部' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsBody(double width) {
    final results = _results;
    if (_loading && results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (results.isEmpty) {
      return StatusPanel(
        title: _error == null ? '没有找到「$_query」' : '搜索失败',
        message: _error ?? '可以换个关键词，或切换站源范围再搜索一次。',
        icon: _error == null
            ? Icons.search_off_rounded
            : Icons.wifi_off_rounded,
        onRetry: _error == null ? null : _requery,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: dramaGridDelegate(context, width),
          itemCount: results.length,
          itemBuilder: (context, index) => _tile(results[index]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: _loading
                ? const CircularProgressIndicator()
                : _hasMore
                ? TextButton.icon(
                    onPressed: _loadMore,
                    icon: const Icon(Icons.expand_more_rounded),
                    label: const Text('加载更多'),
                  )
                : Text(
                    '已经看到全部结果',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _tile(Drama drama) {
    void actions() => showDramaActions(
      context,
      drama: drama,
      store: widget.store,
      onContinue: () => _open(drama),
    );
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      onTap: () => _open(drama),
      onMore: actions,
      actions: DramaActionButton(drama: drama, onPressed: actions),
      subtitle: _groups.length > 1 ? SourceSite.byId(drama.source).name : null,
    );
  }
}

String _sortLabel(CatalogSort sort) => sort.label;

String _releaseLabel(String release) => switch (release) {
  'finished' => '已完结',
  'ongoing' => '更新中',
  'unknown' => '未知状态',
  _ => '全部状态',
};

class _SearchFilterResult {
  const _SearchFilterResult({
    required this.group,
    required this.view,
    required this.hideVip,
  });
  final SourceGroup group;
  final CatalogView view;
  final bool hideVip;
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.groups,
    required this.group,
    required this.view,
    required this.hideVip,
    required this.supportsVipFilter,
  });

  final List<SourceGroup> groups;
  final SourceGroup group;
  final CatalogView view;
  final bool hideVip;
  final bool supportsVipFilter;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late SourceGroup _group = widget.group;
  late CatalogView _view = widget.view;
  late bool _hideVip = widget.hideVip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '按条件查找',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '站源范围与排序对当前搜索结果立即生效。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Text('站源范围', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final group in widget.groups)
                ChoiceChip(
                  label: Text(group.name),
                  selected: group.id == _group.id,
                  onSelected: (_) => setState(() => _group = group),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('更新状态', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, value) in const [
                ('全部', ''),
                ('更新中', 'ongoing'),
                ('已完结', 'finished'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _view.release == value,
                  onSelected: (_) =>
                      setState(() => _view = _view.copyWith(release: value)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('排序', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final sort in CatalogSort.values)
                ChoiceChip(
                  label: Text(sort.label),
                  selected: _view.sort == sort,
                  onSelected: (_) =>
                      setState(() => _view = _view.copyWith(sort: sort)),
                ),
            ],
          ),
          if (widget.supportsVipFilter) ...[
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _hideVip,
              title: const Text('隐藏 VIP 试看集'),
              onChanged: (value) => setState(() => _hideVip = value),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _view = const CatalogView();
                    _group = widget.groups.first;
                  }),
                  child: const Text('重置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _SearchFilterResult(
                      group: _group,
                      view: _view,
                      hideVip: _hideVip,
                    ),
                  ),
                  child: const Text('应用'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/router.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/diary_service.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/source_status.dart';
import 'package:duanju_app/features/sources/sources_view_model.dart';
import 'package:duanju_app/widgets/rule_widgets.dart';
import 'package:duanju_app/widgets/settings_widgets.dart';

String sourceTimestamp(DateTime? value) {
  if (value == null) return '尚无记录';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

enum _RuleFilter { all, enabled, disabled }

/// 规则管理（Kazumi 式）：说明卡 + 搜索 + 过滤 + 规则卡列表 + 规则仓库。
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialSource,
    this.drama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String? initialSource;
  final Drama? drama;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  late final SourcesViewModel _model;
  final _expanded = <String>{};
  final _search = TextEditingController();
  final _selected = <String>{};
  Timer? _timer;
  bool _selecting = false;
  _RuleFilter _filter = _RuleFilter.all;

  Map<String, SourceStatus> get _statuses => _model.statuses;
  Map<String, String> get _errors => _model.errors;
  Set<String> get _pending => _model.pending;
  Map<String, Map<String, dynamic>> get _installed => _model.installed;
  List<Map<String, dynamic>> get _catalog => _model.catalog;
  String? get _catalogError => _model.catalogError;
  Set<String> get _catalogBusy => _model.catalogBusy;
  bool get _updatingAll => _model.updatingAll;
  bool get _deleting => _model.deleting;

  bool get _canManageRules => widget.repository.supportsSourceManagement;

  @override
  void initState() {
    super.initState();
    if (widget.initialSource != null) {
      _expanded.add(widget.initialSource!);
    }
    _model = SourcesViewModel(
      repository: widget.repository,
      store: widget.store,
      drama: widget.drama,
    )..addListener(_modelChanged);
    unawaited(_model.refresh());
    unawaited(_model.loadExtensions());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_model.statuses.values.any((status) => status.retryAt != null)) {
        setState(() {});
      }
      if (_model.statuses.values.any((status) => status.running)) {
        unawaited(_model.refresh());
      }
    });
  }

  void _modelChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    _model.removeListener(_modelChanged);
    _model.dispose();
    super.dispose();
  }

  Future<void> _loadExtensions() => _model.loadExtensions();

  Future<void> _toggleInCatalog(Map<String, dynamic> entry) =>
      _model.toggleInCatalog(entry);

  Future<void> _refresh() => _model.refresh();

  Future<void> _run(SourceSite source, String operation) {
    if (operation == 'check' || operation == 'checkCatalog') {
      setState(() => _expanded.add(source.id));
    }
    return _model.run(source, operation);
  }

  Future<void> _updateAll(List<SourceSite> sources) =>
      _model.updateAll(sources);

  Future<void> _toggle(SourceSite source, bool enabled) =>
      _model.toggle(source, enabled);

  Future<void> _uninstall(List<SourceSite> sources) async {
    if (_deleting || sources.isEmpty) return;
    _model.setDeleting(true);
    final names = sources.map((source) => source.displayEntryName).join('、');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载规则？'),
        content: Text(
          '将移除 $names 的规则文件，已缓存的剧集与下载不受影响；'
          '随时可以在规则仓库重新安装。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      _model.setDeleting(false);
      return;
    }
    await _model.uninstall(sources);
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已卸载 ${sources.length} 条规则')));
  }

  Future<void> _copy(SourceSite source, SourceStatus? status) async {
    final text = StringBuffer('${source.name}\n');
    final health = status?.health;
    text.writeln(
      '缓存 ${status?.count ?? 0} 部，更新 ${sourceTimestamp(status?.updatedAt)}',
    );
    if (health != null) {
      text.writeln('${health.label} · ${sourceTimestamp(health.checkedAt)}');
      if (health.sample.isNotEmpty) text.writeln('检测剧集：${health.sample}');
      for (final step in health.steps) {
        text.writeln('${step.name}：${step.message}');
        text.writeln(
          '${step.host} HTTP ${step.httpStatus} · ${step.elapsedMs} ms',
        );
        if (step.cfRay.isNotEmpty) text.writeln('CF Ray: ${step.cfRay}');
      }
    }
    if ((status?.error ?? '').isNotEmpty) text.writeln(status!.error);
    if ((status?.storageError ?? '').isNotEmpty) {
      text.writeln(status!.storageError);
    }
    if (_errors[source.id]?.isNotEmpty ?? false) {
      text.writeln(_errors[source.id]);
    }
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
    }
  }

  /// 展示该扩展源的设置项（目前是镜像地址）。
  ///
  /// 设置由宿主声明 → 存进该源的 hg.storage，扩展通过 source.base() 读取，
  /// 客户端不需要为每个源写一套表单。
  Future<void> _showSourceSettings(SourceSite source) async {
    unawaited(_model.loadSettings(source.id));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) =>
          _SourceSettingsSheet(source: source, model: _model),
    );
  }

  /// 展示该扩展源的原生日志（hg.log / console.log）。
  Future<void> _showExtensionLogs(SourceSite source) async {
    final lines = await DiaryService.extensionLogs(source.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final colors = Theme.of(sheetContext).colorScheme;
        return SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .7,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${source.name} 扩展日志',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  lines.isEmpty
                      ? '还没有该扩展的输出。触发一次目录或播放后回来查看。'
                      : '共 ${lines.length} 条，最近的在最后。',
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: lines.isEmpty
                      ? const Center(child: Text('暂无日志'))
                      : ListView.builder(
                          itemCount: lines.length,
                          itemBuilder: (context, index) => SelectableText(
                            lines[index],
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                ),
                if (lines.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: lines.join('\n')),
                        );
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('复制全部'),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openCatalog() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RuleCatalogSheet(
        catalog: _catalog,
        busy: _catalogBusy,
        error: _catalogError,
        remoteConfigured: _model.remoteConfigured,
        onToggle: _toggleInCatalog,
        onRefresh: _loadExtensions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final all = SourceSite.values;
        final query = _search.text.trim().toLowerCase();
        final visible = all.where((source) {
          if (_filter == _RuleFilter.enabled &&
              !widget.store.sourceEnabled(source.id)) {
            return false;
          }
          if (_filter == _RuleFilter.disabled &&
              widget.store.sourceEnabled(source.id)) {
            return false;
          }
          if (query.isEmpty) return true;
          return source.name.toLowerCase().contains(query) ||
              source.description.toLowerCase().contains(query) ||
              source.displayGroupName.toLowerCase().contains(query) ||
              source.id.toLowerCase().contains(query);
        }).toList();
        final enabledCount = all
            .where((source) => widget.store.sourceEnabled(source.id))
            .length;
        final selectedSources = all
            .where((source) => _selected.contains(source.id))
            .toList();
        final uninstallable = all
            .where((source) => source.id != SourceSite.hongguo.id)
            .toList();
        return SettingsDetailScaffold(
          title: _selecting ? '已选择 ${_selected.length} 条' : '规则管理',
          actions: [
            if (_selecting)
              IconButton(
                tooltip: '卸载所选规则',
                onPressed: _selected.isEmpty || _deleting || !_canManageRules
                    ? null
                    : () => _uninstall(selectedSources),
                icon: const Icon(Icons.delete_outline_rounded),
              )
            else
              IconButton(
                key: const ValueKey('rules-select-mode'),
                tooltip: '批量选择',
                onPressed: () => setState(() => _selecting = true),
                icon: const Icon(Icons.checklist_rounded),
              ),
            IconButton(
              tooltip: '刷新状态',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
          ],
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    RulePageIntro(
                      title: '我的规则',
                      icon: Icons.extension_rounded,
                      description:
                          '规则决定应用从哪个站源取回剧集。仅红果内置，'
                          '其余规则需要在规则仓库中手动安装；'
                          '离开本页后更新任务仍会继续。',
                      actions: [
                        FilledButton.icon(
                          key: const ValueKey('rules-add'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(120, 48),
                          ),
                          onPressed: _openCatalog,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('规则仓库'),
                        ),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(120, 48),
                          ),
                          onPressed: _updatingAll
                              ? null
                              : () => _updateAll(widget.store.sources),
                          icon: _updatingAll
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.sync_rounded),
                          label: Text(_updatingAll ? '正在更新' : '全部更新'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: ruleInputDecoration(
                        context,
                        hint: '搜索规则名称或站源',
                        prefix: const Icon(Icons.search_rounded),
                        suffix: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final (label, value) in [
                          ('全部 ${all.length}', _RuleFilter.all),
                          ('已启用 $enabledCount', _RuleFilter.enabled),
                          (
                            '已关闭 ${all.length - enabledCount}',
                            _RuleFilter.disabled,
                          ),
                        ])
                          FilterChip(
                            label: Text(label),
                            selected: _filter == value,
                            onSelected: (_) => setState(() => _filter = value),
                          ),
                        if (_catalogError != null)
                          Text(
                            '规则仓库暂不可用：$_catalogError',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                      ],
                    ),
                    if (_selecting)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '选中后可一次卸载；已下载的视频会保留。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                if (selectedSources.length ==
                                    uninstallable.length) {
                                  _selected.clear();
                                } else {
                                  _selected.addAll(
                                    uninstallable.map((s) => s.id),
                                  );
                                }
                              }),
                              child: Text(
                                selectedSources.length ==
                                            uninstallable.length &&
                                        uninstallable.isNotEmpty
                                    ? '取消全选'
                                    : '全选可卸载',
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _selecting = false;
                                _selected.clear();
                              }),
                              child: const Text('退出多选'),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Column(
                          children: [
                            Icon(
                              all.isEmpty
                                  ? Icons.extension_rounded
                                  : Icons.search_off_rounded,
                              size: 40,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              all.isEmpty ? '还没有安装规则' : '没有符合条件的规则',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 20),
                            FilledButton.tonalIcon(
                              onPressed: _openCatalog,
                              icon: const Icon(Icons.travel_explore_rounded),
                              label: const Text('浏览规则仓库'),
                            ),
                          ],
                        ),
                      )
                    else
                      for (final source in visible)
                        _ruleCard(
                          source: source,
                          selected: _selected.contains(source.id),
                        ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _ruleCard({required SourceSite source, required bool selected}) {
    final colors = Theme.of(context).colorScheme;
    final status = _statuses[source.id];
    final error = _errors[source.id] ?? status?.error ?? '';
    final busy = _pending.contains(source.id) || status?.running == true;
    final seconds = status?.retrySeconds ?? 0;
    final enabled = widget.store.sourceEnabled(source.id);
    final builtIn = source.id == SourceSite.hongguo.id;
    final version =
        _installed[source.id]?['version'] as String? ??
        (_catalog.firstWhere(
              (entry) => entry['id'] == source.id,
              orElse: () => const {},
            )['version']
            as String?);
    final health = status?.health;
    final expanded = _expanded.contains(source.id);
    final subtitle = source.group.isEmpty
        ? source.description
        : '${source.groupName} · ${source.entryName} · ${source.description}';
    return RuleCard(
      key: ValueKey('rule-${source.id}'),
      title: source.displayEntryName,
      subtitle: subtitle,
      selected: selected,
      installed: enabled,
      onTap: _selecting
          ? (builtIn
                ? null
                : () => setState(() {
                    if (!_selected.remove(source.id)) _selected.add(source.id);
                  }))
          : () => setState(() {
              if (expanded) {
                _expanded.remove(source.id);
              } else {
                _expanded.add(source.id);
              }
            }),
      tags: [
        RuleTag(
          label: enabled ? '已启用' : '已关闭',
          background: enabled
              ? colors.secondaryContainer
              : colors.surfaceContainerHighest,
          foreground: enabled
              ? colors.onSecondaryContainer
              : colors.onSurfaceVariant,
        ),
        if (version != null)
          RuleTag(
            label: 'v$version',
            background: colors.surfaceContainerHighest,
            foreground: colors.onSurfaceVariant,
          ),
        if (source.restricted)
          RuleTag(
            label: '受限',
            background: colors.tertiaryContainer,
            foreground: colors.onTertiaryContainer,
          ),
        if (source.onlineSearch)
          RuleTag(
            label: '在线搜索',
            background: colors.surfaceContainerHighest,
            foreground: colors.onSurfaceVariant,
          ),
        if (health != null)
          RuleTag(
            label: health.state == 'ok' ? '检测通过' : health.label,
            background: health.state == 'failed'
                ? colors.errorContainer
                : colors.tertiaryContainer,
            foreground: health.state == 'failed'
                ? colors.onErrorContainer
                : colors.onTertiaryContainer,
          ),
        if (enabled && (status?.count ?? 0) > 0)
          RuleTag(
            label: '${status!.count} 部',
            background: colors.primaryContainer,
            foreground: colors.onPrimaryContainer,
          ),
      ],
      caption:
          '最近更新 ${sourceTimestamp(status?.updatedAt)}'
          '${(status?.added ?? 0) > 0 ? ' · 新增 ${status!.added} 部' : ''}'
          '${seconds > 0 ? ' · $seconds 秒后可重试' : ''}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error.isNotEmpty && !expanded)
            Icon(Icons.error_outline_rounded, color: colors.error, size: 18),
          if (_selecting)
            Checkbox(
              value: selected,
              visualDensity: VisualDensity.compact,
              onChanged: builtIn
                  ? null
                  : (_) => setState(() {
                      if (!_selected.remove(source.id)) {
                        _selected.add(source.id);
                      }
                    }),
            )
          else
            Switch(
              key: ValueKey('switch-${source.id}'),
              value: enabled,
              onChanged: busy || !_canManageRules
                  ? null
                  : (value) => _toggle(source, value),
            ),
          _ruleMenu(source, builtIn: builtIn, enabled: enabled, busy: busy),
        ],
      ),
      details: expanded
          ? _ruleDetails(
              source,
              status,
              error,
              busy: busy,
              seconds: seconds,
              builtIn: builtIn,
            )
          : null,
    );
  }

  Widget _ruleDetails(
    SourceSite source,
    SourceStatus? status,
    String error, {
    required bool busy,
    required int seconds,
    required bool builtIn,
  }) {
    final colors = Theme.of(context).colorScheme;
    final enabled =
        !busy && seconds == 0 && widget.repository.supportsSourceManagement;
    final health = status?.health;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: ValueKey('update-${source.id}'),
              onPressed: enabled ? () => _run(source, 'update') : null,
              icon: const Icon(Icons.sync_rounded, size: 18),
              label: const Text('更新目录'),
            ),
            FilledButton.tonalIcon(
              key: ValueKey('check-${source.id}'),
              onPressed: enabled ? () => _run(source, 'check') : null,
              icon: const Icon(Icons.network_check_rounded, size: 18),
              label: const Text('检测连接与播放'),
            ),
            if (status?.hasMore ?? true)
              OutlinedButton.icon(
                onPressed: enabled ? () => _run(source, 'more') : null,
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: const Text('继续加载一页'),
              ),
            OutlinedButton.icon(
              onPressed: enabled ? () => _run(source, 'metadata') : null,
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('补齐资料'),
            ),
            if (busy)
              TextButton(
                onPressed: () => _run(source, 'cancel'),
                child: const Text('停止'),
              ),
            TextButton.icon(
              onPressed: () => _copy(source, status),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('复制诊断'),
            ),
            TextButton.icon(
              onPressed: builtIn ? null : () => _showExtensionLogs(source),
              icon: const Icon(Icons.receipt_long_rounded, size: 18),
              label: const Text('扩展日志'),
            ),
            TextButton.icon(
              key: ValueKey('settings-${source.id}'),
              onPressed: builtIn ? null : () => _showSourceSettings(source),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('设置'),
            ),
          ],
        ),
        if (busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: status != null && status.total > 0
                ? (status.completed / status.total).clamp(0, 1)
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            '${status?.stage ?? '准备中'}'
            '${(status?.total ?? 0) > 0 ? ' · ${status!.completed}/${status.total}' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (status != null && status.storageError.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(status.storageError, style: TextStyle(color: colors.error)),
          TextButton.icon(
            key: ValueKey('save-${source.id}'),
            onPressed: enabled ? () => _run(source, 'retrySave') : null,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('重试保存'),
          ),
        ],
        if (error.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(error, style: TextStyle(color: colors.error)),
        ],
        if (health != null) ...[
          const SizedBox(height: 12),
          Text(
            '${health.label} · ${sourceTimestamp(health.checkedAt)}'
            '${health.sample.isEmpty ? '' : ' · 检测剧集 ${health.sample}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final step in health.steps)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    step.state == 'ok'
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 18,
                    color: step.state == 'ok' ? colors.primary : colors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${step.name}：${step.message}'),
                        if (step.host.isNotEmpty || step.httpStatus > 0)
                          Text(
                            '${step.host}'
                            '${step.httpStatus > 0 ? ' · HTTP ${step.httpStatus}' : ''}'
                            ' · ${step.elapsedMs} ms',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ] else ...[
          const SizedBox(height: 8),
          Text('尚未检测连接与播放。', style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }

  Widget _ruleMenu(
    SourceSite source, {
    required bool builtIn,
    required bool enabled,
    required bool busy,
  }) {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
      builder: (context, controller, child) => IconButton(
        tooltip: '${source.name} 的更多操作',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.more_horiz_rounded),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            enabled ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
          ),
          onPressed: busy ? null : () => _toggle(source, !enabled),
          child: Text(enabled ? '关闭此规则' : '启用此规则'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.sync_rounded),
          onPressed: busy ? null : () => _run(source, 'update'),
          child: const Text('更新目录'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.network_check_rounded),
          onPressed: busy ? null : () => _run(source, 'check'),
          child: const Text('检测连接与播放'),
        ),
        if (!builtIn)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1),
          ),
        if (!builtIn)
          MenuItemButton(
            leadingIcon: Icon(
              Icons.delete_outline_rounded,
              color: colors.error,
            ),
            onPressed: () => _uninstall([source]),
            child: const Text('卸载规则'),
          ),
      ],
    );
  }
}

/// 规则仓库：随包扩展列表，手动安装/卸载。
class _RuleCatalogSheet extends StatefulWidget {
  const _RuleCatalogSheet({
    required this.catalog,
    required this.busy,
    required this.error,
    required this.remoteConfigured,
    required this.onToggle,
    required this.onRefresh,
  });

  final List<Map<String, dynamic>> catalog;
  final Set<String> busy;
  final String? error;
  final bool remoteConfigured;
  final ValueChanged<Map<String, dynamic>> onToggle;
  final VoidCallback onRefresh;

  @override
  State<_RuleCatalogSheet> createState() => _RuleCatalogSheetState();
}

class _RuleCatalogSheetState extends State<_RuleCatalogSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = _search.text.trim().toLowerCase();
    final entries = widget.catalog
        .where(
          (entry) =>
              query.isEmpty ||
              '${entry['name']} ${entry['id']} ${entry['description']}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    final height = MediaQuery.sizeOf(context).height * .82;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '规则仓库',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.remoteConfigured
                  ? '随包附带官方规则，安装后才可作为站源使用。'
                  : '随包附带官方规则，安装后才可作为站源使用。'
                        '此版本未配置在线仓库，无法检查更新或下架。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: ruleInputDecoration(
                context,
                hint: '搜索规则',
                prefix: const Icon(Icons.search_rounded),
                suffix: IconButton(
                  tooltip: '重新读取仓库',
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
            ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  widget.error!,
                  style: TextStyle(color: colors.error),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的规则',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final installed = entry['installed'] == true;
                        final id = entry['id'] as String? ?? '';
                        final pending = widget.busy.contains(id);
                        final blocked = entry['killSwitch'] == true;
                        final updateAvailable =
                            installed && entry['updateAvailable'] == true;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: RuleCard(
                            title: '${entry['name'] ?? id}',
                            subtitle: blocked
                                ? '该规则已下架，建议卸载'
                                : entry['description'] as String? ?? '官方扩展源',
                            installed: installed,
                            caption: entry['changelog'] as String?,
                            tags: [
                              RuleTag(
                                label: 'v${entry['version'] ?? '1'}',
                                background: colors.surfaceContainerHighest,
                                foreground: colors.onSurfaceVariant,
                              ),
                              if (entry['restricted'] == true)
                                RuleTag(
                                  label: '受限',
                                  background: colors.tertiaryContainer,
                                  foreground: colors.onTertiaryContainer,
                                ),
                              if (installed)
                                RuleTag(
                                  label: '已安装',
                                  background: colors.secondaryContainer,
                                  foreground: colors.onSecondaryContainer,
                                ),
                              if (updateAvailable)
                                RuleTag(
                                  label: '可更新',
                                  background: colors.primaryContainer,
                                  foreground: colors.onPrimaryContainer,
                                ),
                              if (blocked)
                                RuleTag(
                                  label: '已下架',
                                  background: colors.errorContainer,
                                  foreground: colors.onErrorContainer,
                                ),
                            ],
                            trailing: pending
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : FilledButton.tonal(
                                    onPressed: blocked
                                        ? (installed
                                              ? () => widget.onToggle(entry)
                                              : null)
                                        : () => widget.onToggle(entry),
                                    child: Text(
                                      blocked
                                          ? '卸载'
                                          : installed
                                          ? (updateAvailable ? '更新' : '卸载')
                                          : '安装',
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SourceDiagnosticsButton extends StatelessWidget {
  const SourceDiagnosticsButton({
    super.key,
    required this.repository,
    required this.store,
    required this.drama,
  });
  final AppRepository repository;
  final LocalStore store;
  final Drama drama;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => context.push(
      '/sources',
      extra: SourcesRouteArgs(initialSource: drama.source, drama: drama),
    ),
    icon: const Icon(Icons.network_check),
    label: const Text('站源诊断'),
  );
}

/// 每源设置的通用表单：宿主下发 schema，这里只负责渲染与保存。
class _SourceSettingsSheet extends StatefulWidget {
  const _SourceSettingsSheet({required this.source, required this.model});
  final SourceSite source;
  final SourcesViewModel model;

  @override
  State<_SourceSettingsSheet> createState() => _SourceSettingsSheetState();
}

class _SourceSettingsSheetState extends State<_SourceSettingsSheet> {
  final _controllers = <String, TextEditingController>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  TextEditingController _controller(String key, String initial) =>
      _controllers.putIfAbsent(key, () => TextEditingController(text: initial));

  /// 按清单声明的类型渲染控件：input / toggle / choice。
  /// 未知类型回落到文本框，避免扩展写错时整块表单不可用。
  Widget _settingField(
    Map<String, dynamic> setting,
    TextEditingController controller,
  ) {
    final key = setting['key'] as String? ?? '';
    final type = setting['type'] as String? ?? 'input';
    if (type == 'toggle') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Switch(
          key: ValueKey('setting-$key'),
          value: controller.text == 'true',
          onChanged: _saving
              ? null
              : (value) => setState(() => controller.text = '$value'),
        ),
      );
    }
    if (type == 'choice') {
      final options = [
        for (final row in setting['options'] as List? ?? const [])
          if (row is Map) Map<String, dynamic>.from(row),
      ];
      final current = options.any((row) => row['value'] == controller.text)
          ? controller.text
          : (setting['default'] as String? ?? '');
      return DropdownButtonFormField<String>(
        key: ValueKey('setting-$key'),
        initialValue: current.isEmpty ? null : current,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option['value'] as String? ?? '',
              child: Text(option['label'] as String? ?? ''),
            ),
        ],
        onChanged: _saving
            ? null
            : (value) => setState(() => controller.text = value ?? ''),
      );
    }
    return TextField(
      key: ValueKey('setting-$key'),
      controller: controller,
      enabled: !_saving,
      decoration: InputDecoration(
        hintText: setting['placeholder'] as String?,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Future<void> _save(Map<String, dynamic> setting) async {
    final key = setting['key'] as String? ?? '';
    if (key.isEmpty) return;
    setState(() => _saving = true);
    final value = _controllers[key]?.text.trim() ?? '';
    final saved = await widget.model.saveSetting(widget.source.id, key, value);
    if (!mounted) return;
    setState(() => _saving = false);
    final message = saved
        ? (value.isEmpty ? '已恢复默认地址' : '已保存')
        : (widget.model.errors[widget.source.id] ?? '保存失败');
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final settings = widget.model.settings[widget.source.id] ?? const [];
    final busy = widget.model.settingsBusy.contains(widget.source.id);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.source.name} 设置',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              '设置保存在本机，扩展通过 source.base() 读取。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: busy && settings.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : settings.isEmpty
                  ? const Center(child: Text('该规则没有可配置项'))
                  : ListView.separated(
                      itemCount: settings.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 16),
                      itemBuilder: (context, index) {
                        final setting = settings[index];
                        final key = setting['key'] as String? ?? '';
                        final controller = _controller(
                          key,
                          setting['value'] as String? ?? '',
                        );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              setting['title'] as String? ?? key,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            if ((setting['description'] as String? ?? '')
                                .isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                setting['description'] as String,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: _settingField(setting, controller),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  onPressed: _saving
                                      ? null
                                      : () => _save(setting),
                                  child: const Text('保存'),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

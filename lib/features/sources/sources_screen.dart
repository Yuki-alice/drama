import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/app/router.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/source_status.dart';
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
  final _statuses = <String, SourceStatus>{};
  final _errors = <String, String>{};
  final _pending = <String>{};
  final _revisions = <String, int>{};
  final _expanded = <String>{};
  final _search = TextEditingController();
  final _selected = <String>{};
  Timer? _timer;
  bool _polling = false;
  bool _selecting = false;
  bool _updatingAll = false;
  bool _deleting = false;
  _RuleFilter _filter = _RuleFilter.all;

  /// 已安装扩展的元数据（id -> 行），用于版本标签与卸载。
  final _installed = <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>> _catalog = const [];
  String? _catalogError;
  final _catalogBusy = <String>{};

  bool get _canManageRules => widget.repository.supportsSourceManagement;

  @override
  void initState() {
    super.initState();
    if (widget.initialSource != null) {
      _expanded.add(widget.initialSource!);
    }
    unawaited(_refresh());
    unawaited(_loadExtensions());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_statuses.values.any((status) => status.retryAt != null)) {
        setState(() {});
      }
      if (_statuses.values.any((status) => status.running)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadExtensions() async {
    String? error;
    var rows = const <Map<String, dynamic>>[];
    try {
      rows = await widget.repository.installedExtensions();
      SourceSite.setInstalledExtensions(rows);
      widget.store.refreshSources();
    } catch (failure) {
      error = failure.toString();
    }
    final installed = {
      for (final row in rows) row['id'] as String? ?? '': row,
    };
    try {
      final raw = await rootBundle.loadString('extensions-repo/index.json');
      final entries = [
        for (final row in jsonDecode(raw) as List)
          if (row is Map)
            {
              ...Map<String, dynamic>.from(row),
              'bundled': true,
              'installed': installed.containsKey(row['id']),
            },
      ];
      if (!mounted) return;
      setState(() {
        _installed
          ..clear()
          ..addAll(installed);
        _catalog = entries;
        _catalogError = error;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _installed
          ..clear()
          ..addAll(installed);
        _catalog = [
          for (final entry in installed.values)
            {...entry, 'bundled': true, 'installed': true},
        ];
        _catalogError = error ?? failure.toString();
      });
    }
  }

  Future<void> _toggleInCatalog(Map<String, dynamic> entry) async {
    final id = entry['id'] as String? ?? '';
    if (id.isEmpty || _catalogBusy.contains(id)) return;
    setState(() => _catalogBusy.add(id));
    try {
      if (entry['installed'] == true) {
        await widget.repository.uninstallExtension(id);
      } else {
        final code = await rootBundle.loadString(
          'extensions-repo/extensions/$id.js',
        );
        await widget.repository.installExtension(id, code: code);
      }
      await _loadExtensions();
      await _refresh();
    } catch (failure) {
      if (mounted) setState(() => _catalogError = failure.toString());
    } finally {
      if (mounted) setState(() => _catalogBusy.remove(id));
    }
  }

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      final targets = widget.store.sources;
      await Future.wait([
        for (final source in targets)
          (() async {
            final revision = _revisions[source.id] ?? 0;
            try {
              final status = await widget.repository.sourceStatus(source.id);
              if (!mounted || revision != (_revisions[source.id] ?? 0)) return;
              setState(() {
                _statuses[source.id] = status;
                _errors.remove(source.id);
              });
            } catch (failure) {
              if (mounted && revision == (_revisions[source.id] ?? 0)) {
                setState(() => _errors[source.id] = failure.toString());
              }
            }
          })(),
      ]);
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(SourceSite source, String operation) async {
    if (_pending.contains(source.id)) return;
    setState(() {
      _pending.add(source.id);
      _errors.remove(source.id);
      _revisions[source.id] = (_revisions[source.id] ?? 0) + 1;
      if (operation == 'check' || operation == 'checkCatalog') {
        _expanded.add(source.id);
      }
    });
    try {
      final status = operation == 'cancel'
          ? await widget.repository.cancelSourceJob(source.id)
          : await widget.repository.startSourceJob(
              source.id,
              operation,
              drama: source.id == widget.drama?.source ? widget.drama : null,
            );
      if (mounted) setState(() => _statuses[source.id] = status);
    } catch (error) {
      if (mounted) setState(() => _errors[source.id] = error.toString());
    } finally {
      if (mounted) setState(() => _pending.remove(source.id));
    }
  }

  Future<void> _updateAll(List<SourceSite> sources) async {
    if (_updatingAll || sources.isEmpty) return;
    setState(() => _updatingAll = true);
    for (final source in sources) {
      await _run(source, 'update');
    }
    if (mounted) setState(() => _updatingAll = false);
  }

  Future<void> _toggle(SourceSite source, bool enabled) async {
    setState(() => _errors.remove(source.id));
    try {
      await widget.store.setSourceEnabled(source.id, enabled);
      if (enabled) unawaited(_refresh());
    } catch (error) {
      if (mounted) setState(() => _errors[source.id] = error.toString());
    }
  }

  Future<void> _uninstall(List<SourceSite> sources) async {
    if (_deleting || sources.isEmpty) return;
    setState(() => _deleting = true);
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
      if (mounted) setState(() => _deleting = false);
      return;
    }
    for (final source in sources) {
      try {
        await widget.repository.uninstallExtension(source.id);
      } catch (error) {
        if (mounted) {
          setState(() => _errors[source.id] = error.toString());
        }
      }
    }
    await _loadExtensions();
    if (mounted) {
      setState(() {
        _deleting = false;
        _selecting = false;
        _selected.clear();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已卸载 ${sources.length} 条规则')));
    }
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

  void _openCatalog() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RuleCatalogSheet(
        catalog: _catalog,
        busy: _catalogBusy,
        error: _catalogError,
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
          if (_filter == _RuleFilter.enabled && !widget.store.sourceEnabled(source.id)) {
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
                              : () => _updateAll(
                                  widget.store.sources,
                                ),
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
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    final version = _installed[source.id]?['version'] as String? ??
        (_catalog.firstWhere(
              (entry) => entry['id'] == source.id,
              orElse: () => const {},
            )['version'] as String?);
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
          background: enabled ? colors.secondaryContainer : colors.surfaceContainerHighest,
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
                      if (!_selected.remove(source.id)) _selected.add(source.id);
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
          ? _ruleDetails(source, status, error, busy: busy, seconds: seconds)
          : null,
    );
  }

  Widget _ruleDetails(
    SourceSite source,
    SourceStatus? status,
    String error, {
    required bool busy,
    required int seconds,
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
          Text(
            status.storageError,
            style: TextStyle(color: colors.error),
          ),
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
          Text(
            '尚未检测连接与播放。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
          onPressed: busy
              ? null
              : () => _toggle(source, !enabled),
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
    required this.onToggle,
    required this.onRefresh,
  });

  final List<Map<String, dynamic>> catalog;
  final Set<String> busy;
  final String? error;
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
        .where((entry) =>
            query.isEmpty ||
            '${entry['name']} ${entry['id']} ${entry['description']}'
                .toLowerCase()
                .contains(query))
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
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '随包附带官方规则，安装后才可作为站源使用。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
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
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: RuleCard(
                            title: '${entry['name'] ?? id}',
                            subtitle: entry['description'] as String? ??
                                '官方扩展源',
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
                                        ? null
                                        : () => widget.onToggle(entry),
                                    child: Text(installed ? '卸载' : '安装'),
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

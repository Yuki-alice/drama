import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/detail/episode_browser.dart';

typedef DetailPersist = Future<void> Function(Future<void> Function() action);

enum DetailInitialAction { none, resume, download }

/// 详情页数据状态与加载/补全逻辑；导航与弹窗留在 View。
class DetailViewModel extends ChangeNotifier {
  DetailViewModel({
    required this.repository,
    required this.store,
    required this.drama,
    required this.persist,
  });

  final AppRepository repository;
  final LocalStore store;
  final Drama drama;
  final DetailPersist persist;

  DramaDetail? _detail;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  int _episodePage = 0;
  DetailInitialAction? _pendingAction;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  DramaDetail? get detail => _detail;
  String? get error => _error;
  bool get loading => _loading;
  int get episodePage => _episodePage;
  Drama get displayDrama => _detail?.drama ?? drama;
  List<Episode> get episodes => _detail?.episodes ?? const [];
  int get resumeIndex =>
      resumeEpisodeIndex(episodes, store.watched(displayDrama.id));

  Future<void> load({
    bool resumeOnOpen = false,
    bool downloadOnOpen = false,
  }) async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final detail = await repository.detail(drama);
      if (generation != _generation) return;
      final merged = repository.catalogUpdates
          .current(drama)
          .merge(detail.drama);
      _detail = DramaDetail(merged, detail.episodes, warning: detail.warning);
      _loading = false;
      _episodePage =
          resumeEpisodeIndex(detail.episodes, store.watched(merged.id)) ~/
          episodePageSize;
      notifyListeners();
      repository.catalogUpdates.publish(merged, retryCover: true);
      unawaited(_supplement(merged, generation));
      await persist(() => store.refreshDrama(merged));
      if (generation != _generation || detail.episodes.isEmpty) return;
      _pendingAction = resumeOnOpen
          ? DetailInitialAction.resume
          : downloadOnOpen && store.canDownload
          ? DetailInitialAction.download
          : DetailInitialAction.none;
      notifyListeners();
    } catch (error) {
      if (generation != _generation) return;
      _error = error.toString();
      _loading = false;
      notifyListeners();
      repository.catalogUpdates.publish(
        repository.catalogUpdates.current(drama),
        retryCover: true,
      );
    }
  }

  DetailInitialAction takeInitialAction() {
    final action = _pendingAction ?? DetailInitialAction.none;
    _pendingAction = null;
    return action;
  }

  Future<void> _supplement(Drama drama, int generation) async {
    try {
      final fresh = await repository.supplementMetadata(drama);
      if (generation != _generation || fresh == null || _detail == null) return;
      final updated = _detail!.drama.merge(fresh);
      _detail = DramaDetail(
        updated,
        _detail!.episodes,
        warning: _detail!.warning,
      );
      notifyListeners();
      repository.catalogUpdates.publish(updated);
      await persist(() => store.refreshDrama(updated));
    } catch (_) {}
  }

  void setEpisodePage(int page) {
    if (_episodePage == page) return;
    _episodePage = page;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

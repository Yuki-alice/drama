import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/features/detail/detail_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _DetailRepository extends FixtureRepository {
  _DetailRepository({this.failure, this.supplemented});

  final String? failure;
  final Drama? supplemented;

  @override
  Future<DramaDetail> detail(Drama drama) async {
    if (failure != null) throw AppFailure(failure!);
    return DramaDetail(drama, [
      for (var number = 1; number <= 3; number++)
        Episode({
          'id': '$number',
          'title': '第$number集',
          'currentEpisode': number,
        }, number),
    ]);
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async => supplemented;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DetailViewModel> build(
    _DetailRepository repository, {
    Drama drama = FixtureRepository.free,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final model = DetailViewModel(
      repository: repository,
      store: store,
      drama: drama,
      persist: (action) => action(),
    );
    addTearDown(model.dispose);
    return model;
  }

  test('load exposes detail and episodes', () async {
    final model = await build(_DetailRepository());

    await model.load();

    expect(model.loading, isFalse);
    expect(model.error, isNull);
    expect(model.detail, isNotNull);
    expect(model.episodes, hasLength(3));
    expect(model.episodePage, 0);
  });

  test('load failure surfaces error', () async {
    final model = await build(_DetailRepository(failure: '详情接口失败'));

    await model.load();

    expect(model.loading, isFalse);
    expect(model.detail, isNull);
    expect(model.error, contains('详情接口失败'));
  });

  test('catalog updates are merged into the loaded detail', () async {
    final repository = _DetailRepository();
    final model = await build(repository);
    repository.catalogUpdates.publish(
      Drama(
        id: FixtureRepository.free.id,
        source: FixtureRepository.free.source,
        title: '',
        description: '来自目录更新的简介',
      ),
    );

    await model.load();

    expect(model.detail!.drama.description, '来自目录更新的简介');
  });

  test('initial action is delivered exactly once', () async {
    final model = await build(_DetailRepository());

    await model.load(resumeOnOpen: true);

    expect(model.takeInitialAction(), DetailInitialAction.resume);
    expect(model.takeInitialAction(), DetailInitialAction.none);
    expect(model.resumeIndex, 0);
  });

  test('download on open becomes the initial action', () async {
    final model = await build(_DetailRepository());

    await model.load(downloadOnOpen: true);

    expect(model.takeInitialAction(), DetailInitialAction.download);
  });

  test('supplemented metadata is merged asynchronously', () async {
    final repository = _DetailRepository(
      supplemented: const Drama(
        id: 'hongguo:100',
        source: 'hongguo',
        title: '补全标题',
      ),
    );
    final model = await build(repository);

    await model.load();
    await Future<void>.delayed(Duration.zero);

    expect(model.detail!.drama.title, '补全标题');
  });
}

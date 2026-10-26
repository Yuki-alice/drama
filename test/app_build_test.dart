import 'package:duanju_app/core/app_build.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('single package exposes hongguo and installed extensions', () async {
    SharedPreferences.setMockInitialValues({'source': 'huangdou'});
    final store = testStore(await SharedPreferences.getInstance());
    expect(appSlug, 'hongguojian');
    // 默认只开启红果、韩小圈、鬼片网与青空次元，其余站源在站源管理中开启。
    expect(store.sources.length, 4);
    expect(SourceSite.values.any((source) => source.id == 'dsd'), isTrue);
    expect(SourceSite.isAvailable('dsd'), isTrue);
    expect(SourceSite.isKnown('dsd'), isTrue);
    expect(SourceSite.byId('dsd').name, '帝果');
    expect(store.allowsSource('dsd'), isFalse);
    expect(store.source, 'hongguo');
    await store.setSourceEnabled('dsd', true);
    expect(store.sources.length, 5);
    expect(store.allowsSource('dsd'), isTrue);
    store.dispose();
  });

  test('站源列表只包含红果与已安装扩展', () {
    SourceSite.resetInstalledExtensions();
    expect(SourceSite.values.map((site) => site.id), ['hongguo']);
    expect(SourceSite.isAvailable('dsd'), isFalse);
    SourceSite.setInstalledExtensions([
      {
        'id': 'demo',
        'name': '示例源',
        'description': '测试扩展',
        'restricted': true,
        'group': 'huangguo',
        'groupName': '黄果',
        'entryName': '示例',
        'onlineSearch': true,
        'pagedSearch': true,
      },
    ]);
    expect(SourceSite.values.map((site) => site.id), ['hongguo', 'demo']);
    expect(SourceSite.isAvailable('demo'), isTrue);
    expect(SourceSite.isRestricted('demo'), isTrue);
    expect(SourceSite.byId('demo').displayGroupName, '黄果');
    expect(SourceSite.byId('demo').displayEntryName, '示例');
    SourceSite.resetInstalledExtensions();
  });

  test(
    'background requests reject unavailable sources before native I/O',
    () async {
      SourceSite.resetInstalledExtensions();
      final repository = NativeRepository(background: true);
      final denied = [
        ...SourceSite.allValues
            .where((source) => !SourceSite.isAvailable(source.id))
            .map((source) => source.id),
        'unknown',
      ];
      for (final source in denied) {
        final drama = Drama(id: '$source:123', source: source, title: '合成数据');
        final episode = Episode({'id': '1'}, 1);
        for (final request in [
          () => repository.catalog(source),
          () => repository.cached(source),
          () => repository.sourceStatus(source),
          () => repository.startSourceJob(source, 'update'),
          () => repository.cancelSourceJob(source),
          () => repository.detail(drama),
          () => repository.cover(drama),
          () => repository.resolve(drama, episode),
          () => repository.resolveOnline(drama, episode),
          () => repository.enqueueDownloads(DramaDetail(drama, [episode]), [
            episode,
          ]),
          () => repository.localPlayback(drama, episode),
        ]) {
          await expectLater(
            request(),
            throwsA(
              isA<AppFailure>().having(
                (error) => error.message,
                'message',
                '当前版本不包含此站源',
              ),
            ),
          );
        }
      }
    },
  );
}

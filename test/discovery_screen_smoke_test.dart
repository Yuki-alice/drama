import 'package:duanju_app/app/app_theme.dart';
import 'package:duanju_app/features/home/discovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  testWidgets('discovery screen loads through its view model', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final repository = FixtureRepository();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: DiscoveryScreen(repository: repository, store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('推荐'), findsOneWidget);
    expect(repository.requests, isNotEmpty);
  });
}

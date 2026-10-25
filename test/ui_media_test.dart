// The media filter and kind badges appear only when the catalog mixes kinds.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/ui/feed_page.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

Future<AppState> boot(WidgetTester t, String fixture) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_ui');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/$fixture.db').copySync('${dir.path}/catalog_custom.db');
  final u = UserStore.open('${dir.path}/user.db');
  u.setSetting('catalog_source', 'file');
  u.putAll(const [
    UserEntry(id: 1, status: EntryStatus.watched, rating: 10),
    UserEntry(id: 7, status: EntryStatus.watched, rating: 9),
  ]);
  u.close();
  final app = AppState();
  await t.runAsync(() => app.init(supportDirOverride: dir.path));
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  return app;
}

Future<void> show(WidgetTester t, AppState app) async {
  t.view.physicalSize = const Size(1280, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: Atlas.theme(),
        home: Scaffold(body: FeedPage(onGoLibrary: () {})),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

/// lets the 250 ms debounce + the async refresh complete
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 300));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
  }
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  Cover.offline = true;
  testWidgets(
    'mixed catalog: media chips + kind badges; chips filter the feed',
    (t) async {
      final app = await boot(t, 'mixed');
      await show(t, app);
      for (final label in ['All media', 'Anime', 'Movies', 'TV']) {
        expect(
          find.widgetWithText(ChoiceChip, label),
          findsOneWidget,
          reason: label,
        );
      }
      expect(
        app.feed.map((r) => app.data.titles[r.idx].kind).toSet().length,
        greaterThan(1),
      );
      expect(
        find.text('MOVIE').evaluate().length +
            find.text('TV').evaluate().length +
            find.textContaining('· MOVIE').evaluate().length,
        greaterThan(0),
        reason: 'kind badges are visible',
      );

      await t.tap(find.widgetWithText(ChoiceChip, 'Movies'));
      await settle(t);
      expect(app.controls.kinds, {'movie'});
      expect(app.feed, isNotEmpty);
      expect(
        app.feed.every((r) => app.data.titles[r.idx].kind == 'movie'),
        isTrue,
      );
      expect(app.activeFilterCount, 1);

      await t.tap(find.widgetWithText(ChoiceChip, 'All media'));
      await settle(t);
      expect(app.controls.kinds, isEmpty);
    },
  );

  testWidgets('anime-only catalog: no media chips, no kind badges', (t) async {
    final app = await boot(t, 'legacy_v1');
    await show(t, app);
    expect(find.widgetWithText(ChoiceChip, 'All media'), findsNothing);
    expect(find.text('MOVIE'), findsNothing);
    expect(app.data.kinds, {'anime'});
    expect(
      find.widgetWithText(FilterChip, 'Romance'),
      findsOneWidget,
    ); // categories still there
  });
}

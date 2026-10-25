// The media filter and kind badges appear only when the catalog mixes kinds.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/ui/feed_page.dart';
import 'package:lodestar/ui/filter_panel.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

Future<AppState> boot(
  WidgetTester t,
  String fixture, {
  String? catalogFile,
}) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_ui');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(
    catalogFile ?? 'test/fixtures/$fixture.db',
  ).copySync('${dir.path}/catalog_custom.db');
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

  testWidgets(
    'anime-only catalog: the three media chips are still there; missing types are greyed out and explain themselves',
    (t) async {
      final app = await boot(t, 'legacy_v1');
      await show(t, app);
      expect(app.data.kinds, {'anime'});
      for (final label in ['All media', 'Anime', 'Movies', 'TV']) {
        expect(
          find.widgetWithText(ChoiceChip, label),
          findsOneWidget,
          reason: label,
        );
      }
      expect(
        find.text('MOVIE'),
        findsNothing,
        reason: 'no kind badges on single-kind catalogs',
      );
      expect(find.byType(Tooltip), findsWidgets);
      // tapping a type the catalog does not have changes nothing and says how to get it
      await t.tap(find.widgetWithText(ChoiceChip, 'Movies'));
      await t.pump();
      expect(app.controls.kinds, isEmpty);
      expect(
        find.textContaining('Movies are not in your catalog yet'),
        findsOneWidget,
      );
      expect(find.textContaining('Settings'), findsWidgets);
      await t.tap(find.widgetWithText(ChoiceChip, 'Anime'));
      await settle(t);
      expect(app.controls.kinds, {'anime'});
      expect(
        find.widgetWithText(FilterChip, 'Romance'),
        findsOneWidget,
      ); // categories still there
    },
  );

  testWidgets(
    'the filter sheet always has the Media section, also for an anime-only catalog',
    (t) async {
      final app = await boot(t, 'legacy_v1');
      await show(t, app);
      showFilters(t.element(find.byType(FeedPage)));
      await t.pumpAndSettle();
      expect(find.text('Media'), findsOneWidget);
      for (final label in ['Anime', 'Movies', 'TV']) {
        expect(
          find.widgetWithText(FilterChip, label),
          findsOneWidget,
          reason: label,
        );
      }
      expect(
        find.textContaining('Greyed-out types are not in your catalog yet'),
        findsOneWidget,
      );
      await t.tap(find.widgetWithText(FilterChip, 'TV'));
      await t.pump();
      expect(app.controls.kinds, isEmpty);
      await t.tap(find.widgetWithText(FilterChip, 'Anime'));
      await t.pump();
      expect(app.controls.kinds, {'anime'});
      await settle(t);
    },
  );

  testWidgets(
    'a saved selection of a type the catalog does not have does not empty the feed',
    (t) async {
      final app = await boot(t, 'legacy_v1');
      app.setControls(Controls(kinds: {'movie'}));
      await show(t, app);
      await settle(t);
      expect(app.feed, isNotEmpty);
    },
  );

  testWidgets(
    'three-kind catalog: every chip is enabled and in the feed strip and the filter sheet (real catalog when it has all three)',
    (t) async {
      final real =
          File('catalog.db').existsSync() &&
          CatalogStore.open('catalog.db').data.kinds.length == 3;
      final app = await boot(
        t,
        'mixed',
        catalogFile: real ? 'catalog.db' : null,
      );
      await show(t, app);
      expect(app.data.kinds.length, 3);
      for (final label in ['Anime', 'Movies', 'TV']) {
        final chip = t.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, label),
        );
        expect(chip.onSelected, isNotNull);
        expect(
          t.getRect(find.widgetWithText(ChoiceChip, label)).right,
          lessThan(1280),
          reason: '$label is on screen',
        );
      }
      expect(find.byType(Tooltip), findsNothing, reason: 'nothing greyed out');
      showFilters(t.element(find.byType(FeedPage)));
      await t.pumpAndSettle();
      for (final label in ['Anime', 'Movies', 'TV']) {
        expect(
          find.widgetWithText(FilterChip, label),
          findsOneWidget,
          reason: label,
        );
      }
    },
  );
}

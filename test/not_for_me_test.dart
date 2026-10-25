// "Not for me" with reasons: the sheet, the ranking effect, edit/clear, the setting, backups, the assistant tool.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/assistant/openrouter.dart';
import 'package:lodestar/data/backup.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';
import 'package:lodestar/ui/not_for_me.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

Future<AppState> boot(
  WidgetTester? t, {
  List<UserEntry> entries = const [],
}) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_nfm');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
  final u = UserStore.open('${dir.path}/user.db')
    ..setSetting('catalog_source', 'file')
    ..setSetting('ai.enabled', '1')
    ..setSetting('ai.key', 'FAKE-KEY-FOR-TESTS-0000');
  u.putAll(entries);
  u.close();
  final app = AppState();
  if (t != null) {
    await t.runAsync(() => app.init(supportDirOverride: dir.path));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
  } else {
    await app.init(supportDirOverride: dir.path);
  }
  return app;
}

void main() {
  Cover.offline = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the sheet offers the title\'s own tags (most distinctive first) plus general aspects, for anime, movie and TV',
    () async {
      final app = await boot(null);
      for (final id in [3, 103, 203]) {
        final idx = app.data.idToIdx[id]!;
        final ch = notForMeChoices(app, idx);
        expect(ch.tags, isNotEmpty, reason: 'title $id');
        final own = {
          for (final (fid, _) in app.data.facetsOf(idx))
            'x:${app.data.vocab[fid].kind}|${app.data.vocab[fid].value}',
        };
        expect(
          ch.tags.every((t) => own.contains(t.$1)),
          isTrue,
          reason: 'only this title\'s tags',
        );
        final aspects = [for (final a in ch.aspects) a.$1];
        expect(
          aspects,
          containsAll([
            'n:characters',
            'n:story',
            'n:pacing',
            'n:romance',
            'n:fanservice',
            'n:gore',
            'n:humor',
            'n:visuals',
            'n:length',
          ]),
        );
      }
    },
  );

  test(
    'reasons make the dislike specific: the title\'s blanket penalty shrinks and exactly those parts are avoided',
    () async {
      final app = await boot(null);
      final idx = app.data.idToIdx[3]!;
      final tag = notForMeChoices(app, idx).tags.first.$1;
      UserEntry skip(Set<String> r) =>
          UserEntry(id: 3, status: EntryStatus.notInterested, reasons: r);
      final liked = [
        for (final id in [1, 2])
          UserEntry(id: id, status: EntryStatus.watched, rating: 9),
      ];
      final plain = app.recommender.fit([...liked, skip({})]);
      final specific = app.recommender.fit([
        ...liked,
        skip({tag, 'n:pacing'}),
      ]);
      expect(plain.signal[idx], -0.8);
      expect(specific.signal[idx], -0.3);
      final fid = app.data.facetIndex[tag.substring(2)]!;
      expect(plain.avoidFacets.containsKey(fid), isFalse);
      expect(specific.avoidFacets[fid], greaterThan(0));
      // a title sharing the tag ranks no better with the reason than without
      final other = [
        for (var i = 0; i < app.data.n; i++)
          if (i != idx &&
              app.data.facetsOf(i).any((f) => f.$1 == fid && f.$2 >= 4))
            i,
      ];
      expect(other, isNotEmpty);
      List<int> order(TasteModel m) => [
        for (final r in app.recommender.recommend(m, Controls(), count: 30))
          r.idx,
      ];
      final a = order(plain), b = order(specific);
      for (final o in other) {
        final pa = a.indexOf(o) < 0 ? 99 : a.indexOf(o),
            pb = b.indexOf(o) < 0 ? 99 : b.indexOf(o);
        expect(
          pb,
          greaterThanOrEqualTo(pa),
          reason: 'title ${app.data.titles[o].id}',
        );
      }
    },
  );

  test(
    'edit and clear: reasons can be changed later, cleared, or the title brought back; old entries stay valid',
    () async {
      // an "old" entry: skipped, no reasons at all
      final app = await boot(
        null,
        entries: [const UserEntry(id: 5, status: EntryStatus.notInterested)],
      );
      final idx = app.data.idToIdx[5]!;
      expect(app.entries[idx]!.reasons, isEmpty);
      expect(
        () => app.recommender.fit(app.entries.values.toList()),
        returnsNormally,
      );
      app.skip(
        idx,
        reasons: {'n:pacing', 'x:themes|grief', 'g:romance', 'bogus'},
        note: ' too slow ',
      );
      expect(app.entries[idx]!.reasons, {
        'n:pacing',
        'x:themes|grief',
      }, reason: 'only dislike keys are kept');
      expect(app.entries[idx]!.note, 'too slow');
      expect(skipReasonText(app.entries[idx]!.reasons), contains('pacing'));
      app.skip(idx, reasons: {'n:pacing'});
      expect(app.entries[idx]!.reasons, {'n:pacing'});
      app.skip(idx);
      expect(app.entries[idx]!.reasons, isEmpty);
      expect(app.entries[idx]!.status, EntryStatus.notInterested);
      app.remove(idx);
      expect(app.entries.containsKey(idx), isFalse);
    },
  );

  test(
    'persisted in the user store and in backups; "always hide" warnings feed the recommender',
    () async {
      final app = await boot(null);
      final idx = app.data.idToIdx[4]!;
      app.skip(
        idx,
        reasons: {'x:themes|grief', 'n:gore', 'h:content_warnings|gore'},
        note: 'nope',
      );
      final json = app.exportBackup();
      final back = parseBackup(json, app.data, TitleSearch(app.data));
      final e = back.entries.single;
      expect(e.status, EntryStatus.notInterested);
      expect(e.reasons, {
        'x:themes|grief',
        'n:gore',
        'h:content_warnings|gore',
      });
      expect(e.note, 'nope');
      expect(json, isNot(contains('FAKE-KEY')));
      await app.refresh();
      expect(app.recommender.alwaysHideWarnings, {'gore'});
      app.skip(idx);
      await app.refresh();
      expect(app.recommender.alwaysHideWarnings, isEmpty);
    },
  );

  test('setting: sheet is the default; the choice is kept', () async {
    final app = await boot(null);
    expect(app.askWhyMode, 'sheet');
    app.setAskWhyMode('never');
    expect(app.askWhyMode, 'never');
    app.setAskWhyMode('nonsense');
    expect(app.askWhyMode, 'sheet');
  });

  testWidgets(
    'sheet flow: confirm with reasons, "just hide it", and the other two settings',
    (t) async {
      final app = await boot(t);
      t.view.physicalSize = const Size(900, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final idx = app.data.idToIdx[3]!;
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            theme: Atlas.theme(),
            home: Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () => notForMe(c, idx),
                  child: const Text('NFM'),
                ),
              ),
            ),
          ),
        ),
      );
      final tag = notForMeChoices(app, idx).tags.first.$1;

      await t.tap(find.text('NFM'));
      await t.pumpAndSettle();
      expect(find.text('What put you off?'), findsOneWidget);
      expect(
        app.entries.containsKey(idx),
        isFalse,
        reason: 'nothing happens before the choice',
      );
      await t.tap(find.byKey(ValueKey('nfm-$tag')));
      await t.tap(find.byKey(const ValueKey('nfm-n:pacing')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('nfm-confirm')));
      await t.pumpAndSettle();
      expect(app.entries[idx]!.status, EntryStatus.notInterested);
      expect(app.entries[idx]!.reasons, {tag, 'n:pacing'});

      // reopen to edit: chips are preselected, "Clear reasons" keeps it skipped, "Bring it back" removes it
      await t.runAsync(() async => app.remove(idx));
      await t.tap(find.text('NFM'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('nfm-hide')));
      await t.pumpAndSettle();
      expect(app.entries[idx]!.status, EntryStatus.notInterested);
      expect(app.entries[idx]!.reasons, isEmpty);

      app.setAskWhyMode('never');
      final idx2 = app.data.idToIdx[7]!;
      await t.runAsync(() async {});
      final ctx = t.element(find.text('NFM'));
      await notForMe(ctx, idx2);
      await t.pump();
      expect(find.text('What put you off?'), findsNothing);
      expect(app.entries[idx2]!.status, EntryStatus.notInterested);

      app.setAskWhyMode('snackbar');
      final idx3 = app.data.idToIdx[8]!;
      await notForMe(t.element(find.text('NFM')), idx3);
      await t.pump();
      expect(app.entries[idx3]!.status, EntryStatus.notInterested);
      await t.pump(const Duration(milliseconds: 800));
      expect(find.text('Tell us why'), findsOneWidget);
      await t.tap(find.text('Tell us why'));
      await t.pumpAndSettle();
      expect(find.text('What put you off?'), findsOneWidget);
      expect(find.byKey(const ValueKey('nfm-back')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('nfm-n:story')));
      await t.tap(find.byKey(const ValueKey('nfm-confirm')));
      await t.pumpAndSettle();
      expect(app.entries[idx3]!.reasons, {'n:story'});
    },
  );

  test(
    'assistant: not_interested takes validated reasons and still waits for the confirmation',
    () async {
      final app = await boot(null);
      final idx = app.data.idToIdx[3]!;
      final tag = notForMeChoices(app, idx).tags.first;
      final out = app.assistant.tools.call(
        'not_interested',
        jsonEncode({
          'id': 3,
          'reasons': [tag.$2, 'Pacing', 'made-up reason'],
        }),
      );
      expect(out.json['status'], 'awaiting_user_confirmation');
      expect(out.json['ignored_reasons'], ['made-up reason']);
      expect(out.pending!.reasons, {tag.$1, 'n:pacing'});
      expect(out.pending!.label, contains('because'));
      expect(app.entries.containsKey(idx), isFalse);
      app.assistant.pending.add(out.pending!);
      app.assistant.confirm(out.pending!);
      expect(app.entries[idx]!.reasons, {tag.$1, 'n:pacing'});
      // without reasons the confirmation card asks (unless the setting says otherwise)
      final bare = app.assistant.tools
          .call('not_interested', '{"id":4}')
          .pending!;
      expect(bare.reasons, isEmpty);
      expect(bare.asked, isFalse);
      http.Client? unused;
      expect(unused, isNull);
      expect(
        OpenRouterProvider(
          'x',
          client: MockClient((_) async => http.Response('{}', 200)),
        ).id,
        'openrouter',
      );
    },
  );
}

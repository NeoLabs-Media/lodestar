// Taste page: the improve flow (preview -> Send -> gate -> review -> apply) and the layer controls.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/assistant/openrouter.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/ui/taste_page.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

Future<AppState> boot(WidgetTester t, {bool library = true}) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_layerui');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
  final u = UserStore.open('${dir.path}/user.db')
    ..setSetting('catalog_source', 'file')
    ..setSetting('ai.enabled', '1')
    ..setSetting('ai.key', 'FAKE-KEY-FOR-TESTS-0000')
    ..setSetting('ai.library', library ? '1' : '0');
  final probe = UserStore.open('${dir.path}/probe.db');
  probe.close();
  u.close();
  final app = AppState();
  await t.runAsync(() => app.init(supportDirOverride: dir.path));
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  final es = <UserEntry>[
    for (final x in app.data.titles)
      if (x.genres.any({'romance', 'drama'}.contains))
        UserEntry(id: x.id, status: EntryStatus.watched, rating: 9)
      else if (x.genres.any({'action', 'comedy'}.contains))
        UserEntry(id: x.id, status: EntryStatus.watched, rating: 3),
  ];
  for (final e in es) {
    app.users.put(e);
  }
  await t.runAsync(
    () async => app.restoreBackup(app.exportBackup(), replace: false),
  );
  return app;
}

String reply(Object o) => jsonEncode({
  'choices': [
    {
      'message': {'role': 'assistant', 'content': jsonEncode(o)},
    },
  ],
  'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
});

Map<String, dynamic> rule(String facet, {String type = 'facet_up'}) => {
  'type': type,
  'facet': facet,
  'magnitude': .8,
  'confidence': .7,
  'justification': 'Because of the ratings.',
  'titles': ['Fixture Anime 1', 'Fixture Anime 5'],
};

Future<void> show(WidgetTester t, AppState app) async {
  t.view.physicalSize = const Size(1000, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: Atlas.theme(),
        home: const Scaffold(body: TastePage()),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  Cover.offline = true;

  testWidgets(
    'disabled without library consent; with it, nothing is sent before Send and the preview is the real payload',
    (t) async {
      final off = await boot(t, library: false);
      await show(t, off);
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('improve-button')))
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('Allow the assistant to read your library'),
        findsOneWidget,
      );

      final app = await boot(t);
      final bodies = <Map<String, dynamic>>[];
      app.providerFactory = (k) => OpenRouterProvider(
        k,
        client: MockClient((req) async {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
            reply({
              'summary': 'Likes romance.',
              'adjustments': [rule('genre|romance')],
              'contradictions': [],
              'questions': [],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await show(t, app);
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('improve-button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const ValueKey('improve-button')));
      await t.pumpAndSettle();
      final shown = t
          .widget<SelectableText>(
            find.descendant(
              of: find.byKey(const ValueKey('improve-preview')),
              matching: find.byType(SelectableText),
            ),
          )
          .data!;
      expect(shown, app.tasteRequest().preview);
      expect(shown, contains('Fixture Anime 1'));
      expect(bodies, isEmpty, reason: 'the preview alone sends nothing');
      await t.tap(find.byKey(const ValueKey('improve-cancel')));
      await t.pumpAndSettle();
      expect(bodies, isEmpty);

      // Send -> reply -> gate -> review
      await t.tap(find.byKey(const ValueKey('improve-button')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('improve-send')));
      await t.pump();
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await t.pumpAndSettle();
      expect(bodies, hasLength(1));
      expect(find.text('Review the proposal'), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-verdict')), findsOneWidget);
      expect(app.layer.isEmpty, isTrue, reason: 'nothing changes before Apply');
      final id = (app.tasteRequest().system.isEmpty ? '' : '');
      expect(id, '');
      // the single rule is on by default (it matches the ratings); lower its strength and apply
      final sw = find.byWidgetPredicate(
        (w) => w is Switch && '${w.key}'.contains('rule-accept-'),
      );
      expect(t.widget<Switch>(sw).value, isTrue);
      final slider = find.byWidgetPredicate(
        (w) => w is Slider && '${w.key}'.contains('rule-strength-'),
      );
      t.widget<Slider>(slider).onChanged!(0.4);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('review-apply')));
      await t.pumpAndSettle();
      expect(app.layer.rules, hasLength(1));
      expect(app.layer.rules.single.strength, closeTo(0.4, 1e-9));
      expect(app.layer.summary, 'Likes romance.');
      expect(find.textContaining('Prefer romance'), findsWidgets);

      // layer controls on the taste page
      await t.tap(find.byKey(const ValueKey('layer-switch')));
      await t.pump();
      expect(app.layer.enabled, isFalse);
      expect(app.recommender.layer!.active, isFalse);
      await t.tap(find.byKey(const ValueKey('layer-switch')));
      await t.pump();
      t.widget<Slider>(find.byKey(const ValueKey('layer-strength'))).onChanged!(
        0.5,
      );
      await t.pump();
      expect(app.layer.strength, .5);
      await t.tap(find.byKey(const ValueKey('layer-reset')));
      await t.pump();
      expect(app.layer.isEmpty, isTrue);
      expect(find.byKey(const ValueKey('layer-undo')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('layer-undo')));
      await t.pump();
      expect(app.layer.rules, hasLength(1));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await t.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'a proposal that goes against the ratings is shown as not recommended and is off by default; questions answer inline',
    (t) async {
      final app = await boot(t);
      app.providerFactory = (k) => OpenRouterProvider(
        k,
        client: MockClient(
          (req) async => http.Response(
            reply({
              'summary': 'Maybe action.',
              'adjustments': [rule('genre|comedy'), rule('genre|action')],
              'contradictions': ['Rates romance high but skips slow ones.'],
              'questions': [
                {
                  'text': 'Fast or slow?',
                  'options': [
                    {'label': 'Slow', 'adjustment': rule('genre|romance')},
                    {'label': 'Fast'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await show(t, app);
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('improve-button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const ValueKey('improve-button')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('improve-send')));
      await t.pump();
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await t.pumpAndSettle();
      expect(find.textContaining('Not recommended'), findsWidgets);
      final sws = t
          .widgetList<Switch>(
            find.byWidgetPredicate(
              (w) => w is Switch && '${w.key}'.contains('rule-accept-'),
            ),
          )
          .toList();
      expect(sws, hasLength(2));
      expect(sws.every((s) => !s.value), isTrue);
      expect(
        find.text(
          'Rates romance high but skips slow ones.',
          findRichText: true,
        ),
        findsNothing,
      ); // shown with a bullet
      expect(find.textContaining('Rates romance high'), findsOneWidget);
      // inline answer becomes a rule on Apply; the rejected proposals are not applied
      await t.tap(find.byKey(const ValueKey('q-opt-0-0')));
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('review-apply')));
      await t.tap(find.byKey(const ValueKey('review-apply')));
      await t.pumpAndSettle();
      expect(app.layer.rules.map((r) => r.value), ['romance']);
      expect(app.layer.answers.single, ('Fast or slow?', 'Slow'));
    },
  );
}

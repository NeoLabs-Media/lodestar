// Assistant tab and the AI section of Settings (fake HTTP, no key).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/assistant/openrouter.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/ui/assistant_page.dart';
import 'package:lodestar/ui/settings_page.dart';
import 'package:lodestar/ui/theme.dart';
import 'package:lodestar/ui/widgets.dart';
import 'package:provider/provider.dart';

String reply({
  String? content,
  List<(String, String, String)> calls = const [],
}) => jsonEncode({
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': content,
        if (calls.isNotEmpty)
          'tool_calls': [
            for (final c in calls)
              {
                'id': c.$1,
                'type': 'function',
                'function': {'name': c.$2, 'arguments': c.$3},
              },
          ],
      },
    },
  ],
  'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
});

Future<AppState> boot(
  WidgetTester t, {
  bool enabled = false,
  bool key = false,
}) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_aiui');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
  final u = UserStore.open('${dir.path}/user.db')
    ..setSetting('catalog_source', 'file');
  if (enabled) u.setSetting('ai.enabled', '1');
  if (key) u.setSetting('ai.key', 'FAKE-KEY-FOR-TESTS-0000');
  u.close();
  final app = AppState();
  await t.runAsync(() => app.init(supportDirOverride: dir.path));
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  return app;
}

Future<void> show(WidgetTester t, AppState app, Widget page) async {
  t.view.physicalSize = const Size(1000, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: Atlas.theme(),
        home: Scaffold(body: page),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  Cover.offline = true;

  testWidgets(
    'assistant page explains how to enable it when off or without a key',
    (t) async {
      var opened = 0;
      final app = await boot(t);
      await show(t, app, AssistantPage(onOpenSettings: () => opened++));
      expect(find.textContaining('off by default'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.text('Open settings'));
      expect(opened, 1);

      final app2 = await boot(t, enabled: true);
      await show(t, app2, AssistantPage(onOpenSettings: () {}));
      expect(find.textContaining('no API key yet'), findsOneWidget);
    },
  );

  testWidgets(
    'chat: example chip sends, answer shows a tappable title card and the tool trace; confirmation card works',
    (t) async {
      final app = await boot(t, enabled: true, key: true);
      final queue = [
        reply(
          calls: [
            ('1', 'search_catalog', '{"query":"Fixture Movie 2"}'),
            ('2', 'add_to_plan', '{"id":102}'),
          ],
        ),
        reply(
          content:
              'Try [#102]. I asked to plan it — it is waiting for your confirmation.',
        ),
      ];
      app.providerFactory = (k) => OpenRouterProvider(
        k,
        client: MockClient(
          (req) async => http.Response(
            queue.removeAt(0),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await show(t, app, AssistantPage(onOpenSettings: () {}));
      expect(find.text('A movie for tonight, under 2 hours'), findsOneWidget);
      await t.runAsync(() async {
        app.assistant.send('Fixture Movie 2 please');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Try Fixture Movie 2.'), findsOneWidget);
      expect(find.textContaining('used tools: search_catalog'), findsOneWidget);
      expect(
        find.text('Fixture Movie 2'),
        findsWidgets,
      ); // the tappable title card
      expect(
        find.textContaining('asks to: Add “Fixture Movie 2” to your plan'),
        findsOneWidget,
      );
      final idx = app.data.idToIdx[102]!;
      expect(app.entries.containsKey(idx), isFalse);
      await t.tap(find.text('Confirm'));
      await t.pump();
      expect(app.entries[idx]!.status.name, 'planned');
      expect(find.textContaining('Done:'), findsOneWidget);
      await t.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'settings: key is saved, hidden afterwards and removable; library switch is off by default',
    (t) async {
      final app = await boot(t);
      await show(t, app, const SettingsPage());
      await t.scrollUntilVisible(
        find.text('AI assistant (optional)'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(app.ai.enabled, isFalse);
      expect(app.ai.libraryAllowed, isFalse);
      expect(find.textContaining('Privacy: what you type'), findsOneWidget);
      await t.enterText(
        find.widgetWithText(TextField, 'OpenRouter API key'),
        'FAKE-KEY-FOR-TESTS-0000',
      );
      await t.tap(find.widgetWithText(FilledButton, 'Save').first);
      await t.pump();
      expect(app.ai.apiKey, 'FAKE-KEY-FOR-TESTS-0000');
      expect(find.textContaining('API key saved (hidden)'), findsOneWidget);
      expect(
        find.textContaining('FAKE-KEY'),
        findsNothing,
        reason: 'the key is never shown again',
      );
      await t.tap(find.text('Remove key'));
      await t.pump();
      expect(app.ai.hasKey, isFalse);
      expect(
        find.widgetWithText(TextField, 'OpenRouter API key'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'chat: spoiler switch (default off) announces itself; filter chips are removable; feed/chat filter source switch',
    (t) async {
      final app = await boot(t, enabled: true, key: true);
      await show(t, app, AssistantPage(onOpenSettings: () {}));
      final sw = find.byKey(const ValueKey('spoiler-switch'));
      expect(t.widget<Switch>(sw).value, isFalse);
      await t.tap(sw);
      await t.pump();
      expect(app.ai.spoilers, isTrue);
      expect(t.widget<Switch>(sw).value, isTrue);

      // no filters yet
      expect(find.text('No filters'), findsOneWidget);
      // the feed's filters are shown as chips and can be removed from here
      app.setControls(Controls(kinds: {'movie'})..active.runtimeMax = 100);
      await t.pump();
      expect(find.byKey(const ValueKey('chip-Movies')), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-≤ 100 min')), findsOneWidget);
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('chip-≤ 100 min')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await t.pump();
      expect(app.controls.active.runtimeMax, isNull);
      expect(find.byKey(const ValueKey('chip-≤ 100 min')), findsNothing);

      // switch to the chat's own filters: the feed filters disappear from the bar, the feed keeps them
      await t.tap(find.text('Chat filters only'));
      await t.pump();
      expect(app.ai.useFeedFilters, isFalse);
      expect(find.byKey(const ValueKey('chip-Movies')), findsNothing);
      expect(app.controls.kinds, {'movie'});
      // the filter button opens the same sheet, now editing the chat's filters
      await t.tap(find.byKey(const ValueKey('chat-filter-button')));
      await t.pumpAndSettle();
      expect(find.text('Assistant filters'), findsOneWidget);
      await t.tap(find.widgetWithText(FilterChip, 'Anime'));
      await t.pump();
      expect(app.chatControls.kinds, {'anime'});
      expect(app.controls.kinds, {'movie'});
    },
  );
}

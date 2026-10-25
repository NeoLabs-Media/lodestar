// Assistant spoiler switch and manual chat filters: enforced in code (tool results), not by the prompt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/assistant/openrouter.dart';
import 'package:lodestar/assistant/session.dart';
import 'package:lodestar/assistant/settings.dart';
import 'package:lodestar/assistant/tools.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = CatalogStore.open('test/fixtures/mixed.db');
  final data = store.data;
  final rec = Recommender(data);
  final search = TitleSearch(data);
  var spoilers = false;
  var controls = Controls();
  var library = false;
  final entries = [
    const UserEntry(id: 1, status: EntryStatus.watched, rating: 10),
    const UserEntry(id: 104, status: EntryStatus.watched, rating: 8),
  ];
  final tools = AssistantTools(
    AssistantContext(
      store: store,
      rec: rec,
      search: search,
      controls: () => controls,
      entries: () => entries,
      libraryAllowed: () => library,
      spoilers: () => spoilers,
    ),
  );
  Map<String, dynamic> run(String n, [Map<String, dynamic> a = const {}]) =>
      tools.call(n, jsonEncode(a)).json;
  final allIds = [for (final t in data.titles) t.id];
  setUp(() {
    spoilers = false;
    controls = Controls();
    library = false;
  });

  group('spoiler switch (tools)', () {
    test('off: no spoiler field in any tool result, for every title', () {
      library = true;
      for (final id in allIds) {
        final out = jsonEncode([
          run('get_title', {'id': id}),
          run('explain_match', {'id': id}),
          run('find_similar', {'id': id, 'n': 10}),
        ]);
        expect(out, isNot(contains('SECRET')), reason: 'title $id');
      }
      final t = run('get_title', {'id': 103});
      for (final k in [
        'full_synopsis',
        'ending',
        'ending_description',
        'key_relationships',
      ]) {
        expect(t.containsKey(k), isFalse, reason: k);
      }
      expect(t['spoilers'], 'off');
      expect(t['spoiler_note'], contains('spoiler switch'));
      expect(t['pitch'], contains('Spoiler-free text'));
      expect(
        '${t['main_characters']}',
        isNot(contains('mentor')),
      ); // archetypes can hint at fates
      expect(
        jsonEncode(t['top_tags']).toLowerCase(),
        isNot(contains('ending')),
      );
      expect(jsonEncode(t['content_warnings']), isNot(contains('death')));
      expect(t['content_warnings'], contains('gore'));
      for (final r
          in (run('get_recommendations', {'n': 10})['recommendations']
              as List)) {
        expect(
          '${r['why']}'.toLowerCase(),
          isNot(matches(r'ending|payoff|twist|tragic')),
        );
      }
    });

    test(
      'on: the full synopsis, ending, character arcs and relationship turns are available',
      () {
        spoilers = true;
        final t = jsonEncode(run('get_title', {'id': 103}));
        for (final s in [
          'SECRET-FULL-PLOT',
          'SECRET-ENDING-DESCRIPTION',
          'SECRET-FATE-ARC',
          'SECRET-RELATION-TURN',
          'SECRET-TWIST-WHY',
          'death of a major character',
        ]) {
          expect(t, contains(s));
        }
        expect(run('get_title', {'id': 103})['spoilers'], 'on');
        expect(
          run('get_title', {'id': 103}).containsKey('spoiler_note'),
          isFalse,
        );
      },
    );

    test('the recommender flag is restored after a call', () {
      run('get_recommendations');
      expect(rec.spoilerFreeWhy, isFalse);
    });

    test('system prompt states the current mode', () {
      String prompt({required bool sp, String f = ''}) => buildSystemPrompt(
        titleCount: 5,
        kinds: {'anime'},
        filters: f,
        libraryAllowed: false,
        now: DateTime(2026, 10, 25),
        spoilers: sp,
      );
      expect(prompt(sp: false), contains('Spoilers are OFF'));
      expect(prompt(sp: false), contains('turn it on'));
      expect(prompt(sp: true), contains('Spoilers are ON'));
      expect(prompt(sp: true), isNot(contains('Spoilers are OFF')));
      expect(
        prompt(sp: false, f: 'movies · ≤ 120 min'),
        contains('movies · ≤ 120 min'),
      );
      expect(prompt(sp: false), contains('no filters active'));
    });
  });

  group('chat filters are hard constraints', () {
    List<Map> results(Map<String, dynamic> r, [String key = 'results']) =>
        (r[key] as List).cast<Map>();

    test('every title-returning tool respects them, per kind', () {
      controls = Controls(kinds: {'movie'})..active.runtimeMax = 100;
      final movies = {
        for (final t in data.titles)
          if (t.kind == 'movie' && (t.runtime ?? 999) <= 100) t.id,
      };
      expect(movies, isNotEmpty);
      for (final r in [
        results(run('search_catalog', {'limit': 10})),
        results(run('search_catalog', {'query': 'Fixture', 'limit': 10})),
        results(run('get_recommendations', {'n': 10}), 'recommendations'),
        results(run('find_similar', {'id': 1, 'n': 10})),
      ]) {
        expect(r, isNotEmpty);
        expect(r.every((x) => movies.contains(x['id'])), isTrue, reason: '$r');
      }
      controls = Controls(kinds: {'tv'})..active.statuses = {'ongoing'};
      final ongoing = {
        for (final t in data.titles)
          if (t.kind == 'tv' && t.statusGroup == 'ongoing') t.id,
      };
      expect(ongoing, isNotEmpty);
      expect(
        results(
          run('search_catalog', {'limit': 10}),
        ).every((x) => ongoing.contains(x['id'])),
        isTrue,
      );
      controls = Controls(kinds: {'anime'})..active.maxEpisodes = 5;
      expect(run('search_catalog', {'kind': 'anime'})['results'], isEmpty);
    });

    test(
      'the model cannot loosen them: kind, bounds and any-of sets all stay in force',
      () {
        controls = Controls(kinds: {'movie'})..active.runtimeMax = 100;
        // other kind -> nothing
        final tv = run('search_catalog', {'kind': 'tv'});
        expect(tv['results'], isEmpty);
        expect(tv['blocked_by_user_filters'], isTrue);
        // a looser runtime in the arguments does not widen the user's bound
        final loose = results(
          run('search_catalog', {
            'kind': 'movie',
            'filters': {'max_runtime_min': 300},
            'limit': 10,
          }),
        );
        expect(loose.every((x) => (x['runtime_min'] as int) <= 100), isTrue);
        // years: the stricter bound wins from either side
        controls = Controls(kinds: {'movie'})..active.yearMin = 2010;
        expect(
          results(
            run('search_catalog', {
              'filters': {'year_min': 1990},
              'limit': 10,
            }),
          ).every((x) => (x['year'] as int) >= 2010),
          isTrue,
        );
        // any-of sets: country UK is not allowed when the user picked FR
        controls = Controls(kinds: {'movie'})..active.countries = {'FR'};
        expect(
          run('search_catalog', {
            'filters': {'country': 'US'},
          })['results'],
          isEmpty,
        );
        // common filters of the "all" scope still apply when the model narrows to one kind
        controls = Controls()..active.minScore = 99;
        expect(run('search_catalog', {'kind': 'movie'})['results'], isEmpty);
      },
    );

    test('empty results say that only the user can change the filters', () {
      controls = Controls(kinds: {'movie'})..active.runtimeMax = 10;
      for (final r in [
        run('search_catalog'),
        run('get_recommendations'),
        run('find_similar', {'id': 1}),
      ]) {
        expect(
          '${r['note']}',
          contains('only the user can change the filters'),
        );
        expect(r['blocked_by_user_filters'], isTrue);
      }
      controls = Controls();
      expect(
        run('search_catalog', {'query': 'zzzz nothing'})['note'],
        isNot(contains('filters')),
      );
    });
  });

  group('app wiring', () {
    Future<(AppState, Directory)> boot() async {
      final dir = Directory.systemTemp.createTempSync('lodestar_aimodes');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
      UserStore.open('${dir.path}/user.db')
        ..setSetting('catalog_source', 'file')
        ..setSetting('ai.enabled', '1')
        ..setSetting('ai.key', 'FAKE-KEY-FOR-TESTS-0000')
        ..close();
      final app = AppState();
      await app.init(supportDirOverride: dir.path);
      return (app, dir);
    }

    test(
      'settings persist; defaults are spoilers off and "use my feed filters"',
      () async {
        final (app, dir) = await boot();
        expect(app.ai.spoilers, isFalse);
        expect(app.ai.useFeedFilters, isTrue);
        app.setSpoilers(true);
        app.setUseFeedFilters(false);
        app.setChatControls(Controls(kinds: {'movie'})..active.runtimeMax = 90);
        final again = AiSettings(UserStore.open('${dir.path}/user.db'));
        expect(again.spoilers, isTrue);
        expect(again.useFeedFilters, isFalse);
        final c = again.loadChatFilters();
        expect(c.kinds, {'movie'});
        expect(c.scopeFilters('movie').runtimeMax, 90);
      },
    );

    test(
      '"use my feed filters" follows the feed; "chat filters only" is independent',
      () async {
        final (app, _) = await boot();
        app.setControls(Controls(kinds: {'tv'}));
        expect(app.assistantControls.kinds, {'tv'});
        app.setUseFeedFilters(false);
        expect(app.assistantControls.kinds, isEmpty);
        app.setChatControls(Controls(kinds: {'anime'}));
        expect(app.assistantControls.kinds, {'anime'});
        expect(app.controls.kinds, {
          'tv',
        }, reason: 'the feed is untouched by chat filters');
        // the tools see whichever is in force
        final out = app.assistant.tools
            .call('search_catalog', '{"limit":10}')
            .json;
        expect(
          (out['results'] as List).every((x) => x['kind'] == 'anime'),
          isTrue,
        );
        app.setUseFeedFilters(true);
        final out2 = app.assistant.tools
            .call('search_catalog', '{"limit":10}')
            .json;
        expect(
          (out2['results'] as List).every((x) => x['kind'] == 'tv'),
          isTrue,
        );
      },
    );

    test(
      'switching mid-conversation: notice in the chat, new mode in the next system prompt, no restart',
      () async {
        final (app, _) = await boot();
        final bodies = <Map<String, dynamic>>[];
        final queue = [reply(content: 'First.'), reply(content: 'Second.')];
        app.providerFactory = (k) => OpenRouterProvider(
          k,
          client: MockClient((req) async {
            bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
              queue.removeAt(0),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        final s = app.assistant;
        await s.send('hi');
        expect(
          bodies[0]['messages'][0]['content'],
          contains('Spoilers are OFF'),
        );
        app.setSpoilers(true);
        expect(s.messages.last.role, 'info');
        expect(s.messages.last.text, contains('Spoilers are now ON'));
        app.setChatControls(Controls());
        app.setUseFeedFilters(false);
        app.setChatControls(
          Controls(kinds: {'movie'})..active.runtimeMax = 100,
        );
        expect(s.messages.last.text, contains('Filters changed'));
        expect(s.messages.last.text, contains('≤ 100 min'));
        await s.send('again');
        final msgs = bodies[1]['messages'] as List;
        expect(msgs[0]['content'], contains('Spoilers are ON'));
        expect(msgs[0]['content'], contains('≤ 100 min'));
        expect(
          msgs.any(
            (m) =>
                m['role'] == 'user' && '${m['content']}'.contains('[App note'),
          ),
          isTrue,
        );
        // a change is announced once
        final n = s.messages.where((m) => m.role == 'info').length;
        s.syncState();
        expect(s.messages.where((m) => m.role == 'info').length, n);
      },
    );

    test(
      'end to end: with impossible filters the model gets the empty-result note and tells the user',
      () async {
        final (app, _) = await boot();
        app.setUseFeedFilters(false);
        app.setChatControls(Controls(kinds: {'movie'})..active.runtimeMax = 5);
        final bodies = <Map<String, dynamic>>[];
        final queue = [
          reply(calls: [('1', 'search_catalog', '{"query":"Fixture"}')]),
          reply(
            content:
                'Your filters leave nothing. Change them with the filter button.',
          ),
        ];
        app.providerFactory = (k) => OpenRouterProvider(
          k,
          client: MockClient((req) async {
            bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
              queue.removeAt(0),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        await app.assistant.send('something to watch');
        final toolMsg = (bodies[1]['messages'] as List).firstWhere(
          (m) => m['role'] == 'tool',
        );
        expect(toolMsg['content'], contains('blocked_by_user_filters'));
        expect(
          toolMsg['content'],
          contains('only the user can change the filters'),
        );
        expect(app.assistant.messages.last.text, contains('filter button'));
      },
    );
  });
}

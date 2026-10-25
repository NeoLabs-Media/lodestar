// AI assistant: tools, provider (OpenRouter shape), tool loop, confirmation gate, settings + key hygiene.
// Fake HTTP only: no network, no real key anywhere (the "key" below is a made-up marker string).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/assistant/llm.dart';
import 'package:lodestar/assistant/openrouter.dart';
import 'package:lodestar/assistant/session.dart';
import 'package:lodestar/assistant/tools.dart';
import 'package:lodestar/data/backup.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';

const fakeKey = 'FAKE-KEY-FOR-TESTS-0000';

String reply({
  String? content,
  List<(String id, String name, String args)> calls = const [],
  int pt = 100,
  int ct = 20,
  double? cost,
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
  'usage': {
    'prompt_tokens': pt,
    'completion_tokens': ct,
    if (cost != null) 'cost': cost,
  },
});

/// Scripted OpenRouter: answers chat requests from a queue and records them.
class FakeRouter {
  final List<Object>
  script; // String body | http.Response | Exception | Future<String> Function()
  final requests = <http.Request>[];
  FakeRouter(this.script);
  int get chats =>
      requests.where((r) => r.url.path.endsWith('/chat/completions')).length;
  List<Map<String, dynamic>> get bodies => [
    for (final r in requests)
      if (r.method == 'POST') jsonDecode(r.body) as Map<String, dynamic>,
  ];

  http.Client get client => MockClient((req) async {
    requests.add(req);
    if (script.isEmpty)
      return http.Response('{"error":{"message":"script exhausted"}}', 500);
    final next = script.removeAt(0);
    if (next is Exception) throw next;
    if (next is http.Response) return next;
    const h = {'content-type': 'application/json; charset=utf-8'};
    if (next is Future<String> Function())
      return http.Response(await next(), 200, headers: h);
    return http.Response(next as String, 200, headers: h);
  });
}

Future<(AppState, Directory)> boot({bool library = false}) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_ai');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
  final u = UserStore.open('${dir.path}/user.db');
  u.setSetting('catalog_source', 'file');
  u.putAll(const [
    UserEntry(id: 1, status: EntryStatus.watched, rating: 10),
    UserEntry(id: 104, status: EntryStatus.watched, rating: 8.5),
    UserEntry(id: 7, status: EntryStatus.planned),
  ]);
  u.setSetting('ai.enabled', '1');
  u.setSetting('ai.key', fakeKey);
  u.setSetting('ai.library', library ? '1' : '0');
  u.close();
  final app = AppState();
  await app.init(supportDirOverride: dir.path);
  return (app, dir);
}

AssistantSession sessionWith(AppState app, FakeRouter r) {
  app.providerFactory = (k) => OpenRouterProvider(k, client: r.client);
  return app.assistant;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tools', () {
    final store = CatalogStore.open('test/fixtures/mixed.db');
    final rec = Recommender(store.data);
    final search = TitleSearch(store.data);
    List<UserEntry> lib = const [
      UserEntry(id: 1, status: EntryStatus.watched, rating: 10),
      UserEntry(id: 104, status: EntryStatus.watched, rating: 8),
    ];
    var allowed = false;
    var controls = Controls();
    final tools = AssistantTools(
      AssistantContext(
        store: store,
        rec: rec,
        search: search,
        controls: () => controls,
        entries: () => lib,
        libraryAllowed: () => allowed,
      ),
    );
    Map<String, dynamic> run(String n, [Map<String, dynamic> a = const {}]) =>
        tools.call(n, jsonEncode(a)).json;
    List ids(Map<String, dynamic> r, [String key = 'results']) => [
      for (final x in r[key] as List) x['id'],
    ];

    setUp(() {
      allowed = false;
      controls = Controls();
    });

    test(
      'search_catalog finds by title, filters by kind and runtime, and respects the feed filters',
      () {
        expect(
          ids(run('search_catalog', {'query': 'Fixture Movie 3'})).first,
          103,
        );
        final under = run('search_catalog', {
          'kind': 'movie',
          'filters': {'max_runtime_min': 120},
        });
        expect(ids(under).toSet(), {101, 102});
        expect(under['filters_applied'], contains('≤ 120 min'));
        controls = Controls(kinds: {'tv'});
        expect(
          run('search_catalog', {
            'query': 'Fixture',
          })['results'].every((x) => x['kind'] == 'tv'),
          isTrue,
        );
        expect(
          run('search_catalog', {'query': 'zzzz nothing'})['note'],
          contains('do not invent'),
        );
      },
    );

    test('results are compact and capped', () {
      final r = run('search_catalog', {'query': 'Fixture', 'limit': 100});
      expect((r['results'] as List).length, lessThanOrEqualTo(10));
      expect(jsonEncode(r).length, lessThan(5000));
      expect(
        run('get_recommendations', {'n': 99})['recommendations'].length,
        lessThanOrEqualTo(10),
      );
    });

    test(
      'get_title returns the useful bits; unknown ids are an error, not a crash',
      () {
        final t = run('get_title', {'id': 103});
        expect(t['title'], 'Fixture Movie 3');
        expect(t['runtime_min'], 121);
        expect(t['pitch'], isNotEmpty);
        expect(t['top_tags'], isNotEmpty);
        expect(t['standout_dimensions'], isNotEmpty);
        expect(run('get_title', {'id': 424242})['error'], 'not_found');
        expect(run('get_title', {'id': 'x'})['error'], 'not_found');
      },
    );

    test(
      'get_recommendations: personalised only with library access, otherwise says so',
      () {
        final off = run('get_recommendations', {'n': 3});
        expect(off['personalized'], isFalse);
        expect(off['note'], contains('Library access is off'));
        allowed = true;
        final on = run('get_recommendations', {'n': 3, 'kind': 'movie'});
        expect(on['personalized'], isTrue);
        final recs = on['recommendations'] as List;
        expect(recs, isNotEmpty);
        expect(
          recs.every(
            (x) =>
                x['kind'] == 'movie' &&
                x['why'] != null &&
                x['match_percent'] != null,
          ),
          isTrue,
        );
        expect(
          recs.any((x) => x['id'] == 104 || x['id'] == 1),
          isFalse,
          reason: 'watched titles are not recommended',
        );
      },
    );

    test('find_similar is sorted, excludes the title itself', () {
      final r = run('find_similar', {'id': 103, 'n': 4});
      final sims = [
        for (final x in r['results'] as List) x['similarity'] as double,
      ];
      expect(sims, orderedEquals([...sims]..sort((a, b) => b.compareTo(a))));
      expect(ids(r), isNot(contains(103)));
      expect(ids(r).length, 4);
    });

    test(
      'library tools refuse politely when access is off and leak nothing',
      () {
        for (final n in [
          'get_taste_profile',
          'get_library_summary',
          'explain_match',
        ]) {
          final r = run(n, {'id': 102});
          expect(r['error'], 'library_access_off', reason: n);
          expect(jsonEncode(r), isNot(contains('Fixture Anime 1')));
        }
        allowed = true;
        final s = run('get_library_summary');
        expect(s['watched'], 2);
        expect(ids(s, 'top_rated').first, 1);
        expect(run('get_taste_profile')['rated_titles'], 2);
        expect(run('explain_match', {'id': 1})['in_library'], isTrue);
        final ex = run('explain_match', {'id': 102});
        expect(ex['why'], isNotEmpty);
        expect(ex['match_percent'], isNotNull);
      },
    );

    test('state-changing tools only create a pending confirmation', () {
      final o = tools.call('add_to_plan', '{"id": 102}');
      expect(o.json['status'], 'awaiting_user_confirmation');
      expect(o.pending!.type, 'plan');
      expect(o.pending!.label, contains('Fixture Movie 2'));
      final w = tools
          .call('mark_watched', '{"id": 102, "rating": 8.7}')
          .pending!;
      expect((w.type, w.rating), ('watched', 8.5));
      expect(tools.call('not_interested', '{"id": 102}').pending!.type, 'skip');
      expect(tools.call('add_to_plan', '{"id": 777777}').pending, isNull);
    });

    test('bad calls come back as data', () {
      expect(tools.call('nope', '{}').json['error'], 'unknown_tool');
      expect(
        tools.call('search_catalog', '{not json').json['error'],
        'invalid_arguments',
      );
      expect(
        tools.call('search_catalog', '').json['results'],
        isNotNull,
        reason: 'empty arguments = defaults',
      );
    });
  });

  group('provider', () {
    test(
      'sends the OpenAI-style request with the OpenRouter headers; parses tool calls and usage',
      () async {
        final r = FakeRouter([
          reply(
            content: null,
            calls: [('c1', 'get_title', '{"id":1}')],
            pt: 50,
            ct: 5,
            cost: 0.0012,
          ),
        ]);
        final p = OpenRouterProvider(fakeKey, client: r.client);
        final resp = await p.chat(
          model: 'm/x',
          messages: const [ChatMessage('user', 'hi')],
          tools: AssistantTools.specs,
        );
        final req = r.requests.single;
        expect(
          req.url.toString(),
          'https://openrouter.ai/api/v1/chat/completions',
        );
        expect(req.headers['Authorization'], 'Bearer $fakeKey');
        expect(req.headers['HTTP-Referer'], startsWith('https://'));
        expect(req.headers['X-Title'], 'Lodestar');
        final body = r.bodies.single;
        expect(body['model'], 'm/x');
        expect((body['tools'] as List).length, AssistantTools.specs.length);
        expect(body['tools'][0]['type'], 'function');
        expect(resp.message.toolCalls.single.name, 'get_title');
        expect(resp.usage.total, 55);
        expect(resp.usage.cost, 0.0012);
      },
    );

    test(
      'maps HTTP failures to friendly messages that never contain the key',
      () async {
        Future<LlmException> failing(Object o) async {
          final p = OpenRouterProvider(fakeKey, client: FakeRouter([o]).client);
          try {
            await p.chat(
              model: 'm',
              messages: const [ChatMessage('user', 'x')],
            );
          } on LlmException catch (e) {
            return e;
          }
          fail('expected an LlmException');
        }

        final cases = <(Object, LlmErrorKind, String)>[
          (
            http.Response('{"error":{"message":"bad key $fakeKey"}}', 401),
            LlmErrorKind.auth,
            'rejected the API key',
          ),
          (http.Response('{}', 402), LlmErrorKind.credits, 'credits'),
          (http.Response('{}', 429), LlmErrorKind.rateLimit, 'Rate limit'),
          (
            http.Response(
              '{"error":{"message":"No endpoints found that support tool use"}}',
              400,
            ),
            LlmErrorKind.unsupported,
            'tool calling',
          ),
          (http.Response('oops', 503), LlmErrorKind.server, 'problem'),
          (
            http.ClientException('socket down $fakeKey'),
            LlmErrorKind.network,
            'Could not reach',
          ),
          (
            http.Response(
              '{"error":{"message":"upstream $fakeKey failed"}}',
              200,
            ),
            LlmErrorKind.server,
            'upstream',
          ),
        ];
        for (final (o, kind, needle) in cases) {
          final e = await failing(o);
          expect(e.kind, kind, reason: needle);
          expect(e.message, contains(needle));
          expect(e.message, isNot(contains(fakeKey)));
        }
      },
    );

    test(
      'lists only tool-capable models, free first; test() validates key and model',
      () async {
        final models = jsonEncode({
          'data': [
            {
              'id': 'a/paid',
              'name': 'Paid',
              'created': 100,
              'pricing': {'prompt': '0.001', 'completion': '0.002'},
              'supported_parameters': ['tools', 'temperature'],
            },
            {
              'id': 'a/paid-newer',
              'name': 'Paid newer',
              'created': 300,
              'pricing': {'prompt': '0.001', 'completion': '0.002'},
              'supported_parameters': ['tools'],
            },
            {
              'id': 'b/free:free',
              'name': 'Free One',
              'created': 50,
              'pricing': {'prompt': '0', 'completion': '0'},
              'supported_parameters': ['tools'],
            },
            {
              'id': 'c/notools',
              'name': 'No Tools',
              'pricing': {'prompt': '0', 'completion': '0'},
              'supported_parameters': ['temperature'],
            },
          ],
        });
        var p = OpenRouterProvider(
          fakeKey,
          client: FakeRouter([models]).client,
        );
        final list = await p.listModels();
        expect(
          [for (final m in list) m.id],
          ['b/free:free', 'a/paid-newer', 'a/paid'],
        );
        expect(list.first.free, isTrue);

        p = OpenRouterProvider(
          fakeKey,
          client: FakeRouter(['{"data":{"label":"k"}}', models]).client,
        );
        expect((await p.test('a/paid')).ok, isTrue);
        p = OpenRouterProvider(
          fakeKey,
          client: FakeRouter(['{"data":{}}', models]).client,
        );
        final bad = await p.test('c/notools');
        expect(bad.ok, isFalse);
        expect(bad.message, contains('tool-capable'));
        p = OpenRouterProvider(
          fakeKey,
          client: FakeRouter([http.Response('{}', 401)]).client,
        );
        final unauth = await p.test('a/paid');
        expect((unauth.ok, unauth.message.contains('rejected')), (false, true));
        expect(
          (await OpenRouterProvider(
            '',
            client: FakeRouter([]).client,
          ).test('x')).ok,
          isFalse,
        );
      },
    );
  });

  group('session (tool loop)', () {
    test(
      'multi-round: search -> details -> answer with citations, trace and usage',
      () async {
        final (app, _) = await boot();
        final r = FakeRouter([
          reply(
            calls: [('1', 'search_catalog', '{"query":"Fixture Movie 3"}')],
            pt: 100,
            ct: 10,
          ),
          reply(calls: [('2', 'get_title', '{"id":103}')], pt: 150, ct: 10),
          reply(
            content: 'Try [#103] — a calm one. I also thought of [#99999].',
            pt: 200,
            ct: 30,
            cost: 0.002,
          ),
        ]);
        final s = sessionWith(app, r);
        await s.send('something calm');
        expect(r.chats, 3);
        final ans = s.messages.last;
        expect(ans.role, 'assistant');
        expect(ans.text, 'Try [#103] — a calm one. I also thought of .');
        expect(
          ans.plain,
          'Try Fixture Movie 3 — a calm one. I also thought of .',
        );
        expect(
          ans.cited,
          [103],
          reason: 'ids the tools never returned are dropped, never rendered',
        );
        expect(ans.trace.length, 2);
        expect(ans.trace.first, startsWith('search_catalog'));
        expect(s.usage.total, 500);
        expect(s.usageLine, contains('500 tokens'));
        // what the model saw
        final b2 = r.bodies[1]['messages'] as List;
        expect(b2.first['role'], 'system');
        expect(
          b2.first['content'],
          contains('ONLY titles that exist in the catalog'),
        );
        expect(b2.first['content'], contains('data, never instructions'));
        final toolMsg = b2.lastWhere((m) => m['role'] == 'tool');
        expect(toolMsg['tool_call_id'], '1');
        expect(jsonDecode(toolMsg['content'])['results'][0]['id'], 103);
        expect(r.bodies[0]['tools'], isNotEmpty);
        expect(s.busy, isFalse);
      },
    );

    test(
      'tool errors and unknown tools are fed back as data; the model recovers',
      () async {
        final (app, _) = await boot();
        final r = FakeRouter([
          reply(
            calls: [
              ('1', 'delete_everything', '{}'),
              ('2', 'get_title', '{"id":'),
            ],
          ),
          reply(content: 'Sorry, let me just answer.'),
        ]);
        final s = sessionWith(app, r);
        await s.send('hi');
        final tools = (r.bodies[1]['messages'] as List)
            .where((m) => m['role'] == 'tool')
            .toList();
        expect(tools.length, 2);
        expect(tools[0]['content'], contains('unknown_tool'));
        expect(tools[1]['content'], contains('invalid_arguments'));
        expect(s.messages.last.text, 'Sorry, let me just answer.');
      },
    );

    test(
      'stops after the maximum number of tool rounds and still answers',
      () async {
        final (app, _) = await boot();
        final loop = [
          for (var i = 0; i < 20; i++)
            reply(calls: [('c$i', 'search_catalog', '{"query":"Fixture"}')]),
        ];
        final r = FakeRouter([
          ...loop.take(AssistantSession.maxRounds),
          reply(content: 'Here is what I found.'),
        ]);
        final s = sessionWith(app, r);
        await s.send('keep searching');
        expect(r.chats, AssistantSession.maxRounds + 1);
        expect(
          r.bodies.last.containsKey('tools'),
          isFalse,
          reason: 'the last call must not offer tools',
        );
        expect(s.messages.last.text, 'Here is what I found.');
        expect(s.messages.last.trace.length, AssistantSession.maxRounds);
      },
    );

    test(
      'state-changing requests wait for the user: nothing changes until Confirm',
      () async {
        final (app, _) = await boot();
        final r = FakeRouter([
          reply(
            calls: [
              ('1', 'add_to_plan', '{"id":102}'),
              ('2', 'mark_watched', '{"id":103,"rating":9}'),
            ],
          ),
          reply(
            content:
                'I asked for both; they are waiting for your confirmation.',
          ),
        ]);
        final s = sessionWith(app, r);
        final idx102 = app.data.idToIdx[102]!, idx103 = app.data.idToIdx[103]!;
        await s.send('plan 102 and mark 103 watched');
        expect(s.pending.length, 2);
        expect(app.entries.containsKey(idx102), isFalse);
        expect(app.entries.containsKey(idx103), isFalse);
        final toolResult =
            (r.bodies[1]['messages'] as List)
                    .where((m) => m['role'] == 'tool')
                    .first['content']
                as String;
        expect(toolResult, contains('awaiting_user_confirmation'));
        s.confirm(s.pending.first);
        expect(app.entries[idx102]!.status, EntryStatus.planned);
        s.dismiss(s.pending.single);
        expect(
          app.entries.containsKey(idx103),
          isFalse,
          reason: 'dismissed = never executed',
        );
        expect(s.pending, isEmpty);
        expect(
          app.users.all().where((e) => e.id == 102).single.status,
          EntryStatus.planned,
          reason: 'persisted',
        );
      },
    );

    test(
      'library tools refuse while the switch is off, and work when it is on',
      () async {
        for (final allowed in [false, true]) {
          final (app, _) = await boot(library: allowed);
          final r = FakeRouter([
            reply(calls: [('1', 'get_taste_profile', '{}')]),
            reply(content: 'ok'),
          ]);
          final s = sessionWith(app, r);
          await s.send('what do I like?');
          final result =
              (r.bodies[1]['messages'] as List).lastWhere(
                    (m) => m['role'] == 'tool',
                  )['content']
                  as String;
          expect(result.contains('library_access_off'), !allowed);
          expect(result.contains('rated_titles'), allowed);
          // and the system prompt tells the model which mode it is in
          expect(
            (r.bodies[0]['messages'] as List).first['content'],
            contains(allowed ? 'allowed you to read' : 'NOT allowed'),
          );
        }
      },
    );

    test(
      'friendly errors for bad key, credits, rate limit and network; never crashes, never leaks the key',
      () async {
        final cases = <(Object, String)>[
          (http.Response('{}', 401), 'rejected the API key'),
          (http.Response('{}', 402), 'credits'),
          (http.Response('{}', 429), 'Rate limit'),
          (http.ClientException('offline'), 'Could not reach'),
        ];
        for (final (o, needle) in cases) {
          final (app, _) = await boot();
          final s = sessionWith(app, FakeRouter([o]));
          await s.send('hello');
          expect(s.messages.last.role, 'error');
          expect(s.messages.last.text, contains(needle));
          expect(
            [for (final m in s.messages) m.text].join(),
            isNot(contains(fakeKey)),
          );
          expect(s.busy, isFalse);
        }
      },
    );

    test(
      'Stop discards the in-flight answer; Clear resets the conversation',
      () async {
        final (app, _) = await boot();
        final gate = Completer<String>();
        final r = FakeRouter([
          () => gate.future,
          reply(content: 'fresh answer'),
        ]);
        final s = sessionWith(app, r);
        final f = s.send('slow question');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(s.busy, isTrue);
        s.stop();
        gate.complete(reply(content: 'late answer that must be ignored'));
        await f;
        expect(s.messages.map((m) => m.role), ['user']);
        expect(s.busy, isFalse);
        s.clear();
        expect(s.messages, isEmpty);
        await s.send('again');
        expect(s.messages.last.text, 'fresh answer');
        expect(
          (r.bodies.last['messages'] as List)
              .where((m) => m['role'] == 'user')
              .length,
          1,
          reason: 'history was cleared',
        );
      },
    );
  });

  group('settings and key hygiene', () {
    test(
      'settings persist in app storage; the key stays out of backups and exports',
      () async {
        final dir = Directory.systemTemp.createTempSync('lodestar_aiset');
        addTearDown(() => dir.deleteSync(recursive: true));
        final a = AppState();
        await a.init(supportDirOverride: dir.path);
        expect(a.ai.enabled, isFalse, reason: 'off by default');
        expect(
          a.ai.libraryAllowed,
          isFalse,
          reason: 'library access is off by default',
        );
        expect(a.ai.hasKey, isFalse);
        a.ai
          ..enabled = true
          ..model = 'openai/gpt-4o-mini'
          ..libraryAllowed = true
          ..saveKey(fakeKey);
        a.rate(3, rating: 9, reasons: {'g:romance'});
        final backup = a.exportBackup();
        expect(backup, isNot(contains(fakeKey)));
        expect(backup, isNot(contains('ai.')));
        final full = buildBackup(
          a.users.all(),
          a.data,
          settings: {'obscurity': '0.3'},
        );
        expect(full, isNot(contains(fakeKey)));
        expect(jsonDecode(backup)['settings'].keys, ['obscurity']);
        // restoring a backup does not touch the key either
        a.restoreBackup(backup, replace: true);
        expect(a.ai.apiKey, fakeKey);
        a.users.close();
        final b = AppState();
        await b.init(supportDirOverride: dir.path);
        expect(
          (b.ai.enabled, b.ai.model, b.ai.libraryAllowed, b.ai.apiKey),
          (true, 'openai/gpt-4o-mini', true, fakeKey),
        );
        expect(b.ai.ready, isTrue);
        b.ai.removeKey();
        expect((b.ai.hasKey, b.ai.ready), (false, false));
      },
    );

    test('redact() removes the secret from any text', () {
      expect(
        redact('Bearer $fakeKey failed for $fakeKey', fakeKey),
        'Bearer [key] failed for [key]',
      );
      expect(redact('nothing here', fakeKey), 'nothing here');
      expect(redact('x', null), 'x');
    });

    test('no secret-looking strings in the assistant sources', () {
      for (final f in Directory('lib/assistant').listSync().whereType<File>()) {
        final src = f.readAsStringSync();
        expect(
          RegExp(r'sk-or-[A-Za-z0-9-]{8,}').hasMatch(src),
          isFalse,
          reason: f.path,
        );
      }
    });
  });
}

// "Improve my taste profile": request preview, strict reply validation, leave-one-out gate, the separate layer
// (ranking + explanations), review/apply/undo, backups, cold start. Fake HTTP only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/assistant/openrouter.dart';
import 'package:lodestar/assistant/taste_ai.dart';
import 'package:lodestar/data/backup.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';
import 'package:lodestar/engine/taste_layer.dart';

const fakeKey = 'FAKE-KEY-FOR-TESTS-0000';

String reply(Object content) => jsonEncode({
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': content is String ? content : jsonEncode(content),
      },
    },
  ],
  'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
});

class Router {
  final List<String> script;
  final bodies = <Map<String, dynamic>>[];
  Router(this.script);
  http.Client get client => MockClient((req) async {
    bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    return http.Response(
      script.isEmpty ? '{"error":{"message":"empty"}}' : script.removeAt(0),
      script.isEmpty && bodies.isEmpty ? 500 : 200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

/// Romance/drama favourites, action/comedy duds: a persona with a clear taste.
List<UserEntry> persona(AppState app, {int? limit}) {
  final out = <UserEntry>[];
  for (final t in app.data.titles) {
    if (t.genres.any({'romance', 'drama'}.contains)) {
      out.add(
        UserEntry(
          id: t.id,
          status: EntryStatus.watched,
          rating: 9,
          note: t.id == 1 ? 'slow burn, adults only, loved it' : '',
        ),
      );
    } else if (t.genres.any({'action', 'comedy'}.contains)) {
      out.add(
        UserEntry(
          id: t.id,
          status: EntryStatus.watched,
          rating: 3,
          reasons: t.id == 2 ? {'n:pacing'} : const {},
        ),
      );
    }
  }
  return limit == null ? out : out.take(limit).toList();
}

Future<AppState> boot({
  List<UserEntry> Function(AppState)? entries,
  bool library = true,
  bool enabled = true,
}) async {
  final dir = Directory.systemTemp.createTempSync('lodestar_layer');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('test/fixtures/mixed.db').copySync('${dir.path}/catalog_custom.db');
  final u = UserStore.open('${dir.path}/user.db')
    ..setSetting('catalog_source', 'file')
    ..setSetting('ai.enabled', enabled ? '1' : '0')
    ..setSetting('ai.key', fakeKey)
    ..setSetting('ai.library', library ? '1' : '0');
  u.close();
  final app = AppState();
  await app.init(supportDirOverride: dir.path);
  if (entries != null) {
    for (final e in entries(app)) {
      app.users.put(e);
    }
    app.restoreBackup(
      app.exportBackup(),
      replace: false,
    ); // reload entries from the store
  }
  return app;
}

Map<String, dynamic> adj(
  String type, {
  String? facet,
  String? ifFacet,
  String? dim,
  double mag = .8,
  List<String> titles = const ['Fixture Anime 1', 'Fixture Anime 5'],
}) => {
  'type': type,
  if (facet != null) 'facet': facet,
  if (ifFacet != null) 'if_facet': ifFacet,
  if (dim != null) 'dimension': dim,
  'magnitude': mag,
  'confidence': .7,
  'justification': 'Because of the titles cited.',
  'titles': titles,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the preview is exactly what is sent, capped, and carries ratings, reasons, notes and the learned profile',
    () async {
      final app = await boot(entries: persona);
      final req = app.tasteRequest();
      expect(req.interview, isFalse);
      expect(req.preview, contains(req.system));
      expect(req.preview, contains(req.user));
      final j = jsonDecode(req.user) as Map<String, dynamic>;
      expect((j['library'] as List).length, lessThanOrEqualTo(maxLibraryRows));
      expect(req.user, contains('slow burn, adults only'));
      expect(req.user, contains('"disliked"'));
      expect(j['learned_by_the_model'], isNotNull);
      expect((j['vocabulary']['dimensions'] as List), isNotEmpty);
      expect(req.user, isNot(contains(fakeKey)));
      // long notes are cut so the whole request stays bounded
      final big = [
        for (var i = 0; i < 40; i++)
          UserEntry(
            id: app.data.titles[i % app.data.n].id,
            status: EntryStatus.watched,
            rating: (i % 10) + 1.0,
            note: 'x' * 900,
          ),
      ];
      final capped = buildTasteRequest(
        app.data,
        big,
        app.summary(),
        null,
        cap: 30,
      );
      expect(capped.user.length, lessThan(14000));
      // and the call sends precisely those two messages
      final r = Router([
        reply({
          'summary': 'ok',
          'adjustments': [],
          'questions': [],
          'contradictions': ['x'],
        }),
      ]);
      app.providerFactory = (k) => OpenRouterProvider(k, client: r.client);
      await app.sendTasteRequest(req);
      final msgs = r.bodies.single['messages'] as List;
      expect(msgs.length, 2);
      expect(msgs[0]['content'], req.system);
      expect(msgs[1]['content'], req.user);
      expect(r.bodies.single['tools'], anyOf(isNull, isEmpty));
    },
  );

  test(
    'nothing is sent unless the assistant is on AND library access is allowed; building the preview never calls the network',
    () async {
      final r = Router([]);
      for (final (lib, en) in [(false, true), (true, false), (false, false)]) {
        final app = await boot(entries: persona, library: lib, enabled: en);
        app.providerFactory = (k) => OpenRouterProvider(k, client: r.client);
        expect(app.canImproveProfile, isFalse);
        app.tasteRequest();
        await expectLater(
          app.sendTasteRequest(app.tasteRequest()),
          throwsA(isA<TasteAiException>()),
        );
      }
      expect(r.bodies, isEmpty);
      expect((await boot(entries: persona)).canImproveProfile, isTrue);
    },
  );

  test(
    'reply validation: unknown vocabulary, unknown dimensions, bad types and uncited claims are dropped; the rest is kept',
    () async {
      final app = await boot(entries: persona);
      final req = app.tasteRequest();
      final good = adj('facet_up', facet: 'genre|romance');
      final raw = jsonEncode({
        'summary': 'Likes romance.',
        'adjustments': [
          good,
          adj('facet_down', facet: 'genre|no-such-genre'),
          adj('facet_up', facet: 'madeup|romance'),
          adj('dimension_high', dim: 'romance_centrality'),
          adj('dimension_high', dim: 'telepathy'),
          adj('teleport', facet: 'genre|romance'),
          adj(
            'exclude',
            facet: 'genre|action',
            titles: const ['Not In Library'],
          ),
          adj(
            'conditional_boost',
            facet: 'genre|romance',
            ifFacet: 'keyword|road trip',
          ),
          adj(
            'conditional_penalize',
            facet: 'genre|romance',
          ), // missing if_facet
          good, // duplicate
        ],
        'contradictions': ['Rates X a 9 but dislikes Y.'],
        'questions': [
          {
            'text': 'Slow burn or fast?',
            'options': [
              {
                'label': 'Slow',
                'adjustment': adj(
                  'facet_up',
                  facet: 'genre|romance',
                  titles: const [],
                ),
              },
              {'label': 'Fast'},
            ],
          },
          {'text': 'broken', 'options': 'nope'},
        ],
      });
      final p = parseTasteReply('```json\n$raw\n```', app.data, req);
      expect(p.summary, 'Likes romance.');
      expect(
        [for (final r in p.rules) r.type],
        [RuleType.facet, RuleType.dimension, RuleType.conditional],
      );
      expect(p.rules.first.cites, ['Fixture Anime 1', 'Fixture Anime 5']);
      expect(p.dropped, greaterThanOrEqualTo(6));
      expect(p.contradictions, hasLength(1));
      expect(p.questions, hasLength(1));
      expect(p.questions.single.options.first.rule, isNotNull);
      expect(p.questions.single.options.last.rule, isNull);
      expect(
        () => parseTasteReply('sorry, no json', app.data, req),
        throwsFormatException,
      );
      expect(
        () => parseTasteReply('{"adjustments": "x"}', app.data, req),
        throwsFormatException,
      );
    },
  );

  test(
    'invalid JSON is retried exactly once; two failures give a clear error',
    () async {
      final app = await boot(entries: persona);
      final ok = reply({
        'summary': 'Fine.',
        'adjustments': [adj('facet_up', facet: 'genre|romance')],
        'questions': [],
      });
      var r = Router([
        '{"choices":[{"message":{"role":"assistant","content":"not json at all"}}]}',
        ok,
      ]);
      app.providerFactory = (k) => OpenRouterProvider(k, client: r.client);
      final p = await app.sendTasteRequest(app.tasteRequest());
      expect(p.rules, hasLength(1));
      expect(r.bodies, hasLength(2));
      expect(
        jsonEncode(r.bodies[1]['messages']),
        contains('not valid for the schema'),
      );
      r = Router([
        for (var i = 0; i < 3; i++)
          '{"choices":[{"message":{"role":"assistant","content":"still nope"}}]}',
      ]);
      app.providerFactory = (k) => OpenRouterProvider(k, client: r.client);
      await expectLater(
        app.sendTasteRequest(app.tasteRequest()),
        throwsA(isA<TasteAiException>()),
      );
      expect(r.bodies, hasLength(2));
    },
  );

  test(
    'leave-one-out gate: a sensible rule helps, a rule that goes against the ratings is flagged as worse',
    () async {
      final app = await boot(entries: persona);
      final entries = app.entries.values.toList();
      LayerRule facet(String v, int dir) => LayerRule(
        id: 'f$v$dir',
        type: RuleType.facet,
        kind: 'genre',
        value: v,
        dir: dir,
        magnitude: .8,
      );
      final good = await app.recommender.evaluateLayer(entries, [
        facet('romance', 1),
      ]);
      expect(good.tested, greaterThanOrEqualTo(10));
      expect(good.verdict, isNot(LayerVerdict.worse));
      expect(good.meanDelta, greaterThan(0));
      expect(good.perRule['fromance1']!.$1, LayerVerdict.helps);
      final bad = await app.recommender.evaluateLayer(entries, [
        facet('comedy', 1),
        facet('action', 1),
      ]);
      expect(bad.verdict, LayerVerdict.worse);
      expect(bad.text, contains('worse'));
      expect(bad.perRule['fcomedy1']!.$1, LayerVerdict.worse);
      // too few ratings: no verdict
      final few = await app.recommender.evaluateLayer(
        entries.take(3).toList(),
        [facet('romance', 1)],
      );
      expect(few.verdict, LayerVerdict.unknown);
      expect(few.text, contains('Not enough'));
      // the app's recommender state is untouched by the test run
      expect(app.recommender.layer!.rules, isEmpty);
    },
  );

  test(
    'the layer is separate: learned weights stay identical; rules steer the ranking and the explanations say so',
    () async {
      final app = await boot(entries: persona);
      final entries = app.entries.values.toList();
      final before = app.recommender.fit(entries);
      final base = app.recommender.recommend(before, Controls(), count: 40);
      expect(base, isNotEmpty);
      // penalise whatever the top pick is about, exclude the 2nd pick's genre
      final top = app.data.titles[base.first.idx];
      final genre = top.genres.first;
      app.applyLayer(
        TasteLayer(
          rules: [
            LayerRule(
              id: 'a',
              type: RuleType.facet,
              kind: 'genre',
              value: genre,
              dir: -1,
              magnitude: 1,
            ),
          ],
        ),
      );
      final after = app.recommender.fit(entries);
      expect(
        after.wFac,
        before.wFac,
        reason: 'the layer never touches the learned weights',
      );
      expect(after.wDim, before.wDim);
      final steered = app.recommender.recommend(after, Controls(), count: 40);
      int pos(List<Rec> l, int idx) => l.indexWhere((r) => r.idx == idx);
      expect(
        pos(steered, base.first.idx) == -1 ||
            pos(steered, base.first.idx) > pos(base, base.first.idx),
        isTrue,
      );
      final hit = steered
          .where((r) => r.why.contains('AI taste layer'))
          .toList();
      expect(hit, isNotEmpty);
      expect(hit.first.why.toLowerCase(), contains(genre));
      expect(base.where((r) => r.why.contains('AI taste layer')), isEmpty);
      // off / strength 0 -> exactly the old ranking
      app.updateLayer(app.layer.copyWith(enabled: false));
      expect(
        [
          for (final r in app.recommender.recommend(
            after,
            Controls(),
            count: 40,
          ))
            r.idx,
        ],
        [for (final r in base) r.idx],
      );
      app.updateLayer(app.layer.copyWith(enabled: true, strength: 0));
      expect(
        [
          for (final r in app.recommender.recommend(
            after,
            Controls(),
            count: 40,
          ))
            r.idx,
        ],
        [for (final r in base) r.idx],
      );
      // a hard exclusion removes the facet's titles
      app.updateLayer(
        TasteLayer(
          rules: [
            LayerRule(
              id: 'x',
              type: RuleType.exclude,
              kind: 'genre',
              value: genre,
              dir: -1,
              magnitude: 1,
            ),
          ],
        ),
      );
      final excl = app.recommender.recommend(
        app.recommender.fit(entries),
        Controls(),
        count: 40,
      );
      expect(
        excl.every((r) => !app.data.titles[r.idx].genres.contains(genre)),
        isTrue,
      );
      // vocabulary missing in this catalog does nothing and does not crash
      app.updateLayer(
        TasteLayer(
          rules: [
            LayerRule(
              id: 'z',
              type: RuleType.facet,
              kind: 'genre',
              value: 'ghost',
              magnitude: 1,
            ),
          ],
        ),
      );
      expect(
        () => app.recommender.recommend(
          app.recommender.fit(entries),
          Controls(),
          count: 10,
        ),
        returnsNormally,
      );
    },
  );

  test(
    'review flow: accept / reject / edit strength, apply, what changed, undo, reset',
    () async {
      final app = await boot(entries: persona);
      final r1 = LayerRule(
        id: 'r1',
        type: RuleType.facet,
        kind: 'genre',
        value: 'romance',
        magnitude: .6,
        why: 'w',
        cites: const ['Fixture Anime 1'],
      );
      final r2 = LayerRule(
        id: 'r2',
        type: RuleType.facet,
        kind: 'genre',
        value: 'action',
        dir: -1,
        magnitude: .5,
      );
      final r3 = LayerRule(
        id: 'r3',
        type: RuleType.dimension,
        dim: 'romance_centrality',
        magnitude: .4,
      );
      // user accepts r1 (strength edited to 0.5), rejects r2, accepts r3
      app.applyLayer(
        TasteLayer(
          summary: 'Likes romance.',
          rules: [r1.copyWith(strength: .5), r3],
        ),
      );
      expect(app.layer.rules.map((r) => r.id), ['r1', 'r3']);
      expect(app.layer.rules.first.strength, .5);
      expect(app.layer.changes, hasLength(2));
      expect(app.layer.changes.first, startsWith('Added:'));
      expect(app.layerPrev, isNull);
      // second run: r3 dropped, r2 added, r1 re-weighted
      app.applyLayer(
        TasteLayer(summary: 'Updated.', rules: [r1.copyWith(strength: 1), r2]),
      );
      expect(app.layer.changes.toSet(), {
        'Added: ${r2.text}',
        'Removed: ${r3.text}',
        'Changed strength: ${r1.text}',
      });
      expect(app.layerPrev!.rules.map((r) => r.id), ['r1', 'r3']);
      app.undoLayer();
      expect(app.layer.rules.map((r) => r.id), ['r1', 'r3']);
      app.resetLayer();
      expect(app.layer.isEmpty, isTrue);
      expect(app.recommender.layer!.rules, isEmpty);
      app.undoLayer();
      expect(app.layer.rules, isNotEmpty);
      // individual rules can be switched off and re-weighted without touching the others
      app.updateLayer(
        app.layer.copyWith(
          rules: [
            app.layer.rules.first.copyWith(enabled: false),
            app.layer.rules.last,
          ],
        ),
      );
      expect(app.layer.active, isTrue);
      expect(app.recommender.layer!.rules.first.enabled, isFalse);
    },
  );

  test(
    'persisted with the user data, restored from backups, and the API key is never in a backup',
    () async {
      final app = await boot(entries: persona);
      app.applyLayer(
        TasteLayer(
          summary: 'S',
          strength: .8,
          rules: [
            LayerRule(
              id: 'r1',
              type: RuleType.facet,
              kind: 'genre',
              value: 'romance',
              why: 'because',
              cites: const ['Fixture Anime 1'],
            ),
          ],
          answers: const [('Slow burn?', 'Yes')],
        ),
      );
      app.applyLayer(
        app.layer.copyWith(
          rules: [app.layer.rules.first.copyWith(strength: .7)],
        ),
      );
      final json = app.exportBackup();
      expect(json, contains('taste_layer'));
      expect(json, contains('taste_layer_prev'));
      expect(json, isNot(contains(fakeKey)));
      expect(json.toLowerCase(), isNot(contains('ai.key')));
      // a different device: empty store, restore the file
      final other = await boot();
      expect(other.layer.isEmpty, isTrue);
      other.restoreBackup(json, replace: true);
      expect(other.layer.rules.single.id, 'r1');
      expect(other.layer.rules.single.strength, .7);
      expect(other.layer.strength, .8);
      expect(other.layer.answers.single, ('Slow burn?', 'Yes'));
      expect(other.layerPrev, isNotNull);
      expect(other.recommender.layer!.rules, hasLength(1));
      // and a plain backup without a layer clears it on replace
      final plain = parseBackup(
        buildBackup(other.users.all(), other.data),
        other.data,
        TitleSearch(other.data),
      );
      expect(plain.settings.containsKey('taste_layer'), isFalse);
    },
  );

  test(
    'cold start: fewer than 10 ratings -> a short interview whose answers become rules',
    () async {
      final app = await boot(entries: (a) => persona(a, limit: 4));
      final req = app.tasteRequest();
      expect(req.interview, isTrue);
      expect(req.system, contains('interview'));
      final raw = jsonEncode({
        'summary': '',
        'adjustments': [
          adj('facet_up', facet: 'genre|romance'),
        ], // ignored in interview mode
        'questions': [
          for (var i = 0; i < 6; i++)
            {
              'text': 'Question $i?',
              'options': [
                {
                  'label': 'Yes',
                  'adjustment': {
                    'type': 'facet_up',
                    'facet': 'genre|romance',
                    'magnitude': .5,
                    'confidence': .5,
                    'justification': 'They said so.',
                  },
                },
                {
                  'label': 'No',
                  'adjustment': {
                    'type': 'facet_down',
                    'facet': 'genre|ghost',
                    'magnitude': .5,
                  },
                },
                {'label': 'Skip'},
              ],
            },
        ],
      });
      final p = parseTasteReply(raw, app.data, req);
      expect(p.interview, isTrue);
      expect(p.rules, isEmpty);
      expect(p.questions, hasLength(6));
      expect(p.questions.first.options[0].rule!.type, RuleType.facet);
      expect(
        p.questions.first.options[1].rule,
        isNull,
        reason: 'unknown vocabulary is dropped',
      );
      expect(
        () => parseTasteReply('{"questions": []}', app.data, req),
        throwsFormatException,
      );
      // the answers feed the next run
      app.applyLayer(
        TasteLayer(
          rules: [p.questions.first.options[0].rule!],
          answers: [(p.questions.first.text, 'Yes')],
        ),
      );
      expect(app.tasteRequest().user, contains('earlier_answers'));
    },
  );
}

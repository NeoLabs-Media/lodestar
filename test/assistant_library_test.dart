// The assistant knows what the user has watched: library status on every title, check_library, list_library,
// seen titles left out by default, and a clear "I cannot know" when library access is off.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/assistant/session.dart';
import 'package:lodestar/assistant/tools.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';

void main() {
  final store = CatalogStore.open('test/fixtures/mixed.db');
  final rec = Recommender(store.data);
  final search = TitleSearch(store.data);
  var allowed = true;
  var spoilers = false;
  final lib = <UserEntry>[
    const UserEntry(
      id: 1,
      status: EntryStatus.watched,
      rating: 9,
      reasons: {'g:romance', 'f:ending_types|bittersweet', 'n:pacing'},
      updatedAt: 5,
    ),
    const UserEntry(
      id: 103,
      status: EntryStatus.watched,
      rating: 7.5,
      updatedAt: 4,
    ),
    const UserEntry(id: 104, status: EntryStatus.watched, updatedAt: 3),
    const UserEntry(id: 5, status: EntryStatus.planned, updatedAt: 2),
    const UserEntry(id: 7, status: EntryStatus.notInterested, updatedAt: 1),
    const UserEntry(id: 8, status: EntryStatus.ignored, updatedAt: 0),
  ];
  final tools = AssistantTools(
    AssistantContext(
      store: store,
      rec: rec,
      search: search,
      controls: Controls.new,
      entries: () => lib,
      libraryAllowed: () => allowed,
      spoilers: () => spoilers,
    ),
  );
  Map<String, dynamic> run(String n, [Map<String, dynamic> a = const {}]) =>
      tools.call(n, jsonEncode(a)).json;
  List<Map> rows(Map<String, dynamic> r, [String key = 'results']) =>
      (r[key] as List).cast<Map>();
  Map? row(List<Map> l, int id) => l.where((x) => x['id'] == id).firstOrNull;

  setUp(() {
    allowed = true;
    spoilers = false;
  });

  test(
    'every title object carries a compact library field when access is allowed',
    () {
      final all = <List<Map>>[
        rows(
          run('search_catalog', {
            'query': 'Fixture',
            'limit': 10,
            'exclude_seen': false,
          }),
        ),
        rows(run('find_similar', {'id': 2, 'n': 10, 'exclude_seen': false})),
        rows(run('get_recommendations', {'n': 10}), 'recommendations'),
        rows(run('list_library', {'limit': 30}), 'items'),
        rows(
          run('check_library', {
            'titles': ['Fixture Anime 1', 'Fixture Movie 3'],
          }),
        ),
        [
          run('get_title', {'id': 1}),
          run('get_title', {'id': 2}),
        ],
        [
          run('explain_match', {'id': 1}),
          run('explain_match', {'id': 2}),
        ],
      ];
      for (final group in all) {
        expect(group, isNotEmpty);
        for (final r in group) {
          expect(r['library'], isA<Map>(), reason: '$r');
          expect(
            (r['library'] as Map)['status'],
            isIn(['watched', 'planned', 'not_interested', 'ignored', 'none']),
          );
        }
      }
      final t1 = run('get_title', {'id': 1})['library'] as Map;
      expect(t1['status'], 'watched');
      expect(t1['rating'], 9);
      expect(t1['liked'], contains('romance'));
      expect(t1['disliked'], contains('pacing'));
      expect((run('get_title', {'id': 6})['library'] as Map)['status'], 'none');
      expect(
        (run('get_title', {'id': 5})['library'] as Map)['status'],
        'planned',
      );
      expect(
        (run('get_title', {'id': 8})['library'] as Map)['status'],
        'ignored',
      );
      expect(
        (run('get_title', {'id': 7})['library'] as Map)['status'],
        'not_interested',
      );
      expect(run('get_title', {'id': 6}).containsKey('library_known'), isFalse);
    },
  );

  test(
    'with library access off: no library field anywhere, library_known=false, library tools refuse',
    () {
      allowed = false;
      for (final r in [
        run('search_catalog', {'query': 'Fixture'}),
        run('find_similar', {'id': 2}),
        run('get_recommendations'),
        run('get_title', {'id': 1}),
      ]) {
        expect(r['library_known'], false);
        expect(jsonEncode(r), isNot(contains('"library"')));
        expect(jsonEncode(r), isNot(contains('franchise_seen')));
        expect(jsonEncode(r), isNot(contains('hidden_seen_count')));
      }
      // nothing is hidden when the library is unknown
      expect(
        rows(
          run('search_catalog', {'query': 'Fixture Anime', 'limit': 10}),
        ).map((x) => x['id']),
        contains(1),
      );
      for (final n in [
        'check_library',
        'list_library',
        'get_library_summary',
      ]) {
        expect(
          run(n, {
            'titles': ['x'],
          })['error'],
          'library_access_off',
          reason: n,
        );
      }
      final prompt = buildSystemPrompt(
        titleCount: 5,
        kinds: {'anime'},
        filters: '',
        libraryAllowed: false,
        now: DateTime(2026),
      );
      expect(prompt, contains('cannot know what the user has watched'));
      expect(prompt, contains('library_known=false'));
      expect(prompt, contains('Settings → AI assistant'));
      expect(prompt, contains('Never guess'));
    },
  );

  test('the prompt with access on tells the model how to use the library', () {
    final prompt = buildSystemPrompt(
      titleCount: 5,
      kinds: {'anime'},
      filters: '',
      libraryAllowed: true,
      now: DateTime(2026),
    );
    for (final s in [
      'Library access is ON',
      'Never recommend a title whose status is watched',
      'check_library',
      'list_library',
      'mark_watched',
      'franchise_seen',
    ]) {
      expect(prompt, contains(s), reason: s);
    }
  });

  test(
    'check_library resolves exact, synonym and typo titles, ids, and says "not found"',
    () {
      final r = rows(
        run('check_library', {
          'titles': [
            'Fixture Anime 1',
            'alt Fixture Movie 3',
            'Fixtur Anime 5',
            'Totally Unknown Show 99',
          ],
          'ids': [7, 424242],
        }),
      );
      expect(r[0]['id'], 1);
      expect((r[0]['library'] as Map)['status'], 'watched');
      expect(r[1]['id'], 103, reason: 'synonym');
      expect((r[1]['library'] as Map)['rating'], 7.5);
      expect(r[2]['id'], 5, reason: 'typo');
      expect((r[2]['library'] as Map)['status'], 'planned');
      expect(r[3]['match'], contains('not found'));
      expect(r[3].containsKey('library'), isFalse);
      expect(r[4]['id'], 7);
      expect((r[4]['library'] as Map)['status'], 'not_interested');
      expect(r[5]['match'], contains('not found'));
      // capped at 20
      final many = rows(
        run('check_library', {'titles': List.filled(50, 'Fixture Anime 1')}),
      );
      expect(many.length, 20);
      expect(run('check_library')['error'], 'invalid_arguments');
    },
  );

  test('franchise_seen comes from the relations data', () {
    final sequel = run('get_title', {
      'id': 2,
    }); // 2 is the sequel of 1 (watched, rated 9)
    expect(
      sequel['franchise_seen'],
      allOf(
        contains('you watched'),
        contains('previous part'),
        contains('Fixture Anime 1'),
        contains('rated 9'),
      ),
    );
    expect(
      run('get_title', {'id': 1})['franchise_seen'],
      isNull,
      reason: 'its sequel is not in the library',
    );
    expect(run('get_title', {'id': 6}).containsKey('franchise_seen'), isFalse);
    // planned counts too
    lib.add(const UserEntry(id: 2, status: EntryStatus.planned));
    addTearDown(() => lib.removeWhere((e) => e.id == 2));
    expect(
      run('get_title', {'id': 1})['franchise_seen'],
      allOf(contains('planned'), contains('sequel')),
    );
  });

  test(
    'exclude_seen: watched / skipped / ignored are dropped by default and counted; planned stay and are marked; overridable',
    () {
      final r = run('search_catalog', {'query': 'Fixture Anime', 'limit': 10});
      final ids = rows(r).map((x) => x['id']).toList();
      expect(ids, isNot(contains(1)));
      expect(ids, isNot(contains(7)));
      expect(ids, isNot(contains(8)));
      expect(ids, contains(5));
      expect((row(rows(r), 5)!['library'] as Map)['status'], 'planned');
      expect(r['hidden_seen_count'], 3);
      expect(r['note_seen'], contains('exclude_seen=false'));
      final all = run('search_catalog', {
        'query': 'Fixture Anime',
        'limit': 10,
        'exclude_seen': false,
      });
      expect(rows(all).map((x) => x['id']), containsAll([1, 5, 7, 8]));
      expect(all.containsKey('hidden_seen_count'), isFalse);
      // browse mode (no query) too
      expect(
        rows(run('search_catalog', {'limit': 10})).map((x) => x['id']),
        isNot(contains(103)),
      );
      // similar titles
      final sim = run('find_similar', {'id': 6, 'n': 30});
      expect(
        rows(sim).every(
          (x) => {'none', 'planned'}.contains((x['library'] as Map)['status']),
        ),
        isTrue,
      );
      expect(sim['hidden_seen_count'], greaterThan(0));
      expect(
        rows(
          run('find_similar', {'id': 6, 'n': 30, 'exclude_seen': false}),
        ).any((x) => (x['library'] as Map)['status'] == 'watched'),
        isTrue,
      );
      // recommendations: told how many are left out
      final recs = run('get_recommendations', {'n': 10});
      expect(recs['hidden_seen_count'], 5);
      expect(recs['left_out_because_in_library'], {
        'watched': 3,
        'not_interested': 1,
        'ignored': 1,
        'planned': 1,
      });
      expect(
        rows(
          recs,
          'recommendations',
        ).every((x) => (x['library'] as Map)['status'] == 'none'),
        isTrue,
      );
    },
  );

  test(
    'list_library pages through everything, filters by status and kind, and caps the page size',
    () {
      final first = run('list_library', {'limit': 2});
      expect(first['total'], 6);
      expect(first['returned'], 2);
      expect(first['has_more'], true);
      expect(first['next_offset'], 2);
      expect(rows(first, 'items').map((x) => x['id']), [
        1,
        103,
      ], reason: 'most recent first');
      final second = run('list_library', {'limit': 2, 'offset': 2});
      expect(rows(second, 'items').map((x) => x['id']), [104, 5]);
      final last = run('list_library', {'limit': 2, 'offset': 4});
      expect(last['has_more'], false);
      expect(last.containsKey('next_offset'), isFalse);
      final watched = run('list_library', {
        'status': 'watched',
        'sort': 'rating',
      });
      expect(rows(watched, 'items').map((x) => x['id']), [1, 103, 104]);
      expect(
        run('list_library', {'status': 'watched', 'kind': 'movie'})['total'],
        2,
      );
      expect(run('list_library', {'offset': 999})['returned'], 0);
      // page size is capped
      for (var i = 0; i < 60; i++) {
        lib.add(
          UserEntry(id: i % 2 == 0 ? 9 : 10, status: EntryStatus.ignored),
        );
      }
      lib.removeRange(6, lib.length);
      expect(
        (run('list_library', {'limit': 1000})['returned'] as int),
        lessThanOrEqualTo(30),
      );
    },
  );

  test(
    'spoiler mode still applies: library reason tags do not leak ending tags while spoilers are off',
    () {
      final off = jsonEncode(run('get_title', {'id': 1})['library']);
      expect(off, isNot(contains('bittersweet')));
      expect(off, contains('romance'));
      spoilers = true;
      expect(
        jsonEncode(run('get_title', {'id': 1})['library']),
        contains('bittersweet'),
      );
      // and the watched status itself is fine either way
      spoilers = false;
      expect(
        (run('get_title', {'id': 1})['library'] as Map)['status'],
        'watched',
      );
    },
  );
}

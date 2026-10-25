// Movies + TV + anime in one catalog (synthetic fixture, see tools/make_fixture.py): kinds, keys for
// titles without AniList ids, search, kind filter, tmdb-based "also liked" signals, explanations.
import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';

void main() {
  final c = CatalogStore.open('test/fixtures/mixed_v2.db').data;
  final rec = Recommender(c);
  final search = TitleSearch(c);
  int idx(int id) => c.idToIdx[id]!;

  test(
    'loads all kinds and stable keys, including titles without anilist ids',
    () {
      expect(c.n, 24);
      expect(c.kinds, {'anime', 'movie', 'tv'});
      expect(c.titles[idx(1)].key, 'anilist:1001');
      expect(c.titles[idx(9)].key, 'mal:9009'); // anime with a MAL id only
      expect(c.titles[idx(10)].key, 'id:10'); // no external id at all
      expect(c.titles[idx(101)].key, 'tmdb:movie:5001');
      expect(c.titles[idx(201)].key, 'tmdb:tv:7001');
      expect(c.titles[idx(108)].key, 'imdb:tt108'); // imdb only
      expect(c.titles[idx(101)].anilist, isNull);
      expect(c.titles[idx(101)].kind, 'movie');
      expect(
        c.titles[idx(101)].cover,
        'https://img.example/101.jpg',
      ); // stored cover url
      expect(c.titles[idx(1)].cover, 'https://img.example/1.jpg');
    },
  );

  test('search covers every kind and can be restricted', () {
    expect(search.search('Fixture Movie 3').first.idx, idx(103));
    expect(search.search('Fixture Series 2').first.idx, idx(202));
    expect(search.search('Fixture Anime 4').first.idx, idx(4));
    expect(
      search
          .search('Fixture', limit: 30)
          .map((h) => c.titles[h.idx].kind)
          .toSet(),
      {'anime', 'movie', 'tv'},
    );
    expect(
      search
          .search('Fixture', limit: 30, kind: 'tv')
          .every((h) => c.titles[h.idx].kind == 'tv'),
      isTrue,
    );
    expect(search.bestMatch('Fixture Movie 3', kind: 'anime'), isNull);
    expect(search.bestMatch('Fixture Movie 3'), idx(103));
  });

  test(
    'tmdb recommendations become "also liked" links between movie and tv',
    () {
      final m = idx(101), m2 = idx(102), tv = idx(201);
      expect(c.recs[m].map((e) => e.$1), containsAll([m2, tv]));
      expect(c.recs[tv].map((e) => e.$1), contains(m)); // symmetric
      final taste = rec.fit([
        UserEntry(id: 101, status: EntryStatus.watched, rating: 10),
      ]);
      expect(taste.comm[m2], isNotNull);
      expect(taste.comm[tv], isNotNull);
      expect(taste.comm[m2]!, greaterThan(0));
      expect(taste.comm[tv]!, greaterThan(0));
    },
  );

  List<UserEntry> romanceFan() => [
    UserEntry(
      id: 1,
      status: EntryStatus.watched,
      rating: 10,
    ), // romance cluster anime
    UserEntry(id: 7, status: EntryStatus.watched, rating: 9),
    UserEntry(
      id: 104,
      status: EntryStatus.watched,
      rating: 9,
    ), // romance cluster movie
    UserEntry(id: 5, status: EntryStatus.watched, rating: 3),
  ];

  test('kind filter restricts the feed; default mixes kinds', () {
    final m = rec.fit(romanceFan());
    final mix = rec.recommend(m, Controls(), count: 12);
    expect(
      mix.map((r) => c.titles[r.idx].kind).toSet().length,
      greaterThanOrEqualTo(2),
      reason: 'default mixes media',
    );
    for (final kind in ['anime', 'movie', 'tv']) {
      final r = rec.recommend(m, Controls(kinds: {kind}), count: 6);
      expect(r, isNotEmpty);
      expect(
        r.every((x) => c.titles[x.idx].kind == kind),
        isTrue,
        reason: kind,
      );
    }
    final two = rec.recommend(m, Controls(kinds: {'movie', 'tv'}), count: 12);
    expect(two.map((r) => c.titles[r.idx].kind).toSet(), {'movie', 'tv'});
    // watched titles never come back
    expect(
      mix.any((r) => {1, 7, 104, 5}.contains(c.titles[r.idx].id)),
      isFalse,
    );
  });

  test('explanations work for titles without any anilist data', () {
    final m = rec.fit(romanceFan());
    final movieIdx = idx(108); // imdb-only title
    final (why, _, _) = rec.explain(movieIdx, m);
    expect(why, isNotEmpty);
    expect(why, isNot(contains('null')));
    final recs = rec.recommend(m, Controls(kinds: {'movie'}), count: 5);
    expect(recs.every((r) => r.why.isNotEmpty), isTrue);
  });

  test('categories use TMDB keywords where anime use AniList tags', () {
    expect(rec.inCategory(idx(2), 'isekai'), isTrue); // anilist_tag
    expect(
      rec.inCategory(idx(102), 'school'),
      isTrue,
    ); // keyword|school on a movie
    expect(rec.inCategory(idx(104), 'school'), isFalse);
    final m = rec.fit(romanceFan());
    final r = rec.recommend(m, Controls(categories: {'school'}), count: 10);
    expect(r, isNotEmpty);
    expect(r.every((x) => rec.inCategory(x.idx, 'school')), isTrue);
  });
}

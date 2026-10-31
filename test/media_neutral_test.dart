// The app should not feel anime-only: movie/TV genres as categories, mixed cold-start feed, CSV imports from
// Letterboxd / IMDb, neutral wording and type-appropriate meta lines.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/data/importers.dart';
import 'package:lodestar/engine/categories.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';
import 'package:lodestar/ui/widgets.dart';

void main() {
  final store = CatalogStore.open('test/fixtures/mixed.db');
  final d = store.data;
  final rec = Recommender(d);
  final search = TitleSearch(d);

  test(
    'categories cover movie and TV genres, generic ones come before the anime-specific ones',
    () {
      final keys = [for (final c in categories) c.key];
      expect(
        keys,
        containsAll([
          'crime',
          'documentary',
          'biography',
          'family',
          'western',
          'animation',
          'historical',
        ]),
      );
      expect(keys.indexOf('drama'), lessThan(keys.indexOf('isekai')));
      expect(keys.indexOf('crime'), lessThan(keys.indexOf('mecha')));
      expect(
        keys.length,
        lessThanOrEqualTo(31),
        reason: 'one bit per category in a 32-bit mask',
      );
      expect(
        mediaKinds.first,
        'movie',
        reason: 'chips: movies and TV before anime',
      );
    },
  );

  test(
    'an unrated user browsing "all media" gets a mix of types, not just one',
    () {
      final m = rec.fit(const []);
      final feed = rec.recommend(m, Controls(), count: 12);
      final kinds = {for (final r in feed) d.titles[r.idx].kind};
      expect(kinds.length, 3);
      final byKind = <String, int>{};
      for (final r in feed) {
        byKind[d.titles[r.idx].kind] = (byKind[d.titles[r.idx].kind] ?? 0) + 1;
      }
      expect(byKind.values.every((n) => n <= 8), isTrue, reason: '$byKind');
      // a single type is still a single type
      expect(
        rec
            .recommend(m, Controls(kinds: {'movie'}), count: 6)
            .every((r) => d.titles[r.idx].kind == 'movie'),
        isTrue,
      );
    },
  );

  test(
    'meta lines fit the type: runtime for movies, seasons for series, format and episodes for anime',
    () {
      final movie = d.titles.firstWhere(
        (t) => t.kind == 'movie' && t.runtime != null,
      );
      expect(metaLine(movie), contains('${movie.runtime} min'));
      expect(metaLine(movie), isNot(contains('Movie')));
      final tv = d.titles.firstWhere(
        (t) => t.kind == 'tv' && t.seasons != null,
      );
      expect(metaLine(tv), contains('season'));
      final anime = d.titles.firstWhere((t) => t.kind == 'anime');
      expect(metaLine(anime), contains('ep'));
    },
  );

  test(
    'Letterboxd ratings.csv: stars become a 10-point rating, matched by name and year',
    () {
      final csv =
          'Date,Name,Year,Letterboxd URI,Rating\n'
          '2024-01-01,Fixture Movie 2,2004,https://boxd.it/a,4.5\n'
          '2024-01-02,"Fixture Movie 3",2006,https://boxd.it/b,3\n'
          '2024-01-03,Totally Unknown Film,1999,https://boxd.it/c,5\n';
      final r = parseAnyImport(utf8.encode(csv), d, search);
      expect(r.entries.length, 2);
      final byId = {for (final e in r.entries) e.id: e};
      expect(byId[102]!.rating, 9);
      expect(byId[103]!.rating, 6);
      expect(r.unmatched.single, contains('Totally Unknown Film (1999)'));
    },
  );

  test(
    'IMDb ratings.csv: matched by IMDb id first, then by title and type; 10-point ratings kept',
    () {
      final csv =
          'Const,Your Rating,Date Rated,Title,URL,Title Type,IMDb Rating,Runtime (mins),Year\n'
          'tt108,8,2024-01-01,Some Renamed Title,https://imdb.com/x,Movie,7.0,100,2016\n'
          'tt999,7,2024-01-02,Fixture Series 3,https://imdb.com/y,TV Series,7.0,45,2013\n';
      final r = parseAnyImport(utf8.encode(csv), d, search);
      final byId = {for (final e in r.entries) e.id: e};
      expect(byId[108]!.rating, 8, reason: 'by IMDb id');
      final tvHit = d.titles.firstWhere((t) => t.display == 'Fixture Series 3');
      expect(
        byId[tvHit.id]!.rating,
        7,
        reason: 'by title, restricted to series',
      );
    },
  );

  test('older formats still import: plain lists and one-column CSVs', () {
    final r = parseAnyImport(
      utf8.encode('title\nFixture Anime 1\nFixture Movie 2\n'),
      d,
      search,
    );
    expect(r.entries.map((e) => e.id).toSet(), {1, 102});
    expect(
      parsePastedList('Fixture Anime 5 - 9', d, search).entries.single.rating,
      9,
    );
  });
}

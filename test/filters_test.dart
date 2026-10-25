// Per-kind filters (movies / TV / anime), state kept per kind, data-driven options, JSON round trip.
import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/engine/catalog_data.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';

void main() {
  final c = CatalogStore.open('test/fixtures/mixed.db').data;
  final rec = Recommender(c);
  final model = rec.fit(const []);

  /// ids of every title that passes the controls (cold start: ranking irrelevant, filters are hard).
  Set<int> passing(Controls ctl) => {
    for (final r in rec.recommend(model, ctl, count: 100, diversify: false))
      c.titles[r.idx].id,
  };

  group('movies', () {
    test('runtime range', () {
      final ctl = Controls(kinds: {'movie'})..active.runtimeMax = 120;
      expect(passing(ctl), {101, 102}); // 97 and 109 min
      ctl.active.runtimeMin = 130;
      ctl.active.runtimeMax = 150;
      expect(passing(ctl), {104, 105}); // 133, 145
    });

    test(
      'country, content rating, language, decade, director combine with AND across fields',
      () {
        final ctl = Controls(kinds: {'movie'})..active.countries.add('FR');
        expect(passing(ctl), {102, 104, 106, 108});
        ctl.active.ratings.add('R');
        expect(passing(ctl), {102, 108});
        ctl.active.languages.add('fr');
        ctl.active.decades.add('2000s');
        expect(passing(ctl), {102});
        expect(
          passing(
            Controls(kinds: {'movie'})..active.directors.add('Director A'),
          ),
          {102, 104, 106, 108},
        );
      },
    );
  });

  group('tv', () {
    test('seasons, status, creator/network, country', () {
      expect(passing(Controls(kinds: {'tv'})..active.maxSeasons = 2), {
        201,
        202,
      });
      expect(passing(Controls(kinds: {'tv'})..active.statuses.add('ongoing')), {
        201,
        203,
        205,
      });
      expect(passing(Controls(kinds: {'tv'})..active.statuses.add('ended')), {
        202,
        204,
        206,
      });
      expect(
        passing(Controls(kinds: {'tv'})..active.creators.add('Network Y')),
        {201, 203, 205},
      );
      expect(passing(Controls(kinds: {'tv'})..active.countries.add('GB')), {
        202,
        204,
        206,
      });
      expect(passing(Controls(kinds: {'tv'})..active.ratings.add('TV-MA')), {
        201,
        203,
        205,
      });
    });
  });

  group('anime', () {
    test('format, episodes, studio, source', () {
      expect(
        passing(Controls(kinds: {'anime'})..active.studios.add('Studio A')),
        {1, 3, 5, 7, 9},
      );
      expect(
        passing(Controls(kinds: {'anime'})..active.sources.add('ORIGINAL')),
        {3, 6, 9},
      );
      expect(
        passing(Controls(kinds: {'anime'})..active.formats.add('MOVIE')),
        isEmpty,
      );
      expect(
        passing(Controls(kinds: {'anime'})..active.formats.add('TV')).length,
        10,
      );
      expect(
        passing(Controls(kinds: {'anime'})..active.maxEpisodes = 6),
        isEmpty,
      );
      expect(
        passing(Controls(kinds: {'anime'})..active.maxEpisodes = 13).length,
        10,
      );
    });
  });

  group('scopes', () {
    test(
      'each kind keeps its own choices; "All" applies only the common filters',
      () {
        final ctl = Controls();
        ctl.kinds = {'movie'};
        ctl.active.runtimeMax = 100;
        ctl.kinds = {'tv'};
        ctl.active.maxSeasons = 1;
        ctl.kinds = {'anime'};
        ctl.active.studios.add('Studio B');
        // switching back restores everything
        ctl.kinds = {'movie'};
        expect(ctl.active.runtimeMax, 100);
        ctl.kinds = {'tv'};
        expect(ctl.active.maxSeasons, 1);
        ctl.kinds = {'anime'};
        expect(ctl.active.studios, {'Studio B'});
        // "All" (no kind or several kinds) ignores the kind-specific ones
        ctl.kinds = {};
        final all = passing(ctl);
        expect(all.length, 24);
        expect(
          all,
          contains(108),
        ); // 181 min movie passes: runtime filter is not active in "All"
        ctl.kinds = {'movie', 'tv'};
        expect(passing(ctl).length, 14);
        // common filters do apply everywhere
        ctl.active.yearMin = 2014;
        expect(
          passing(ctl).every((id) => c.titles[c.idToIdx[id]!].year! >= 2014),
          isTrue,
        );
        expect(ctl.activeCount(multiKindCatalog: true), 1 + 2);
      },
    );

    test('filters are hard constraints and the explanation says so', () {
      final ctl = Controls(kinds: {'movie'})..active.runtimeMax = 130;
      final recs = rec.recommend(model, ctl, count: 10);
      expect(recs, isNotEmpty);
      for (final r in recs) {
        final t = c.titles[r.idx];
        expect(t.kind, 'movie');
        expect(t.runtime! <= 130, isTrue, reason: t.title);
        expect(r.why, contains('Within your filters'));
        expect(r.why, contains('movies'));
        expect(r.why, contains('≤ 130 min'));
      }
      expect(Controls().describe(), '');
    });

    test('unknown values never slip through an active filter', () {
      // a catalog written before the filter columns existed has no runtimes: nothing can match
      final old = CatalogStore.open('test/fixtures/legacy_v2.db').data;
      expect(old.countWith('runtime', {}), 0);
      final r2 = Recommender(old);
      final ctl = Controls(kinds: {'movie'})..active.runtimeMax = 120;
      expect(r2.recommend(r2.fit(const []), ctl, count: 10), isEmpty);
    });
  });

  test(
    'status wording from TMDB and AniList maps onto ongoing / ended / upcoming',
    () {
      Show s(String? st) =>
          Show(idx: 0, id: 0, key: 'x', title: 't', status: st);
      expect([
        for (final x in [
          'Continuing',
          'RELEASING',
          'Returning Series',
          'In Production',
        ])
          s(x).statusGroup,
      ], everyElement('ongoing'));
      expect([
        for (final x in ['Ended', 'FINISHED', 'Canceled']) s(x).statusGroup,
      ], everyElement('ended'));
      expect([
        for (final x in ['Upcoming', 'NOT_YET_RELEASED']) s(x).statusGroup,
      ], everyElement('upcoming'));
      expect([
        s(null).statusGroup,
        s('???').statusGroup,
      ], everyElement('unknown'));
    },
  );

  group('data-driven options', () {
    test('options come from the selected kinds only', () {
      expect(c.optionCounts('director', {'movie'}).keys, {
        'Director A',
        'Director B',
      });
      expect(c.optionCounts('director', {'tv'}), isEmpty);
      expect(
        c.optionCounts('creator', {'tv'}).keys,
        containsAll(['Network X', 'Network Y']),
      );
      expect(c.optionCounts('studio', {'anime'}).keys, {
        'Studio A',
        'Studio B',
      });
      expect(c.optionCounts('studio', {'movie'}), isEmpty);
      expect(c.optionCounts('status', {'tv'}).keys, {'ongoing', 'ended'});
      expect(c.optionCounts('decade', {'movie'}).keys, {'2000s', '2010s'});
      expect(c.numericRange('runtime', {'movie'}), (97, 181));
      expect(c.numericRange('runtime', {'anime'}), (24, 24));
      expect(c.numericRange('seasons', {'tv'}), (1, 6));
      expect(c.countWith('director', {'anime'}), 0);
      expect(c.countWith('seasons', {'movie'}), 0);
    });
  });

  group('persistence format', () {
    test('Controls JSON round trip keeps every scope', () {
      final ctl = Controls(obscurity: 0.8);
      ctl.kinds = {'movie'};
      ctl.active.runtimeMax = 120;
      ctl.active.directors.add('Director A');
      ctl.kinds = {'tv'};
      ctl.active.statuses.add('ended');
      ctl.active.minScore = 7.5;
      final back = Controls.fromJson(ctl.toJson());
      expect(back.obscurity, 0.8);
      expect(back.kinds, {'tv'});
      expect(back.scopeFilters('movie').runtimeMax, 120);
      expect(back.scopeFilters('movie').directors, {'Director A'});
      expect(back.scopeFilters('tv').statuses, {'ended'});
      expect(back.scopeFilters('tv').minScore, 7.5);
    });

    test(
      'previously saved flat filters still load into the matching scope',
      () {
        final back = Controls.fromJson({
          'obscurity': 0.3,
          'formats': ['TV'],
          'maxEpisodes': 26,
          'moods': ['cozy'],
          'excludeWarnings': ['gore'],
          'categories': ['romance'],
          'kinds': <String>[],
          'minYear': 2010,
        });
        expect(back.scope, 'all');
        expect(back.moods, {'cozy'});
        expect(back.excludeWarnings, {'gore'});
        expect(back.categories, {'romance'});
        expect(back.minYear, 2010);
        expect(back.obscurity, 0.3);
      },
    );
  });
}

// Synthetic-persona checks for the recommender. Each persona has a hidden utility over the
// catalog's own dimensions/facets; we "watch and rate" 40 popular titles with it, ask the engine
// for recommendations and measure how good (by the hidden utility) and how non-generic they are.
//
// Run:  flutter test test/persona_test.dart   (needs catalog.db from tools/export.py)
import 'dart:math' as math;

import 'package:lodestar/engine/catalog_data.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:flutter_test/flutter_test.dart';

class Persona {
  final String name;
  final Map<String, double> dims;
  final Map<(String, String), double> facets; // (kind,value) -> weight
  final List<(String, String)> reasonFacets;
  Persona(this.name, this.dims, this.facets, this.reasonFacets);

  double utility(CatalogData c, int i) {
    var u = 0.0;
    dims.forEach((d, w) {
      final di = c.dimIndex(d);
      u += w * c.dimZ[i * CatalogData.dimCount + di];
    });
    for (final (fid, w) in c.facetsOf(i)) {
      final f = c.vocab[fid];
      final pw = facets[(f.kind, f.value)];
      if (pw != null && w >= 5) u += pw * 2.0;
    }
    return u;
  }
}

final personas = [
  Persona(
    'slow-burn romance + bittersweet endings, low fanservice',
    {
      'romance_slow_burn': 1.0,
      'romance_centrality': .7,
      'tearjerker': .3,
      'fanservice': -.9,
    },
    {
      ('ending_types', 'bittersweet'): 1.0,
      ('romance_dynamics', 'slow burn'): 1.0,
    },
    [('ending_types', 'bittersweet'), ('romance_dynamics', 'slow burn')],
  ),
  Persona(
    'dark psychological, high plot complexity',
    {
      'psychological_darkness': 1.0,
      'plot_complexity': 1.0,
      'mystery_intrigue': .6,
      'moral_ambiguity': .5,
      'cuteness': -.6,
      'wholesomeness': -.5,
    },
    {},
    [],
  ),
  Persona(
    'cozy slice-of-life comedy',
    {
      'slice_of_life': 1.0,
      'wholesomeness': 1.0,
      'comedy': .6,
      'cuteness': .5,
      'violence_gore': -.7,
      'tension_suspense': -.7,
    },
    {},
    [],
  ),
  Persona(
    'hype battle shounen with rivalries',
    {
      'action_intensity': 1.0,
      'hype': 1.0,
      'rivalry_competition': .8,
      'visual_spectacle_expected': .4,
      'romance_centrality': -.3,
    },
    {},
    [],
  ),
];

List<UserEntry> simulate(CatalogData c, Persona p, int seed, {int n = 40}) {
  final rnd = math.Random(seed);
  final popular = [
    for (var i = 0; i < c.n; i++)
      if (c.titles[i].kind == 'anime') i,
  ]..sort((a, b) => c.titles[b].popularity.compareTo(c.titles[a].popularity));
  final pool = popular.take(900).toList()..shuffle(rnd);
  final sample = pool.take(n).toList();
  final us = {for (final i in sample) i: p.utility(c, i)};
  final sorted = sample.toList()..sort((a, b) => us[a]!.compareTo(us[b]!));
  final entries = <UserEntry>[];
  for (var r = 0; r < sorted.length; r++) {
    final i = sorted[r];
    final pct = r / (sorted.length - 1);
    var rating = 3 + 7 * pct + (rnd.nextDouble() - .5);
    rating = ((rating.clamp(1.0, 10.0)) * 2).round() / 2;
    final reasons = <String>{};
    if (rating >= 8.5) {
      for (final (kind, value) in p.reasonFacets) {
        final fid = c.facetIndex['$kind|$value'];
        if (fid == null) continue;
        for (final (f, w) in c.facetsOf(i)) {
          if (f == fid && w >= 5) reasons.add('f:$kind|$value');
        }
      }
    }
    entries.add(
      UserEntry(
        id: c.titles[i].id,
        status: EntryStatus.watched,
        rating: rating,
        reasons: reasons,
      ),
    );
  }
  return entries;
}

void main() {
  late CatalogStore store;
  late CatalogData c;
  late Recommender rec;

  setUpAll(() {
    store = CatalogStore.open('catalog.db');
    c = store.data;
    rec = Recommender(c);
  });

  group('personas', () {
    for (final p in personas) {
      test(p.name, () {
        final entries = simulate(c, p, 7);
        final seenIds = entries.map((e) => e.id).toSet();
        final model = rec.fit(entries);
        final recs = rec.recommend(model, Controls(obscurity: 0.7), count: 30);
        expect(recs.length, 30);
        expect(recs.any((r) => seenIds.contains(c.titles[r.idx].id)), isFalse);

        // utility distribution over unwatched
        final us = <double>[];
        for (var i = 0; i < c.n; i++) {
          if (!seenIds.contains(c.titles[i].id)) us.add(p.utility(c, i));
        }
        final mu = us.reduce((a, b) => a + b) / us.length;
        final sd = math.sqrt(
          us.map((x) => (x - mu) * (x - mu)).reduce((a, b) => a + b) /
              us.length,
        );
        final topMean =
            recs.map((r) => p.utility(c, r.idx)).reduce((a, b) => a + b) /
            recs.length;
        final gap = (topMean - mu) / sd;
        final unpopular = recs.where((r) => c.obscurity[r.idx] > 0.5).length;
        final franchise = <int, int>{};
        for (final r in recs) {
          franchise[c.franchise[r.idx]] =
              (franchise[c.franchise[r.idx]] ?? 0) + 1;
        }
        final maxFranchise = franchise.values.reduce(math.max);
        // ignore: avoid_print
        print(
          '\n== ${p.name}\n   utility gap ${gap.toStringAsFixed(2)} sd, unpopular(top-50%-obscure) $unpopular/30, '
          'max per franchise $maxFranchise',
        );
        for (final r in recs.take(8)) {
          final t = c.titles[r.idx];
          // ignore: avoid_print
          print(
            '   ${r.match.toStringAsFixed(0)}%  ${t.display} (${t.format}, pop ${t.popularity})  ${r.why}',
          );
        }
        expect(
          gap,
          greaterThan(1.2),
          reason: 'top picks should score well on the hidden utility',
        );
        expect(
          unpopular,
          greaterThanOrEqualTo(8),
          reason: 'slider at 0.7 must surface unpopular titles',
        );
        expect(maxFranchise, lessThanOrEqualTo(3));
        expect(recs.every((r) => r.why.isNotEmpty), isTrue);
      });

      test('${p.name}: leave-one-out', () {
        final entries = simulate(c, p, 11);
        final liked = entries.where((e) => (e.rating ?? 0) >= 8.5).toList()
          ..shuffle(math.Random(3));
        final ranks = <double>[];
        for (final held in liked.take(8)) {
          final rest = entries.where((e) => e.id != held.id).toList();
          final model = rec.fit(rest);
          final ranked = rec.rankAll(
            model,
            controls: Controls(obscurity: 0.33, kinds: {'anime'}),
          ); // the persona only watched anime
          final hi = c.idToIdx[held.id]!;
          final pos = ranked.indexOf(hi);
          ranks.add(pos / ranked.length);
        }
        ranks.sort();
        final median = ranks[ranks.length ~/ 2];
        // ignore: avoid_print
        print(
          '   LOO ${p.name}: median held-out rank percentile ${(median * 100).toStringAsFixed(1)}% '
          '(random = 50%)',
        );
        expect(median, lessThan(0.12));
      });
    }
  });

  test('cold start: five titles give sensible output', () {
    final p = personas[0];
    final entries = simulate(
      c,
      p,
      5,
      n: 40,
    ).where((e) => (e.rating ?? 0) >= 9).take(5).toList();
    final model = rec.fit(entries);
    final recs = rec.recommend(model, Controls(), count: 20);
    expect(recs.length, 20);
    final us = [for (var i = 0; i < c.n; i++) p.utility(c, i)];
    final mu = us.reduce((a, b) => a + b) / us.length;
    final sd = math.sqrt(
      us.map((x) => (x - mu) * (x - mu)).reduce((a, b) => a + b) / us.length,
    );
    final topMean =
        recs.map((r) => us[r.idx]).reduce((a, b) => a + b) / recs.length;
    expect((topMean - mu) / sd, greaterThan(0.6));
  });

  test('slider moves results toward obscure titles', () {
    final p = personas[1];
    final model = rec.fit(simulate(c, p, 3));
    double avgObs(double slider) {
      final r = rec.recommend(model, Controls(obscurity: slider), count: 30);
      return r.map((x) => c.obscurity[x.idx]).reduce((a, b) => a + b) /
          r.length;
    }

    final lo = avgObs(0.0), hi = avgObs(1.0);
    // ignore: avoid_print
    print(
      '   avg obscurity slider 0 -> ${lo.toStringAsFixed(2)}, slider 1 -> ${hi.toStringAsFixed(2)}',
    );
    expect(hi, greaterThan(lo + 0.15));
  });
}

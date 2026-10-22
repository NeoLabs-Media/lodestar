import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/categories.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final c = CatalogStore.open('catalog.db').data;
  final rec = Recommender(c);

  test('every category rule resolves to real facets and has titles', () {
    for (final cat in categories) {
      for (final (kind, value, _) in cat.any) {
        expect(c.facetIndex['$kind|$value'], isNotNull, reason: '${cat.key}: $kind|$value missing in catalog');
      }
      final n = [for (var i = 0; i < c.n; i++) if (rec.inCategory(i, cat.key)) i].length;
      // ignore: avoid_print
      print('${cat.label}: $n titles');
      expect(n, greaterThan(30), reason: cat.key);
    }
  });

  test('category filter only returns members, any-of widens', () {
    final seed = [UserEntry(id: c.titles[0].id, status: EntryStatus.watched, rating: 9)];
    final m = rec.fit(seed);
    for (final key in ['romance', 'isekai']) {
      final r = rec.recommend(m, Controls(categories: {key}), count: 30);
      expect(r.length, 30);
      expect(r.every((x) => rec.inCategory(x.idx, key)), isTrue);
    }
    final both = rec.recommend(m, Controls(categories: {'romance', 'isekai'}), count: 60);
    expect(both.any((x) => rec.inCategory(x.idx, 'romance')), isTrue);
    expect(both.any((x) => rec.inCategory(x.idx, 'isekai')), isTrue);
  });
}

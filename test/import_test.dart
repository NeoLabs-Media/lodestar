import 'dart:convert';

import 'package:lodestar/data/importers.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/engine/search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ignoreTests();
  final store = CatalogStore.open('catalog.db');
  final c = store.data;
  final search = TitleSearch(c);

  test('crunchyexporter-style MAL XML (no MAL ids, no scores) imports unrated watched titles', () {
    const xml = '''<?xml version="1.0"?><myanimelist>
<myinfo><user_export_type>1</user_export_type></myinfo>
<anime><series_title>Frieren: Beyond Journey's End</series_title><my_status>Completed</my_status><my_score>0</my_score></anime>
<anime><series_title>Mushishi</series_title><my_status>Watching</my_status></anime>
<anime><series_title>Totally Unknown Zzyzx Show</series_title><my_status>Completed</my_status></anime>
</myanimelist>''';
    final r = parseAnyImport(utf8.encode(xml), c, search);
    expect(r.matched, 2);
    expect(r.unmatched, ['Totally Unknown Zzyzx Show']);
    expect(r.entries.every((e) => e.status == EntryStatus.watched && e.rating == null), isTrue);
  });

  test('history.json with episode records and series titles', () {
    final json = jsonEncode([
      {'series_title': 'Mushishi', 'episode_title': 'The Green Seat', 'episode': 1},
      {'series_title': 'Mushishi', 'episode_title': 'Fountain of Fertility', 'episode': 2},
      {'panel': {'episode_metadata': {'series_title': 'Monster', 'episode_number': 3}}},
    ]);
    final r = parseAnyImport(utf8.encode(json), c, search);
    expect(r.matched, 2);
  });

  test('csv / plain list', () {
    final r = parseAnyImport(utf8.encode('title\n"Monster",9\nMushishi\n'), c, search);
    expect(r.matched, 2);
  });
}

void ignoreTests() {
  test('ignored titles are excluded from the feed, give no taste signal and survive re-import', () {
    final store = CatalogStore.open('catalog.db');
    final c = store.data;
    final rec = Recommender(c);
    final a = c.titles[0], b = c.titles[1];
    final base = [UserEntry(id: a.id, status: EntryStatus.watched, rating: 9)];
    final withIgnored = [...base, UserEntry(id: b.id, status: EntryStatus.ignored)];
    final m1 = rec.fit(base), m2 = rec.fit(withIgnored);
    expect(m2.nSignals, m1.nSignals);
    expect(m2.seen.contains(1), isTrue);
    expect(m2.watched.contains(1), isFalse);
    expect(rec.recommend(m2, Controls(), count: 30).any((r) => r.idx == 1), isFalse);
  });
}

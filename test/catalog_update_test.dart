// Catalog migration (schema 1 -> 2) and delta updates; user data must never be touched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lodestar/app_state.dart';
import 'package:lodestar/data/user_store.dart';
import 'package:lodestar/engine/catalog_data.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/catalog_update.dart';
import 'package:lodestar/engine/recommender.dart';
import 'package:lodestar/platform/sql.dart' as sql;
import 'package:sqlite3/common.dart';

String fx(String name) => 'test/fixtures/$name.db';

File copyTo(Directory d, String fixture, String as) =>
    File(fx(fixture)).copySync('${d.path}/$as');

/// Everything in the catalog tables as comparable text (ordered), for idempotency checks.
String dump(CommonDatabase db) => [
  for (final t in ['title', 'rel', 'rec', 'facet_vocab', 'meta'])
    '$t: ${db.select('SELECT * FROM $t ORDER BY ${t == 'meta'
        ? 'key'
        : t == 'facet_vocab'
        ? 'fid'
        : '1,2,3'}').map((r) => r.values.toString()).join('|')}',
].join('\n');

Set<(String, String, double)> facetsOf(CatalogData c, int idx) => {
  for (final (fid, w) in c.facetsOf(idx))
    (c.vocab[fid].kind, c.vocab[fid].value, (w * 4).round() / 4),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lodestar_upd'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('schema migration', () {
    test(
      'a schema-1 catalog loads with defaults (kind, key, cover, links by anilist id)',
      () {
        final c = CatalogStore.open(fx('legacy_v1')).data;
        expect(c.n, 10);
        expect(c.kinds, {'anime'});
        final one = c.titles[c.idToIdx[1]!];
        expect(one.key, 'anilist:1001');
        expect(one.cover, 'https://img.example/1.jpg'); // falls back to pic
        expect(c.titles[c.idToIdx[9]!].key, 'mal:9009');
        expect(c.titles[c.idToIdx[10]!].key, 'id:10');
        expect(
          c.recs[c.idToIdx[1]!].map((e) => e.$1),
          containsAll([c.idToIdx[4], c.idToIdx[5]]),
        );
        expect(c.relations[c.idToIdx[1]!].first, (c.idToIdx[2]!, 'SEQUEL'));
      },
    );

    test(
      'migrateCatalog upgrades the file in place, idempotently, and loads identically',
      () {
        final f = copyTo(tmp, 'legacy_v1', 'cat.db');
        final before = CatalogStore.open(f.path).data;
        final db = sql.openFile(f.path);
        expect(schemaOf(db), 1);
        expect(migrateCatalog(db), isTrue);
        expect(schemaOf(db), 2);
        final once = dump(db);
        expect(migrateCatalog(db), isFalse);
        expect(dump(db), once);
        db.dispose();
        final after = CatalogStore.open(f.path).data;
        expect(
          [for (final t in after.titles) t.key],
          [for (final t in before.titles) t.key],
        );
        expect({for (final t in after.titles) t.kind}, {'anime'});
        expect(
          after.recs.map((l) => l.length).toList(),
          before.recs.map((l) => l.length).toList(),
        );
        expect(
          after.relations.map((l) => l.length).toList(),
          before.relations.map((l) => l.length).toList(),
        );
        expect(after.dimsRaw, before.dimsRaw);
      },
    );
  });

  group('delta merge', () {
    test('adds, updates and removes titles; remaps facet ids; keeps links', () {
      final f = copyTo(tmp, 'mixed_v2', 'cat.db');
      final target = sql.openFile(f.path);
      final delta = sql.openFile(fx('delta_ok'), readOnly: true);
      expect(isDeltaDb(delta), isTrue);
      expect(isDeltaDb(target), isFalse);
      final res = mergeDelta(target, delta);
      target.dispose();
      delta.dispose();
      expect(res.applied, isTrue, reason: res.message);
      expect((res.added, res.updated, res.removed), (3, 1, 1));
      expect(res.newIds..sort(), [11, 109, 207]);

      final c = CatalogStore.open(f.path).data;
      expect(c.n, 24 + 3 - 1);
      expect(c.idToIdx.containsKey(5), isFalse, reason: 'removed');
      for (final id in [11, 109, 207]) {
        expect(c.idToIdx.containsKey(id), isTrue);
      }
      final three = c.titles[c.idToIdx[3]!];
      expect(three.title, "Fixture Anime 3 (Director's Cut)");
      expect(three.popularity, 424242);
      expect(three.key, 'anilist:1003'); // identity unchanged

      // facets use the target's numbering: the new keyword was appended, shared ones re-mapped
      final movie9 = c.idToIdx[109]!;
      expect(
        facetsOf(c, movie9).map((e) => '${e.$1}|${e.$2}'),
        containsAll([
          'keyword|space opera',
          'keyword|time travel',
          'genre|sci-fi',
        ]),
      );
      expect(c.facetIndex.containsKey('keyword|space opera'), isTrue);
      final tvx = c.idToIdx[207]!;
      expect(
        facetsOf(c, tvx).map((e) => '${e.$1}|${e.$2}'),
        contains('keyword|heist'),
      );
      // vocab ids stay contiguous (the engine indexes arrays by fid)
      expect([
        for (final v in c.vocab) v.fid,
      ], List.generate(c.vocab.length, (i) => i));
      // df recounted over the merged catalog
      for (final v in c.vocab) {
        final n = [
          for (var i = 0; i < c.n; i++)
            if (c.facetsOf(i).any((e) => e.$1 == v.fid)) i,
        ].length;
        expect(v.df, n, reason: '${v.kind}|${v.value}');
      }
      // links of the new movie resolve to an existing title through its key
      expect(c.recs[movie9].map((e) => e.$1), contains(c.idToIdx[101]));
      expect(c.titles[movie9].kind, 'movie');
      expect(c.meta['snapshot'], '200.0');
      expect(c.meta['count'], '26');
      // re-quantised embedding is still a usable unit vector close to the delta's
      final e = c.emb.sublist(
        c.idToIdx[11]! * c.embDim,
        (c.idToIdx[11]! + 1) * c.embDim,
      );
      expect(e.fold<double>(0, (a, b) => a + b * b), closeTo(1, 1e-3));
    });

    test('is idempotent: applying the same delta again changes nothing', () {
      final f = copyTo(tmp, 'mixed_v2', 'cat.db');
      final target = sql.openFile(f.path);
      final delta = sql.openFile(fx('delta_ok'), readOnly: true);
      expect(mergeDelta(target, delta).applied, isTrue);
      final once = dump(target);
      final again = mergeDelta(target, delta);
      expect(again.applied, isFalse);
      expect(again.message, contains('up to date'));
      expect(dump(target), once);
      target.dispose();
      delta.dispose();
    });

    test(
      'rejects a delta that skips ahead; ignores a stale one; leaves the file untouched',
      () {
        final f = copyTo(tmp, 'mixed_v2', 'cat.db');
        final target = sql.openFile(f.path);
        final before = dump(target);
        for (final (name, applied, needle) in [
          ('delta_gap', false, 'full catalog'),
          ('delta_stale', false, 'up to date'),
        ]) {
          final d = sql.openFile(fx(name), readOnly: true);
          final r = mergeDelta(target, d);
          d.dispose();
          expect(r.applied, applied);
          expect(r.message, contains(needle));
        }
        expect(dump(target), before);
        target.dispose();
      },
    );

    test('also upgrades an installed schema-1 catalog on the way', () {
      final f = copyTo(tmp, 'legacy_v1', 'cat.db');
      final target = sql.openFile(f.path);
      final delta = sql.openFile(fx('delta_ok'), readOnly: true);
      final res = mergeDelta(target, delta);
      target.dispose();
      delta.dispose();
      expect(res.applied, isTrue, reason: res.message);
      final c = CatalogStore.open(f.path).data;
      expect(c.kinds, {'anime', 'movie', 'tv'});
      expect(c.idToIdx.containsKey(109), isTrue);
      expect(c.titles[c.idToIdx[1]!].key, 'anilist:1001');
    });

    test(
      'Python export + delta merge in Dart equals a full rebuild (cross-check)',
      () {
        final f = copyTo(tmp, 'pipeline_base', 'cat.db');
        final target = sql.openFile(f.path);
        final delta = sql.openFile(fx('pipeline_delta'), readOnly: true);
        final res = mergeDelta(target, delta);
        target.dispose();
        delta.dispose();
        expect(res.applied, isTrue, reason: res.message);
        expect((res.added, res.removed), (4, 1));
        final m = CatalogStore.open(f.path).data,
            full = CatalogStore.open(fx('pipeline_full')).data;
        expect(m.n, full.n);
        expect(m.kinds, {'anime', 'movie', 'tv'});
        for (final t in full.titles) {
          final mi = m.idToIdx[t.id]!, fi = t.idx;
          final mt = m.titles[mi];
          expect(
            (mt.key, mt.kind, mt.title, mt.cover, mt.year, mt.format),
            (t.key, t.kind, t.title, t.cover, t.year, t.format),
          );
          expect(
            facetsOf(m, mi),
            facetsOf(full, fi),
            reason: 'facets of ${t.title}',
          );
          for (var d = 0; d < CatalogData.dimCount; d++) {
            expect(
              m.dimsRaw[mi * CatalogData.dimCount + d],
              full.dimsRaw[fi * CatalogData.dimCount + d],
            );
          }
          expect(
            {for (final r in m.recs[mi]) m.titles[r.$1].key},
            {for (final r in full.recs[fi]) full.titles[r.$1].key},
          );
          var maxDiff = 0.0;
          for (var k = 0; k < m.embDim; k++) {
            maxDiff = [
              maxDiff,
              (m.emb[mi * m.embDim + k] - full.emb[fi * full.embDim + k]).abs(),
            ].reduce((a, b) => a > b ? a : b);
          }
          expect(maxDiff, lessThan(0.02));
        }
      },
    );
  });

  group('user data and the app', () {
    Future<AppState> appWith(Directory dir, List<UserEntry> entries) async {
      copyTo(dir, 'mixed_v2', 'catalog_custom.db');
      final u = UserStore.open('${dir.path}/user.db');
      u.setSetting('catalog_source', 'file');
      u.putAll(entries);
      u.close();
      final app = AppState();
      await app.init(supportDirOverride: dir.path);
      expect(app.error, isNull);
      return app;
    }

    test(
      'delta merge keeps user.db intact, shows the new-titles notice and is repeatable',
      () async {
        final app = await appWith(tmp, [
          const UserEntry(
            id: 1,
            status: EntryStatus.watched,
            rating: 9,
            reasons: {'g:romance'},
          ),
          const UserEntry(id: 3, status: EntryStatus.watched, rating: 7),
          const UserEntry(id: 5, status: EntryStatus.planned),
          const UserEntry(id: 101, status: EntryStatus.notInterested),
        ]);
        expect(app.data.n, 24);
        // keys were back-filled for entries written before keys existed
        expect(app.entries[app.data.idToIdx[1]!]!.key, 'anilist:1001');
        expect(
          app.users.all().every((e) => e.key != null || e.id == 5),
          isTrue,
        );
        final before = {
          for (final e in app.users.all())
            e.id: '${e.status}|${e.rating}|${e.reasons}|${e.key}',
        };

        final msg = await app.applyDeltaFile(File(fx('delta_ok')));
        expect(msg, contains('3 new titles'));
        expect(app.newTitlesNotice, 3);
        expect(app.newTitleIds..sort(), [11, 109, 207]);
        expect(app.data.n, 26);
        expect(app.entries[app.data.idToIdx[1]!]!.rating, 9);
        expect(app.entries[app.data.idToIdx[3]!]!.rating, 7);
        expect(
          app.entries.containsKey(app.data.idToIdx[5] ?? -1),
          isFalse,
          reason: 'title 5 left the catalog',
        );
        // the stored user rows are exactly as before, including the one for the removed title
        expect({
          for (final e in app.users.all())
            e.id: '${e.status}|${e.rating}|${e.reasons}|${e.key}',
        }, before);

        app.dismissNewTitlesNotice();
        expect(app.newTitlesNotice, 0);
        final again = await app.applyDeltaFile(File(fx('delta_ok')));
        expect(again, contains('up to date'));
        expect(app.newTitlesNotice, 0);
        expect(app.data.n, 26);
        // survives a restart (the merged catalog is the installed one)
        app.users.close();
        final b = AppState();
        await b.init(supportDirOverride: tmp.path);
        expect(b.data.n, 26);
        expect(b.entries.length, 3);

        // the merged titles can be recommended
        final r = b.recommender.recommend(
          b.model ?? b.recommender.fit(b.entries.values.toList()),
          Controls(),
          count: 30,
        );
        expect(
          r.any((x) => {11, 109, 207}.contains(b.data.titles[x.idx].id)),
          isTrue,
        );
      },
    );

    test('a rejected delta leaves the installed catalog usable', () async {
      final app = await appWith(tmp, const []);
      final msg = await app.applyDeltaFile(File(fx('delta_gap')));
      expect(msg, contains('full catalog'));
      expect(app.data.n, 24);
      expect(app.newTitlesNotice, 0);
    });

    test(
      'old user.db (no key column) is migrated in place without losing rows',
      () async {
        final path = '${tmp.path}/user.db';
        final db = sql.openFile(path);
        db.execute(
          '''CREATE TABLE entry(id INTEGER PRIMARY KEY, status TEXT NOT NULL, rating REAL,
        reasons TEXT NOT NULL DEFAULT '[]', note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL);
        CREATE TABLE setting(key TEXT PRIMARY KEY, value TEXT);''',
        );
        db.execute(
          "INSERT INTO entry VALUES(101,'watched',8.5,'[\"g:story\"]','nice',5)",
        );
        db.dispose();
        final u = UserStore.open(path);
        final e = u.all().single;
        expect([e.id, e.rating, e.note, e.key], [101, 8.5, 'nice', null]);
        expect(e.reasons, {'g:story'});
        u.put(e.withKey('tmdb:movie:5001'));
        expect(u.all().single.key, 'tmdb:movie:5001');
        u.close();
      },
    );

    test(
      'entries re-link by key when the catalog renumbers its internal ids',
      () async {
        final app = await appWith(tmp, [
          const UserEntry(
            id: 99001,
            key: 'tmdb:movie:5001',
            status: EntryStatus.watched,
            rating: 8,
          ), // id no longer exists
          const UserEntry(
            id: 99002,
            key: 'tmdb:tv:7001',
            status: EntryStatus.watched,
            rating: 6,
          ),
          const UserEntry(
            id: 99003,
            key: 'tmdb:movie:404404',
            status: EntryStatus.watched,
            rating: 5,
          ), // not in catalog
        ]);
        final movie = app.data.idToIdx[101]!, tv = app.data.idToIdx[201]!;
        expect(app.entries[movie]!.rating, 8);
        expect(app.entries[tv]!.rating, 6);
        final ids = app.users.all().map((e) => e.id).toSet();
        expect(ids, {
          101,
          201,
          99003,
        }, reason: 'rows re-pointed; unmatched one kept untouched');
      },
    );
  });
}

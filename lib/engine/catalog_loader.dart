import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqlite3/common.dart';

import '../platform/sql.dart' as sql;

import 'catalog_data.dart';

/// Loads catalog.db (produced by tools/export.py) into [CatalogData]; keeps the DB open for
/// lazy per-title detail lookups. No Flutter imports so it also works in plain `dart test`.
class CatalogStore {
  final CommonDatabase db;
  final CatalogData data;
  final _detailCache = <int, Map<String, dynamic>>{};

  CatalogStore._(this.db, this.data);

  /// Native: open a catalog.db file.
  static CatalogStore open(String path) =>
      fromDb(sql.openFile(path, readOnly: true));

  /// Web: open a catalog.db held in memory.
  static Future<CatalogStore> openBytes(Uint8List bytes) async =>
      fromDb(await sql.openBytes(bytes));

  static CatalogStore fromDb(CommonDatabase db) {
    final meta = <String, String>{
      for (final r in db.select('SELECT key,value FROM meta'))
        r['key'] as String: r['value'] as String,
    };
    final dimNames = (jsonDecode(meta['dims']!) as List).cast<String>();
    final embDim = int.parse(meta['emb_dim']!);
    final vocabRows = db.select(
      'SELECT fid,kind,value,df FROM facet_vocab ORDER BY fid',
    );
    final vocab = [
      for (final r in vocabRows)
        FacetDef(
          r['fid'] as int,
          r['kind'] as String,
          r['value'] as String,
          r['df'] as int,
        ),
    ];

    // schema 1 (anime only) and schema 2 (multi-media) catalogs both load; missing columns get defaults
    final cols = {
      for (final r in db.select('PRAGMA table_info(title)'))
        r['name'] as String,
    };
    String col(String name, [String fallback = 'NULL']) =>
        cols.contains(name) ? name : '$fallback AS $name';
    final rows = db.select(
      'SELECT id,${col('key')},${col('kind', "'anime'")},anilist,mal,${col('tmdb')},${col('imdb')},'
      'title,title_en,syn,year,season,format,episodes,status,${col('release_date')},popularity,mean_score,tier,quality,'
      'thumb,pic,${col('cover')},pitch,oneliner,ending,genres,emb,dims,facets FROM title ORDER BY id',
    );
    final n = rows.length;
    final titles = <Show>[];
    final emb = Float32List(n * embDim);
    final dims = Uint8List(n * CatalogData.dimCount);
    final facetOff = Int32List(n + 1);
    final fIds = <int>[];
    final fW = <int>[];
    var i = 0;
    for (final r in rows) {
      titles.add(
        Show(
          idx: i,
          id: r['id'] as int,
          anilist: r['anilist'] as int?,
          mal: r['mal'] as int?,
          tmdb: r['tmdb'] as int?,
          imdb: r['imdb'] as String?,
          key:
              (r['key'] as String?) ??
              _legacyKey(
                r['id'] as int,
                r['anilist'] as int?,
                r['mal'] as int?,
              ),
          kind: (r['kind'] as String?) ?? 'anime',
          releaseDate: r['release_date'] as String?,
          coverUrl: r['cover'] as String?,
          title: r['title'] as String? ?? '?',
          titleEn: r['title_en'] as String?,
          synonyms: ((r['syn'] as String?) ?? '')
              .split('\n')
              .where((s) => s.isNotEmpty)
              .toList(),
          year: r['year'] as int?,
          season: r['season'] as String?,
          format: r['format'] as String?,
          status: r['status'] as String?,
          episodes: r['episodes'] as int?,
          popularity: (r['popularity'] as int?) ?? 0,
          meanScore: (r['mean_score'] as num?)?.toDouble(),
          tier: r['tier'] as String? ?? 'compact',
          quality: (r['quality'] as num?)?.toDouble(),
          thumb: r['thumb'] as String?,
          pic: r['pic'] as String?,
          pitch: r['pitch'] as String? ?? '',
          oneliner: r['oneliner'] as String? ?? '',
          ending: r['ending'] as String?,
          genres: ((r['genres'] as String?) ?? '')
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList(),
        ),
      );
      final scale = double.parse(meta['emb_scale']!);
      final q = (r['emb'] as Uint8List);
      var norm = 0.0;
      for (var k = 0; k < embDim; k++) {
        final v = (q[k] > 127 ? q[k] - 256 : q[k]) / scale;
        emb[i * embDim + k] = v;
        norm += v * v;
      }
      norm = norm == 0 ? 1 : 1 / math.sqrt(norm);
      for (var k = 0; k < embDim; k++) {
        emb[i * embDim + k] *= norm;
      }
      dims.setRange(
        i * CatalogData.dimCount,
        (i + 1) * CatalogData.dimCount,
        r['dims'] as Uint8List,
      );
      final fb = r['facets'] as Uint8List;
      for (var k = 0; k + 2 < fb.length; k += 3) {
        fIds.add(fb[k] | (fb[k + 1] << 8));
        fW.add(fb[k + 2]);
      }
      facetOff[i + 1] = fIds.length;
      i++;
    }
    final idx = {for (final t in titles) t.id: t.idx};
    final keyIdx = {for (final t in titles) t.key: t.idx};
    String otherKey(Row r) {
      final k = r['other_key'];
      if (k != null) return k as String;
      return 'anilist:${r['other_anilist']}'; // schema 1
    }

    String linkCols(String table) =>
        {
          for (final r in db.select('PRAGMA table_info($table)'))
            r['name'] as String,
        }.contains('other_key')
        ? 'other_key'
        : 'other_anilist';
    final relations = List.generate(n, (_) => <(int, String)>[]);
    for (final r in db.select('SELECT id,${linkCols('rel')},type FROM rel')) {
      final a = idx[r['id'] as int];
      final b = keyIdx[otherKey(r)];
      if (a != null && b != null)
        relations[a].add((b, r['type'] as String? ?? ''));
    }
    final recs = List.generate(n, (_) => <(int, int)>[]);
    for (final r in db.select('SELECT id,${linkCols('rec')},rating FROM rec')) {
      final a = idx[r['id'] as int];
      final b = keyIdx[otherKey(r)];
      if (a != null && b != null) {
        final rating = (r['rating'] as int?) ?? 1;
        recs[a].add((b, rating));
        recs[b].add((a, rating));
      }
    }
    final data = CatalogData(
      titles: titles,
      embDim: embDim,
      emb: emb,
      dimsRaw: dims,
      dimNames: dimNames,
      facetOff: facetOff,
      facetIds: Uint16List.fromList(fIds),
      facetW: Uint8List.fromList(fW),
      vocab: vocab,
      relations: relations,
      recs: recs,
      meta: meta,
    );
    return CatalogStore._(db, data);
  }

  /// Decoded detail JSON (characters, relationships, similar titles, full summary…).
  Map<String, dynamic> detail(int idx) {
    return _detailCache.putIfAbsent(idx, () {
      final r = db.select('SELECT detail FROM title WHERE id=?', [
        data.titles[idx].id,
      ]);
      if (r.isEmpty) return <String, dynamic>{};
      final bytes = const ZLibDecoder().decodeBytes(
        r.first['detail'] as Uint8List,
      );
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    });
  }

  void close() => db.dispose();
}

/// Key for catalogs written before schema 2.
String _legacyKey(int id, int? anilist, int? mal) => anilist != null
    ? 'anilist:$anilist'
    : (mal != null ? 'mal:$mal' : 'id:$id');

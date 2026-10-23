import 'dart:typed_data';

import 'package:sqlite3/common.dart';

/// Result of applying a catalog delta.
class DeltaResult {
  final bool applied;
  final String message; // human readable outcome (also for rejections / no-ops)
  final int added, updated, removed;
  final List<int> newIds;
  final double from, to;
  const DeltaResult(this.applied, this.message,
      {this.added = 0, this.updated = 0, this.removed = 0, this.newIds = const [], this.from = 0, this.to = 0});
}

const supportedSchema = 2;
const _deltaFormat = 1;

bool _hasTable(CommonDatabase db, String name) =>
    db.select("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name]).isNotEmpty;

Map<String, String> _meta(CommonDatabase db, String table) => {
      for (final r in db.select('SELECT key,value FROM $table')) r['key'] as String: '${r['value']}'
    };

/// True when [db] is a `catalog_delta` file (has a delta_meta table) rather than a full catalog.
bool isDeltaDb(CommonDatabase db) => _hasTable(db, 'delta_meta');

int schemaOf(CommonDatabase db) => int.tryParse(_meta(db, 'meta')['schema'] ?? '') ?? 0;

/// Upgrades a schema-1 catalog (anime only, rel/rec keyed by AniList id) to schema 2 in place.
/// Idempotent; returns true when something was changed.
bool migrateCatalog(CommonDatabase db) {
  if (schemaOf(db) >= supportedSchema) return false;
  db.execute('BEGIN');
  try {
    final have = {for (final r in db.select('PRAGMA table_info(title)')) r['name'] as String};
    const adds = {
      'key': 'TEXT',
      'kind': "TEXT DEFAULT 'anime'",
      'tmdb': 'INT',
      'imdb': 'TEXT',
      'release_date': 'TEXT',
      'cover': 'TEXT',
      'updated_at': 'REAL',
    };
    adds.forEach((c, t) {
      if (!have.contains(c)) db.execute('ALTER TABLE title ADD COLUMN $c $t');
    });
    db.execute("UPDATE title SET kind='anime' WHERE kind IS NULL");
    db.execute("UPDATE title SET key = CASE WHEN anilist IS NOT NULL THEN 'anilist:'||anilist "
        "WHEN mal IS NOT NULL THEN 'mal:'||mal ELSE 'id:'||id END WHERE key IS NULL");
    db.execute('UPDATE title SET cover = COALESCE(pic, thumb) WHERE cover IS NULL');
    for (final t in const ['rel', 'rec']) {
      final cols = {for (final r in db.select('PRAGMA table_info($t)')) r['name'] as String};
      if (cols.contains('other_key')) continue;
      final extra = t == 'rel' ? 'type TEXT' : 'rating INT';
      final extraCol = t == 'rel' ? 'type' : 'rating';
      db.execute('CREATE TABLE ${t}_v2(id INT, other_key TEXT, $extra)');
      db.execute("INSERT INTO ${t}_v2 SELECT id, 'anilist:'||other_anilist, $extraCol FROM $t");
      db.execute('DROP TABLE $t');
      db.execute('ALTER TABLE ${t}_v2 RENAME TO $t');
      db.execute('CREATE INDEX IF NOT EXISTS ${t}_id ON $t(id)');
    }
    db.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('schema','$supportedSchema')");
    db.execute('COMMIT');
    return true;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Merges a `catalog_delta` file into the installed catalog [target] (insert-or-replace by title id,
/// facet vocabularies merged by (kind, value), embeddings re-quantised to the target's scale).
/// Never touches user data. Idempotent: re-applying the same delta is a no-op.
DeltaResult mergeDelta(CommonDatabase target, CommonDatabase delta) {
  if (!isDeltaDb(delta)) return const DeltaResult(false, 'This file is not a catalog update.');
  final dm = _meta(delta, 'delta_meta');
  if (int.tryParse(dm['format'] ?? '') != _deltaFormat) {
    return const DeltaResult(false, 'Unsupported update format — please update the app.');
  }
  final from = double.tryParse(dm['from'] ?? '') ?? 0, to = double.tryParse(dm['to'] ?? '') ?? 0;
  migrateCatalog(target);
  final tm = _meta(target, 'meta'), xm = _meta(delta, 'meta');
  final installed = double.tryParse(tm['snapshot'] ?? '') ?? 0;
  if (to <= installed) {
    return DeltaResult(false, 'Already up to date.', from: from, to: to);
  }
  if (from > installed) {
    return DeltaResult(false,
        'This update continues from a newer catalog than the one installed — a full catalog is needed first.',
        from: from, to: to);
  }
  if (tm['dims'] != xm['dims'] || tm['emb_dim'] != xm['emb_dim']) {
    return const DeltaResult(false, 'The update was built with a different feature layout than this catalog.');
  }
  final scaleT = double.parse(tm['emb_scale']!), scaleD = double.parse(xm['emb_scale']!);

  // facet vocabulary: map delta fids -> target fids, appending unseen (kind, value) pairs
  final targetVocab = <String, int>{};
  var nextFid = 0;
  for (final r in target.select('SELECT fid,kind,value FROM facet_vocab')) {
    targetVocab['${r['kind']}|${r['value']}'] = r['fid'] as int;
    if ((r['fid'] as int) >= nextFid) nextFid = (r['fid'] as int) + 1;
  }
  final remap = <int, int>{};
  final newVocab = <(int, String, String)>[];
  for (final r in delta.select('SELECT fid,kind,value FROM facet_vocab')) {
    final k = '${r['kind']}|${r['value']}';
    var f = targetVocab[k];
    if (f == null) {
      f = nextFid++;
      targetVocab[k] = f;
      newVocab.add((f, r['kind'] as String, r['value'] as String));
    }
    remap[r['fid'] as int] = f;
  }

  final tCols = {for (final r in target.select('PRAGMA table_info(title)')) r['name'] as String};
  final rows = delta.select('SELECT * FROM title');
  final cols = [for (final c in rows.columnNames) if (tCols.contains(c)) c];
  final insert = target.prepare('INSERT OR REPLACE INTO title(${cols.join(',')}) VALUES(${List.filled(cols.length, '?').join(',')})');
  final delRel = target.prepare('DELETE FROM rel WHERE id=?');
  final delRec = target.prepare('DELETE FROM rec WHERE id=?');
  final addRel = target.prepare('INSERT INTO rel(id,other_key,type) VALUES(?,?,?)');
  final addRec = target.prepare('INSERT INTO rec(id,other_key,rating) VALUES(?,?,?)');
  final newIds = <int>[];
  var updated = 0, removed = 0;
  target.execute('BEGIN');
  try {
    for (final v in newVocab) {
      target.execute('INSERT INTO facet_vocab(fid,kind,value,df) VALUES(?,?,?,0)', [v.$1, v.$2, v.$3]);
    }
    for (final r in rows) {
      final id = r['id'] as int;
      final existed = target.select('SELECT 1 FROM title WHERE id=?', [id]).isNotEmpty;
      final values = <Object?>[];
      for (final c in cols) {
        final v = r[c];
        if (c == 'facets' && v is Uint8List) {
          values.add(_remapFacets(v, remap));
        } else if (c == 'emb' && v is Uint8List) {
          values.add(_requantise(v, scaleD, scaleT));
        } else {
          values.add(v);
        }
      }
      insert.execute(values);
      existed ? updated++ : newIds.add(id);
      delRel.execute([id]);
      delRec.execute([id]);
      for (final x in delta.select('SELECT other_key,type FROM rel WHERE id=?', [id])) {
        addRel.execute([id, x['other_key'], x['type']]);
      }
      for (final x in delta.select('SELECT other_key,rating FROM rec WHERE id=?', [id])) {
        addRec.execute([id, x['other_key'], x['rating']]);
      }
    }
    if (_hasTable(delta, 'removed')) {
      for (final r in delta.select('SELECT id FROM removed')) {
        final id = r['id'] as int;
        if (target.select('SELECT 1 FROM title WHERE id=?', [id]).isNotEmpty) removed++;
        target.execute('DELETE FROM title WHERE id=?', [id]);
        delRel.execute([id]);
        delRec.execute([id]);
      }
    }
    // document frequencies drive the idf weights: recount over the merged catalog
    final df = <int, int>{};
    for (final r in target.select('SELECT facets FROM title')) {
      final b = r['facets'] as Uint8List?;
      if (b == null) continue;
      for (var i = 0; i + 2 < b.length; i += 3) {
        final f = b[i] | (b[i + 1] << 8);
        df[f] = (df[f] ?? 0) + 1;
      }
    }
    final setDf = target.prepare('UPDATE facet_vocab SET df=? WHERE fid=?');
    for (final fid in targetVocab.values) {
      setDf.execute([df[fid] ?? 0, fid]);
    }
    setDf.dispose();
    final count = target.select('SELECT COUNT(*) c FROM title').first['c'];
    final up = target.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)");
    up.execute(['snapshot', '$to']);
    up.execute(['count', '$count']);
    up.execute(['built_at', dm['built_at'] ?? tm['built_at'] ?? '']);
    up.dispose();
    target.execute('COMMIT');
  } catch (_) {
    target.execute('ROLLBACK');
    rethrow;
  } finally {
    insert.dispose();
    delRel.dispose();
    delRec.dispose();
    addRel.dispose();
    addRec.dispose();
  }
  final msg = '${newIds.length} new titles, $updated updated${removed > 0 ? ', $removed removed' : ''}.';
  return DeltaResult(true, msg,
      added: newIds.length, updated: updated, removed: removed, newIds: newIds, from: from, to: to);
}

Uint8List _remapFacets(Uint8List b, Map<int, int> remap) {
  final out = BytesBuilder();
  for (var i = 0; i + 2 < b.length; i += 3) {
    final f = remap[b[i] | (b[i + 1] << 8)];
    if (f == null) continue;
    out.add([f & 255, f >> 8, b[i + 2]]);
  }
  return out.toBytes();
}

Uint8List _requantise(Uint8List b, double fromScale, double toScale) {
  if (fromScale == toScale) return b;
  final out = Uint8List(b.length);
  for (var i = 0; i < b.length; i++) {
    final q = (b[i] > 127 ? b[i] - 256 : b[i]) / fromScale * toScale;
    out[i] = q.round().clamp(-127, 127) & 255;
  }
  return out;
}

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../engine/recommender.dart';
import 'user_store.dart';

UserStore openUserStore(String path) => SqliteUserStore._(sqlite3.open(path)..execute('''
      CREATE TABLE IF NOT EXISTS entry(
        id INTEGER PRIMARY KEY,
        status TEXT NOT NULL,
        rating REAL,
        reasons TEXT NOT NULL DEFAULT '[]',
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT);
    ''')..migrate());

extension on Database {
  /// Additive migration: entries gain a stable title `key` (kind + external id). Existing rows keep
  /// working through their numeric id and are back-filled with a key when the catalog is loaded.
  void migrate() {
    final cols = {for (final r in select('PRAGMA table_info(entry)')) r['name'] as String};
    if (!cols.contains('key')) execute('ALTER TABLE entry ADD COLUMN key TEXT');
  }
}

class SqliteUserStore implements UserStore {
  final Database db;
  SqliteUserStore._(this.db);

  @override
  List<UserEntry> all() => [
        for (final r in db.select('SELECT id,key,status,rating,reasons,note,updated_at FROM entry'))
          UserEntry(
            id: r['id'] as int,
            key: r['key'] as String?,
            status: EntryStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => EntryStatus.watched),
            rating: (r['rating'] as num?)?.toDouble(),
            reasons: (jsonDecode(r['reasons'] as String) as List).cast<String>().toSet(),
            note: r['note'] as String,
            updatedAt: r['updated_at'] as int,
          )
      ];

  @override
  void put(UserEntry e) => db.execute(
      'INSERT OR REPLACE INTO entry(id,key,status,rating,reasons,note,updated_at) VALUES(?,?,?,?,?,?,?)',
      [e.id, e.key, e.status.name, e.rating, jsonEncode(e.reasons.toList()), e.note, e.updatedAt]);

  @override
  void putAll(Iterable<UserEntry> entries) {
    db.execute('BEGIN');
    try {
      for (final e in entries) {
        put(e);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  void clear() => db.execute('DELETE FROM entry');

  @override
  void relink(int oldId, int newId) => db.execute('UPDATE OR REPLACE entry SET id=? WHERE id=?', [newId, oldId]);

  @override
  void remove(int id) => db.execute('DELETE FROM entry WHERE id=?', [id]);

  @override
  String? setting(String key) {
    final r = db.select('SELECT value FROM setting WHERE key=?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  @override
  void setSetting(String key, String value) =>
      db.execute('INSERT OR REPLACE INTO setting(key,value) VALUES(?,?)', [key, value]);

  @override
  void close() => db.dispose();
}

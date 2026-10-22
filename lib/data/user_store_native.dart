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
    '''));

class SqliteUserStore implements UserStore {
  final Database db;
  SqliteUserStore._(this.db);

  @override
  List<UserEntry> all() => [
        for (final r in db.select('SELECT id,status,rating,reasons,note,updated_at FROM entry'))
          UserEntry(
            id: r['id'] as int,
            status: EntryStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => EntryStatus.watched),
            rating: (r['rating'] as num?)?.toDouble(),
            reasons: (jsonDecode(r['reasons'] as String) as List).cast<String>().toSet(),
            note: r['note'] as String,
            updatedAt: r['updated_at'] as int,
          )
      ];

  @override
  void put(UserEntry e) => db.execute(
      'INSERT OR REPLACE INTO entry(id,status,rating,reasons,note,updated_at) VALUES(?,?,?,?,?,?)',
      [e.id, e.status.name, e.rating, jsonEncode(e.reasons.toList()), e.note, e.updatedAt]);

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

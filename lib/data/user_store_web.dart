import 'dart:convert';

import 'package:web/web.dart' as web;

import '../engine/recommender.dart';
import 'user_store.dart';

UserStore openUserStore(String path) => WebUserStore();

/// Browser storage for the web build. localStorage (not cookies): cookies are capped at ~4 KB and are
/// sent with every request, which would break a library of hundreds of ratings; localStorage is just as
/// local, per-browser and persistent, but holds megabytes and never leaves the device.
class WebUserStore implements UserStore {
  static const _entriesKey = 'atlas.entries.v1';
  static const _settingsKey = 'atlas.settings.v1';
  late Map<String, dynamic> _entries;
  late Map<String, dynamic> _settings;

  WebUserStore() {
    _entries = _read(_entriesKey);
    _settings = _read(_settingsKey);
  }

  Map<String, dynamic> _read(String key) {
    try {
      final raw = web.window.localStorage.getItem(key);
      if (raw != null && raw.isNotEmpty)
        return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    return {};
  }

  void _flush() {
    web.window.localStorage.setItem(_entriesKey, jsonEncode(_entries));
    web.window.localStorage.setItem(_settingsKey, jsonEncode(_settings));
  }

  @override
  List<UserEntry> all() => [
    for (final e in _entries.entries)
      UserEntry(
        id: int.parse(e.key),
        key: e.value['k'] as String?,
        status: EntryStatus.values.firstWhere(
          (s) => s.name == e.value['s'],
          orElse: () => EntryStatus.watched,
        ),
        rating: (e.value['r'] as num?)?.toDouble(),
        reasons: ((e.value['x'] as List?) ?? const []).cast<String>().toSet(),
        note: (e.value['n'] as String?) ?? '',
        updatedAt: (e.value['u'] as num?)?.toInt() ?? 0,
      ),
  ];

  void _set(UserEntry e) => _entries['${e.id}'] = {
    if (e.key != null) 'k': e.key,
    's': e.status.name,
    if (e.rating != null) 'r': e.rating,
    if (e.reasons.isNotEmpty) 'x': e.reasons.toList(),
    if (e.note.isNotEmpty) 'n': e.note,
    'u': e.updatedAt,
  };

  @override
  void put(UserEntry e) {
    _set(e);
    _flush();
  }

  @override
  void putAll(Iterable<UserEntry> entries) {
    for (final e in entries) {
      _set(e);
    }
    _flush();
  }

  @override
  void clear() {
    _entries.clear();
    _flush();
  }

  @override
  void relink(int oldId, int newId) {
    final v = _entries.remove('$oldId');
    if (v != null) _entries['$newId'] = v;
    _flush();
  }

  @override
  void remove(int id) {
    _entries.remove('$id');
    _flush();
  }

  @override
  String? setting(String key) => _settings[key] as String?;

  @override
  void setSetting(String key, String value) {
    _settings[key] = value;
    _flush();
  }

  @override
  void close() {}
}

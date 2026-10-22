import 'dart:convert';

import '../engine/catalog_data.dart';
import '../engine/recommender.dart';
import '../engine/search.dart';

const backupFormat = 'lodestar-backup';

/// Portable JSON backup of everything the user entered. Titles carry their AniList/MAL ids and
/// names too, so a backup still restores if the catalog is later swapped for one with other ids.
String buildBackup(List<UserEntry> entries, CatalogData c, {Map<String, String> settings = const {}}) {
  final rows = <Map<String, dynamic>>[];
  for (final e in entries) {
    final i = c.idToIdx[e.id];
    final t = i == null ? null : c.titles[i];
    rows.add({
      'id': e.id,
      if (t?.anilist != null) 'anilist': t!.anilist,
      if (t?.mal != null) 'mal': t!.mal,
      if (t != null) 'title': t.title,
      'status': e.status.name,
      'rating': e.rating,
      'reasons': e.reasons.toList()..sort(),
      'note': e.note,
      'updated_at': e.updatedAt,
    });
  }
  return const JsonEncoder.withIndent('  ').convert({
    'format': backupFormat,
    'version': 1,
    'exported_at': DateTime.now().toIso8601String(),
    'catalog': c.meta['built_at'],
    'settings': settings,
    'entries': rows,
  });
}

class RestoreResult {
  final List<UserEntry> entries = [];
  final List<String> unmatched = [];
  Map<String, String> settings = {};
}

RestoreResult parseBackup(String json, CatalogData c, TitleSearch search) {
  final m = jsonDecode(json);
  if (m is! Map || m['format'] != backupFormat) {
    throw const FormatException('This is not an Lodestar backup file.');
  }
  final res = RestoreResult();
  res.settings = {for (final e in ((m['settings'] as Map?) ?? {}).entries) '${e.key}': '${e.value}'};
  final byAnilist = c.anilistToIdx;
  final byMal = {
    for (final t in c.titles)
      if (t.mal != null) t.mal!: t.idx
  };
  for (final r in (m['entries'] as List).cast<Map>()) {
    int? idx = c.idToIdx[r['id']];
    idx ??= r['anilist'] == null ? null : byAnilist[r['anilist']];
    idx ??= r['mal'] == null ? null : byMal[r['mal']];
    idx ??= r['title'] == null ? null : search.bestMatch('${r['title']}');
    if (idx == null) {
      res.unmatched.add('${r['title'] ?? r['id']}');
      continue;
    }
    res.entries.add(UserEntry(
      id: c.titles[idx].id,
      status: EntryStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => EntryStatus.watched),
      rating: (r['rating'] as num?)?.toDouble(),
      reasons: ((r['reasons'] as List?) ?? const []).cast<String>().toSet(),
      note: '${r['note'] ?? ''}',
      updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
    ));
  }
  return res;
}

import 'dart:convert';
import 'package:archive/archive.dart';

import 'package:xml/xml.dart';

import '../engine/catalog_data.dart';
import 'crunchyroll.dart';
import '../engine/recommender.dart';
import '../engine/search.dart';

class ImportResult {
  final List<UserEntry> entries = [];
  final Map<int, String> hints = {}; // catalog idx -> e.g. "12 episodes on Crunchyroll"
  final List<String> unmatched = [];
  int get matched => entries.length;
}

/// Pasted list: one title per line, optional trailing rating ("Title - 9", "Title, 8.5", "Title | 10").
ImportResult parsePastedList(String text, CatalogData c, TitleSearch search) {
  final res = ImportResult();
  final seen = <int>{};
  final re = RegExp(r'^(.*?)(?:\s*[-–—:|,;]\s*|\s+)(10|\d(?:[.,]5)?)\s*(?:/\s*10)?\s*$');
  for (var line in const LineSplitter().convert(text)) {
    line = line.trim().replaceAll(RegExp(r'^[\-*•\d]+[.)]\s+'), '');
    if (line.isEmpty) continue;
    double? rating;
    var title = line;
    final m = re.firstMatch(line);
    if (m != null && m.group(1)!.trim().isNotEmpty) {
      final cand = double.tryParse(m.group(2)!.replaceAll(',', '.'));
      // a bare trailing number is a rating only if the stripped title still matches something
      if (cand != null && search.bestMatch(m.group(1)!) != null) {
        rating = cand;
        title = m.group(1)!;
      }
    }
    final idx = search.bestMatch(title);
    if (idx == null) {
      res.unmatched.add(line);
    } else if (seen.add(idx)) {
      res.entries.add(UserEntry(id: c.titles[idx].id, status: EntryStatus.watched, rating: rating));
    }
  }
  return res;
}

/// MyAnimeList export (XML or XML.gz).
ImportResult parseMalXml(List<int> bytes, CatalogData c, TitleSearch search) {
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    bytes = GZipDecoder().decodeBytes(bytes);
  }
  final doc = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  final res = ImportResult();
  final byMal = {
    for (final t in c.titles)
      if (t.mal != null) t.mal!: t.idx
  };
  final seen = <int>{};
  for (final a in doc.findAllElements('anime')) {
    String g(String n) => a.getElement(n)?.innerText.trim() ?? '';
    final status = g('my_status').toLowerCase();
    final score = double.tryParse(g('my_score')) ?? 0;
    final malId = int.tryParse(g('series_animedb_id'));
    final name = g('series_title');
    var idx = malId == null ? null : byMal[malId];
    idx ??= name.isEmpty ? null : search.bestMatch(name, kind: 'anime');
    if (idx == null) {
      res.unmatched.add(name.isEmpty ? '(MAL id $malId)' : name);
      continue;
    }
    if (!seen.add(idx)) continue;
    final id = c.titles[idx].id;
    if (status.contains('plan')) {
      res.entries.add(UserEntry(id: id, status: EntryStatus.planned));
    } else if (status.contains('drop')) {
      res.entries.add(UserEntry(id: id, status: EntryStatus.watched, rating: score > 0 ? score : 4));
    } else {
      res.entries.add(UserEntry(id: id, status: EntryStatus.watched, rating: score > 0 ? score : null));
    }
  }
  return res;
}

/// Crunchyroll exports: crunchyexporter-cli writes a MAL-style XML (`data/animelist.xml`) and
/// `data/history.json`; this also accepts any JSON/CSV/text with series titles.
ImportResult parseAnyImport(List<int> bytes, CatalogData c, TitleSearch search) {
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) bytes = GZipDecoder().decodeBytes(bytes);
  final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
  if (text.startsWith('<')) return parseMalXml(bytes, c, search);
  final titles = <String>[];
  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      _collectTitles(jsonDecode(text), titles);
    } catch (_) {}
  }
  if (titles.isEmpty) {
    // CSV / plain text: first column or the whole line
    for (final line in const LineSplitter().convert(text)) {
      var l = line.trim();
      if (l.isEmpty) continue;
      if (l.startsWith('"')) {
        final end = l.indexOf('"', 1);
        l = end > 0 ? l.substring(1, end) : l.substring(1);
      } else if (l.contains('\t')) {
        l = l.split('\t').first;
      }
      titles.add(l);
    }
    if (titles.isNotEmpty && RegExp(r'^(series|title|name)', caseSensitive: false).hasMatch(titles.first)) {
      titles.removeAt(0);
    }
  }
  final res = ImportResult();
  final seen = <int>{};
  for (final t in titles.toSet()) {
    final idx = search.bestMatch(t);
    if (idx == null) {
      res.unmatched.add(t);
    } else if (seen.add(idx)) {
      res.entries.add(UserEntry(id: c.titles[idx].id, status: EntryStatus.watched));
    }
  }
  return res;
}

void _collectTitles(dynamic node, List<String> out) {
  if (node is Map) {
    String? best;
    node.forEach((k, v) {
      final key = k.toString().toLowerCase();
      if (v is String && v.trim().isNotEmpty) {
        if (key == 'series_title' || key == 'seriestitle' || key == 'series_name' || key == 'show' || key == 'show_title') {
          best = v;
        } else if (best == null && (key == 'title' || key == 'name') && node.keys.any((x) => x.toString().toLowerCase().contains('series') || x.toString().toLowerCase().contains('episode'))) {
          best = null; // episode-level title: ignore unless a series key exists
        } else if (key == 'series' ) {
          best = v;
        }
      } else if (v is Map && key.contains('series')) {
        final t = v['title'] ?? v['name'];
        if (t is String) best = t;
      }
    });
    if (best != null) out.add(best!);
    node.forEach((_, v) {
      if (v is Map || v is List) _collectTitles(v, out);
    });
  } else if (node is List) {
    for (final v in node) {
      _collectTitles(v, out);
    }
  }
}

/// Series from the in-app Crunchyroll history -> unrated watched entries (+ hints for the tour).
ImportResult parseCrunchyrollSeries(List<CrSeries> series, CatalogData c, TitleSearch search) {
  final res = ImportResult();
  final seen = <int>{};
  for (final s in series) {
    final idx = search.bestMatch(s.title, kind: 'anime');
    if (idx == null) {
      res.unmatched.add(s.title);
    } else if (seen.add(idx)) {
      res.entries.add(UserEntry(id: c.titles[idx].id, status: EntryStatus.watched));
      final last = s.lastWatched == null ? '' : ', last ${s.lastWatched!.substring(0, 10)}';
      res.hints[idx] = 'Crunchyroll: ${s.episodes} episode${s.episodes == 1 ? '' : 's'} watched$last';
    }
  }
  return res;
}

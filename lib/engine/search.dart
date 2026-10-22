import 'dart:math' as math;

import 'catalog_data.dart';

String normalizeTitle(String s) {
  const map = {
    'ō': 'o', 'ū': 'u', 'ā': 'a', 'ī': 'i', 'ē': 'e', 'ô': 'o', 'û': 'u', 'â': 'a', 'ä': 'a', 'ö': 'o',
    'ü': 'u', 'é': 'e', 'è': 'e', 'ñ': 'n', 'ß': 'ss', 'Ō': 'o', 'Ū': 'u',
  };
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final ch = String.fromCharCode(r);
    final m = map[ch];
    if (m != null) {
      b.write(m);
    } else if ((r >= 97 && r <= 122) || (r >= 48 && r <= 57)) {
      b.write(ch);
    } else if (r > 0x2E80) {
      b.write(ch); // keep CJK so Japanese titles are searchable
    } else {
      b.write(' ');
    }
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

class SearchHit {
  final int idx;
  final double score, raw;
  SearchHit(this.idx, this.score, this.raw);
}

/// Autocomplete over romaji, English and synonym titles; typo tolerant.
class TitleSearch {
  final CatalogData c;
  final List<String> _names = [];
  final List<int> _owner = [];
  final List<bool> _primary = [];

  TitleSearch(this.c) {
    for (final t in c.titles) {
      final seen = <String>{};
      void add(String? s, bool primary) {
        if (s == null || s.isEmpty) return;
        final n = normalizeTitle(s);
        if (n.isEmpty || !seen.add(n)) return;
        _names.add(n);
        _owner.add(t.idx);
        _primary.add(primary);
      }
      add(t.title, true);
      add(t.titleEn, true);
      for (final s in t.synonyms) {
        add(s, false);
      }
    }
  }

  List<SearchHit> search(String query, {int limit = 12}) {
    final q = normalizeTitle(query);
    if (q.isEmpty) return const [];
    final qt = q.split(' ');
    final best = <int, double>{};
    void put(int idx, double s) {
      if (s > (best[idx] ?? -1)) best[idx] = s;
    }

    for (var k = 0; k < _names.length; k++) {
      final name = _names[k];
      double s = -1;
      if (name == q) {
        s = 100;
      } else if (name.startsWith(q)) {
        s = 90 - (name.length - q.length) * 0.15;
      } else if (qt.every((t) => name.split(' ').any((w) => w.startsWith(t)))) {
        s = 76;
      } else if (name.contains(q)) {
        s = 60;
      }
      if (s > 0) {
        if (!_primary[k]) s -= 3;
        put(_owner[k], s);
      }
    }
    if (best.length < 6 && q.length >= 3) {
      for (var k = 0; k < _names.length; k++) {
        if (best.containsKey(_owner[k])) continue;
        final s = _fuzzy(qt, _names[k]);
        if (s > 0) put(_owner[k], s - (_primary[k] ? 0 : 3));
      }
    }
    final hits = [
      for (final e in best.entries)
        SearchHit(e.key, e.value + 3.0 * math.log(c.titles[e.key].popularity + 10) / math.ln10, e.value)
    ]..sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  double _fuzzy(List<String> qt, String name) {
    final words = name.split(' ');
    var total = 0.0;
    for (final t in qt) {
      var bestD = 99;
      for (final w in words) {
        if ((w.length - t.length).abs() > 3 && w.length < t.length) continue;
        final lim = t.length <= 3 ? 0 : (t.length <= 6 ? 1 : 2);
        var d = _lev(t, w.length > t.length ? w.substring(0, t.length) : w, lim);
        if (d > 0 && w.length > t.length) {
          // typo with a deleted/added letter shifts the prefix window by one
          final k = math.min(w.length, t.length + 1);
          d = math.min(d, _lev(t, w.substring(0, k), lim));
        }
        if (d < bestD) bestD = d;
        if (bestD == 0) break;
      }
      final lim = t.length <= 3 ? 0 : (t.length <= 6 ? 1 : 2);
      if (bestD > lim) return -1;
      total += 1.0 * bestD;
    }
    return 52 - total * 6;
  }

  int _lev(String a, String b, int limit) {
    if ((a.length - b.length).abs() > limit) return limit + 1;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      var rowMin = cur[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var v = math.min(math.min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
        if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
          v = math.min(v, (i > 2 ? prev[j - 1] : prev[j - 1]));
        }
        cur[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > limit) return limit + 1;
      prev = cur;
    }
    return prev[b.length];
  }

  /// Best single match for a free-text line (bulk paste). Null when nothing convincing.
  int? bestMatch(String line) {
    final hits = search(line, limit: 3);
    if (hits.isEmpty) return null;
    return hits.first.raw >= 46 ? hits.first.idx : null;
  }
}

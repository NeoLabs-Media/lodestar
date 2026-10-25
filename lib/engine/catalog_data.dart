import 'dart:math' as math;
import 'dart:typed_data';

/// Light-weight per-title metadata (everything shown on cards).
class Show {
  final int idx; // position in the catalog arrays
  final int id; // catalog title id
  final int? anilist, mal, tmdb;
  final String? imdb;
  final String
  key; // stable external identity: anilist:N | mal:N | tmdb:movie:N | tmdb:tv:N | imdb:ttN | id:N
  final String kind; // anime | movie | tv
  final String? releaseDate, coverUrl;
  final String title;
  final String? titleEn;
  final List<String> synonyms;
  final int? year;
  final String? season, format, status, ending, thumb, pic;
  final int? episodes;
  final int popularity;
  final double? meanScore; // AniList 0-100
  final String tier;
  final double? quality;
  final String pitch, oneliner;
  final List<String> genres;
  // schema 3 filter columns (null / empty = unknown)
  final int? runtime, seasons, votes;
  final List<String> countries, languages, directors, studios, creators;
  final String? certification, source;

  Show({
    required this.idx,
    required this.id,
    this.anilist,
    this.mal,
    this.tmdb,
    this.imdb,
    required this.key,
    this.kind = 'anime',
    this.releaseDate,
    this.coverUrl,
    required this.title,
    this.titleEn,
    this.synonyms = const [],
    this.year,
    this.season,
    this.format,
    this.status,
    this.ending,
    this.thumb,
    this.pic,
    this.episodes,
    this.popularity = 0,
    this.meanScore,
    this.tier = 'compact',
    this.quality,
    this.pitch = '',
    this.oneliner = '',
    this.genres = const [],
    this.runtime,
    this.seasons,
    this.votes,
    this.countries = const [],
    this.languages = const [],
    this.directors = const [],
    this.studios = const [],
    this.creators = const [],
    this.certification,
    this.source,
  });

  /// Display title: prefer English when available, romaji as fallback.
  String get display =>
      (titleEn != null && titleEn!.isNotEmpty) ? titleEn! : title;
  String get cover => (coverUrl != null && coverUrl!.isNotEmpty)
      ? coverUrl!
      : ((pic ?? thumb) ?? '');
  bool get isAnime => kind == 'anime';

  /// ongoing | ended | upcoming | unknown, normalised across AniList and TMDB wording.
  String get statusGroup {
    final s = (status ?? '').toLowerCase();
    if (s.isEmpty) return 'unknown';
    if (s.contains('not_yet') ||
        s.contains('planned') ||
        s.contains('upcoming') ||
        s.contains('rumor'))
      return 'upcoming';
    if (s.contains('releas') ||
        s.contains('return') ||
        s.contains('continu') ||
        s.contains('production') ||
        s.contains('airing'))
      return 'ongoing';
    if (s.contains('finish') ||
        s.contains('ended') ||
        s.contains('cancel') ||
        s.contains('released'))
      return 'ended';
    return 'unknown';
  }
}

class FacetDef {
  final int fid;
  final String kind, value;
  final int df;
  FacetDef(this.fid, this.kind, this.value, this.df);
}

/// All numeric + metadata catalog content in flat typed arrays (fast scoring, small memory).
class CatalogData {
  static const dimCount = 45;

  final List<Show> titles;
  final int embDim;
  final Float32List emb; // n*embDim, L2-normalised
  final Uint8List dimsRaw; // n*45, 0..250 => 0..10, 255 = missing
  final Float32List dimZ; // n*45 standardised
  final List<String> dimNames;
  final Float32List dimMean, dimStd;
  final Int32List facetOff; // n+1
  final Uint16List facetIds;
  final Uint8List facetW; // 0..250 => 0..10
  final List<FacetDef> vocab;
  final Float32List facetIdf;
  final List<List<(int, String)>> relations; // idx -> (other idx, type)
  final List<List<(int, int)>>
  recs; // idx -> (other idx, rating), both directions
  final Map<String, String> meta;

  late final Map<int, int> idToIdx;
  late final Map<int, int> anilistToIdx;
  late final Map<String, int> keyToIdx;
  late final Set<String> kinds; // media kinds present in the catalog
  late final Float32List obscurity; // 0 = most popular .. 1 = least popular
  late final Float32List qual; // 0..1
  late final Int32List franchise; // cluster id per title
  late final Map<String, int> facetIndex; // "kind|value" -> fid

  int get n => titles.length;

  CatalogData({
    required this.titles,
    required this.embDim,
    required this.emb,
    required this.dimsRaw,
    required this.dimNames,
    required this.facetOff,
    required this.facetIds,
    required this.facetW,
    required this.vocab,
    required this.relations,
    required this.recs,
    required this.meta,
  }) : dimZ = Float32List(titles.length * dimCount),
       dimMean = Float32List(dimCount),
       dimStd = Float32List(dimCount),
       facetIdf = Float32List(vocab.length) {
    idToIdx = {for (final t in titles) t.id: t.idx};
    keyToIdx = {for (final t in titles) t.key: t.idx};
    kinds = {for (final t in titles) t.kind};
    anilistToIdx = {
      for (final t in titles)
        if (t.anilist != null) t.anilist!: t.idx,
    };
    facetIndex = {for (final f in vocab) '${f.kind}|${f.value}': f.fid};
    _computeDimStats();
    _computeIdf();
    _computePopularity();
    _computeFranchise();
  }

  double dim(int idx, int d) {
    final v = dimsRaw[idx * dimCount + d];
    return v == 255 ? dimMean[d] : v / 25.0;
  }

  int dimIndex(String name) => dimNames.indexOf(name);

  void _computeDimStats() {
    for (var d = 0; d < dimCount; d++) {
      var s = 0.0, s2 = 0.0, c = 0;
      for (var i = 0; i < n; i++) {
        final v = dimsRaw[i * dimCount + d];
        if (v == 255) continue;
        final x = v / 25.0;
        s += x;
        s2 += x * x;
        c++;
      }
      final m = c == 0 ? 5.0 : s / c;
      final varr = c == 0 ? 1.0 : math.max(s2 / c - m * m, 0.25);
      dimMean[d] = m;
      dimStd[d] = math.sqrt(varr);
    }
    for (var i = 0; i < n; i++) {
      for (var d = 0; d < dimCount; d++) {
        dimZ[i * dimCount + d] = (dim(i, d) - dimMean[d]) / dimStd[d];
      }
    }
  }

  void _computeIdf() {
    for (final f in vocab) {
      facetIdf[f.fid] = math.log((n + 1) / (f.df + 1));
    }
  }

  void _computePopularity() {
    // Popularity is not comparable across media (anime: AniList members, movies/TV: TMDB votes), so the
    // "obscure ... popular" rank is computed within each kind. Titles without data sit in the middle.
    obscurity = Float32List(n);
    for (final kind in kinds) {
      final ids = [
        for (var i = 0; i < n; i++)
          if (titles[i].kind == kind) i,
      ];
      final known = ids.where((i) => titles[i].popularity > 0).toList()
        ..sort((a, b) => titles[b].popularity.compareTo(titles[a].popularity));
      for (var r = 0; r < known.length; r++) {
        obscurity[known[r]] = known.length <= 1 ? 0.5 : r / (known.length - 1);
      }
      for (final i in ids) {
        if (titles[i].popularity <= 0) obscurity[i] = 0.5;
      }
    }
    qual = Float32List(n);
    for (var i = 0; i < n; i++) {
      final t = titles[i];
      final qm = t.meanScore == null
          ? 0.35
          : ((t.meanScore! - 55) / 30).clamp(0.0, 1.0);
      final qc = t.quality == null ? qm : (t.quality! / 10).clamp(0.0, 1.0);
      qual[i] = 0.75 * qm + 0.25 * qc;
    }
  }

  static const _franchiseTypes = {
    'PREQUEL',
    'SEQUEL',
    'PARENT',
    'SIDE_STORY',
    'SPIN_OFF',
    'ALTERNATIVE',
    'SUMMARY',
    'FULL_STORY',
  };

  void _computeFranchise() {
    final parent = List<int>.generate(n, (i) => i);
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    for (var i = 0; i < n; i++) {
      for (final (o, type) in relations[i]) {
        if (_franchiseTypes.contains(type)) {
          final a = find(i), b = find(o);
          if (a != b) parent[a] = b;
        }
      }
    }
    franchise = Int32List(n);
    for (var i = 0; i < n; i++) {
      franchise[i] = find(i);
    }
  }

  // ---- data-driven filter options (computed lazily, per scope = set of media kinds) -----
  final Map<String, Map<String, int>> _optionCache = {};

  Iterable<int> idsOfKinds(Set<String> kinds) sync* {
    for (var i = 0; i < n; i++) {
      if (kinds.isEmpty || kinds.contains(titles[i].kind)) yield i;
    }
  }

  /// value -> number of titles, for one of: studio, director, creator, country, language, rating,
  /// source, format, decade, status, mood, warning. Sorted by the caller.
  Map<String, int> optionCounts(String field, Set<String> kinds) {
    final key = '$field|${(kinds.toList()..sort()).join(',')}';
    return _optionCache.putIfAbsent(key, () {
      final out = <String, int>{};
      void add(String? v) {
        if (v == null || v.isEmpty) return;
        out[v] = (out[v] ?? 0) + 1;
      }

      for (final i in idsOfKinds(kinds)) {
        final t = titles[i];
        switch (field) {
          case 'studio':
            t.studios.forEach(add);
          case 'director':
            t.directors.forEach(add);
          case 'creator':
            t.creators.forEach(add);
          case 'country':
            t.countries.forEach(add);
          case 'language':
            t.languages.forEach(add);
          case 'rating':
            add(t.certification);
          case 'source':
            add(t.source);
          case 'format':
            add(t.format);
          case 'decade':
            if (t.year != null) add('${t.year! ~/ 10 * 10}s');
          case 'status':
            if (t.statusGroup != 'unknown') add(t.statusGroup);
          case 'mood':
          case 'warning':
            final want = field == 'mood' ? 'moods' : 'content_warnings';
            for (final (fid, w) in facetsOf(i)) {
              if (vocab[fid].kind == want && w >= (field == 'mood' ? 4 : 3))
                add(vocab[fid].value);
            }
        }
      }
      return out;
    });
  }

  /// min/max of a numeric column among the given kinds (year, runtime, seasons, episodes, score), or null.
  (num, num)? numericRange(String field, Set<String> kinds) {
    num? lo, hi;
    for (final i in idsOfKinds(kinds)) {
      final t = titles[i];
      final v = switch (field) {
        'year' => t.year,
        'runtime' => t.runtime,
        'seasons' => t.seasons,
        'episodes' => t.episodes,
        'score' => t.meanScore == null ? null : t.meanScore! / 10,
        _ => null,
      };
      if (v == null || v <= 0) continue;
      lo = lo == null || v < lo ? v : lo;
      hi = hi == null || v > hi ? v : hi;
    }
    return lo == null ? null : (lo, hi!);
  }

  /// How many titles of these kinds carry data for a column (filters without data are hidden).
  int countWith(String field, Set<String> kinds) {
    var k = 0;
    for (final i in idsOfKinds(kinds)) {
      final t = titles[i];
      final has = switch (field) {
        'runtime' => t.runtime != null,
        'seasons' => t.seasons != null,
        'country' => t.countries.isNotEmpty,
        'language' => t.languages.isNotEmpty,
        'rating' => t.certification != null,
        'director' => t.directors.isNotEmpty,
        'studio' => t.studios.isNotEmpty,
        'creator' => t.creators.isNotEmpty,
        'source' => t.source != null,
        'score' => t.meanScore != null,
        _ => true,
      };
      if (has) k++;
    }
    return k;
  }

  Iterable<(int fid, double w)> facetsOf(int idx) sync* {
    for (var k = facetOff[idx]; k < facetOff[idx + 1]; k++) {
      yield (facetIds[k], facetW[k] / 25.0);
    }
  }

  double cosine(int a, int b) {
    var s = 0.0;
    final oa = a * embDim, ob = b * embDim;
    for (var k = 0; k < embDim; k++) {
      s += emb[oa + k] * emb[ob + k];
    }
    return s;
  }
}

import 'dart:math' as math;
import 'dart:typed_data';

/// Light-weight per-title metadata (everything shown on cards).
class Show {
  final int idx; // position in the catalog arrays
  final int id; // catalog title id
  final int? anilist, mal;
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

  Show({
    required this.idx,
    required this.id,
    this.anilist,
    this.mal,
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
  });

  /// Display title: prefer English when available, romaji as fallback.
  String get display => (titleEn != null && titleEn!.isNotEmpty) ? titleEn! : title;
  String get cover => (pic ?? thumb) ?? '';
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
  final List<List<(int, int)>> recs; // idx -> (other idx, rating), both directions
  final Map<String, String> meta;

  late final Map<int, int> idToIdx;
  late final Map<int, int> anilistToIdx;
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
  })  : dimZ = Float32List(titles.length * dimCount),
        dimMean = Float32List(dimCount),
        dimStd = Float32List(dimCount),
        facetIdf = Float32List(vocab.length) {
    idToIdx = {for (final t in titles) t.id: t.idx};
    anilistToIdx = {
      for (final t in titles)
        if (t.anilist != null) t.anilist!: t.idx
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
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => titles[b].popularity.compareTo(titles[a].popularity));
    obscurity = Float32List(n);
    final known = order.where((i) => titles[i].popularity > 0).toList(); // 0 = no data
    for (var r = 0; r < known.length; r++) {
      obscurity[known[r]] = known.length <= 1 ? 0.5 : r / (known.length - 1);
    }
    for (final i in order) {
      if (titles[i].popularity <= 0) obscurity[i] = 0.5;
    }
    qual = Float32List(n);
    for (var i = 0; i < n; i++) {
      final t = titles[i];
      final qm = t.meanScore == null ? 0.35 : ((t.meanScore! - 55) / 30).clamp(0.0, 1.0);
      final qc = t.quality == null ? qm : (t.quality! / 10).clamp(0.0, 1.0);
      qual[i] = 0.75 * qm + 0.25 * qc;
    }
  }

  static const _franchiseTypes = {
    'PREQUEL', 'SEQUEL', 'PARENT', 'SIDE_STORY', 'SPIN_OFF', 'ALTERNATIVE', 'SUMMARY', 'FULL_STORY'
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

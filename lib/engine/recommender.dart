import 'dart:math' as math;
import 'dart:typed_data';

import 'catalog_data.dart';
import 'categories.dart';
import 'filters.dart';
import 'labels.dart';

enum EntryStatus { watched, planned, notInterested, ignored }

/// One row of user state about a title.
class UserEntry {
  final int id; // catalog title id
  final String?
  key; // stable external title key (kind + external id) used to re-link if ids change
  final EntryStatus status;
  final double? rating; // 1..10 (half steps)
  final Set<String>
  reasons; // liked: "g:romance" / "f:kind|value"; disliked: "n:romance" / "x:kind|value"
  final String note;
  final int updatedAt;
  UserEntry withKey(String? k, {int? id}) => UserEntry(
    id: id ?? this.id,
    key: k,
    status: status,
    rating: rating,
    reasons: reasons,
    note: note,
    updatedAt: updatedAt,
  );
  const UserEntry({
    required this.id,
    this.key,
    required this.status,
    this.rating,
    this.reasons = const {},
    this.note = '',
    this.updatedAt = 0,
  });
}

class Controls {
  /// 0 = popular picks … 1 = deep cuts.
  double obscurity;
  Set<String>
  kinds; // media kinds to include: anime | movie | tv (empty = mix everything)
  /// Filter state per scope ('all', 'anime', 'movie', 'tv'); only the active scope's filters apply.
  final Map<String, ScopeFilters> scopes = {};

  /// A second set of hard filters that must ALSO hold (not persisted). The assistant uses it to layer the
  /// model's own search arguments on top of the user's filters without ever being able to loosen them.
  Controls? also;

  /// Judge each title by the filters of its own kind (instead of the single active scope). Used with [also].
  bool perKind = false;

  /// One selected kind -> that kind's scope (with its specific filters); anything else -> 'all' (common filters).
  String get scope => kinds.length == 1 ? kinds.first : 'all';
  ScopeFilters get active => scopes.putIfAbsent(scope, ScopeFilters.new);
  ScopeFilters scopeFilters(String name) =>
      scopes.putIfAbsent(name, ScopeFilters.new);

  // Convenience accessors for the active scope (the pre-per-kind API).
  Set<String> get formats => active.formats;
  Set<String> get moods => active.moods;
  Set<String> get excludeWarnings => active.excludeWarnings;
  Set<String> get categories => active.categories;
  int? get maxEpisodes => active.maxEpisodes;
  set maxEpisodes(int? v) => active.maxEpisodes = v;
  int? get minYear => active.yearMin;
  set minYear(int? v) => active.yearMin = v;

  Controls({
    this.obscurity = 0.45,
    Set<String>? formats,
    int? maxEpisodes,
    Set<String>? moods,
    Set<String>? excludeWarnings,
    Set<String>? categories,
    Set<String>? kinds,
    int? minYear,
  }) : kinds = kinds ?? {} {
    final a = active;
    a.formats.addAll(formats ?? const {});
    a.moods.addAll(moods ?? const {});
    a.excludeWarnings.addAll(excludeWarnings ?? const {});
    a.categories.addAll(categories ?? const {});
    a.maxEpisodes = maxEpisodes;
    a.yearMin = minYear;
  }

  Map<String, dynamic> toJson() => {
    'obscurity': obscurity,
    'kinds': kinds.toList(),
    'scopes': {for (final e in scopes.entries) e.key: e.value.toJson()},
  };

  /// Reads the saved form; also understands the older flat form (one global filter set).
  static Controls fromJson(Map<String, dynamic> m) {
    final c = Controls(obscurity: (m['obscurity'] as num?)?.toDouble() ?? 0.45);
    c.kinds = ((m['kinds'] as List?) ?? const []).cast<String>().toSet();
    final sc = m['scopes'];
    if (sc is Map) {
      sc.forEach(
        (k, v) => c.scopes['$k'] = ScopeFilters.fromJson(
          (v as Map).cast<String, dynamic>(),
        ),
      );
    } else {
      c.scopes[c.scope] = ScopeFilters.fromJson(m); // legacy: flat keys
    }
    return c;
  }

  /// Number of active hard filters (plus the media restriction) for badges.
  int activeCount({bool multiKindCatalog = false}) =>
      active.activeCount(scope) + (multiKindCatalog ? kinds.length : 0);

  /// One removable chip per active restriction: (label, remove).
  List<(String, void Function())> chips({bool multiKindCatalog = true}) {
    final names = {'anime': 'Anime', 'movie': 'Movies', 'tv': 'TV'};
    return [
      if (multiKindCatalog)
        for (final k in kinds.toList()) (names[k] ?? k, () => kinds.remove(k)),
      ...active.chips(scope),
    ];
  }

  /// Short text of everything that is restricting the feed, e.g. "movies · 80–120 min, PG-13" ('' = nothing).
  String describe() {
    final names = {'anime': 'anime', 'movie': 'movies', 'tv': 'TV'};
    final head = kinds.isEmpty
        ? ''
        : kinds.map((k) => names[k] ?? k).join(' + ');
    final tail = active.describe(scope);
    return [head, tail].where((x) => x.isNotEmpty).join(' · ');
  }
}

class Rec {
  final int idx;
  final double score; // final ranking score
  final double match; // 0..100 display
  final String why;
  final int? anchor; // watched title that explains the match
  final bool gem;
  final List<String> tags;
  Rec(
    this.idx,
    this.score,
    this.match,
    this.why,
    this.anchor,
    this.gem,
    this.tags,
  );
}

class DimPref {
  final String name;
  final double z; // preference strength in std-devs (signed)
  final double likedAvg; // average 0..10 among liked titles
  DimPref(this.name, this.z, this.likedAvg);
}

class FacetPref {
  final String kind, value;
  final double strength; // signed
  final int support;
  FacetPref(this.kind, this.value, this.strength, this.support);
}

class TasteSummary {
  final int rated;
  final double meanRating;
  final List<DimPref> likes, avoids;
  final List<FacetPref> facetLikes, facetAvoids;
  final Map<String, int> reasonCounts; // label -> count
  final List<FacetPref>
  dislikedTags; // tags the user explicitly flagged (strength = -times flagged)
  final List<String>
  dislikedAspects; // generic aspects flagged ("Humor", "Pacing"…)
  TasteSummary(
    this.rated,
    this.meanRating,
    this.likes,
    this.avoids,
    this.facetLikes,
    this.facetAvoids,
    this.reasonCounts, {
    this.dislikedTags = const [],
    this.dislikedAspects = const [],
  });
}

/// Fitted user taste: everything needed to score a candidate.
class TasteModel {
  final int nSignals;
  final double mean;
  final Float32List? taste; // unit vector, null when no signal
  final Float32List wDim; // preference weights over standardised dims
  final Float32List wFac; // over facet vocab
  final Map<int, double>
  reasonFacets; // fid -> strength (explicit "what I liked")
  final Map<int, double>
  avoidFacets; // fid -> how often the user flagged this tag as disliked
  final Map<int, double> comm; // idx -> community (AniList recs) score
  final Set<int> seen; // indices excluded from the feed
  final Set<int> watched;
  final Map<int, double> signal; // idx -> signed preference signal s_i
  final List<(int idx, double s)> positives, negatives;
  final Map<int, UserEntry> byIdx;
  TasteModel({
    required this.nSignals,
    required this.mean,
    required this.taste,
    required this.wDim,
    required this.wFac,
    required this.reasonFacets,
    this.avoidFacets = const {},
    required this.comm,
    required this.seen,
    required this.watched,
    required this.signal,
    required this.positives,
    required this.negatives,
    required this.byIdx,
  });
  bool get hasSignal => nSignals > 0;
}

class Recommender {
  final CatalogData c;
  static const _facetScale = 0.8;
  Recommender(this.c);

  // --- feature rows ------------------------------------------------------
  // Facet row = idf-weighted facet weights, L2-normalised, scaled.
  double _facetNorm(int idx) {
    var s = 0.0;
    for (final (fid, w) in c.facetsOf(idx)) {
      final x = w / 10 * c.facetIdf[fid];
      s += x * x;
    }
    return s == 0 ? 1.0 : math.sqrt(s);
  }

  late final Float32List _fNorm = () {
    final f = Float32List(c.n);
    for (var i = 0; i < c.n; i++) {
      f[i] = _facetNorm(i).toDouble();
    }
    return f;
  }();

  double _score(int i, Float32List wDim, Float32List wFac) {
    var s = 0.0;
    final o = i * CatalogData.dimCount;
    for (var d = 0; d < CatalogData.dimCount; d++) {
      s += wDim[d] * c.dimZ[o + d];
    }
    s *= 1 / math.sqrt(CatalogData.dimCount.toDouble());
    var f = 0.0;
    for (var k = c.facetOff[i]; k < c.facetOff[i + 1]; k++) {
      final fid = c.facetIds[k];
      f += wFac[fid] * (c.facetW[k] / 250.0) * c.facetIdf[fid];
    }
    return s + _facetScale * f / _fNorm[i];
  }

  // --- fitting -------------------------------------------------------------
  TasteModel fit(List<UserEntry> entries) {
    final byIdx = <int, UserEntry>{};
    final seen = <int>{};
    final watched = <int>{};
    for (final e in entries) {
      final i = c.idToIdx[e.id];
      if (i == null) continue;
      byIdx[i] = e;
      seen.add(i);
      if (e.status == EntryStatus.watched) watched.add(i);
    }
    // user's own mean rating, shrunk to a prior of 7 when little data
    final rated = [
      for (final e in byIdx.entries)
        if (e.value.status == EntryStatus.watched && e.value.rating != null)
          e.value.rating!,
    ];
    final mean =
        (rated.fold(0.0, (a, b) => a + b) + 3 * 7.0) / (rated.length + 3);

    final signal = <int, double>{};
    for (final e in byIdx.entries) {
      final u = e.value;
      if (u.status == EntryStatus.watched) {
        signal[e.key] = u.rating == null
            ? 0.35
            : ((u.rating! - mean) / 2.0).clamp(-2.0, 2.0);
      } else if (u.status == EntryStatus.notInterested) {
        signal[e.key] = -0.8;
      }
    }
    final positives = [
      for (final e in signal.entries)
        if (e.value > 0.05) (e.key, e.value),
    ];
    final negatives = [
      for (final e in signal.entries)
        if (e.value < -0.05) (e.key, e.value),
    ];
    final nSignals = signal.length;
    final F = c.vocab.length;
    final D = CatalogData.dimCount;
    final wDim = Float32List(D), wFac = Float32List(F);
    if (nSignals == 0) {
      return TasteModel(
        nSignals: 0,
        mean: mean,
        taste: null,
        wDim: wDim,
        wFac: wFac,
        reasonFacets: {},
        comm: {},
        seen: seen,
        watched: watched,
        signal: signal,
        positives: positives,
        negatives: negatives,
        byIdx: byIdx,
      );
    }

    // embedding taste vector
    final taste = Float32List(c.embDim);
    var any = false;
    for (final (i, s) in positives) {
      final extra = 1 + 0.25 * math.min(4, byIdx[i]!.reasons.length);
      for (var k = 0; k < c.embDim; k++) {
        taste[k] += s * extra * c.emb[i * c.embDim + k];
      }
      any = true;
    }
    for (final (i, s) in negatives) {
      for (var k = 0; k < c.embDim; k++) {
        taste[k] += 0.5 * s * c.emb[i * c.embDim + k]; // s negative
      }
      any = true;
    }
    Float32List? tasteVec;
    if (any) {
      var nn = 0.0;
      for (final v in taste) {
        nn += v * v;
      }
      if (nn > 1e-9) {
        final inv = 1 / math.sqrt(nn);
        for (var k = 0; k < c.embDim; k++) {
          taste[k] *= inv;
        }
        tasteVec = taste;
      }
    }

    // --- dim + facet weights: centroid and ridge (dual form) ---------------
    final ids = signal.keys.toList();
    final m = ids.length;
    final y = [for (final i in ids) signal[i]!];
    final sq = 1 / math.sqrt(D.toDouble());

    // sparse facet rows per rated title (fid -> value), normalised
    final rows = <Map<int, double>>[];
    for (final i in ids) {
      final r = <int, double>{};
      for (final (fid, w) in c.facetsOf(i)) {
        r[fid] = (w / 10) * c.facetIdf[fid] / _fNorm[i] * _facetScale;
      }
      rows.add(r);
    }
    // centroid weights
    final cDim = Float32List(D), cFac = Float32List(F);
    var absSum = 1e-6;
    for (var a = 0; a < m; a++) {
      final s = y[a];
      absSum += s.abs();
      for (var d = 0; d < D; d++) {
        cDim[d] += s * c.dimZ[ids[a] * D + d] * sq;
      }
      rows[a].forEach((fid, v) => cFac[fid] += s * v);
    }
    for (var d = 0; d < D; d++) {
      cDim[d] /= absSum;
    }
    for (var f = 0; f < F; f++) {
      cFac[f] /= absSum;
    }
    // ridge: alpha = (K + lambda I)^-1 y ; w = sum alpha_a phi_a
    final K = List.generate(m, (_) => List<double>.filled(m, 0));
    for (var a = 0; a < m; a++) {
      for (var b = a; b < m; b++) {
        var dot = 0.0;
        for (var d = 0; d < D; d++) {
          dot += c.dimZ[ids[a] * D + d] * c.dimZ[ids[b] * D + d];
        }
        dot *= sq * sq;
        final ra = rows[a], rb = rows[b];
        final (small, large) = ra.length < rb.length ? (ra, rb) : (rb, ra);
        small.forEach((fid, v) {
          final o = large[fid];
          if (o != null) dot += v * o;
        });
        K[a][b] = dot;
        K[b][a] = dot;
      }
      K[a][a] += 0.6;
    }
    final alpha = _solveSpd(K, y);
    final rDim = Float32List(D), rFac = Float32List(F);
    for (var a = 0; a < m; a++) {
      final al = alpha[a];
      for (var d = 0; d < D; d++) {
        rDim[d] += al * c.dimZ[ids[a] * D + d] * sq;
      }
      rows[a].forEach((fid, v) => rFac[fid] += al * v);
    }
    // normalise each to unit std of the catalog scores, then blend
    final sc = _stdOfScores(cDim, cFac), sr = _stdOfScores(rDim, rFac);
    final blend = ((m - 4) / 14).clamp(0.0, 1.0);
    for (var d = 0; d < D; d++) {
      wDim[d] = ((1 - blend) * cDim[d] / sc + blend * rDim[d] / sr).toDouble();
    }
    for (var f = 0; f < F; f++) {
      wFac[f] = ((1 - blend) * cFac[f] / sc + blend * rFac[f] / sr).toDouble();
    }

    // --- "what I liked" boosts ------------------------------------------------
    final bDim = Float32List(D), bFac = Float32List(F);
    final reasonFacets = <int, double>{};
    final avoidFacets = <int, double>{};
    var nReasons = 0;
    for (final e in byIdx.entries) {
      final u = e.value;
      if (u.status != EntryStatus.watched || u.reasons.isEmpty) continue;
      final s = signal[e.key] ?? 0.35;
      final strength = s > 0 ? math.min(1.5, math.max(0.5, s)) : 0.3;
      for (final r in u.reasons) {
        nReasons++;
        if (r.startsWith('g:')) {
          final g = genericReasonByKey(r.substring(2));
          if (g == null) continue;
          g.dims.forEach((dn, w) {
            final di = c.dimIndex(dn);
            if (di >= 0) bDim[di] += strength * w;
          });
          for (final (fid, w) in c.facetsOf(e.key)) {
            if (g.facetKinds.contains(c.vocab[fid].kind) && w >= 5) {
              bFac[fid] += 0.5 * strength * w / 10;
            }
          }
        } else if (r.startsWith('f:')) {
          final fid = c.facetIndex[r.substring(2)];
          if (fid != null) {
            bFac[fid] += 1.2 * strength;
            reasonFacets[fid] = (reasonFacets[fid] ?? 0) + strength;
          }
        } else if (r.startsWith('n:')) {
          // disliked aspect (independent of the rating): push the matching dimensions down
          final g = genericReasonByKey(r.substring(2));
          if (g == null) continue;
          g.dims.forEach((dn, w) {
            final di = c.dimIndex(dn);
            if (di >= 0) bDim[di] -= 1.0 * w;
          });
        } else if (r.startsWith('x:')) {
          final fid = c.facetIndex[r.substring(2)];
          if (fid != null) {
            bFac[fid] -= 1.5;
            avoidFacets[fid] = math.min(3.0, (avoidFacets[fid] ?? 0) + 1);
          }
        }
      }
    }
    if (nReasons > 0) {
      final sb = _stdOfScores(bDim, bFac);
      final beta = 0.55 * math.min(1.0, 0.4 + nReasons / 8);
      for (var d = 0; d < D; d++) {
        wDim[d] += beta * bDim[d] / sb;
      }
      for (var f = 0; f < F; f++) {
        wFac[f] += beta * bFac[f] / sb;
      }
    }

    // --- community signal (AniList "users also liked") ---------------------------
    final comm = <int, double>{};
    for (final (i, s) in positives) {
      for (final (o, rating) in c.recs[i]) {
        comm[o] = (comm[o] ?? 0) + s * (1 + math.log(1 + rating));
      }
    }
    for (final (i, s) in negatives) {
      for (final (o, rating) in c.recs[i]) {
        comm[o] = (comm[o] ?? 0) + 0.5 * s * (1 + math.log(1 + rating));
      }
    }

    return TasteModel(
      nSignals: nSignals,
      mean: mean,
      taste: tasteVec,
      wDim: wDim,
      wFac: wFac,
      reasonFacets: reasonFacets,
      avoidFacets: avoidFacets,
      comm: comm,
      seen: seen,
      watched: watched,
      signal: signal,
      positives: positives,
      negatives: negatives,
      byIdx: byIdx,
    );
  }

  double _stdOfScores(Float32List wDim, Float32List wFac) {
    var s = 0.0, s2 = 0.0;
    // sample every 3rd title: enough for a scale estimate
    var cnt = 0;
    for (var i = 0; i < c.n; i += 3) {
      final x = _score(i, wDim, wFac);
      s += x;
      s2 += x * x;
      cnt++;
    }
    final mu = s / cnt;
    return math.max(math.sqrt(math.max(s2 / cnt - mu * mu, 0)), 1e-6);
  }

  /// Solve (A) x = b for symmetric positive definite A via Cholesky.
  List<double> _solveSpd(List<List<double>> a, List<double> b) {
    final n = b.length;
    final l = List.generate(n, (_) => List<double>.filled(n, 0));
    for (var i = 0; i < n; i++) {
      for (var j = 0; j <= i; j++) {
        var sum = a[i][j];
        for (var k = 0; k < j; k++) {
          sum -= l[i][k] * l[j][k];
        }
        if (i == j) {
          l[i][i] = math.sqrt(math.max(sum, 1e-9));
        } else {
          l[i][j] = sum / l[j][j];
        }
      }
    }
    final z = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      var sum = b[i];
      for (var k = 0; k < i; k++) {
        sum -= l[i][k] * z[k];
      }
      z[i] = sum / l[i][i];
    }
    final x = List<double>.filled(n, 0);
    for (var i = n - 1; i >= 0; i--) {
      var sum = z[i];
      for (var k = i + 1; k < n; k++) {
        sum -= l[k][i] * x[k];
      }
      x[i] = sum / l[i][i];
    }
    return x;
  }

  // --- scoring ----------------------------------------------------------------
  static const _loOk = {
    'fanservice',
    'sexual_content',
    'violence_gore',
    'horror_dread',
    'psychological_darkness',
    'action_intensity',
    'tension_suspense',
    'plot_complexity',
    'romance_centrality',
    'cuteness',
  };
  static const _penaltyRel = {
    'SUMMARY': 0.7,
    'ALTERNATIVE': 0.6,
    'SPIN_OFF': 0.3,
    'SIDE_STORY': 0.3,
  };
  static const _contRel = {'SEQUEL', 'PREQUEL', 'PARENT', 'FULL_STORY'};

  /// Per-title bitmask of the categories in categories.dart.
  late final Int32List _catMask = () {
    final rules = <int, List<(int, double)>>{}; // category index -> (fid, minW)
    for (var k = 0; k < categories.length; k++) {
      rules[k] = [
        for (final (kind, value, w) in categories[k].any)
          // movie/TV catalogs carry TMDB keywords where anime carry AniList tags
          for (final kk
              in (kind == 'anilist_tag' ? ['anilist_tag', 'keyword'] : [kind]))
            if (c.facetIndex['$kk|$value'] != null)
              (c.facetIndex['$kk|$value']!, w),
      ];
    }
    final out = Int32List(c.n);
    for (var i = 0; i < c.n; i++) {
      var mask = 0;
      for (var k = c.facetOff[i]; k < c.facetOff[i + 1]; k++) {
        final fid = c.facetIds[k];
        final w = c.facetW[k] / 25.0;
        rules.forEach((ci, list) {
          for (final (f, mw) in list) {
            if (f == fid && w >= mw) mask |= 1 << ci;
          }
        });
      }
      out[i] = mask;
    }
    return out;
  }();

  /// How many titles of the given kinds (empty = all) belong to a category.
  int categoryCount(String key, Set<String> kinds) {
    final ci = categories.indexWhere((x) => x.key == key);
    if (ci < 0) return 0;
    var n = 0;
    for (var i = 0; i < c.n; i++) {
      if ((kinds.isEmpty || kinds.contains(c.titles[i].kind)) &&
          (_catMask[i] & (1 << ci)) != 0)
        n++;
    }
    return n;
  }

  bool inCategory(int idx, String key) {
    final ci = categories.indexWhere((x) => x.key == key);
    return ci >= 0 && (_catMask[idx] & (1 << ci)) != 0;
  }

  bool _passes(int i, Controls ctl) {
    if (ctl.also != null && !_passes(i, ctl.also!)) return false;
    final t = c.titles[i];
    if (ctl.kinds.isNotEmpty && !ctl.kinds.contains(t.kind)) return false;
    final f = ctl.perKind ? ctl.scopeFilters(t.kind) : ctl.active;
    if (f.categories.isNotEmpty && !f.categories.any((k) => inCategory(i, k)))
      return false;
    if (!f.passes(t, ctl.perKind ? t.kind : ctl.scope)) return false;
    if (f.moods.isNotEmpty || f.excludeWarnings.isNotEmpty) {
      var moodOk = f.moods.isEmpty;
      for (final (fid, w) in c.facetsOf(i)) {
        final fd = c.vocab[fid];
        if (!moodOk &&
            fd.kind == 'moods' &&
            w >= 4 &&
            f.moods.contains(fd.value))
          moodOk = true;
        if (fd.kind == 'content_warnings' &&
            w >= 3 &&
            f.excludeWarnings.contains(fd.value))
          return false;
      }
      if (!moodOk) return false;
    }
    return true;
  }

  /// Does title [idx] satisfy the hard filters of [ctl]?
  bool passes(int idx, Controls ctl) => _passes(idx, ctl);

  /// Titles that pass [ctl], best first by quality then popularity (no taste involved), at most [n].
  List<int> browse(Controls ctl, {int n = 8, Set<int> exclude = const {}}) {
    final ids =
        [
          for (var i = 0; i < c.n; i++)
            if (!exclude.contains(i) && _passes(i, ctl)) i,
        ]..sort((a, b) {
          final q = c.qual[b].compareTo(c.qual[a]);
          return q != 0
              ? q
              : c.titles[b].popularity.compareTo(c.titles[a].popularity);
        });
    return ids.take(n).toList();
  }

  /// The recommender's view of one title for this user: match %, explanation (null if it is already in
  /// the library, which is excluded from ranking).
  Rec? scoreOne(int idx, TasteModel m, {Controls? controls}) {
    final ranked = _rank(m, controls ?? Controls(obscurity: 0.33));
    for (final cand in ranked) {
      if (cand.idx == idx) return _toRec(cand, m);
    }
    return null;
  }

  /// Base (taste-only) scores for every title plus z-normalisation stats.
  _Scores _baseScores(TasteModel m) {
    final n = c.n;
    final emb = Float32List(n), feat = Float32List(n);
    for (var i = 0; i < n; i++) {
      if (m.taste != null) {
        var s = 0.0;
        final o = i * c.embDim;
        for (var k = 0; k < c.embDim; k++) {
          s += c.emb[o + k] * m.taste![k];
        }
        emb[i] = s;
      }
      feat[i] = _score(i, m.wDim, m.wFac);
    }
    return _Scores(emb, feat);
  }

  double _z(double x, double mu, double sd) => (x - mu) / sd;

  List<Rec> recommend(
    TasteModel m,
    Controls ctl, {
    int count = 40,
    bool diversify = true,
  }) {
    final scored = _rank(m, ctl);
    final pool = scored.take(300).toList();
    final chosen = diversify ? _mmr(pool, m, count) : pool.take(count).toList();
    final use = <int, int>{};
    final note = ctl.describe();
    return [
      for (final s in chosen)
        _withFilterNote(_toRec(s, m, anchorUse: use), note),
    ];
  }

  /// All unseen titles ranked by raw score (no diversification); for evaluation.
  List<int> rankAll(TasteModel m, {Controls? controls}) => [
    for (final x in _rank(m, controls ?? Controls(obscurity: 0.33))) x.idx,
  ];

  List<_Cand> _rank(TasteModel m, Controls ctl) {
    final n = c.n;
    final sc = _baseScores(m);
    final qm = _meanStd(c.qual);
    final embStats = _meanStd(sc.emb), featStats = _meanStd(sc.feat);
    final g = ctl.obscurity;
    final out = <_Cand>[];
    for (var i = 0; i < n; i++) {
      if (m.seen.contains(i) || !_passes(i, ctl)) continue;
      final ze = m.taste == null
          ? 0.0
          : _z(sc.emb[i], embStats.$1, embStats.$2);
      final zf = m.hasSignal ? _z(sc.feat[i], featStats.$1, featStats.$2) : 0.0;
      final cm = m.comm[i];
      final commTerm = cm == null ? 0.0 : 1.1 * _tanh(cm / 2.5);
      final zq = _z(c.qual[i], qm.$1, qm.$2);
      var base = m.hasSignal ? 0.9 * ze + 1.0 * zf + commTerm : 0.0;
      // penalties for franchise relations to things the user already has
      var pen = 0.0;
      var seqOf = -1, preOf = -1;
      for (final (o, type) in c.relations[i]) {
        if (!m.seen.contains(o)) continue;
        final p = _penaltyRel[type];
        if (p != null) pen += p;
        if (_contRel.contains(type)) {
          final s = m.signal[o] ?? 0;
          pen += s < 0 ? 1.2 : 0.35;
          if (s > 0.2 && seqOf < 0 && (type == 'PREQUEL' || type == 'PARENT'))
            seqOf = o;
          if (s > 0.2 && preOf < 0 && type == 'SEQUEL') preOf = o;
        }
      }
      if (m.taste != null) {
        var mx = 0.0;
        for (final w in m.watched) {
          final cs = c.cosine(i, w);
          if (cs > mx) mx = cs;
        }
        if (mx > 0.9) pen += 0.8 * (mx - 0.9) / 0.1 + 0.3;
      }
      // tags the user explicitly flagged as disliked: strong, independent of how well the rest matches
      if (m.avoidFacets.isNotEmpty) {
        var avoid = 0.0;
        for (final (fid, w) in c.facetsOf(i)) {
          final a = m.avoidFacets[fid];
          if (a != null && w >= 4)
            avoid += 2.4 * math.min(a, 2.0) * (w / 10).clamp(0.4, 1.0);
        }
        pen += math.min(avoid, 8.0) / 1.4;
      }
      // hidden-gem control: slider centred at ~0.35, matters only for decent matches
      final matchZ = m.hasSignal ? (base / 1.9) : 0.0;
      final obsC = c.obscurity[i] - 0.5; // -0.5 popular .. +0.5 obscure
      final gate = _sigmoid((matchZ - 0.2) * 2.2);
      final gem = (g - 0.33) * 9.0 * obsC * (m.hasSignal ? gate : 1.0);
      final qualTerm = 0.45 * zq * (0.6 + 0.4 * g);
      final fin =
          base +
          gem +
          qualTerm -
          pen * 1.4 +
          (m.hasSignal ? 0 : 0.8 * zq - 1.5 * obsC * (1 - g));
      out.add(_Cand(i, fin, base, ze, zf, seqOf, preOf));
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  List<_Cand> _mmr(List<_Cand> pool, TasteModel m, int count) {
    final chosen = <_Cand>[];
    final rest = List<_Cand>.from(pool);
    final maxSim = List<double>.filled(rest.length, 0, growable: true);
    final franchiseCount = <int, int>{};
    while (chosen.length < count && rest.isNotEmpty) {
      var best = -1;
      var bestV = -1e9;
      for (var k = 0; k < rest.length; k++) {
        final cand = rest[k];
        var v = cand.score;
        v -= 7.0 * math.max(0.0, maxSim[k] - 0.55);
        final fc = franchiseCount[c.franchise[cand.idx]] ?? 0;
        if (fc >= 1) v -= 2.5 * fc;
        if (v > bestV) {
          bestV = v;
          best = k;
        }
      }
      final pick = rest.removeAt(best);
      maxSim.removeAt(best);
      chosen.add(pick);
      franchiseCount[c.franchise[pick.idx]] =
          (franchiseCount[c.franchise[pick.idx]] ?? 0) + 1;
      for (var k = 0; k < rest.length; k++) {
        final s = c.cosine(rest[k].idx, pick.idx);
        if (s > maxSim[k]) maxSim[k] = s;
      }
    }
    return chosen;
  }

  Rec _withFilterNote(Rec r, String note) => note.isEmpty
      ? r
      : Rec(
          r.idx,
          r.score,
          r.match,
          '${r.why} Within your filters ($note).',
          r.anchor,
          r.gem,
          r.tags,
        );

  /// "Surprise me": a good match that is deliberately off the beaten path.
  Rec? surprise(TasteModel m, Controls ctl, {int? seed}) {
    final ranked = _rank(m, ctl);
    if (ranked.isEmpty) return null;
    final rnd = math.Random(seed);
    final top = ranked.take(500).toList();
    final topScore = top.first.score;
    final weights = <double>[];
    for (final cand in top) {
      var nov = 1.0;
      if (m.taste != null && m.watched.isNotEmpty) {
        var mx = 0.0;
        for (final w in m.watched) {
          mx = math.max(mx, c.cosine(cand.idx, w));
        }
        nov = (1 - mx).clamp(0.0, 1.0);
      }
      final obs = c.obscurity[cand.idx];
      final w = math.exp((cand.score - topScore) / 1.4 + 2.5 * nov + 1.8 * obs);
      weights.add(w);
    }
    var total = weights.fold(0.0, (a, b) => a + b);
    var r = rnd.nextDouble() * total;
    for (var k = 0; k < top.length; k++) {
      r -= weights[k];
      if (r <= 0) {
        final rec = _toRec(top[k], m);
        return _withFilterNote(
          Rec(
            rec.idx,
            rec.score,
            rec.match,
            'Off the beaten path: ${rec.why}',
            rec.anchor,
            rec.gem,
            rec.tags,
          ),
          ctl.describe(),
        );
      }
    }
    return _toRec(top.first, m);
  }

  // --- explanation ---------------------------------------------------------------
  Rec _toRec(_Cand cand, TasteModel m, {Map<int, int>? anchorUse}) {
    final t = c.titles[cand.idx];
    final avgZ = cand.base / 1.9;
    final match = m.hasSignal ? 100 * _sigmoid((avgZ - 1.1) * 1.9) : 0.0;
    final gem =
        c.obscurity[cand.idx] > 0.55 &&
        c.qual[cand.idx] > 0.55 &&
        (m.hasSignal ? avgZ > 0.7 : true);
    final (why, anchor, tags) = explain(
      cand.idx,
      m,
      seqOf: cand.seqOf,
      preOf: cand.preOf,
      anchorUse: anchorUse,
    );
    return Rec(
      cand.idx,
      cand.score,
      m.hasSignal ? match.clamp(1, 99.0).toDouble() : 0.0,
      why,
      anchor,
      gem && t.popularity >= 0,
      tags,
    );
  }

  /// When set, explanations never mention plot-revealing tags or outcome dimensions (the assistant's spoiler switch).
  bool spoilerFreeWhy = false;

  /// Specific "why this" text from the largest contributors.
  (String, int?, List<String>) explain(
    int idx,
    TasteModel m, {
    int seqOf = -1,
    int preOf = -1,
    Map<int, int>? anchorUse,
  }) {
    if (!m.hasSignal) {
      return (
        'Well-reviewed pick — rate a few titles to personalise.',
        null,
        const [],
      );
    }
    final D = CatalogData.dimCount;
    final phrases = <(double, String, String)>[]; // (strength, phrase, key)
    // 1. explicit reasons
    var reasonHit = <int>[];
    for (final (fid, w) in c.facetsOf(idx)) {
      final rs = m.reasonFacets[fid];
      if (rs != null && w >= 4) {
        final f = c.vocab[fid];
        if (spoilerFreeWhy && isSpoilerFacet(f.kind, f.value)) continue;
        phrases.add((10 + rs * w, facetPhrase(f.kind, f.value), 'f$fid'));
        reasonHit.add(fid);
      }
    }
    // 2. learned facet contributions
    final fn = _fNorm[idx];
    for (final (fid, w) in c.facetsOf(idx)) {
      final f = c.vocab[fid];
      if (f.kind == 'content_warnings' || f.kind == 'relationship_types')
        continue;
      if (spoilerFreeWhy && isSpoilerFacet(f.kind, f.value)) continue;
      if (reasonHit.contains(fid)) continue;
      var contrib = m.wFac[fid] * (w / 10) * c.facetIdf[fid] / fn;
      if (f.kind == 'genre' || f.kind == 'anilist_tag') contrib *= 0.55;
      if (contrib > 0.02 && w >= 4) {
        phrases.add((contrib, facetPhrase(f.kind, f.value), 'f$fid'));
      }
    }
    phrases.sort((a, b) => b.$1.compareTo(a.$1));
    final picked = <String>[];
    for (final p in phrases) {
      if (picked.length >= 2) break;
      if (!picked.contains(p.$2)) picked.add(p.$2);
    }
    // 3. strongest dimension
    String? dimPhrase, bestDimName;
    var bestDim = 0.0;
    for (var d = 0; d < D; d++) {
      final z = c.dimZ[idx * D + d];
      final contrib = m.wDim[d] * z;
      if (contrib > bestDim && z.abs() > 0.8) {
        if (spoilerFreeWhy && spoilerDims.contains(c.dimNames[d])) continue;
        final ph = dimPhrases[c.dimNames[d]];
        if (ph == null) continue;
        bestDim = contrib;
        if (z < 0 && !_loOk.contains(c.dimNames[d])) continue;
        dimPhrase = z > 0 ? ph.$1 : ph.$2;
        bestDimName = c.dimNames[d];
      }
    }
    final dimKey = bestDimName;
    final stems = dimKey == null
        ? <String>[]
        : dimKey.split('_').where((w) => w.length > 3).toList();
    String norm(String x) => x.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    final overlaps = picked.any(
      (p) => stems.any(
        (w) => norm(p).contains(norm(w).substring(0, norm(w).length - 1)),
      ),
    );
    if (dimPhrase != null && picked.length < 3 && !overlaps) {
      picked.add(dimPhrase);
    }
    // anchor: most similar watched title the user liked
    int? anchor;
    var bestA = -1.0;
    for (final (i, s) in m.positives) {
      if (s < 0.45) continue;
      final cs = c.cosine(idx, i) + 0.06 * s - 0.05 * (anchorUse?[i] ?? 0);
      if (cs > bestA) {
        bestA = cs;
        anchor = i;
      }
    }
    String text;
    if (picked.isEmpty) {
      text = 'Close to your taste overall';
    } else {
      text = _join(picked);
      text = text[0].toUpperCase() + text.substring(1);
    }
    if (seqOf >= 0) {
      text =
          'Continues ${c.titles[seqOf].display} (rated ${_fmt(m.byIdx[seqOf]?.rating)}) — $text';
    } else if (preOf >= 0) {
      text =
          'Prequel to ${c.titles[preOf].display} (rated ${_fmt(m.byIdx[preOf]?.rating)}) — $text';
      anchor = null;
    } else if (anchor != null && bestA > 0.3) {
      anchorUse?[anchor] = (anchorUse[anchor] ?? 0) + 1;
      final r = m.byIdx[anchor]?.rating;
      text =
          '$text, like ${c.titles[anchor].display}${r != null ? ' (you rated ${_fmt(r)})' : ''}';
    } else {
      anchor = null;
    }
    final tags = <String>[for (final p in picked.take(3)) p];
    return ('$text.', anchor, tags);
  }

  String _join(List<String> p) {
    if (p.length == 1) return p.first;
    if (p.length == 2) return '${p[0]} and ${p[1]}';
    return '${p[0]}, ${p[1]} and ${p[2]}';
  }

  static String _fmt(double? r) {
    if (r == null) return '—';
    return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
  }

  // --- taste profile summary -----------------------------------------------------
  TasteSummary summarize(TasteModel m) {
    final D = CatalogData.dimCount;
    final rated = m.positives.length + m.negatives.length;
    final ratings = [
      for (final e in m.byIdx.values)
        if (e.status == EntryStatus.watched && e.rating != null) e.rating!,
    ];
    final meanR = ratings.isEmpty
        ? 0.0
        : ratings.reduce((a, b) => a + b) / ratings.length;
    if (!m.hasSignal) {
      return TasteSummary(0, 0, [], [], [], [], {});
    }
    // weighted mean z of liked items minus half of disliked
    final pref = List<double>.filled(D, 0);
    final likedAvg = List<double>.filled(D, 0);
    var pw = 0.0, nw = 0.0;
    for (final (_, s) in m.positives) {
      pw += s;
    }
    for (final (_, s) in m.negatives) {
      nw += -s;
    }
    for (var d = 0; d < D; d++) {
      var pz = 0.0, nz = 0.0, pa = 0.0;
      for (final (i, s) in m.positives) {
        pz += s * c.dimZ[i * D + d];
        pa += s * c.dim(i, d);
      }
      for (final (i, s) in m.negatives) {
        nz += -s * c.dimZ[i * D + d];
      }
      final posMean = pw > 0 ? pz / pw : 0.0;
      final negMean = nw > 0 ? nz / nw : 0.0;
      pref[d] = posMean - (nw > 0 ? 0.5 * negMean : 0.0);
      likedAvg[d] = pw > 0 ? pa / pw : 5.0;
    }
    final order = List<int>.generate(D, (i) => i)
      ..sort((a, b) => pref[b].abs().compareTo(pref[a].abs()));
    final likes = <DimPref>[], avoids = <DimPref>[];
    for (final d in order) {
      if (pref[d].abs() < 0.35) continue;
      final dp = DimPref(c.dimNames[d], pref[d], likedAvg[d]);
      (pref[d] > 0 ? likes : avoids).add(dp);
    }
    // facets
    final num = <int, double>{}, den = <int, double>{}, sup = <int, int>{};
    void acc(int i, double s) {
      for (final (fid, w) in c.facetsOf(i)) {
        final k = c.vocab[fid].kind;
        if (k == 'content_warnings' || k == 'relationship_types') continue;
        if (w < 5) continue;
        num[fid] = (num[fid] ?? 0) + s * w / 10;
        den[fid] = (den[fid] ?? 0) + w / 10;
        sup[fid] = (sup[fid] ?? 0) + 1;
      }
    }

    for (final (i, s) in m.positives) {
      acc(i, s);
    }
    for (final (i, s) in m.negatives) {
      acc(i, s);
    }
    final fl = <FacetPref>[], fa = <FacetPref>[];
    num.forEach((fid, nv) {
      final f = c.vocab[fid];
      final reasonBoost = m.reasonFacets[fid] ?? 0;
      final support = sup[fid]!;
      if (support < 2 && reasonBoost == 0) return;
      final strength =
          (nv / (den[fid]! + 1.5)) * c.facetIdf[fid] + reasonBoost * 0.8;
      (strength > 0 ? fl : fa).add(
        FacetPref(f.kind, f.value, strength, support),
      );
    });
    fl.sort((a, b) => b.strength.compareTo(a.strength));
    fa.sort((a, b) => a.strength.compareTo(b.strength));
    final rc = <String, int>{};
    final xCounts = <String, int>{}, nCounts = <String>{};
    for (final e in m.byIdx.values) {
      for (final r in e.reasons) {
        if (r.startsWith('x:')) {
          xCounts[r.substring(2)] = (xCounts[r.substring(2)] ?? 0) + 1;
          continue;
        }
        if (r.startsWith('n:')) {
          nCounts.add(genericReasonByKey(r.substring(2))?.label ?? r);
          continue;
        }
        String label;
        if (r.startsWith('g:')) {
          label = genericReasonByKey(r.substring(2))?.label ?? r;
        } else {
          final parts = r.substring(2).split('|');
          label = parts.length == 2 ? facetChipLabel(parts[0], parts[1]) : r;
        }
        rc[label] = (rc[label] ?? 0) + 1;
      }
    }
    final disliked = <FacetPref>[];
    xCounts.forEach((k, n) {
      final parts = k.split('|');
      if (parts.length == 2)
        disliked.add(FacetPref(parts[0], parts[1], -n.toDouble(), n));
    });
    disliked.sort((a, b) => a.strength.compareTo(b.strength));
    return TasteSummary(
      rated,
      meanR,
      likes.take(8).toList(),
      avoids.take(6).toList(),
      fl.take(14).toList(),
      fa.take(8).toList(),
      rc,
      dislikedTags: disliked,
      dislikedAspects: nCounts.toList()..sort(),
    );
  }

  (double, double) _meanStd(Float32List a) {
    var s = 0.0, s2 = 0.0;
    for (final x in a) {
      s += x;
      s2 += x * x;
    }
    final mu = s / a.length;
    return (
      mu,
      math.max(math.sqrt(math.max(s2 / a.length - mu * mu, 0)), 1e-6),
    );
  }

  static double _sigmoid(double x) => 1 / (1 + math.exp(-x));
  static double _tanh(double x) {
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }
}

class _Scores {
  final Float32List emb, feat;
  _Scores(this.emb, this.feat);
}

class _Cand {
  final int idx;
  final double score, base, ze, zf;
  final int seqOf, preOf;
  _Cand(
    this.idx,
    this.score,
    this.base,
    this.ze,
    this.zf,
    this.seqOf,
    this.preOf,
  );
}

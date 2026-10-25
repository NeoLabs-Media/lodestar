import 'catalog_data.dart';

/// Hard filters for one scope. A scope is a media kind ('anime' | 'movie' | 'tv') or 'all' (a mix of
/// kinds, where only the *common* filters apply). Every scope keeps its own state, so switching
/// the media filter never loses what was chosen for another kind.
class ScopeFilters {
  // ---- common (all scopes) ----
  Set<String> categories = {}; // any-of, see categories.dart
  Set<String> moods = {}; // any-of
  Set<String> excludeWarnings = {};
  int? yearMin, yearMax;
  double? minScore; // 0..10

  // ---- anime ----
  Set<String> formats = {}; // TV | MOVIE | SHORT | OVA (OVA covers ONA/special)
  int? maxEpisodes;
  Set<String> studios = {}, sources = {};

  // ---- movies ----
  int? runtimeMin, runtimeMax; // minutes
  Set<String> decades = {}, directors = {};

  // ---- movies + TV ----
  Set<String> countries = {}, languages = {}, ratings = {};

  // ---- TV ----
  int? maxSeasons;
  Set<String> statuses = {}; // ongoing | ended | upcoming
  Set<String> creators = {};

  Map<String, dynamic> toJson() => {
    'categories': categories.toList(),
    'moods': moods.toList(),
    'excludeWarnings': excludeWarnings.toList(),
    'yearMin': yearMin,
    'yearMax': yearMax,
    'minScore': minScore,
    'formats': formats.toList(),
    'maxEpisodes': maxEpisodes,
    'studios': studios.toList(),
    'sources': sources.toList(),
    'runtimeMin': runtimeMin,
    'runtimeMax': runtimeMax,
    'decades': decades.toList(),
    'directors': directors.toList(),
    'countries': countries.toList(),
    'languages': languages.toList(),
    'ratings': ratings.toList(),
    'maxSeasons': maxSeasons,
    'statuses': statuses.toList(),
    'creators': creators.toList(),
  };

  static Set<String> _set(Object? v) =>
      ((v as List?) ?? const []).cast<String>().toSet();

  static ScopeFilters fromJson(Map<String, dynamic> m) => ScopeFilters()
    ..categories = _set(m['categories'])
    ..moods = _set(m['moods'])
    ..excludeWarnings = _set(m['excludeWarnings'])
    ..yearMin = (m['yearMin'] ?? m['minYear']) as int?
    ..yearMax = m['yearMax'] as int?
    ..minScore = (m['minScore'] as num?)?.toDouble()
    ..formats = _set(m['formats'])
    ..maxEpisodes = m['maxEpisodes'] as int?
    ..studios = _set(m['studios'])
    ..sources = _set(m['sources'])
    ..runtimeMin = m['runtimeMin'] as int?
    ..runtimeMax = m['runtimeMax'] as int?
    ..decades = _set(m['decades'])
    ..directors = _set(m['directors'])
    ..countries = _set(m['countries'])
    ..languages = _set(m['languages'])
    ..ratings = _set(m['ratings'])
    ..maxSeasons = m['maxSeasons'] as int?
    ..statuses = _set(m['statuses'])
    ..creators = _set(m['creators']);

  void clear() {
    final fresh = ScopeFilters();
    categories = fresh.categories;
    moods = fresh.moods;
    excludeWarnings = fresh.excludeWarnings;
    yearMin = yearMax = null;
    minScore = null;
    formats = fresh.formats;
    maxEpisodes = null;
    studios = fresh.studios;
    sources = fresh.sources;
    runtimeMin = runtimeMax = null;
    decades = fresh.decades;
    directors = fresh.directors;
    countries = fresh.countries;
    languages = fresh.languages;
    ratings = fresh.ratings;
    maxSeasons = null;
    statuses = fresh.statuses;
    creators = fresh.creators;
  }

  /// Number of active filters that apply in [scope] (others are kept but ignored).
  int activeCount(String scope) {
    var n = categories.length + moods.length + excludeWarnings.length;
    if (yearMin != null || yearMax != null) n++;
    if (minScore != null) n++;
    if (scope == 'anime') {
      n +=
          formats.length +
          studios.length +
          sources.length +
          (maxEpisodes != null ? 1 : 0);
    }
    if (scope == 'movie') {
      n +=
          decades.length +
          directors.length +
          countries.length +
          languages.length +
          ratings.length;
      if (runtimeMin != null || runtimeMax != null) n++;
    }
    if (scope == 'tv') {
      n +=
          countries.length +
          languages.length +
          ratings.length +
          statuses.length +
          creators.length;
      if (maxSeasons != null) n++;
    }
    return n;
  }

  /// Does [t] pass the filters that apply in [scope]? (`moodOk`/`warnBlocked` come from the caller,
  /// which already walks the title's facets.)
  bool passes(Show t, String scope) {
    if (yearMin != null && (t.year ?? 0) < yearMin!) return false;
    if (yearMax != null && (t.year == null || t.year! > yearMax!)) return false;
    if (minScore != null &&
        (t.meanScore == null || t.meanScore! / 10 < minScore!))
      return false;
    switch (scope) {
      case 'anime':
        if (formats.isNotEmpty) {
          final f = t.format ?? '';
          final g = f == 'TV'
              ? 'TV'
              : f == 'MOVIE'
              ? 'MOVIE'
              : f == 'TV_SHORT'
              ? 'SHORT'
              : 'OVA';
          if (!formats.contains(g)) return false;
        }
        if (maxEpisodes != null && (t.episodes ?? 0) > maxEpisodes!)
          return false;
        if (studios.isNotEmpty && !t.studios.any(studios.contains))
          return false;
        if (sources.isNotEmpty && !sources.contains(t.source)) return false;
      case 'movie':
        if (runtimeMin != null &&
            (t.runtime == null || t.runtime! < runtimeMin!))
          return false;
        if (runtimeMax != null &&
            (t.runtime == null || t.runtime! > runtimeMax!))
          return false;
        if (decades.isNotEmpty &&
            (t.year == null || !decades.contains('${t.year! ~/ 10 * 10}s')))
          return false;
        if (directors.isNotEmpty && !t.directors.any(directors.contains))
          return false;
        if (!_regional(t)) return false;
      case 'tv':
        if (maxSeasons != null &&
            (t.seasons == null || t.seasons! > maxSeasons!))
          return false;
        if (statuses.isNotEmpty && !statuses.contains(t.statusGroup))
          return false;
        if (creators.isNotEmpty && !t.creators.any(creators.contains))
          return false;
        if (!_regional(t)) return false;
    }
    return true;
  }

  bool _regional(Show t) {
    if (countries.isNotEmpty && !t.countries.any(countries.contains))
      return false;
    if (languages.isNotEmpty && !t.languages.any(languages.contains))
      return false;
    if (ratings.isNotEmpty && !ratings.contains(t.certification)) return false;
    return true;
  }

  /// One removable chip per active filter that applies in [scope]: (label, remove).
  List<(String, void Function())> chips(String scope) {
    final out = <(String, void Function())>[];
    void each(Set<String> set, String Function(String) label) {
      for (final v in set.toList()) {
        out.add((label(v), () => set.remove(v)));
      }
    }

    each(categories, (v) => v);
    each(moods, (v) => '$v mood');
    each(excludeWarnings, (v) => 'no $v');
    if (yearMin != null || yearMax != null) {
      out.add((
        yearMin != null && yearMax != null
            ? '$yearMin–$yearMax'
            : yearMin != null
            ? 'from $yearMin'
            : 'up to $yearMax',
        () => yearMin = yearMax = null,
      ));
    }
    if (minScore != null)
      out.add((
        'score ≥ ${minScore!.toStringAsFixed(1)}',
        () => minScore = null,
      ));
    if (scope == 'anime') {
      each(formats, (v) => v);
      if (maxEpisodes != null)
        out.add(('≤ $maxEpisodes ep', () => maxEpisodes = null));
      each(studios, (v) => v);
      each(sources, (v) => 'from ${v.toLowerCase()}');
    }
    if (scope == 'movie') {
      if (runtimeMin != null || runtimeMax != null) {
        out.add((
          runtimeMin != null && runtimeMax != null
              ? '$runtimeMin–$runtimeMax min'
              : runtimeMax != null
              ? '≤ $runtimeMax min'
              : '≥ $runtimeMin min',
          () => runtimeMin = runtimeMax = null,
        ));
      }
      each(decades, (v) => v);
      each(directors, (v) => 'dir. $v');
    }
    if (scope == 'movie' || scope == 'tv') {
      each(countries, (v) => v);
      each(languages, (v) => v);
      each(ratings, (v) => v);
    }
    if (scope == 'tv') {
      if (maxSeasons != null)
        out.add(('≤ $maxSeasons seasons', () => maxSeasons = null));
      each(statuses, (v) => v);
      each(creators, (v) => v);
    }
    return out;
  }

  /// Short human text of the filters that apply in [scope], for explanations ("PG-13, 80–120 min").
  String describe(String scope) {
    final p = <String>[];
    if (yearMin != null || yearMax != null) {
      p.add(
        yearMin != null && yearMax != null
            ? '$yearMin–$yearMax'
            : yearMin != null
            ? 'from $yearMin'
            : 'up to $yearMax',
      );
    }
    if (minScore != null) p.add('score ≥ ${minScore!.toStringAsFixed(1)}');
    if (moods.isNotEmpty) p.add('mood: ${moods.join('/')}');
    if (excludeWarnings.isNotEmpty)
      p.add('no ${excludeWarnings.join(', no ')}');
    if (scope == 'anime') {
      if (formats.isNotEmpty) p.add(formats.join('/'));
      if (maxEpisodes != null) p.add('≤ $maxEpisodes ep');
      if (studios.isNotEmpty) p.add(studios.join('/'));
      if (sources.isNotEmpty) p.add('from ${sources.join('/').toLowerCase()}');
    }
    if (scope == 'movie') {
      if (runtimeMin != null || runtimeMax != null) {
        p.add(
          runtimeMin != null && runtimeMax != null
              ? '$runtimeMin–$runtimeMax min'
              : runtimeMax != null
              ? '≤ $runtimeMax min'
              : '≥ $runtimeMin min',
        );
      }
      if (decades.isNotEmpty) p.add(decades.join('/'));
      if (directors.isNotEmpty) p.add('dir. ${directors.join('/')}');
    }
    if (scope == 'movie' || scope == 'tv') {
      if (countries.isNotEmpty) p.add(countries.join('/'));
      if (languages.isNotEmpty) p.add(languages.join('/'));
      if (ratings.isNotEmpty) p.add(ratings.join('/'));
    }
    if (scope == 'tv') {
      if (maxSeasons != null) p.add('≤ $maxSeasons seasons');
      if (statuses.isNotEmpty) p.add(statuses.join('/'));
      if (creators.isNotEmpty) p.add(creators.join('/'));
    }
    return p.join(', ');
  }
}

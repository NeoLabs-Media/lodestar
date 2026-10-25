import 'dart:convert';

import '../engine/catalog_data.dart';
import '../engine/catalog_loader.dart';
import '../engine/categories.dart';
import '../engine/labels.dart';
import '../engine/recommender.dart';
import '../engine/search.dart';
import 'llm.dart';

/// What the tools may touch. Everything is read through callbacks so tests can fake it and the
/// "allow the assistant to read my library" switch is evaluated on every call.
class AssistantContext {
  final CatalogStore store;
  final Recommender rec;
  final TitleSearch search;
  final Controls Function()
  controls; // the filters in force for the chat (hard constraints, see AssistantTools._controls)
  final List<UserEntry> Function() entries; // the user's library
  final bool Function() libraryAllowed;
  final bool Function()
  spoilers; // spoiler switch: false = tool results are spoiler-free (enforced here, not by the prompt)
  AssistantContext({
    required this.store,
    required this.rec,
    required this.search,
    required this.controls,
    required this.entries,
    required this.libraryAllowed,
    this.spoilers = _never,
  });
  static bool _never() => false;
  CatalogData get data => store.data;
}

/// A state-changing request from the model. Never executed by the model: the UI shows a
/// confirmation card and only the user's tap runs it.
class PendingAction {
  final String type; // plan | watched | skip
  final int idx;
  final double? rating;
  final String title;
  const PendingAction(this.type, this.idx, this.title, {this.rating});

  String get label => switch (type) {
    'plan' => 'Add “$title” to your plan-to-watch list',
    'watched' =>
      'Mark “$title” as watched${rating == null ? '' : ' with a ${rating == rating!.roundToDouble() ? rating!.toInt() : rating}/10'}',
    _ => 'Mark “$title” as not interested',
  };
}

class ToolOutcome {
  final Map<String, dynamic> json;
  final Set<int> ids; // catalog title ids that appear in the result
  final PendingAction? pending;
  const ToolOutcome(this.json, {this.ids = const {}, this.pending});
}

const _refusal = {
  'error': 'library_access_off',
  'message':
      'The user has not allowed the assistant to read their library and ratings. '
      'Tell them they can switch this on in Settings → AI assistant, and carry on with catalog-only help.',
};

class AssistantTools {
  final AssistantContext ctx;
  AssistantTools(this.ctx);

  static const _filterProps = {
    'year_min': {'type': 'integer'},
    'year_max': {'type': 'integer'},
    'min_score': {
      'type': 'number',
      'description': 'minimum average score on a 0-10 scale',
    },
    'max_runtime_min': {
      'type': 'integer',
      'description': 'movies: runtime upper bound in minutes',
    },
    'min_runtime_min': {'type': 'integer'},
    'country': {
      'type': 'string',
      'description': 'movies/TV: production country code or name',
    },
    'language': {'type': 'string'},
    'content_rating': {'type': 'string', 'description': 'e.g. PG-13, R, TV-MA'},
    'max_episodes': {
      'type': 'integer',
      'description': 'anime: maximum number of episodes',
    },
    'max_seasons': {
      'type': 'integer',
      'description': 'TV: maximum number of seasons',
    },
    'status': {
      'type': 'string',
      'enum': ['ongoing', 'ended'],
      'description': 'TV status',
    },
    'studio': {'type': 'string'},
    'director': {'type': 'string'},
    'mood': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'exclude_warnings': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'content warnings to avoid, e.g. gore',
    },
    'category': {
      'type': 'array',
      'items': {'type': 'string'},
      'description':
          'broad categories: romance, isekai, action, comedy, drama, …',
    },
  };

  static Map<String, dynamic> _obj(
    Map<String, dynamic> props, [
    List<String> required = const [],
  ]) => {
    'type': 'object',
    'properties': props,
    if (required.isNotEmpty) 'required': required,
  };

  static const _kindProp = {
    'type': 'string',
    'enum': ['anime', 'movie', 'tv'],
    'description': 'restrict to one media type',
  };
  static const _idProp = {
    'type': 'integer',
    'description': 'catalog title id as returned by the other tools',
  };

  static final specs = <ToolSpec>[
    ToolSpec(
      'search_catalog',
      'Search the catalog by title (any language, typo tolerant), or browse by filters when no query is given. '
          'The user\'s filters are always applied and cannot be loosened. Returns compact matches.',
      _obj({
        'query': {'type': 'string'},
        'kind': _kindProp,
        'limit': {
          'type': 'integer',
          'description': 'max results (default 6, max 10)',
        },
        'filters': _obj(_filterProps),
      }),
    ),
    ToolSpec(
      'get_title',
      'Details of one title: pitch, key dimensions, top tags, main characters, similar titles, content warnings. With the user\'s spoiler switch on it also has the full synopsis, ending and character arcs; with it off those are withheld.',
      _obj({'id': _idProp}, ['id']),
    ),
    ToolSpec(
      'get_recommendations',
      'The app\'s own recommender output for this user (with its reasons). Uses the library only if the user allowed it.',
      _obj({
        'n': {'type': 'integer', 'description': 'how many (default 5, max 10)'},
        'kind': _kindProp,
        'obscurity': {
          'type': 'number',
          'description': '0 = popular picks … 1 = deep cuts / hidden gems',
        },
        'mood': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'filters': _obj(_filterProps),
      }),
    ),
    ToolSpec(
      'find_similar',
      'Titles most similar to a given title (by the catalog\'s text embedding).',
      _obj(
        {
          'id': _idProp,
          'n': {'type': 'integer'},
          'kind': _kindProp,
          'filters': _obj(_filterProps),
        },
        ['id'],
      ),
    ),
    ToolSpec(
      'explain_match',
      'Why the recommender scores a title for this user (needs library access).',
      _obj({'id': _idProp}, ['id']),
    ),
    ToolSpec(
      'get_taste_profile',
      'What the app has learned about the user\'s taste (needs library access).',
      _obj({}),
    ),
    ToolSpec(
      'get_library_summary',
      'Counts, top rated, planned and recent titles of the user\'s library (needs library access).',
      _obj({'kind': _kindProp}),
    ),
    ToolSpec(
      'add_to_plan',
      'Ask to add a title to the plan-to-watch list. The user must confirm in the UI; it does NOT happen automatically.',
      _obj({'id': _idProp}, ['id']),
    ),
    ToolSpec(
      'mark_watched',
      'Ask to mark a title as watched, optionally with a 1-10 rating. The user must confirm in the UI.',
      _obj(
        {
          'id': _idProp,
          'rating': {'type': 'number'},
        },
        ['id'],
      ),
    ),
    ToolSpec(
      'not_interested',
      'Ask to mark a title as not interested. The user must confirm in the UI.',
      _obj({'id': _idProp}, ['id']),
    ),
  ];

  /// Runs one tool call. Never throws: failures come back as `{"error": …}` data for the model.
  ToolOutcome call(String name, String rawArgs) {
    Map<String, dynamic> a;
    try {
      final j = rawArgs.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(rawArgs);
      a = (j as Map).cast<String, dynamic>();
    } catch (_) {
      return const ToolOutcome({
        'error': 'invalid_arguments',
        'message': 'Arguments must be a JSON object.',
      });
    }
    try {
      switch (name) {
        case 'search_catalog':
          return _search(a);
        case 'get_title':
          return _getTitle(a);
        case 'get_recommendations':
          return _recommend(a);
        case 'find_similar':
          return _similar(a);
        case 'explain_match':
          return _explain(a);
        case 'get_taste_profile':
          return _taste();
        case 'get_library_summary':
          return _library(a);
        case 'add_to_plan':
          return _action('plan', a);
        case 'mark_watched':
          return _action('watched', a);
        case 'not_interested':
          return _action('skip', a);
        default:
          return ToolOutcome({
            'error': 'unknown_tool',
            'message': 'There is no tool called "$name".',
          });
      }
    } catch (e) {
      return const ToolOutcome({
        'error': 'tool_failed',
        'message': 'The tool failed; try different arguments.',
      });
    }
  }

  // ------------------------------------------------------------------ helpers
  Map<String, dynamic> compact(int idx, {Rec? rec, bool pitch = true}) {
    final t = ctx.data.titles[idx];
    final txt = t.oneliner.isNotEmpty ? t.oneliner : t.pitch;
    final m = <String, dynamic>{
      'id': t.id,
      'title': t.display,
      'kind': t.kind,
      'year': t.year,
      'format': t.format,
      'runtime_min': t.runtime,
      'episodes': (t.format == 'MOVIE' || t.episodes == null || t.episodes == 0)
          ? null
          : t.episodes,
      'seasons': t.seasons,
      'score': t.meanScore == null
          ? null
          : double.parse((t.meanScore! / 10).toStringAsFixed(1)),
      'genres': t.genres.take(3).toList(),
      if (pitch) 'pitch': _cut(txt, 150),
      if (rec != null) 'match_percent': rec.match.round(),
      if (rec != null) 'why': _cut(rec.why, 240),
      if (rec != null && rec.gem) 'hidden_gem': true,
    };
    m.removeWhere((k, v) => v == null || (v is List && v.isEmpty));
    return m;
  }

  static String _cut(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1).trimRight()}…';

  int? _idx(Map<String, dynamic> a) {
    final id = a['id'];
    final i = id is num ? id.toInt() : int.tryParse('$id');
    return i == null ? null : ctx.data.idToIdx[i];
  }

  static const _notFound = ToolOutcome({
    'error': 'not_found',
    'message':
        'No title with that id exists in the catalog. Only use ids returned by the tools.',
  });

  /// The user's filters (the chat's own, or the feed's, depending on the switch) as HARD constraints, with the
  /// model's tool arguments layered on top through [Controls.also]: both must hold, so a tool call can narrow
  /// the search but never loosen what the user set.
  Controls _controls(Map<String, dynamic> a) {
    final ctl = Controls.fromJson(ctx.controls().toJson());
    final m = Controls(); // the model's own constraints
    final f = <String, dynamic>{
      ...?(a['filters'] as Map?)?.cast<String, dynamic>(),
    };
    if (a['mood'] != null) f['mood'] = a['mood'];
    int? i(String k) => f[k] is num ? (f[k] as num).toInt() : null;
    List<String> l(String k) => f[k] is List
        ? (f[k] as List).map((e) => '$e').toList()
        : (f[k] is String ? ['${f[k]}'] : const []);

    // a media type named by the model, or implied by a type-specific argument
    final kind = a['kind'];
    if (kind is String && const {'anime', 'movie', 'tv'}.contains(kind)) {
      m.kinds = {kind};
    } else {
      final implied = <String>{
        if (i('max_runtime_min') != null ||
            i('min_runtime_min') != null ||
            l('director').isNotEmpty)
          'movie',
        if (i('max_episodes') != null || l('studio').isNotEmpty) 'anime',
        if (i('max_seasons') != null ||
            l('status').isNotEmpty ||
            l('creator').isNotEmpty)
          'tv',
      };
      if (implied.length == 1) m.kinds = implied;
    }
    final o = a['obscurity'];
    if (o is num) ctl.obscurity = o.toDouble().clamp(0.0, 1.0);

    // the arguments apply to whichever kind a title is: each kind's scope gets the same constraints
    m.perKind = true;
    for (final scope in const ['anime', 'movie', 'tv']) {
      final s = m.scopeFilters(scope);
      s.yearMin = i('year_min');
      s.yearMax = i('year_max');
      if (f['min_score'] is num)
        s.minScore = (f['min_score'] as num).toDouble();
      s.runtimeMax = i('max_runtime_min');
      s.runtimeMin = i('min_runtime_min');
      s.maxEpisodes = i('max_episodes');
      s.maxSeasons = i('max_seasons');
      s.countries.addAll(l('country'));
      s.languages.addAll(l('language'));
      s.ratings.addAll(l('content_rating'));
      s.statuses.addAll(l('status'));
      s.studios.addAll(l('studio'));
      s.directors.addAll(l('director'));
      s.creators.addAll(l('creator'));
      s.moods.addAll(l('mood'));
      s.excludeWarnings.addAll(l('exclude_warnings'));
      s.categories.addAll(
        l('category').where((k) => categories.any((c) => c.key == k)),
      );
    }
    ctl.also = m;
    return ctl;
  }

  /// The user's filters plus the arguments of this call, as short text.
  String _applied(Controls ctl) {
    final m = ctl.also;
    final extra = <String>{};
    if (m != null) {
      final scopes = m.kinds.isEmpty
          ? const ['anime', 'movie', 'tv']
          : m.kinds.toList();
      for (final k in scopes) {
        final d = m.scopeFilters(k).describe(k);
        if (d.isNotEmpty) extra.add(d);
      }
    }
    return [ctl.describe(), ...extra].where((x) => x.isNotEmpty).join(' · ');
  }

  /// What to tell the model when a search comes back empty.
  Map<String, dynamic> _emptyNote(Controls ctl) {
    final fl = ctl.describe();
    return {
      'note': fl.isEmpty
          ? 'Nothing in the catalog matches. Say so; do not invent titles.'
          : 'Nothing matches within the user\'s filters ($fl). Say so plainly: only the user can change the filters (filter button next to the message box). '
                'Never suggest titles that break them; do not invent titles.',
      if (fl.isNotEmpty) 'blocked_by_user_filters': true,
    };
  }

  /// Runs [fn] with the recommender's explanations set to the current spoiler mode.
  T _withMode<T>(T Function() fn) {
    final before = ctx.rec.spoilerFreeWhy;
    ctx.rec.spoilerFreeWhy = !ctx.spoilers();
    try {
      return fn();
    } finally {
      ctx.rec.spoilerFreeWhy = before;
    }
  }

  TasteModel _model() =>
      ctx.libraryAllowed() ? ctx.rec.fit(ctx.entries()) : ctx.rec.fit(const []);

  static int _n(Object? v, int def, int max) =>
      (v is num ? v.toInt() : def).clamp(1, max);

  // ------------------------------------------------------------------ read tools
  ToolOutcome _search(Map<String, dynamic> a) {
    final ctl = _controls(a);
    final limit = _n(a['limit'], 6, 10);
    final q = '${a['query'] ?? ''}'.trim();
    final List<int> idxs;
    if (q.isEmpty) {
      idxs = ctx.rec.browse(ctl, n: limit);
    } else {
      idxs = [
        for (final h in ctx.search.search(
          q,
          limit: 40,
          kind: ctl.kinds.length == 1 ? ctl.kinds.first : null,
        ))
          if (ctx.rec.passes(h.idx, ctl)) h.idx,
      ].take(limit).toList();
    }
    return ToolOutcome(
      {
        'results': [for (final i in idxs) compact(i)],
        if (_applied(ctl).isNotEmpty) 'filters_applied': _applied(ctl),
        if (idxs.isEmpty) ..._emptyNote(ctl),
      },
      ids: {for (final i in idxs) ctx.data.titles[i].id},
    );
  }

  ToolOutcome _getTitle(Map<String, dynamic> a) {
    final idx = _idx(a);
    if (idx == null) return _notFound;
    final d = ctx.data;
    final t = d.titles[idx];
    final det = ctx.store.detail(idx);
    final spoilers = ctx.spoilers();
    final zs = [
      for (var k = 0; k < CatalogData.dimCount; k++)
        if (spoilers || !spoilerDims.contains(d.dimNames[k]))
          (k, d.dimZ[idx * CatalogData.dimCount + k]),
    ]..sort((x, y) => y.$2.abs().compareTo(x.$2.abs()));
    final facets = [for (final (fid, w) in d.facetsOf(idx)) (fid, w)]
      ..sort((x, y) => y.$2.compareTo(x.$2));
    final tags = [
      for (final (fid, _) in facets)
        if (!const {
              'content_warnings',
              'relationship_types',
            }.contains(d.vocab[fid].kind) &&
            (spoilers ||
                !isSpoilerFacet(d.vocab[fid].kind, d.vocab[fid].value)))
          facetChipLabel(d.vocab[fid].kind, d.vocab[fid].value),
    ].take(8).toList();
    final rawChars = ((det['chars'] as List?) ?? const []).take(3);
    final chars = [
      for (final c in rawChars)
        spoilers
            ? '${c['n']} (${((c['a'] as List?) ?? const []).take(2).join(', ')}${c['arc'] == null ? '' : '; arc: ${c['arc']}'})'
            : '${c['n']}',
    ];
    final sims = ((det['sim'] as List?) ?? const []).take(5);
    final sim = [
      for (final s in sims)
        spoilers && (s['w'] ?? '') != ''
            ? '${s['t']} — ${s['w']}'
            : '${s['t']}',
    ];
    final warnings = [
      for (final w in ((det['cw'] as List?) ?? const []))
        if (spoilers || !isSpoilerFacet('content_warnings', '$w')) w,
    ].take(6).toList();
    final full = (det['full'] as String?) ?? '';
    final m = {
      ...compact(idx, pitch: false),
      // the spoiler-free pitch is always safe; the full synopsis and the ending only exist behind the switch
      'pitch': _cut((det['sf'] as String?) ?? t.pitch, 420),
      'spoilers': spoilers ? 'on' : 'off',
      if (!spoilers)
        'spoiler_note':
            'Spoilers are OFF: the full plot, ending and character fates are withheld. If the user asks for them, tell them the '
            'spoiler switch in the chat is off and that they can turn it on there; do not guess or hint.',
      if (spoilers && full.isNotEmpty) 'full_synopsis': _cut(full, 1400),
      if (spoilers && t.ending != null) 'ending': t.ending,
      if (spoilers && (det['endd'] as String?)?.isNotEmpty == true)
        'ending_description': det['endd'],
      'standout_dimensions': [
        for (final (k, z) in zs.take(6))
          '${z > 0 ? 'high' : 'low'} ${dimTitle(d.dimNames[k]).toLowerCase()}',
      ],
      'top_tags': tags,
      if (chars.isNotEmpty) 'main_characters': chars,
      if (spoilers && ((det['rels'] as List?) ?? const []).isNotEmpty)
        'key_relationships': [
          for (final r in (det['rels'] as List).take(3))
            '${r['a']} & ${r['b']}${(r['e'] ?? '') == '' ? '' : ': ${r['e']}'}',
        ],
      if (sim.isNotEmpty) 'similar_titles_by_name': sim,
      if (warnings.isNotEmpty) 'content_warnings': warnings,
      if (t.directors.isNotEmpty) 'directors': t.directors.take(3).toList(),
      if (t.studios.isNotEmpty) 'studios': t.studios.take(3).toList(),
      if (t.certification != null) 'content_rating': t.certification,
      if (t.countries.isNotEmpty) 'countries': t.countries.take(3).toList(),
    };
    return ToolOutcome(m, ids: {t.id});
  }

  ToolOutcome _recommend(Map<String, dynamic> a) {
    final ctl = _controls(a);
    final n = _n(a['n'], 5, 10);
    final allowed = ctx.libraryAllowed();
    final recs = _withMode(() => ctx.rec.recommend(_model(), ctl, count: n));
    return ToolOutcome(
      {
        'personalized': allowed && ctx.entries().isNotEmpty,
        if (!allowed)
          'note':
              'Library access is off, so these are quality picks, not personalised. The user can enable it in Settings → AI assistant.',
        if (_applied(ctl).isNotEmpty) 'filters_applied': _applied(ctl),
        'recommendations': [for (final r in recs) compact(r.idx, rec: r)],
        if (recs.isEmpty) ..._emptyNote(ctl),
      },
      ids: {for (final r in recs) ctx.data.titles[r.idx].id},
    );
  }

  ToolOutcome _similar(Map<String, dynamic> a) {
    final idx = _idx(a);
    if (idx == null) return _notFound;
    final ctl = _controls(a);
    final n = _n(a['n'], 5, 10);
    final d = ctx.data;
    final scored = <(int, double)>[];
    for (var i = 0; i < d.n; i++) {
      if (i == idx || !ctx.rec.passes(i, ctl)) continue;
      scored.add((i, d.cosine(idx, i)));
    }
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    final top = scored.take(n).toList();
    return ToolOutcome(
      {
        'similar_to': d.titles[idx].display,
        'results': [
          for (final (i, s) in top)
            {...compact(i), 'similarity': double.parse(s.toStringAsFixed(2))},
        ],
        if (top.isEmpty) ..._emptyNote(ctl),
      },
      ids: {d.titles[idx].id, for (final (i, _) in top) d.titles[i].id},
    );
  }

  ToolOutcome _explain(Map<String, dynamic> a) {
    if (!ctx.libraryAllowed()) return const ToolOutcome(_refusal);
    final idx = _idx(a);
    if (idx == null) return _notFound;
    final t = ctx.data.titles[idx];
    final own = ctx.entries().where((e) => e.id == t.id);
    if (own.isNotEmpty) {
      final e = own.first;
      return ToolOutcome(
        {
          'title': t.display,
          'in_library': true,
          'status': e.status.name,
          'rating': e.rating,
        },
        ids: {t.id},
      );
    }
    final r = _withMode(() => ctx.rec.scoreOne(idx, _model()));
    if (r == null)
      return ToolOutcome(
        {'title': t.display, 'note': 'Not scored.'},
        ids: {t.id},
      );
    return ToolOutcome(
      {
        'title': t.display,
        'match_percent': r.match.round(),
        'why': r.why,
        if (r.gem) 'hidden_gem': true,
      },
      ids: {t.id},
    );
  }

  ToolOutcome _taste() {
    if (!ctx.libraryAllowed()) return const ToolOutcome(_refusal);
    final entries = ctx.entries();
    if (entries.isEmpty)
      return const ToolOutcome({
        'note': 'The library is empty, so there is no taste profile yet.',
      });
    final s = ctx.rec.summarize(_model());
    String phrase(DimPref d, bool hi) {
      final p = dimPhrases[d.name];
      return p == null ? dimTitle(d.name) : (hi ? p.$1 : p.$1);
    }

    return ToolOutcome({
      'rated_titles': s.rated,
      'average_rating': double.parse(s.meanRating.toStringAsFixed(1)),
      'rewards': [for (final d in s.likes.take(6)) phrase(d, true)],
      'avoids': [for (final d in s.avoids.take(5)) phrase(d, true)],
      'liked_tags': [
        for (final f in s.facetLikes.take(8)) facetChipLabel(f.kind, f.value),
      ],
      'disliked_tags': [
        for (final f in s.facetAvoids.take(6)) facetChipLabel(f.kind, f.value),
      ],
      'explicitly_flagged_dislikes': [
        for (final f in s.dislikedTags) facetChipLabel(f.kind, f.value),
        ...s.dislikedAspects,
      ],
    });
  }

  ToolOutcome _library(Map<String, dynamic> a) {
    if (!ctx.libraryAllowed()) return const ToolOutcome(_refusal);
    final d = ctx.data;
    final kind = a['kind'] is String ? a['kind'] as String : null;
    final all = [
      for (final e in ctx.entries())
        if (d.idToIdx[e.id] != null &&
            (kind == null || d.titles[d.idToIdx[e.id]!].kind == kind))
          e,
    ];
    final watched = all.where((e) => e.status == EntryStatus.watched).toList();
    final rated = watched.where((e) => e.rating != null).toList()
      ..sort((x, y) => y.rating!.compareTo(x.rating!));
    final planned = all.where((e) => e.status == EntryStatus.planned).toList();
    final recent = [...watched]
      ..sort((x, y) => y.updatedAt.compareTo(x.updatedAt));
    Map<String, dynamic> row(UserEntry e) => {
      ...compact(d.idToIdx[e.id]!, pitch: false),
      if (e.rating != null) 'your_rating': e.rating,
    };
    final ids = <int>{};
    List<Map<String, dynamic>> rows(Iterable<UserEntry> es, int n) {
      final out = <Map<String, dynamic>>[];
      for (final e in es.take(n)) {
        out.add(row(e));
        ids.add(e.id);
      }
      return out;
    }

    return ToolOutcome(
      {
        'watched': watched.length,
        'planned': planned.length,
        'not_interested': all
            .where((e) => e.status == EntryStatus.notInterested)
            .length,
        'average_rating': rated.isEmpty
            ? null
            : double.parse(
                (rated.fold<double>(0, (s, e) => s + e.rating!) / rated.length)
                    .toStringAsFixed(1),
              ),
        'top_rated': rows(rated, 12),
        'planned_titles': rows(planned, 8),
        'recently_watched': rows(recent, 8),
      }..removeWhere((k, v) => v == null),
      ids: ids,
    );
  }

  // ------------------------------------------------------------------ state-changing (confirmation required)
  ToolOutcome _action(String type, Map<String, dynamic> a) {
    final idx = _idx(a);
    if (idx == null) return _notFound;
    final t = ctx.data.titles[idx];
    double? rating;
    if (type == 'watched' && a['rating'] is num)
      rating = ((a['rating'] as num).toDouble().clamp(1, 10) * 2).round() / 2;
    final p = PendingAction(type, idx, t.display, rating: rating);
    return ToolOutcome(
      {
        'status': 'awaiting_user_confirmation',
        'action': p.label,
        'message':
            'Nothing has changed yet. The user sees a confirmation card and must tap it. Tell them it is waiting for their confirmation.',
      },
      ids: {t.id},
      pending: p,
    );
  }
}

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
  final Set<String>
  reasons; // skip only: n:aspect / x:kind|value, validated against the title
  final bool
  asked; // the user already answered "what put you off?" for this action
  const PendingAction(
    this.type,
    this.idx,
    this.title, {
    this.rating,
    this.reasons = const {},
    this.asked = false,
  });

  PendingAction withReasons(Set<String> r) =>
      PendingAction(type, idx, title, rating: rating, reasons: r, asked: true);

  String get label => switch (type) {
    'plan' => 'Add “$title” to your plan-to-watch list',
    'watched' =>
      'Mark “$title” as watched${rating == null ? '' : ' with a ${rating == rating!.roundToDouble() ? rating!.toInt() : rating}/10'}',
    _ =>
      'Mark “$title” as not interested${reasons.isEmpty ? '' : ' (because: ${_reasonText(reasons)})'}',
  };
}

String _reasonText(Set<String> reasons) => [
  for (final r in reasons)
    if (r.startsWith('n:'))
      genericReasonByKey(r.substring(2))?.label.toLowerCase() ?? r.substring(2)
    else if (r.startsWith('x:'))
      _kv(r.substring(2)),
].join(', ');

String _kv(String kindValue) {
  final p = kindValue.split('|');
  return (p.length == 2 ? facetChipLabel(p[0], p[1]) : kindValue).toLowerCase();
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
  static const _seenProp = {
    'type': 'boolean',
    'description':
        'default true when library access is on: leave out titles the user watched, skipped or ignored. Set false only if they ask for things they have seen.',
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
        'exclude_seen': _seenProp,
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
          'exclude_seen': _seenProp,
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
      'check_library',
      'Did the user watch / plan / skip these? Resolves free-text titles (typo tolerant, romaji or English) and/or ids and returns, for each, '
          'the matched catalog title, the library status, the rating and franchise_seen. Use it for "did I watch X?" and "have I seen any of these?". Needs library access.',
      _obj({
        'titles': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'titles as the user typed them (max 20)',
        },
        'ids': {
          'type': 'array',
          'items': {'type': 'integer'},
        },
      }),
    ),
    ToolSpec(
      'list_library',
      'Walk the user\'s library page by page (use when they ask what they watched, rated highest, planned, skipped). Needs library access.',
      _obj({
        'status': {
          'type': 'string',
          'enum': ['watched', 'planned', 'not_interested', 'ignored'],
        },
        'kind': _kindProp,
        'sort': {
          'type': 'string',
          'enum': ['recent', 'rating', 'title'],
        },
        'limit': {
          'type': 'integer',
          'description': 'page size (default 15, max 30)',
        },
        'offset': {'type': 'integer'},
      }),
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
      'Ask to mark a title as not interested. The user must confirm in the UI. Optionally say what puts them off '
          '(only if they told you): tags of that title such as "slow-burn romance", or aspects like pacing, fanservice, violence / gore.',
      _obj(
        {
          'id': _idProp,
          'reasons': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'what the user dislikes about this title',
          },
        },
        ['id'],
      ),
    ),
  ];

  /// Runs one tool call. Never throws: failures come back as `{"error": …}` data for the model.
  ToolOutcome call(String name, String rawArgs) {
    _libCache = null;
    final out = _call(name, rawArgs);
    // with library access off the model must know it cannot tell what was watched
    if (!ctx.libraryAllowed() &&
        out.ids.isNotEmpty &&
        !out.json.containsKey('error')) {
      return ToolOutcome(
        {...out.json, 'library_known': false},
        ids: out.ids,
        pending: out.pending,
      );
    }
    return out;
  }

  ToolOutcome _call(String name, String rawArgs) {
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
        case 'check_library':
          return _checkLibrary(a);
        case 'list_library':
          return _listLibrary(a);
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
    m.addAll(_libraryFields(idx));
    return m;
  }

  static String _cut(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1).trimRight()}…';

  // ------------------------------------------------------------------ library status on every title
  Map<int, UserEntry>? _libCache;
  Map<int, UserEntry> get _lib =>
      _libCache ??= {for (final e in ctx.entries()) e.id: e};

  String _reasonLabels1(String r) {
    if (r.startsWith('g:') || r.startsWith('n:'))
      return genericReasonByKey(r.substring(2))?.label.toLowerCase() ??
          r.substring(2);
    final p = r.substring(2).split('|');
    return p.length == 2
        ? facetChipLabel(p[0], p[1]).toLowerCase()
        : r.substring(2);
  }

  /// `library` (+ `franchise_seen`) for one title; empty when library access is off.
  Map<String, dynamic> _libraryFields(int idx) {
    if (!ctx.libraryAllowed()) return const {};
    final d = ctx.data;
    final t = d.titles[idx];
    final e = _lib[t.id];
    bool ok(String r) =>
        ctx.spoilers() ||
        !(r.startsWith('f:') || r.startsWith('x:')) ||
        !isSpoilerFacet(
          r.substring(2).split('|').first,
          r.substring(2).split('|').last,
        );
    final liked = e == null
        ? <String>[]
        : [
            for (final r in e.reasons)
              if ((r.startsWith('g:') || r.startsWith('f:')) && ok(r))
                _reasonLabels1(r),
          ];
    final disliked = e == null
        ? <String>[]
        : [
            for (final r in e.reasons)
              if ((r.startsWith('n:') || r.startsWith('x:')) && ok(r))
                _reasonLabels1(r),
          ];
    final lib = <String, dynamic>{
      'status': e == null
          ? 'none'
          : switch (e.status) {
              EntryStatus.watched => 'watched',
              EntryStatus.planned => 'planned',
              EntryStatus.notInterested => 'not_interested',
              EntryStatus.ignored => 'ignored',
            },
      if (e?.rating != null) 'rating': e!.rating,
      if (liked.isNotEmpty) 'liked': liked.take(6).toList(),
      if (disliked.isNotEmpty) 'disliked': disliked.take(6).toList(),
    };
    // related entries of the same franchise that the user has watched or planned
    final seen = <String>[];
    for (final (o, type) in d.relations[idx]) {
      final other = d.titles[o];
      final oe = _lib[other.id];
      if (oe == null ||
          (oe.status != EntryStatus.watched &&
              oe.status != EntryStatus.planned))
        continue;
      final part = switch (type) {
        'PREQUEL' || 'PARENT' => 'previous part',
        'SEQUEL' => 'sequel',
        'SIDE_STORY' => 'side story',
        'SPIN_OFF' => 'spin-off',
        'SUMMARY' || 'ALTERNATIVE' => 'alternate version',
        _ => 'related entry',
      };
      seen.add(
        'you ${oe.status == EntryStatus.watched ? 'watched' : 'planned'} the $part: ${other.display}${oe.rating == null ? '' : ' (rated ${oe.rating == oe.rating!.roundToDouble() ? oe.rating!.toInt() : oe.rating})'}',
      );
      if (seen.length >= 2) break;
    }
    return {
      'library': lib,
      if (seen.isNotEmpty) 'franchise_seen': seen.join('; '),
    };
  }

  bool _isSeen(int idx) {
    if (!ctx.libraryAllowed()) return false;
    final e = _lib[ctx.data.titles[idx].id];
    return e != null &&
        (e.status == EntryStatus.watched ||
            e.status == EntryStatus.notInterested ||
            e.status == EntryStatus.ignored);
  }

  /// Keeps up to [limit] titles; seen ones are dropped (and counted) when [exclude].
  (List<int>, int) _dropSeen(List<int> idxs, int limit, bool exclude) {
    final kept = <int>[];
    var hidden = 0;
    for (final i in idxs) {
      if (kept.length >= limit) break;
      if (exclude && _isSeen(i)) {
        hidden++;
      } else {
        kept.add(i);
      }
    }
    return (kept, hidden);
  }

  bool _excludeSeen(Map<String, dynamic> a) =>
      ctx.libraryAllowed() && a['exclude_seen'] != false;

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
    final exclude = _excludeSeen(a);
    final List<int> pool;
    if (q.isEmpty) {
      pool = ctx.rec.browse(ctl, n: limit * 4 + 30);
    } else {
      pool = [
        for (final h in ctx.search.search(
          q,
          limit: 40,
          kind: ctl.kinds.length == 1 ? ctl.kinds.first : null,
        ))
          if (ctx.rec.passes(h.idx, ctl)) h.idx,
      ];
    }
    final (idxs, hidden) = _dropSeen(pool, limit, exclude);
    return ToolOutcome(
      {
        'results': [for (final i in idxs) compact(i)],
        if (_applied(ctl).isNotEmpty) 'filters_applied': _applied(ctl),
        if (hidden > 0) 'hidden_seen_count': hidden,
        if (hidden > 0)
          'note_seen':
              '$hidden matching title(s) were left out because the user already watched, skipped or ignored them. '
              'If they asked about a specific title or want things they have seen, call again with exclude_seen=false (or use check_library).',
        if (idxs.isEmpty && hidden == 0) ..._emptyNote(ctl),
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
        if (allowed) ..._excludedCounts(),
        'recommendations': [for (final r in recs) compact(r.idx, rec: r)],
        if (recs.isEmpty) ..._emptyNote(ctl),
      },
      ids: {for (final r in recs) ctx.data.titles[r.idx].id},
    );
  }

  /// How many catalog titles the recommender leaves out because they are already in the library.
  Map<String, dynamic> _excludedCounts() {
    var w = 0, n = 0, g = 0, p = 0;
    for (final e in ctx.entries()) {
      if (ctx.data.idToIdx[e.id] == null) continue;
      switch (e.status) {
        case EntryStatus.watched:
          w++;
        case EntryStatus.notInterested:
          n++;
        case EntryStatus.ignored:
          g++;
        case EntryStatus.planned:
          p++;
      }
    }
    return {
      'hidden_seen_count': w + n + g,
      'left_out_because_in_library': {
        'watched': w,
        'not_interested': n,
        'ignored': g,
        'planned': p,
      },
      'note_seen':
          'These picks never include titles the user already watched, skipped or ignored.',
    };
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
    final exclude = _excludeSeen(a);
    var hidden = 0;
    final top = <(int, double)>[];
    for (final e in scored) {
      if (top.length >= n) break;
      if (exclude && _isSeen(e.$1)) {
        hidden++;
        continue;
      }
      top.add(e);
    }
    return ToolOutcome(
      {
        'similar_to': d.titles[idx].display,
        'results': [
          for (final (i, s) in top)
            {...compact(i), 'similarity': double.parse(s.toStringAsFixed(2))},
        ],
        if (hidden > 0) 'hidden_seen_count': hidden,
        if (top.isEmpty && hidden == 0) ..._emptyNote(ctl),
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
          ..._libraryFields(idx),
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
        ..._libraryFields(idx),
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

  /// "Did I watch X?" — resolves free-text titles (or ids) the way the app's own search does.
  ToolOutcome _checkLibrary(Map<String, dynamic> a) {
    if (!ctx.libraryAllowed()) return const ToolOutcome(_refusal);
    final rows = <Map<String, dynamic>>[];
    final ids = <int>{};
    void add(String query, int? idx) {
      if (idx == null) {
        rows.add({'query': query, 'match': 'not found in the catalog'});
        return;
      }
      final t = ctx.data.titles[idx];
      ids.add(t.id);
      rows.add({'query': query, ...compact(idx, pitch: false)});
    }

    for (final t in ((a['titles'] as List?) ?? const []).take(20)) {
      final q = '$t'.trim();
      if (q.isEmpty) continue;
      add(q, ctx.search.bestMatch(q));
    }
    for (final i in ((a['ids'] as List?) ?? const []).take(20)) {
      final n = i is num ? i.toInt() : int.tryParse('$i');
      add('id ${n ?? i}', n == null ? null : ctx.data.idToIdx[n]);
    }
    if (rows.isEmpty)
      return const ToolOutcome({
        'error': 'invalid_arguments',
        'message': 'Give "titles" (free text) and/or "ids".',
      });
    return ToolOutcome({'results': rows}, ids: ids);
  }

  static const _pageCap = 30;

  /// Walks the user's library in pages.
  ToolOutcome _listLibrary(Map<String, dynamic> a) {
    if (!ctx.libraryAllowed()) return const ToolOutcome(_refusal);
    final d = ctx.data;
    final status = switch ('${a['status'] ?? ''}') {
      'watched' => EntryStatus.watched,
      'planned' => EntryStatus.planned,
      'not_interested' => EntryStatus.notInterested,
      'ignored' => EntryStatus.ignored,
      _ => null,
    };
    final kind = a['kind'] is String ? a['kind'] as String : null;
    final all = [
      for (final e in ctx.entries())
        if (d.idToIdx[e.id] != null &&
            (status == null || e.status == status) &&
            (kind == null || d.titles[d.idToIdx[e.id]!].kind == kind))
          e,
    ];
    final sort = '${a['sort'] ?? 'recent'}';
    all.sort(
      (x, y) => switch (sort) {
        'rating' => (y.rating ?? -1).compareTo(x.rating ?? -1),
        'title' => d.titles[d.idToIdx[x.id]!].display.toLowerCase().compareTo(
          d.titles[d.idToIdx[y.id]!].display.toLowerCase(),
        ),
        _ => y.updatedAt.compareTo(x.updatedAt),
      },
    );
    final limit = _n(a['limit'], 15, _pageCap);
    final offset = a['offset'] is num
        ? (a['offset'] as num).toInt().clamp(0, all.length)
        : 0;
    final page = all.skip(offset).take(limit).toList();
    return ToolOutcome(
      {
        'total': all.length,
        'offset': offset,
        'returned': page.length,
        'has_more': offset + page.length < all.length,
        if (offset + page.length < all.length)
          'next_offset': offset + page.length,
        'items': [
          for (final e in page) compact(d.idToIdx[e.id]!, pitch: false),
        ],
      },
      ids: {for (final e in page) e.id},
    );
  }

  // ------------------------------------------------------------------ state-changing (confirmation required)
  /// Keeps only reasons that really are one of this title's tags or a known aspect.
  (Set<String>, {List<String> dropped}) _skipReasons(
    int idx,
    List<String> wanted,
  ) {
    final byName = <String, String>{};
    for (final (fid, w) in ctx.data.facetsOf(idx)) {
      final f = ctx.data.vocab[fid];
      if (w < 3) continue;
      final key = 'x:${f.kind}|${f.value}';
      byName[f.value.toLowerCase()] = key;
      byName[facetChipLabel(f.kind, f.value).toLowerCase()] = key;
    }
    for (final g in [...genericReasons, ...dislikeOnlyAspects]) {
      byName[g.key] = 'n:${g.key}';
      byName[g.label.toLowerCase()] = 'n:${g.key}';
    }
    byName['violence'] = 'n:gore';
    byName['gore'] = 'n:gore';
    final ok = <String>{};
    final dropped = <String>[];
    for (final w in wanted) {
      final k = byName[w.trim().toLowerCase()];
      k == null ? dropped.add(w) : ok.add(k);
    }
    return (ok, dropped: dropped);
  }

  ToolOutcome _action(String type, Map<String, dynamic> a) {
    final idx = _idx(a);
    if (idx == null) return _notFound;
    final t = ctx.data.titles[idx];
    double? rating;
    if (type == 'watched' && a['rating'] is num)
      rating = ((a['rating'] as num).toDouble().clamp(1, 10) * 2).round() / 2;
    var reasons = <String>{};
    final dropped = <String>[];
    if (type == 'skip' && a['reasons'] is List) {
      final r = _skipReasons(
        idx,
        (a['reasons'] as List).map((e) => '$e').toList(),
      );
      reasons = r.$1;
      dropped.addAll(r.dropped);
    }
    final p = PendingAction(
      type,
      idx,
      t.display,
      rating: rating,
      reasons: reasons,
      asked: reasons.isNotEmpty,
    );
    return ToolOutcome(
      {
        if (dropped.isNotEmpty) 'ignored_reasons': dropped,
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

/// Human-readable wording for facets, dimensions and the generic "what I liked" chips.
library;

const kindTitles = {
  'anilist_tag': 'Tag',
  'appeal_factors': 'Appeal',
  'archetypes': 'Character type',
  'character_arc_types': 'Character arc',
  'comedy_styles': 'Comedy',
  'content_warnings': 'Content',
  'ending_types': 'Ending',
  'genre': 'Genre',
  'moods': 'Mood',
  'narrative_devices': 'Narrative device',
  'relationship_dynamics': 'Relationship',
  'relationship_types': 'Relationship type',
  'romance_dynamics': 'Romance',
  'romance_payoffs': 'Romance payoff',
  'setting_types': 'Setting',
  'story_structures': 'Structure',
  'themes': 'Theme',
};

String _an(String v) => RegExp(r'^[aeiouAEIOU]').hasMatch(v) ? 'an $v' : 'a $v';

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Short chip label, e.g. "Slow burn romance".
String facetChipLabel(String kind, String value) {
  String suffix(String word) {
    final v = _cap(value);
    return value.toLowerCase().contains(word) ? v : '$v $word';
  }

  switch (kind) {
    case 'romance_dynamics':
      return suffix('romance');
    case 'ending_types':
      return suffix('ending');
    case 'moods':
      return suffix('mood');
    case 'comedy_styles':
      return suffix('comedy');
    case 'archetypes':
      return suffix('characters');
    case 'relationship_dynamics':
      return suffix('dynamic');
    default:
      return _cap(value);
  }
}

/// Phrase that fits into "…because it has (phrase)".
String facetPhrase(String kind, String value) {
  switch (kind) {
    case 'romance_dynamics':
      return value.contains('romance') ? value : '$value romance';
    case 'romance_payoffs':
      return 'a "$value" romantic payoff';
    case 'ending_types':
      return '${_an(value)} ending';
    case 'moods':
      return '${_an(value)} mood';
    case 'themes':
      return 'themes of $value';
    case 'archetypes':
      return '$value characters';
    case 'relationship_dynamics':
      return '$value relationships';
    case 'relationship_types':
      return '$value bonds';
    case 'narrative_devices':
      return '$value storytelling';
    case 'comedy_styles':
      return '$value humour';
    case 'setting_types':
      return '${_an(value)} setting';
    case 'story_structures':
      return '${_an(value)} structure';
    case 'character_arc_types':
      return '${_an(value)} character arc';
    case 'appeal_factors':
      return 'strong $value appeal';
    case 'content_warnings':
      return value;
    default:
      return value;
  }
}

/// (high-phrase, low-phrase) per dimension.
const dimPhrases = <String, (String, String)>{
  'romance_centrality': (
    'romance at the heart of the story',
    'little to no romance',
  ),
  'romance_slow_burn': ('a slow-burning romance', 'quick-moving romance'),
  'romantic_payoff': ('a satisfying romantic payoff', 'no romantic payoff'),
  'fanservice': ('plenty of fanservice', 'almost no fanservice'),
  'sexual_content': ('sexual content', 'no sexual content'),
  'action_intensity': ('intense action', 'calm pacing without action'),
  'violence_gore': ('graphic violence', 'little violence'),
  'psychological_darkness': ('psychological darkness', 'a light tone'),
  'horror_dread': ('horror and dread', 'no horror'),
  'tragedy': ('real tragedy', 'little tragedy'),
  'tearjerker': ('tearjerker moments', 'few tearjerker moments'),
  'comedy': ('lots of comedy', 'little comedy'),
  'absurdity': ('absurd humour', 'a grounded tone'),
  'wholesomeness': ('warmth and wholesomeness', 'a cynical edge'),
  'hype': ('goosebump hype moments', 'a calm mood'),
  'tension_suspense': ('edge-of-seat tension', 'a relaxed mood'),
  'mystery_intrigue': ('mystery-driven plotting', 'no puzzle-box mysteries'),
  'plot_complexity': ('intricate plotting', 'a simple, clear plot'),
  'worldbuilding_depth': ('deep worldbuilding', 'minimal worldbuilding'),
  'character_depth': (
    'psychologically rich characters',
    'light character work',
  ),
  'character_growth': ('profound character growth', 'static characters'),
  'protagonist_power': (
    'an overpowered protagonist',
    'an underdog protagonist',
  ),
  'protagonist_agency': (
    'a protagonist who drives the story',
    'a protagonist carried by events',
  ),
  'ensemble_focus': ('a true ensemble cast', 'a single-protagonist focus'),
  'moral_ambiguity': ('moral ambiguity', 'clear good-vs-evil'),
  'philosophical_depth': ('philosophical depth', 'no philosophising'),
  'intellectual_strategy': ('battles of wits', 'little strategy'),
  'realism': ('a realistic feel', 'a fantastical setting'),
  'slice_of_life': ('everyday slice-of-life', 'plot-first storytelling'),
  'pacing_speed': ('breakneck pacing', 'slow, meditative pacing'),
  'serialization': ('tightly serialized storytelling', 'an episodic structure'),
  'optimism': ('an uplifting outlook', 'a bleak outlook'),
  'ending_satisfaction': ('a satisfying ending', 'an unresolved ending'),
  'emotional_catharsis': ('emotional catharsis', 'little catharsis'),
  'found_family': ('found family', 'no found-family theme'),
  'rivalry_competition': ('rivalry and competition', 'no rivalry plot'),
  'mature_themes': ('mature themes', 'kid-friendly themes'),
  'youth_focus': ('school and teen life', 'an adult cast'),
  'cringe_factor': ('cringe comedy', 'little cringe'),
  'cuteness': ('moe cuteness', 'no cutesy tone'),
  'coolness_style': ('dripping style', 'a plain style'),
  'visual_spectacle_expected': ('spectacular animation', 'modest visuals'),
  'newcomer_accessibility': (
    'easy entry for newcomers',
    'a steep entry barrier',
  ),
  'rewatch_value': ('high rewatch value', 'little rewatch value'),
  'commitment': ('a long commitment', 'a short commitment'),
};

String dimTitle(String name) => _cap(name.replaceAll('_', ' '));

/// A generic "what I liked" reason: which dimensions it maps onto.
class GenericReason {
  final String key, label;
  final Map<String, double> dims; // dimension -> weight
  final List<String> facetKinds; // facet kinds that are "about" this reason
  const GenericReason(
    this.key,
    this.label,
    this.dims, {
    this.facetKinds = const [],
  });
}

const genericReasons = <GenericReason>[
  GenericReason(
    'characters',
    'Characters',
    {'character_depth': 1, 'character_growth': .8, 'ensemble_focus': .3},
    facetKinds: ['archetypes', 'character_arc_types'],
  ),
  GenericReason(
    'romance',
    'Romance',
    {'romance_centrality': 1, 'romantic_payoff': .6, 'romance_slow_burn': .4},
    facetKinds: ['romance_dynamics', 'romance_payoffs'],
  ),
  GenericReason(
    'story',
    'Story / plot',
    {'plot_complexity': .9, 'serialization': .6, 'mystery_intrigue': .5},
    facetKinds: ['story_structures'],
  ),
  GenericReason(
    'ending',
    'The ending',
    {'ending_satisfaction': 1, 'emotional_catharsis': .5},
    facetKinds: ['ending_types'],
  ),
  GenericReason(
    'world',
    'World & lore',
    {'worldbuilding_depth': 1, 'realism': -.1},
    facetKinds: ['setting_types'],
  ),
  GenericReason(
    'emotion',
    'Emotional impact',
    {'tearjerker': .9, 'emotional_catharsis': .8, 'tragedy': .5},
    facetKinds: ['moods'],
  ),
  GenericReason(
    'humor',
    'Humor',
    {'comedy': 1, 'absurdity': .3},
    facetKinds: ['comedy_styles'],
  ),
  GenericReason('pacing', 'Pacing', {
    'pacing_speed': .7,
    'hype': .5,
    'tension_suspense': .4,
  }),
  GenericReason('visuals', 'Visuals & music', {
    'visual_spectacle_expected': 1,
    'coolness_style': .8,
  }),
  GenericReason(
    'ideas',
    'Themes & ideas',
    {'philosophical_depth': 1, 'moral_ambiguity': .5, 'mature_themes': .4},
    facetKinds: ['themes'],
  ),
];

/// Aspects people dislike but rarely list as a reason to love something; offered only in "Not for me".
const dislikeOnlyAspects = <GenericReason>[
  GenericReason('fanservice', 'Fanservice', {
    'fanservice': 1,
    'sexual_content': .5,
  }),
  GenericReason('gore', 'Violence / gore', {
    'violence_gore': 1,
    'horror_dread': .4,
  }),
  GenericReason('length', 'Too long', {'commitment': 1, 'serialization': .4}),
];

GenericReason? genericReasonByKey(String key) {
  for (final g in dislikeOnlyAspects) {
    if (g.key == key) return g;
  }
  for (final g in genericReasons) {
    if (g.key == key) return g;
  }
  return null;
}

/// Facet kinds that mostly describe how a story ends or turns out.
const _spoilerKinds = {
  'ending_types',
  'romance_payoffs',
  'character_arc_types',
  'narrative_devices',
};
final _spoilerWords = RegExp(
  r'twist|death|dies|dead|killed|reveal|betray|sacrific|ending|unreliable|identity|plot ?armor|tragic end|major character|spoiler',
  caseSensitive: false,
);

/// Is this tag / content warning something that gives away the plot?
bool isSpoilerFacet(String kind, String value) =>
    _spoilerKinds.contains(kind) || _spoilerWords.hasMatch(value);

/// Dimensions that describe the outcome rather than the experience.
const spoilerDims = {
  'ending_satisfaction',
  'romantic_payoff',
  'tragedy',
  'emotional_catharsis',
};

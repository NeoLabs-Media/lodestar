/// Broad browse categories for the feed filter. A title is in a category when it has ANY of the
/// listed genre/tag facets at or above the weight (0–10 scale in the catalog).
class Category {
  final String key, label;
  final List<(String kind, String value, double minWeight)> any;

  /// Only makes sense for anime (isekai, mecha…): offered when anime is the selected type, not under "all media".
  final bool animeOnly;
  const Category(this.key, this.label, this.any, {this.animeOnly = false});
}

const categories = <Category>[
  Category('drama', 'Drama', [
    ('genre', 'drama', 4),
    ('anilist_tag', 'tragedy', 5),
    ('anilist_tag', 'coming of age', 5),
  ]),
  Category('comedy', 'Comedy', [
    ('genre', 'comedy', 5),
    ('anilist_tag', 'parody', 5),
    ('anilist_tag', 'slapstick', 5),
    ('anilist_tag', 'surreal comedy', 5),
  ]),
  Category('action', 'Action', [
    ('genre', 'action', 4),
    ('anilist_tag', 'swordplay', 5),
    ('anilist_tag', 'martial arts', 5),
  ]),
  Category('crime', 'Crime', [
    ('genre', 'crime', 4),
    ('genre', 'film-noir', 4),
  ]),
  Category('mystery', 'Mystery & thriller', [
    ('genre', 'mystery', 4),
    ('genre', 'thriller', 4),
    ('anilist_tag', 'detective', 4),
    ('anilist_tag', 'crime', 5),
    ('anilist_tag', 'conspiracy', 5),
  ]),
  Category('romance', 'Romance', [
    ('genre', 'romance', 3),
    ('anilist_tag', 'love triangle', 4),
    ('anilist_tag', 'unrequited love', 4),
    ('anilist_tag', 'yuri', 4),
    ('anilist_tag', "boys' love", 4),
  ]),
  Category('scifi', 'Sci-Fi', [
    ('genre', 'sci-fi', 4),
    ('genre', 'science fiction', 4),
    ('anilist_tag', 'space', 5),
    ('anilist_tag', 'cyberpunk', 4),
    ('anilist_tag', 'aliens', 5),
  ]),
  Category('fantasy', 'Fantasy', [
    ('genre', 'fantasy', 4),
    ('anilist_tag', 'urban fantasy', 5),
    ('anilist_tag', 'dragons', 4),
    ('anilist_tag', 'medieval', 5),
  ]),
  Category('horror', 'Horror', [
    ('genre', 'horror', 3),
    ('anilist_tag', 'body horror', 4),
  ]),
  Category('adventure', 'Adventure', [
    ('genre', 'adventure', 4),
    ('anilist_tag', 'travel', 5),
  ]),
  Category('documentary', 'Documentary', [('genre', 'documentary', 4)]),
  Category('biography', 'Biography', [('genre', 'biography', 4)]),
  Category('historical', 'Historical', [
    ('genre', 'history', 4),
    ('genre', 'war', 4),
    ('anilist_tag', 'historical', 5),
    ('anilist_tag', 'samurai', 5),
    ('anilist_tag', 'war', 6),
  ]),
  Category('family', 'Family', [('genre', 'family', 4)]),
  Category('animation', 'Animation', [('genre', 'animation', 4)]),
  Category('music', 'Music', [
    ('genre', 'music', 3),
    ('genre', 'musical', 3),
    ('anilist_tag', 'idol', 5),
  ]),
  Category('western', 'Western', [('genre', 'western', 4)]),
  Category('sports', 'Sports', [('genre', 'sports', 3), ('genre', 'sport', 3)]),
  Category('supernatural', 'Supernatural', [
    ('genre', 'supernatural', 4),
    ('anilist_tag', 'youkai', 5),
    ('anilist_tag', 'ghost', 5),
    ('anilist_tag', 'vampire', 5),
    ('anilist_tag', 'demons', 5),
  ]),
  Category('psych', 'Psychological', [('genre', 'psychological', 3)]),
  Category('isekai', 'Isekai', [
    ('anilist_tag', 'isekai', 3),
    ('anilist_tag', 'reincarnation', 4),
  ], animeOnly: true),
  Category('mecha', 'Mecha', [
    ('genre', 'mecha', 3),
    ('anilist_tag', 'robots', 5),
    ('anilist_tag', 'super robot', 4),
    ('anilist_tag', 'real robot', 4),
  ], animeOnly: true),
  Category('school', 'School', [
    ('anilist_tag', 'school', 6),
    ('anilist_tag', 'school club', 5),
  ], animeOnly: true),
  Category('slice', 'Slice of life', [
    ('genre', 'slice of life', 4),
    ('anilist_tag', 'iyashikei', 4),
    ('anilist_tag', 'cute girls doing cute things', 5),
  ], animeOnly: true),
  Category('mahou', 'Magical girl', [
    ('genre', 'mahou shoujo', 3),
  ], animeOnly: true),
];

/// Is [k] worth offering for the current selection? Anime-only categories show up under "Anime" (or when the
/// catalog is anime-only), generic ones everywhere.
bool categoryVisible(
  Category k,
  Set<String> selectedKinds,
  Set<String> catalogKinds,
) =>
    !k.animeOnly ||
    catalogKinds.length == 1 ||
    (selectedKinds.length == 1 && selectedKinds.contains('anime'));

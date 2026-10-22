/// Broad browse categories for the feed filter. A title is in a category when it has ANY of the
/// listed genre/tag facets at or above the weight (0–10 scale in the catalog).
class Category {
  final String key, label;
  final List<(String kind, String value, double minWeight)> any;
  const Category(this.key, this.label, this.any);
}

const categories = <Category>[
  Category('romance', 'Romance', [('genre', 'romance', 3), ('anilist_tag', 'love triangle', 4), ('anilist_tag', 'unrequited love', 4), ('anilist_tag', 'yuri', 4), ('anilist_tag', "boys' love", 4)]),
  Category('isekai', 'Isekai', [('anilist_tag', 'isekai', 3), ('anilist_tag', 'reincarnation', 4)]),
  Category('action', 'Action', [('genre', 'action', 4), ('anilist_tag', 'swordplay', 5), ('anilist_tag', 'martial arts', 5)]),
  Category('adventure', 'Adventure', [('genre', 'adventure', 4), ('anilist_tag', 'travel', 5)]),
  Category('fantasy', 'Fantasy', [('genre', 'fantasy', 4), ('anilist_tag', 'urban fantasy', 5), ('anilist_tag', 'dragons', 4), ('anilist_tag', 'medieval', 5)]),
  Category('scifi', 'Sci-Fi', [('genre', 'sci-fi', 4), ('anilist_tag', 'space', 5), ('anilist_tag', 'cyberpunk', 4), ('anilist_tag', 'aliens', 5)]),
  Category('mecha', 'Mecha', [('genre', 'mecha', 3), ('anilist_tag', 'robots', 5), ('anilist_tag', 'super robot', 4), ('anilist_tag', 'real robot', 4)]),
  Category('comedy', 'Comedy', [('genre', 'comedy', 5), ('anilist_tag', 'parody', 5), ('anilist_tag', 'slapstick', 5), ('anilist_tag', 'surreal comedy', 5)]),
  Category('drama', 'Drama', [('genre', 'drama', 4), ('anilist_tag', 'tragedy', 5), ('anilist_tag', 'coming of age', 5)]),
  Category('slice', 'Slice of life', [('genre', 'slice of life', 4), ('anilist_tag', 'iyashikei', 4), ('anilist_tag', 'cute girls doing cute things', 5)]),
  Category('school', 'School', [('anilist_tag', 'school', 6), ('anilist_tag', 'school club', 5)]),
  Category('mystery', 'Mystery & thriller', [('genre', 'mystery', 4), ('genre', 'thriller', 4), ('anilist_tag', 'detective', 4), ('anilist_tag', 'crime', 5), ('anilist_tag', 'conspiracy', 5)]),
  Category('psych', 'Psychological', [('genre', 'psychological', 3)]),
  Category('horror', 'Horror', [('genre', 'horror', 3), ('anilist_tag', 'body horror', 4)]),
  Category('supernatural', 'Supernatural', [('genre', 'supernatural', 4), ('anilist_tag', 'youkai', 5), ('anilist_tag', 'ghost', 5), ('anilist_tag', 'vampire', 5), ('anilist_tag', 'demons', 5)]),
  Category('sports', 'Sports', [('genre', 'sports', 3)]),
  Category('music', 'Music', [('genre', 'music', 3), ('anilist_tag', 'idol', 5)]),
  Category('historical', 'Historical', [('anilist_tag', 'historical', 5), ('anilist_tag', 'samurai', 5), ('anilist_tag', 'war', 6)]),
  Category('mahou', 'Magical girl', [('genre', 'mahou shoujo', 3)]),
];

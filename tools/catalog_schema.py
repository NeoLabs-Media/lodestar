"""Shared definition of the catalog.db format (schema 2) and of catalog_delta files.

Schema history
  1  anime only. title(id, anilist, mal, …, thumb, pic, …); rel/rec reference other titles by
     AniList id (other_anilist).
  2  multi-media. title gains key, kind ('anime'|'movie'|'tv'), tmdb, imdb, release_date, cover,
     updated_at; rel/rec reference other titles by *key* (other_key); meta carries `snapshot`
     (the profile.updated_at watermark the catalog contains).

Title keys are stable external identities (the internal `id` is only stable while the source DB
lives):  anime -> 'anilist:N' | 'mal:N';  movie/tv -> 'tmdb:<movie|tv>:N' | 'imdb:ttN';
fallback 'id:<internal id>'.

A delta file (`catalog_delta.db`) is a small catalog of just the new/changed titles plus a
`delta_meta` table {format, from, to, built_at} and an optional `removed(id)` table. Facet ids in a
delta are local to the delta (its own facet_vocab); the merge remaps them by (kind, value).
"""
import sqlite3

SCHEMA_VERSION = 2
DELTA_FORMAT = 1

DIM_ORDER = [
    "romance_centrality", "romance_slow_burn", "romantic_payoff", "fanservice", "sexual_content",
    "action_intensity", "violence_gore", "psychological_darkness", "horror_dread", "tragedy",
    "tearjerker", "comedy", "absurdity", "wholesomeness", "hype", "tension_suspense",
    "mystery_intrigue", "plot_complexity", "worldbuilding_depth", "character_depth",
    "character_growth", "protagonist_power", "protagonist_agency", "ensemble_focus",
    "moral_ambiguity", "philosophical_depth", "intellectual_strategy", "realism",
    "slice_of_life", "pacing_speed", "serialization", "optimism", "ending_satisfaction",
    "emotional_catharsis", "found_family", "rivalry_competition", "mature_themes",
    "youth_focus", "cringe_factor", "cuteness", "coolness_style", "visual_spectacle_expected",
    "newcomer_accessibility", "rewatch_value", "commitment",
]

TITLE_COLUMNS = [
    ("id", "INTEGER PRIMARY KEY"), ("key", "TEXT"), ("kind", "TEXT DEFAULT 'anime'"),
    ("anilist", "INT"), ("mal", "INT"), ("tmdb", "INT"), ("imdb", "TEXT"),
    ("title", "TEXT"), ("title_en", "TEXT"), ("syn", "TEXT"), ("year", "INT"), ("season", "TEXT"),
    ("format", "TEXT"), ("episodes", "INT"), ("status", "TEXT"), ("release_date", "TEXT"),
    ("popularity", "INT"), ("mean_score", "REAL"), ("tier", "TEXT"), ("quality", "REAL"),
    ("thumb", "TEXT"), ("pic", "TEXT"), ("cover", "TEXT"), ("pitch", "TEXT"), ("oneliner", "TEXT"),
    ("ending", "TEXT"), ("genres", "TEXT"), ("adult", "INT"), ("emb", "BLOB"), ("dims", "BLOB"),
    ("facets", "BLOB"), ("detail", "BLOB"), ("updated_at", "REAL"),
]
TITLE_NAMES = [c for c, _ in TITLE_COLUMNS]


def create_schema(db: sqlite3.Connection, delta: bool = False) -> None:
    cols = ", ".join(f"{n} {t}" for n, t in TITLE_COLUMNS)
    db.executescript(f"""
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS title({cols});
    CREATE TABLE IF NOT EXISTS rel(id INT, other_key TEXT, type TEXT);
    CREATE TABLE IF NOT EXISTS rec(id INT, other_key TEXT, rating INT);
    CREATE TABLE IF NOT EXISTS facet_vocab(fid INTEGER PRIMARY KEY, kind TEXT, value TEXT, df INT);
    CREATE INDEX IF NOT EXISTS rel_id ON rel(id);
    CREATE INDEX IF NOT EXISTS rec_id ON rec(id);
    """)
    if delta:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS delta_meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS removed(id INTEGER PRIMARY KEY);
        """)


def title_key(kind, ids, internal_id):
    ids = ids or {}
    if kind == "anime":
        if ids.get("anilist"):
            return f"anilist:{ids['anilist']}"
        if ids.get("mal"):
            return f"mal:{ids['mal']}"
    else:
        if ids.get("tmdb"):
            return f"tmdb:{kind}:{ids['tmdb']}"
        if ids.get("imdb"):
            return f"imdb:{ids['imdb']}"
    return f"id:{internal_id}"


def pack_facets(pairs):
    """[(fid, weight 0..10)] -> bytes (uint16 fid LE + uint8 weight*25), strongest first."""
    b = bytearray()
    for fid, w in sorted(pairs, key=lambda p: -p[1]):
        b += bytes((fid & 255, fid >> 8, int(round(max(0, min(10, w)) * 25))))
    return bytes(b)


def unpack_facets(blob):
    return [(blob[i] | (blob[i + 1] << 8), blob[i + 2] / 25.0) for i in range(0, len(blob) - 2, 3)]


def quantize(vec, scale):
    out = bytearray()
    for v in vec:
        q = max(-127, min(127, int(round(v * scale))))
        out.append(q & 255)
    return bytes(out)


def dequantize(blob, scale):
    return [((b - 256) if b > 127 else b) / scale for b in blob]

#!/usr/bin/env python3
"""Builds the synthetic catalogs used by the Dart tests (pure stdlib, deterministic).

  test/fixtures/mixed.db         schema 3: 10 anime + 8 movies + 6 TV, titles without anilist ids, filter columns
  test/fixtures/legacy_v2.db     the same catalog in the schema-2 layout (no filter columns)
  test/fixtures/legacy_v1.db     schema 1 layout (anime only) to exercise the migration
  test/fixtures/delta_ok.db      from 100 -> 200: 3 new titles, 1 changed, 1 removed (own facet ids)
  test/fixtures/delta_gap.db     from 150 -> 250 (installed catalog is at 100: must be rejected)
  test/fixtures/delta_stale.db   from 0 -> 90 (older than the installed catalog: no-op)

Run:  python3 tools/make_fixture.py
"""
import json
import math
import random
import sqlite3
import zlib
from pathlib import Path

from catalog_schema import (COLUMN_SINCE, DELTA_FORMAT, DIM_ORDER, SCHEMA_VERSION, TITLE_NAMES, columns_for, create_schema,
                            pack_facets, quantize, title_key)

OUT = Path(__file__).resolve().parent.parent / "test" / "fixtures"
EMB_DIM = 16
CLUSTERS = ["romance", "action", "comedy", "scifi", "drama", "thriller"]
BIAS = {
    "romance": {"romance_centrality": 8, "tearjerker": 6, "romance_slow_burn": 6},
    "action": {"action_intensity": 8, "hype": 7, "violence_gore": 5},
    "comedy": {"comedy": 8, "absurdity": 5, "wholesomeness": 6},
    "scifi": {"worldbuilding_depth": 7, "plot_complexity": 6, "intellectual_strategy": 5},
    "drama": {"tragedy": 6, "character_depth": 7, "emotional_catharsis": 6},
    "thriller": {"tension_suspense": 8, "mystery_intrigue": 7, "psychological_darkness": 6},
}
GENRE = {"romance": "romance", "action": "action", "comedy": "comedy", "scifi": "sci-fi", "drama": "drama",
         "thriller": "thriller"}
VOCAB = [("genre", g) for g in GENRE.values()] + [
    ("anilist_tag", "isekai"), ("anilist_tag", "school"), ("keyword", "time travel"), ("keyword", "heist"),
    ("keyword", "road trip"), ("keyword", "school"), ("moods", "bittersweet"), ("moods", "tense"), ("moods", "cozy"),
    ("ending_types", "bittersweet"), ("themes", "grief"),
]


def unit(v):
    n = math.sqrt(sum(x * x for x in v)) or 1
    return [x / n for x in v]


rnd = random.Random(7)
CENTERS = {c: unit([rnd.gauss(0, 1) for _ in range(EMB_DIM)]) for c in CLUSTERS}


def filter_cols(tid, kind, popularity):
    """deterministic values for the schema-3 filter columns"""
    if kind == "anime":
        return {"runtime": 24, "countries": "JP", "languages": "ja", "certification": None, "seasons": None,
                "directors": None, "studios": "Studio A" if tid % 2 else "Studio B", "creators": None,
                "source": "MANGA" if tid % 3 else "ORIGINAL", "votes": None}
    if kind == "movie":
        j = tid - 100
        return {"runtime": 85 + j * 12, "countries": "US" if j % 2 else "FR", "languages": "en" if j % 2 else "fr",
                "certification": ["PG", "PG-13", "R"][j % 3], "seasons": None, "directors": f"Director {'AB'[j % 2]}",
                "studios": None, "creators": None, "source": None, "votes": 1000 * j}
    k = tid - 200
    return {"runtime": 45, "countries": "US" if k % 2 else "GB", "languages": "en", "certification": ["TV-14", "TV-MA"][k % 2],
            "seasons": k, "directors": None, "studios": None, "creators": f"Creator {k % 3}\nNetwork {'XY'[k % 2]}",
            "source": None, "votes": 500 * k}


def make_title(tid, kind, cluster, name, *, anilist=None, mal=None, tmdb=None, imdb=None, extra_facets=(),
               recs=(), rels=(), year=2015, popularity=1000, updated=50.0, fmt=None, pitch=None, episodes=None):
    r = random.Random(tid * 131)
    emb = unit([c + 0.25 * r.gauss(0, 1) for c in CENTERS[cluster]])
    dims = bytearray()
    for d in DIM_ORDER:
        base = BIAS[cluster].get(d, 3) + r.uniform(-1, 1)
        dims.append(int(round(max(0, min(10, base)) * 25)))
    ids = {"anilist": anilist, "mal": mal, "tmdb": tmdb, "imdb": imdb}
    key = title_key(kind, ids, tid)
    facets = [(("genre", GENRE[cluster]), 9.0)] + [(f, w) for f, w in extra_facets]
    return {
        "id": tid, "key": key, "kind": kind, "anilist": anilist, "mal": mal, "tmdb": tmdb, "imdb": imdb,
        "title": name, "title_en": None, "syn": f"{name} alt\nalt {name}", "year": year, "season": None,
        "format": fmt or ("TV" if kind in ("anime", "tv") else "MOVIE"), "episodes": episodes or (12 if kind != "movie" else 1),
        "status": "RELEASING" if (kind == "tv" and tid % 2) else "FINISHED", "release_date": f"{year}-06-01", "popularity": popularity, "mean_score": 70 + (tid % 20),
        "tier": "compact", "quality": 7.0, "thumb": None if kind != "anime" else f"https://img.example/{tid}t.jpg",
        "pic": None if kind != "anime" else f"https://img.example/{tid}.jpg",
        "cover": f"https://img.example/{tid}.jpg", "pitch": pitch or f"A {cluster} story called {name}.",
        "oneliner": f"{name}: one line.", "ending": "bittersweet" if tid % 3 == 0 else "happy",
        "genres": GENRE[cluster], "adult": 0, "emb": emb, "dims": bytes(dims), "facet_pairs": facets,
        "detail": {"sf": f"Spoiler-free text for {name}.", "full": f"SECRET-FULL-PLOT of {name}: the hero dies.",
                   "end": "tragic", "endd": "SECRET-ENDING-DESCRIPTION",
                   "chars": [{"n": "Ann", "a": ["mentor"], "m": "SECRET-MINDSET", "arc": "SECRET-FATE-ARC"}],
                   "rels": [{"a": "Ann", "b": "Bo", "t": ["allies"], "e": "SECRET-RELATION-TURN", "rom": False}],
                   "sim": [{"t": "Other Show", "w": "SECRET-TWIST-WHY"}],
                   "cw": ["gore", "death of a major character"], "moods": [], "themes": [], "dur": 24}, "updated_at": updated,
        **filter_cols(tid, kind, popularity),
        "recs": list(recs), "rels": list(rels),
    }


def base_titles():
    t = []
    for i in range(1, 11):
        cl = CLUSTERS[(i - 1) % 6]
        kw = dict(year=2005 + i, popularity=200000 // i, updated=40.0 + i)
        if i <= 8:
            kw["anilist"] = 1000 + i
        if i == 9:
            kw["mal"] = 9009
        extra = [(("anilist_tag", "isekai"), 8.0)] if i in (2, 3) else []
        rels = [("anilist:1002", "SEQUEL")] if i == 1 else ([("anilist:1001", "PREQUEL")] if i == 2 else [])
        recs = [("anilist:1004", 5), ("anilist:1005", 3)] if i == 1 else []
        t.append(make_title(i, "anime", cl, f"Fixture Anime {i}", extra_facets=extra, rels=rels, recs=recs, **kw))
    for j in range(1, 9):
        tid = 100 + j
        cl = CLUSTERS[(j + 1) % 6]
        kw = dict(year=2000 + j * 2, popularity=90000 // j, updated=60.0 + j)
        if j == 8:
            kw["imdb"] = "tt108"
        else:
            kw["tmdb"] = 5000 + j
        kws = [(("keyword", ["time travel", "heist", "road trip"][j % 3]), 7.0)]
        if j == 2:
            kws.append((("keyword", "school"), 8.0))  # movie keyword that maps onto the "School" category
        recs = [("tmdb:movie:5002", 4), ("tmdb:tv:7001", 2)] if j == 1 else []
        t.append(make_title(tid, "movie", cl, f"Fixture Movie {j}", extra_facets=kws, recs=recs, **kw))
    for k in range(1, 7):
        tid = 200 + k
        cl = CLUSTERS[(k + 3) % 6]
        recs = [("tmdb:movie:5001", 3)] if k == 1 else []
        t.append(make_title(tid, "tv", cl, f"Fixture Series {k}", tmdb=7000 + k, year=2010 + k, popularity=60000 // k,
                            updated=80.0 + k, extra_facets=[(("keyword", "road trip"), 6.0)], recs=recs))
    return t


def write_catalog(path, titles, vocab, *, snapshot, schema=SCHEMA_VERSION, delta=None, removed=()):
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    scale = 127.0 / max(abs(x) for t in titles for x in t["emb"])
    fid = {v: i for i, v in enumerate(vocab)}
    if schema == 1:
        create_v1(db)
    else:
        create_schema(db, delta=delta is not None, schema=schema)
    for k, (kind, val) in enumerate(vocab):
        db.execute("INSERT INTO facet_vocab VALUES(?,?,?,?)", (k, kind, val, 5))
    for t in titles:
        blob = pack_facets([(fid[f], w) for f, w in t["facet_pairs"] if f in fid])
        det = zlib.compress(json.dumps(t["detail"], separators=(",", ":")).encode(), 9)
        if schema == 1:
            db.execute("INSERT INTO title VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                t["id"], t["anilist"], t["mal"], t["title"], t["title_en"], t["syn"], t["year"], t["season"], t["format"],
                t["episodes"], t["status"], t["popularity"], t["mean_score"], t["tier"], t["quality"], t["thumb"],
                t["pic"], t["pitch"], t["oneliner"], t["ending"], t["genres"], 0, quantize(t["emb"], scale), t["dims"], blob, det))
            for other, typ in t["rels"]:
                if other.startswith("anilist:"):
                    db.execute("INSERT INTO rel VALUES(?,?,?)", (t["id"], int(other.split(":")[1]), typ))
            for other, rating in t["recs"]:
                if other.startswith("anilist:"):
                    db.execute("INSERT INTO rec VALUES(?,?,?)", (t["id"], int(other.split(":")[1]), rating))
        else:
            row = dict(t, adult=0, emb=quantize(t["emb"], scale), facets=blob, detail=det)
            cols = [n for n, _ in columns_for(schema)]
            db.execute(f"INSERT INTO title({','.join(cols)}) VALUES({','.join('?' * len(cols))})", [row[c] for c in cols])
            for other, typ in t["rels"]:
                db.execute("INSERT INTO rel VALUES(?,?,?)", (t["id"], other, typ))
            for other, rating in t["recs"]:
                db.execute("INSERT INTO rec VALUES(?,?,?)", (t["id"], other, rating))
    meta = {"schema": schema, "built_at": "2026-01-01 00:00", "count": len(titles), "emb_dim": EMB_DIM, "emb_scale": scale,
            "model": "fixture", "dims": json.dumps(DIM_ORDER), "snapshot": snapshot}
    for k, v in meta.items():
        db.execute("INSERT INTO meta VALUES(?,?)", (k, str(v)))
    if delta is not None:
        for k, v in {"format": DELTA_FORMAT, **delta}.items():
            db.execute("INSERT INTO delta_meta VALUES(?,?)", (k, str(v)))
        for rid in removed:
            db.execute("INSERT INTO removed VALUES(?)", (rid,))
    db.commit()
    db.close()


def create_v1(db):
    db.executescript("""
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE title(id INTEGER PRIMARY KEY, anilist INT, mal INT, title TEXT, title_en TEXT,
      syn TEXT, year INT, season TEXT, format TEXT, episodes INT, status TEXT, popularity INT,
      mean_score REAL, tier TEXT, quality REAL, thumb TEXT, pic TEXT, pitch TEXT, oneliner TEXT,
      ending TEXT, genres TEXT, adult INT, emb BLOB, dims BLOB, facets BLOB, detail BLOB);
    CREATE TABLE rel(id INT, other_anilist INT, type TEXT);
    CREATE TABLE rec(id INT, other_anilist INT, rating INT);
    CREATE TABLE facet_vocab(fid INTEGER PRIMARY KEY, kind TEXT, value TEXT, df INT);
    CREATE INDEX rel_id ON rel(id);
    """)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    base = base_titles()
    write_catalog(OUT / "mixed.db", base, VOCAB, snapshot=100.0)
    write_catalog(OUT / "legacy_v2.db", base, VOCAB, snapshot=100.0, schema=2)
    write_catalog(OUT / "legacy_v1.db", [t for t in base if t["kind"] == "anime"], VOCAB, snapshot=100.0, schema=1)

    # delta: own (shuffled + extended) facet numbering, different embedding scale
    dvocab = list(reversed(VOCAB)) + [("keyword", "space opera")]
    new_anime = make_title(11, "anime", "action", "Fixture Anime 11", anilist=1011, year=2024, popularity=500, updated=150.0)
    new_movie = make_title(109, "movie", "scifi", "Fixture Movie 9", tmdb=5009, year=2024, popularity=700, updated=160.0,
                           extra_facets=[(("keyword", "space opera"), 8.0), (("keyword", "time travel"), 7.0)],
                           recs=[("tmdb:movie:5001", 4)])
    new_tv = make_title(207, "tv", "thriller", "Fixture Series 7", tmdb=7007, year=2024, popularity=300, updated=170.0,
                        extra_facets=[(("keyword", "heist"), 7.0)])
    changed = next(t for t in base if t["id"] == 3)
    changed = dict(changed, title="Fixture Anime 3 (Director's Cut)", popularity=424242, pitch="Updated pitch.", updated_at=155.0)
    changed["emb"] = [x * 0.9 for x in changed["emb"]]  # slightly different vector; scale differs too
    write_catalog(OUT / "delta_ok.db", [new_anime, new_movie, new_tv, changed], dvocab, snapshot=200.0,
                  delta={"from": 100.0, "to": 200.0, "built_at": "2026-02-01 00:00"}, removed=[5])
    write_catalog(OUT / "delta_v2.db", [new_movie, new_tv], dvocab, snapshot=200.0, schema=2,
                  delta={"from": 100.0, "to": 200.0, "built_at": "2026-02-01 00:00"})
    write_catalog(OUT / "delta_gap.db", [make_title(12, "tv", "comedy", "Fixture Series 12", tmdb=7012, updated=240.0)],
                  VOCAB, snapshot=250.0, delta={"from": 150.0, "to": 250.0, "built_at": "x"})
    write_catalog(OUT / "delta_stale.db", [make_title(13, "movie", "drama", "Fixture Movie 13", tmdb=5013, updated=80.0)],
                  VOCAB, snapshot=90.0, delta={"from": 0.0, "to": 90.0, "built_at": "x"})
    print("fixtures written to", OUT)


if __name__ == "__main__":
    main()

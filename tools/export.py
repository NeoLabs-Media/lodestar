#!/usr/bin/env python3
"""Build the bundled catalog asset (assets/data/catalog.db) from the slim server snapshot.

  1. merge cache/slim_new.db (a slim export of the source profile DB) into cache/slim.db   (incremental)
  2. embed embedding_text with BAAI/bge-small-en-v1.5 (fastembed/ONNX, CPU); cached by text hash
  3. write a compact SQLite catalog the Flutter app copies to its data dir on first run

Run:  .venv/bin/python export.py [--limit N] [--skip-merge]
"""
import argparse
import hashlib
import json
import re
import sqlite3
import sys
import time
import zlib
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
CACHE = HERE / "cache"
OUT = HERE.parent / "assets" / "data" / "catalog.db"
MODEL = "BAAI/bge-small-en-v1.5"
EMB_DIM = 384
SCHEMA_VERSION = 1
MIN_FACET_DF = 3
FACET_KINDS = [
    "anilist_tag", "appeal_factors", "archetypes", "character_arc_types", "comedy_styles",
    "content_warnings", "ending_types", "genre", "moods", "narrative_devices",
    "relationship_dynamics", "relationship_types", "romance_dynamics", "romance_payoffs",
    "setting_types", "story_structures", "themes",
]
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


def clip(s, n):
    s = (s or "").strip()
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def merge():
    new = CACHE / "slim_new.db"
    if not new.exists():
        print("no slim_new.db to merge")
        return
    db = sqlite3.connect(CACHE / "slim.db")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS slim(anime_id INTEGER PRIMARY KEY, updated_at REAL, quality REAL,
      profile TEXT, embedding_text TEXT, title TEXT, title_english TEXT, synonyms TEXT, picture TEXT,
      thumbnail TEXT, popularity INT, score REAL, tier TEXT);
    CREATE TABLE IF NOT EXISTS facet(anime_id INT, facet TEXT, value TEXT, weight REAL, canonical INT);
    CREATE INDEX IF NOT EXISTS facet_a ON facet(anime_id);
    """)
    db.execute("ATTACH ? AS n", (str(new),))
    db.execute("DELETE FROM facet WHERE anime_id IN (SELECT anime_id FROM n.slim)")
    db.execute("INSERT OR REPLACE INTO slim SELECT * FROM n.slim")
    db.execute("INSERT INTO facet SELECT * FROM n.facet")
    mx = db.execute("SELECT MAX(updated_at) FROM n.slim").fetchone()[0]
    db.commit()
    db.execute("DETACH n")
    n = db.execute("SELECT COUNT(*) FROM slim").fetchone()[0]
    if mx:
        old = float((CACHE / "last_updated_at").read_text()) if (CACHE / "last_updated_at").exists() else 0
        (CACHE / "last_updated_at").write_text(str(max(mx, old)))
    new.unlink()
    print(f"merged; slim.db now has {n} titles")


def embed_all(db, limit):
    emb = sqlite3.connect(CACHE / "emb.db")
    emb.execute("CREATE TABLE IF NOT EXISTS emb(anime_id INTEGER PRIMARY KEY, h TEXT, v BLOB)")
    have = {r[0]: r[1] for r in emb.execute("SELECT anime_id,h FROM emb")}
    todo = []
    for aid, text, title in db.execute("SELECT anime_id,embedding_text,title FROM slim"):
        text = text or title or ""
        h = hashlib.sha1(text.encode()).hexdigest()
        if have.get(aid) != h:
            todo.append((aid, h, text))
    if limit:
        todo = todo[:limit]
    print(f"embedding {len(todo)} new/changed texts")
    if todo:
        from fastembed import TextEmbedding
        model = TextEmbedding(MODEL)
        t0 = time.time()
        B = 256
        for i in range(0, len(todo), B):
            chunk = todo[i:i + B]
            vecs = list(model.embed([t for _, _, t in chunk], batch_size=64))
            for (aid, h, _), v in zip(chunk, vecs):
                emb.execute("INSERT OR REPLACE INTO emb VALUES(?,?,?)",
                            (aid, h, np.asarray(v, dtype=np.float32).tobytes()))
            emb.commit()
            print(f"  {i + len(chunk)}/{len(todo)}  {time.time() - t0:.0f}s", flush=True)
    return emb


def build_detail(p):
    n = p.get("narrative") or {}
    rec = p.get("recommendation") or {}
    em = p.get("emotion") or {}
    chars = []
    for c in (p.get("characters") or [])[:8]:
        chars.append({
            "n": c.get("name"), "r": clip(c.get("role"), 40),
            "a": (c.get("archetypes") or [])[:3],
            "m": clip(c.get("mindset"), 150),
            "arc": c.get("arc_type"),
        })
    rels = sorted(p.get("relationships") or [], key=lambda r: -(r.get("importance") or 0))[:5]
    rel_out = [{
        "a": r.get("a"), "b": r.get("b"), "t": (r.get("types") or [])[:2],
        "d": (r.get("dynamics") or [])[:3], "e": clip(r.get("evolution"), 210),
        "rom": bool(r.get("romantic")),
    } for r in rels]
    sim = [{"t": s.get("title"), "w": clip(s.get("why"), 150)}
           for s in (rec.get("similar_titles") or [])[:8]]
    st = n.get("structure") or {}
    rom = p.get("romance") or {}
    return {
        "sf": clip(rec.get("spoiler_free_pitch") or n.get("summary_spoiler_free"), 700),
        "full": clip(n.get("summary_full"), 1400),
        "chars": chars, "rels": rel_out, "sim": sim,
        "end": st.get("ending_type"), "endd": clip(st.get("ending_description"), 260),
        "pacing": st.get("pacing"), "structure": st.get("type"),
        "love": [clip(x, 140) for x in (rec.get("will_love_if") or [])[:3]],
        "hate": [clip(x, 140) for x in (rec.get("will_dislike_if") or [])[:3]],
        "str": [clip(x, 110) for x in (rec.get("strengths") or [])[:3]],
        "weak": [clip(x, 110) for x in (rec.get("weaknesses") or [])[:3]],
        "after": clip(em.get("aftertaste"), 220),
        "watch": clip(rec.get("watch_order_notes"), 220),
        "newcomer": rec.get("newcomer_friendly"),
        "commit": clip(rec.get("commitment"), 80),
        "ideal": clip(rec.get("ideal_viewer"), 200),
        "rom": {"dyn": (rom.get("dynamics") or [])[:3], "payoff": rom.get("payoff"),
                "pairs": [f'{x.get("a")} × {x.get("b")}' for x in (rom.get("main_pairings") or [])[:2]]},
        "protag": clip((p.get("protagonist") or {}).get("summary"), 260),
        "studios": (p.get("studios") or [])[:2],
        "src": p.get("source_material"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="embed at most N new titles (testing)")
    ap.add_argument("--skip-merge", action="store_true")
    args = ap.parse_args()
    CACHE.mkdir(exist_ok=True)
    if not args.skip_merge:
        merge()
    db = sqlite3.connect(CACHE / "slim.db")
    emb = embed_all(db, args.limit)
    evecs = {r[0]: np.frombuffer(r[1], dtype=np.float32) for r in emb.execute("SELECT anime_id,v FROM emb")}

    # facets: aggregate max weight per (anime, facet, value), canonical only
    facets = {}
    df = {}
    for aid, f, v, w in db.execute(
            "SELECT anime_id,facet,value,weight FROM facet WHERE canonical=1"):
        if f not in FACET_KINDS:
            continue
        d = facets.setdefault(aid, {})
        key = (f, v)
        if w > d.get(key, -1):
            d[key] = w
    for d in facets.values():
        for k in d:
            df[k] = df.get(k, 0) + 1
    vocab = sorted(k for k, c in df.items() if c >= MIN_FACET_DF)
    fid = {k: i for i, k in enumerate(vocab)}
    print(f"facet vocab: {len(vocab)}")

    rows = db.execute("SELECT anime_id,quality,profile,title,title_english,synonyms,picture,thumbnail,"
                      "popularity,score,tier FROM slim").fetchall()
    rows = [r for r in rows if r[0] in evecs]
    gscale = 127.0 / max(float(np.abs(np.stack([evecs[r[0]] for r in rows])).max()), 1e-6)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    out = sqlite3.connect(OUT)
    out.executescript("""
    PRAGMA journal_mode=OFF;
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE title(id INTEGER PRIMARY KEY, anilist INT, mal INT, title TEXT, title_en TEXT,
      syn TEXT, year INT, season TEXT, format TEXT, episodes INT, status TEXT, popularity INT,
      mean_score REAL, tier TEXT, quality REAL, thumb TEXT, pic TEXT, pitch TEXT, oneliner TEXT,
      ending TEXT, genres TEXT, adult INT, emb BLOB, dims BLOB, facets BLOB, detail BLOB);
    CREATE TABLE rel(id INT, other_anilist INT, type TEXT);
    CREATE TABLE rec(id INT, other_anilist INT, rating INT);
    CREATE TABLE facet_vocab(fid INTEGER PRIMARY KEY, kind TEXT, value TEXT, df INT);
    """)
    for k, i in fid.items():
        out.execute("INSERT INTO facet_vocab VALUES(?,?,?,?)", (i, k[0], k[1], df[k]))

    n_ok = 0
    for (aid, quality, pj, title, title_en, syn, pic, thumb, pop, score, tier) in rows:
        try:
            p = json.loads(pj)
        except Exception:
            continue
        if p.get("is_adult"):
            continue
        rec = p.get("recommendation") or {}
        pitch = rec.get("spoiler_free_pitch") or (p.get("narrative") or {}).get("summary_spoiler_free") or ""
        one = rec.get("one_line_pitch") or ""
        if not one and not pitch:
            continue
        dims = bytearray()
        for k in DIM_ORDER:
            d = (p.get("dimensions") or {}).get(k)
            s = d.get("score") if isinstance(d, dict) else d
            dims.append(255 if s is None else int(round(max(0.0, min(10.0, float(s))) * 25)))
        v = evecs[aid]
        v = v / (np.linalg.norm(v) + 1e-9)
        q = np.clip(np.round(v * gscale), -127, 127).astype(np.int8).tobytes()
        fb = bytearray()
        for (f, val), w in sorted(facets.get(aid, {}).items(), key=lambda kv: -kv[1]):
            if (f, val) in fid:
                i = fid[(f, val)]
                fb += bytes((i & 255, i >> 8, int(round(max(0, min(10, w)) * 25))))
        try:
            syns = json.loads(syn) if syn else []
        except Exception:
            syns = []
        names = []
        for s in [title, title_en, p.get("title_native")] + syns:
            if s and s not in names:
                names.append(s)
        ids = p.get("ids") or {}
        cw = (p.get("emotion") or {}).get("content_warnings") or []
        detail = build_detail(p)
        detail["cw"] = cw[:10]
        detail["moods"] = [m.get("name") for m in ((p.get("emotion") or {}).get("moods") or [])[:6]]
        detail["themes"] = [m.get("name") for m in ((p.get("emotion") or {}).get("themes") or [])[:6]]
        detail["dur"] = p.get("duration_min")
        out.execute(
            "INSERT INTO title VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (aid, ids.get("anilist"), ids.get("mal"), title, title_en or p.get("title_english"),
             "\n".join(names[2:30]), p.get("year"), p.get("season"), p.get("format"),
             p.get("episodes"), p.get("status"), pop or p.get("popularity") or 0,
             p.get("mean_score") or (score and score * 10), tier, quality, thumb, pic,
             clip(pitch, 420), clip(one, 220),
             ((p.get("narrative") or {}).get("structure") or {}).get("ending_type"),
             ",".join(p.get("genres") or []), 0, q, bytes(dims), bytes(fb),
             zlib.compress(json.dumps(detail, ensure_ascii=False, separators=(",", ":")).encode(), 9)))
        for r in p.get("relations") or []:
            if r.get("anilist"):
                out.execute("INSERT INTO rel VALUES(?,?,?)", (aid, r["anilist"], r.get("type")))
        for r in p.get("anilist_recommendations") or []:
            if r.get("anilist"):
                out.execute("INSERT INTO rec VALUES(?,?,?)", (aid, r["anilist"], r.get("rating") or 0))
        n_ok += 1
    meta = {
        "schema": SCHEMA_VERSION, "built_at": time.strftime("%Y-%m-%d %H:%M"), "count": n_ok,
        "emb_dim": EMB_DIM, "emb_scale": gscale, "model": MODEL,
        "dims": json.dumps(DIM_ORDER),
        "snapshot": (CACHE / "last_updated_at").read_text() if (CACHE / "last_updated_at").exists() else "",
    }
    for k, v in meta.items():
        out.execute("INSERT INTO meta VALUES(?,?)", (k, str(v)))
    out.execute("CREATE INDEX rel_id ON rel(id)")
    out.commit()
    out.execute("VACUUM")
    out.close()
    (OUT.parent / "catalog.version").write_text(f"{meta['built_at']} n={n_ok} schema={SCHEMA_VERSION}\n")
    print(f"wrote {OUT} with {n_ok} titles, {OUT.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()

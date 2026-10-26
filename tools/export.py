#!/usr/bin/env python3
"""Build the bundled catalog asset (catalog.db, schema 2) -- or a small catalog_delta.db -- from the
slim server snapshot (anime, movies and TV; movie/TV rows carry media_type/tmdb/imdb/cover).

  1. merge cache/slim_new.db (output of fetch_snapshot.sh) into cache/slim.db   (incremental)
  2. embed embedding_text with BAAI/bge-small-en-v1.5 (fastembed/ONNX, CPU); cached by text hash
  3. write a compact SQLite catalog the Flutter app copies to its data dir on first run

Run:  .venv/bin/python export.py [--limit N] [--skip-merge]
      .venv/bin/python export.py --base catalog.db            # delta since that catalog's snapshot
      .venv/bin/python export.py --delta-from 1792446036.25    # delta since a given updated_at stamp
"""
import argparse
import hashlib
import json
import os
import sqlite3
import time
import zlib
from pathlib import Path

import numpy as np

from catalog_schema import (DELTA_FORMAT, DIM_ORDER, SCHEMA_VERSION, TITLE_NAMES, create_schema, lines, pack_facets,
                            title_key)

HERE = Path(__file__).parent
CACHE = Path(os.environ["LODESTAR_CACHE"]) if os.environ.get("LODESTAR_CACHE") else HERE / "cache"
OUT = HERE.parent / "catalog.db"
DELTA_OUT = HERE.parent / "catalog_delta.db"
MODEL = "BAAI/bge-small-en-v1.5"
EMB_DIM = 384
MIN_FACET_DF = 3
FACET_KINDS = [
    "anilist_tag", "keyword", "appeal_factors", "archetypes", "character_arc_types", "comedy_styles",
    "content_warnings", "ending_types", "genre", "moods", "narrative_devices",
    "relationship_dynamics", "relationship_types", "romance_dynamics", "romance_payoffs",
    "setting_types", "story_structures", "themes",
]
# columns added to the slim snapshot for movies/TV (older caches get them via ALTER TABLE)
SLIM_EXTRA = {"media_type": "TEXT", "tmdb_id": "INT", "imdb_id": "TEXT", "release_date": "TEXT", "cover": "TEXT"}


def clip(s, n):
    s = (s or "").strip()
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def ensure_slim(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS slim(anime_id INTEGER PRIMARY KEY, updated_at REAL, quality REAL,
      profile TEXT, embedding_text TEXT, title TEXT, title_english TEXT, synonyms TEXT, picture TEXT,
      thumbnail TEXT, popularity INT, score REAL, tier TEXT);
    CREATE TABLE IF NOT EXISTS facet(anime_id INT, facet TEXT, value TEXT, weight REAL, canonical INT);
    CREATE INDEX IF NOT EXISTS facet_a ON facet(anime_id);
    """)
    have = {r[1] for r in db.execute("PRAGMA table_info(slim)")}
    for col, typ in SLIM_EXTRA.items():
        if col not in have:
            db.execute(f"ALTER TABLE slim ADD COLUMN {col} {typ}")


def merge():
    new = CACHE / "slim_new.db"
    if not new.exists():
        print("no slim_new.db to merge")
        return
    db = sqlite3.connect(CACHE / "slim.db")
    ensure_slim(db)
    db.execute("ATTACH ? AS n", (str(new),))
    newcols = {r[1] for r in db.execute("PRAGMA n.table_info(slim)")}
    cols = [r[1] for r in db.execute("PRAGMA main.table_info(slim)") if r[1] in newcols]
    cl = ",".join(cols)
    db.execute("DELETE FROM facet WHERE anime_id IN (SELECT anime_id FROM n.slim)")
    db.execute(f"INSERT OR REPLACE INTO slim({cl}) SELECT {cl} FROM n.slim")
    db.execute("INSERT INTO facet SELECT * FROM n.facet")
    mx = db.execute("SELECT MAX(updated_at) FROM n.slim").fetchone()[0]
    if db.execute("SELECT 1 FROM n.sqlite_master WHERE name='alive'").fetchone():
        # titles that vanished upstream (deleted / now adult) disappear from the snapshot too
        gone = [r[0] for r in db.execute("SELECT anime_id FROM main.slim WHERE anime_id NOT IN (SELECT anime_id FROM n.alive)")]
        for gid in gone:
            db.execute("DELETE FROM slim WHERE anime_id=?", (gid,))
            db.execute("DELETE FROM facet WHERE anime_id=?", (gid,))
        if gone:
            print(f"removed {len(gone)} titles that no longer exist upstream")
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
    if todo and os.environ.get("LODESTAR_FAKE_EMBEDDINGS"):
        # deterministic stand-in vectors for pipeline tests (no model download)
        for aid, h, text in todo:
            rng = np.random.default_rng(int(h[:12], 16))
            v = rng.normal(size=EMB_DIM).astype(np.float32)
            emb.execute("INSERT OR REPLACE INTO emb VALUES(?,?,?)", (aid, h, (v / np.linalg.norm(v)).tobytes()))
        emb.commit()
        todo = []
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


def names(v, n=6):
    out = []
    for x in v or []:
        t = x.get("name") if isinstance(x, dict) else x
        if t and t not in out:
            out.append(str(t))
    return out[:n]


def runtime_minutes(p):
    v = p.get("runtime") or p.get("duration_min")
    try:
        return int(round(float(v))) if v else None
    except (TypeError, ValueError):
        return None


def season_count(p):
    v = p.get("seasons")
    if isinstance(v, int):
        return v
    if isinstance(v, list):
        return len(v) or None
    return None


def credits(p):
    """Movie/TV extras for the detail screen (empty for anime)."""
    out = {}
    if names(p.get("directors")):
        out["dir"] = names(p.get("directors"), 3)
    if names(p.get("created_by")):
        out["by"] = names(p.get("created_by"), 3)
    if names(p.get("cast")):
        out["cast"] = names(p.get("cast"), 6)
    if p.get("content_rating"):
        out["rated"] = str(p["content_rating"])
    if p.get("countries"):
        out["countries"] = names(p["countries"], 3)
    if p.get("seasons"):
        out["seasons"] = p["seasons"] if isinstance(p["seasons"], int) else len(p["seasons"])
    return out


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
        **credits(p),
    }


def load_facets(db):
    """Aggregate max weight per (title, facet, value), canonical facets only + global df."""
    facets, df = {}, {}
    for aid, f, v, w in db.execute("SELECT anime_id,facet,value,weight FROM facet WHERE canonical=1"):
        if f not in FACET_KINDS:
            continue
        d = facets.setdefault(aid, {})
        if w > d.get((f, v), -1):
            d[(f, v)] = w
    for d in facets.values():
        for k in d:
            df[k] = df.get(k, 0) + 1
    return facets, df


def build_catalog(db, evecs, out_path, *, since=None, removed=(), snapshot="", only_kind=None, trim_detail=False):
    """Writes a full catalog (since=None) or a delta of the titles with updated_at > since."""
    delta = since is not None
    facets, df = load_facets(db)
    vocab = sorted(k for k, c in df.items() if c >= MIN_FACET_DF)
    fid = {k: i for i, k in enumerate(vocab)}
    print(f"facet vocab: {len(vocab)}")

    db.row_factory = sqlite3.Row
    rows = [dict(r) for r in db.execute("SELECT * FROM slim")]
    db.row_factory = None
    rows = [r for r in rows if r["anime_id"] in evecs]
    if delta:
        rows = [r for r in rows if (r["updated_at"] or 0) > since]
    if only_kind:
        rows = [r for r in rows if (r.get("media_type") or "anime").lower() == only_kind]
    if not rows:
        print("nothing to write")
        return 0
    gscale = 127.0 / max(float(np.abs(np.stack([evecs[r["anime_id"]] for r in rows])).max()), 1e-6)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.unlink(missing_ok=True)
    out = sqlite3.connect(out_path)
    out.execute("PRAGMA journal_mode=OFF")
    create_schema(out, delta=delta)
    for k, i in fid.items():
        out.execute("INSERT INTO facet_vocab VALUES(?,?,?,?)", (i, k[0], k[1], df[k]))

    n_ok = 0
    max_upd = 0.0
    for r in rows:
        aid = r["anime_id"]
        try:
            p = json.loads(r["profile"])
        except Exception:
            continue
        if p.get("is_adult"):
            continue
        rec = p.get("recommendation") or {}
        pitch = rec.get("spoiler_free_pitch") or (p.get("narrative") or {}).get("summary_spoiler_free") or ""
        one = rec.get("one_line_pitch") or ""
        if not one and not pitch:
            continue
        kind = (r.get("media_type") or p.get("media_type") or "anime").lower()
        kind = kind if kind in ("anime", "movie", "tv") else "anime"
        ids = dict(p.get("ids") or {})
        if r.get("tmdb_id"):
            ids["tmdb"] = r["tmdb_id"]
        if r.get("imdb_id"):
            ids["imdb"] = r["imdb_id"]
        dims = bytearray()
        for k in DIM_ORDER:
            d = (p.get("dimensions") or {}).get(k)
            sc = d.get("score") if isinstance(d, dict) else d
            dims.append(255 if sc is None else int(round(max(0.0, min(10.0, float(sc))) * 25)))
        v = evecs[aid]
        v = v / (np.linalg.norm(v) + 1e-9)
        q = np.clip(np.round(v * gscale), -127, 127).astype(np.int8).tobytes()
        fb = pack_facets([(fid[k], w) for k, w in facets.get(aid, {}).items() if k in fid])
        try:
            syns = json.loads(r["synonyms"]) if r["synonyms"] else []
        except Exception:
            syns = []
        nm = []
        for sname in [r["title"], r["title_english"], p.get("title_native")] + syns:
            if sname and sname not in nm:
                nm.append(sname)
        cw = (p.get("emotion") or {}).get("content_warnings") or []
        detail = build_detail(p)
        detail["cw"] = cw[:10]
        detail["moods"] = [m.get("name") for m in ((p.get("emotion") or {}).get("moods") or [])[:6]]
        detail["themes"] = [m.get("name") for m in ((p.get("emotion") or {}).get("themes") or [])[:6]]
        detail["dur"] = p.get("duration_min")
        if trim_detail:  # web-first-load diet: drop the spoiler text and the similar-titles list
            for k in ("full", "sim", "endd", "after", "ideal"):
                detail.pop(k, None)
        release = r.get("release_date") or p.get("release_date")
        year = p.get("year") or (int(release[:4]) if release and release[:4].isdigit() else None)
        cover = (p.get("cover") or r.get("cover")) if kind != "anime" else (r.get("picture") or r.get("thumbnail"))
        fmt = p.get("format") or ("MOVIE" if kind == "movie" else "TV" if kind == "tv" else None)
        upd = r["updated_at"] or 0
        max_upd = max(max_upd, upd)
        row = {
            "id": aid, "key": title_key(kind, ids, aid), "kind": kind, "anilist": ids.get("anilist"), "mal": ids.get("mal"),
            "tmdb": ids.get("tmdb"), "imdb": ids.get("imdb"), "title": r["title"],
            "title_en": r["title_english"] or p.get("title_english"), "syn": "\n".join(nm[2:30]), "year": year,
            "season": p.get("season"), "format": fmt, "episodes": p.get("episodes"), "status": p.get("status"),
            "release_date": release, "popularity": r["popularity"] or p.get("popularity") or p.get("vote_count") or 0,
            "mean_score": p.get("mean_score") or (r["score"] and r["score"] * 10), "tier": r["tier"],
            "quality": r["quality"], "thumb": r.get("thumbnail"), "pic": r.get("picture"), "cover": cover,
            "pitch": clip(pitch, 420), "oneliner": clip(one, 220),
            "ending": ((p.get("narrative") or {}).get("structure") or {}).get("ending_type"),
            "genres": ",".join(p.get("genres") or []), "adult": 0, "emb": q, "dims": bytes(dims), "facets": fb,
            "detail": zlib.compress(json.dumps(detail, ensure_ascii=False, separators=(",", ":")).encode(), 9),
            "updated_at": upd,
            # schema 3: queryable filter columns
            "runtime": runtime_minutes(p), "countries": lines(names(p.get("countries"), 8)),
            "languages": lines(names(p.get("languages"), 6)), "certification": p.get("content_rating") or None,
            "seasons": season_count(p), "directors": lines(names(p.get("directors"), 4)),
            "studios": lines(names(p.get("studios"), 4)),
            "creators": lines(names(p.get("created_by"), 4) + names(p.get("networks"), 3)),
            "source": p.get("source_material") or None,
            "votes": p.get("vote_count") or None,
        }
        out.execute(f"INSERT INTO title({','.join(TITLE_NAMES)}) VALUES({','.join('?' * len(TITLE_NAMES))})",
                    [row[c] for c in TITLE_NAMES])
        for rl in p.get("relations") or []:
            if rl.get("anilist"):
                out.execute("INSERT INTO rel VALUES(?,?,?)", (aid, f"anilist:{rl['anilist']}", rl.get("type")))
        for rc in p.get("anilist_recommendations") or []:
            if rc.get("anilist"):
                out.execute("INSERT INTO rec VALUES(?,?,?)", (aid, f"anilist:{rc['anilist']}", rc.get("rating") or 0))
        for rc in p.get("tmdb_recommendations") or []:
            k = (rc.get("kind") or "").lower()
            if rc.get("id") and k in ("movie", "tv"):
                out.execute("INSERT INTO rec VALUES(?,?,?)", (aid, f"tmdb:{k}:{rc['id']}", rc.get("rating") or 2))
        n_ok += 1
    to = snapshot or str(max_upd)
    meta = {
        "schema": SCHEMA_VERSION, "built_at": time.strftime("%Y-%m-%d %H:%M"), "count": n_ok,
        "emb_dim": EMB_DIM, "emb_scale": gscale, "model": MODEL, "dims": json.dumps(DIM_ORDER), "snapshot": to,
    }
    for k, v in meta.items():
        out.execute("INSERT INTO meta VALUES(?,?)", (k, str(v)))
    if delta:
        for k, v in {"format": DELTA_FORMAT, "from": since, "to": float(to), "built_at": meta["built_at"]}.items():
            out.execute("INSERT INTO delta_meta VALUES(?,?)", (k, str(v)))
        for rid in removed:
            out.execute("INSERT OR IGNORE INTO removed VALUES(?)", (rid,))
    out.commit()
    out.execute("VACUUM")
    out.close()
    if not delta and not only_kind:
        (out_path.parent / "catalog.version").write_text(f"{meta['built_at']} n={n_ok} schema={SCHEMA_VERSION}\n")
    print(f"wrote {out_path} with {n_ok} titles{' (delta)' if delta else ''}, {out_path.stat().st_size / 1e6:.1f} MB")
    return n_ok


def main():
    ap = argparse.ArgumentParser(description="Build catalog.db (full) or catalog_delta.db (changes only)")
    ap.add_argument("--limit", type=int, default=0, help="embed at most N new titles (testing)")
    ap.add_argument("--skip-merge", action="store_true")
    ap.add_argument("--delta-from", type=float, help="write only titles with updated_at > this stamp")
    ap.add_argument("--base", type=Path, help="an existing catalog.db: delta starts at its snapshot and lists "
                                              "titles it contains that no longer exist")
    ap.add_argument("--out", type=Path, help="output path (default catalog.db / catalog_delta.db)")
    ap.add_argument("--split-kinds", action="store_true",
                    help="write one catalog per media kind (catalog.anime.db, catalog.movie.db, catalog.tv.db)")
    ap.add_argument("--trim-detail", action="store_true", help="drop spoiler/similar blobs from the detail JSON")
    args = ap.parse_args()
    CACHE.mkdir(exist_ok=True)
    if not args.skip_merge:
        merge()
    db = sqlite3.connect(CACHE / "slim.db")
    ensure_slim(db)
    emb = embed_all(db, args.limit)
    evecs = {r[0]: np.frombuffer(r[1], dtype=np.float32) for r in emb.execute("SELECT anime_id,v FROM emb")}
    last = (CACHE / "last_updated_at")
    snapshot = last.read_text().strip() if last.exists() else ""

    since, removed = args.delta_from, []
    if args.base:
        bdb = sqlite3.connect(args.base)
        bmeta = dict(bdb.execute("SELECT key,value FROM meta"))
        since = float(bmeta.get("snapshot") or 0) if since is None else since
        base_ids = {r[0] for r in bdb.execute("SELECT id FROM title")}
        now_ids = {r[0] for r in db.execute("SELECT anime_id FROM slim")}
        removed = sorted(base_ids - now_ids)
    if since is not None:
        build_catalog(db, evecs, args.out or DELTA_OUT, since=since, removed=removed, snapshot=snapshot,
                      trim_detail=args.trim_detail)
    elif args.split_kinds:
        base = args.out or OUT
        for kind in ("anime", "movie", "tv"):
            build_catalog(db, evecs, base.with_name(f"catalog.{kind}.db"), snapshot=snapshot, only_kind=kind,
                          trim_detail=args.trim_detail)
    else:
        build_catalog(db, evecs, args.out or OUT, snapshot=snapshot, trim_detail=args.trim_detail)


if __name__ == "__main__":
    main()

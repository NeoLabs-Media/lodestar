#!/usr/bin/env python3
"""Merge a catalog_delta.db into a catalog.db (reference implementation of lib/engine/catalog_update.dart).

    python3 tools/apply_delta.py catalog.db catalog_delta.db

* migrates a schema-1 catalog to schema 2 first,
* inserts-or-replaces titles by id, merges facet_vocab by (kind, value), re-quantises embeddings to the
  target's scale, recounts facet document frequencies, applies `removed`,
* is idempotent and refuses deltas that start after the installed snapshot (a full catalog is needed).
Exit codes: 0 applied or already up to date, 2 rejected.
"""
import sqlite3
import sys

from catalog_schema import SCHEMA_VERSION, TITLE_NAMES, dequantize, quantize, unpack_facets


def meta(db, table="meta"):
    return {k: str(v) for k, v in db.execute(f"SELECT key,value FROM {table}")}


def has_table(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def migrate(db):
    if int(meta(db).get("schema", 0)) >= SCHEMA_VERSION:
        return False
    have = {r[1] for r in db.execute("PRAGMA table_info(title)")}
    for col, typ in {"key": "TEXT", "kind": "TEXT DEFAULT 'anime'", "tmdb": "INT", "imdb": "TEXT",
                     "release_date": "TEXT", "cover": "TEXT", "updated_at": "REAL"}.items():
        if col not in have:
            db.execute(f"ALTER TABLE title ADD COLUMN {col} {typ}")
    db.execute("UPDATE title SET kind='anime' WHERE kind IS NULL")
    db.execute("UPDATE title SET key = CASE WHEN anilist IS NOT NULL THEN 'anilist:'||anilist "
               "WHEN mal IS NOT NULL THEN 'mal:'||mal ELSE 'id:'||id END WHERE key IS NULL")
    db.execute("UPDATE title SET cover = COALESCE(pic, thumb) WHERE cover IS NULL")
    for t, extra in (("rel", ("type", "type TEXT")), ("rec", ("rating", "rating INT"))):
        cols = {r[1] for r in db.execute(f"PRAGMA table_info({t})")}
        if "other_key" in cols:
            continue
        db.execute(f"CREATE TABLE {t}_v2(id INT, other_key TEXT, {extra[1]})")
        db.execute(f"INSERT INTO {t}_v2 SELECT id, 'anilist:'||other_anilist, {extra[0]} FROM {t}")
        db.execute(f"DROP TABLE {t}")
        db.execute(f"ALTER TABLE {t}_v2 RENAME TO {t}")
        db.execute(f"CREATE INDEX IF NOT EXISTS {t}_id ON {t}(id)")
    db.execute("INSERT OR REPLACE INTO meta VALUES('schema', ?)", (str(SCHEMA_VERSION),))
    db.commit()
    return True


def apply(target_path, delta_path):
    t = sqlite3.connect(target_path)
    d = sqlite3.connect(delta_path)
    if not has_table(d, "delta_meta"):
        return 2, "not a catalog delta"
    dm, tm0 = meta(d, "delta_meta"), None
    frm, to = float(dm.get("from", 0)), float(dm.get("to", 0))
    migrate(t)
    tm, xm = meta(t), meta(d)
    installed = float(tm.get("snapshot") or 0)
    if to <= installed:
        return 0, "already up to date"
    if frm > installed:
        return 2, f"delta starts at {frm} but the catalog is at {installed}: a full catalog is needed first"
    if tm["dims"] != xm["dims"] or tm["emb_dim"] != xm["emb_dim"]:
        return 2, "different feature layout"
    scale_t, scale_d = float(tm["emb_scale"]), float(xm["emb_scale"])

    vocab = {(k, v): f for f, k, v in t.execute("SELECT fid,kind,value FROM facet_vocab")}
    nxt = max(vocab.values(), default=-1) + 1
    remap = {}
    for f, k, v in d.execute("SELECT fid,kind,value FROM facet_vocab"):
        if (k, v) not in vocab:
            vocab[(k, v)] = nxt
            t.execute("INSERT INTO facet_vocab VALUES(?,?,?,0)", (nxt, k, v))
            nxt += 1
        remap[f] = vocab[(k, v)]

    tcols = {r[1] for r in t.execute("PRAGMA table_info(title)")}
    d.row_factory = sqlite3.Row
    added = updated = removed = 0
    for row in d.execute("SELECT * FROM title"):
        r = dict(row)
        r["facets"] = b"".join(bytes((remap[f] & 255, remap[f] >> 8, round(w * 25)))
                               for f, w in unpack_facets(r["facets"]) if f in remap)
        if scale_d != scale_t:
            r["emb"] = quantize(dequantize(r["emb"], scale_d), scale_t)
        cols = [c for c in r if c in tcols]
        existed = t.execute("SELECT 1 FROM title WHERE id=?", (r["id"],)).fetchone() is not None
        t.execute(f"INSERT OR REPLACE INTO title({','.join(cols)}) VALUES({','.join('?' * len(cols))})",
                  [r[c] for c in cols])
        updated, added = (updated + 1, added) if existed else (updated, added + 1)
        t.execute("DELETE FROM rel WHERE id=?", (r["id"],))
        t.execute("DELETE FROM rec WHERE id=?", (r["id"],))
        t.executemany("INSERT INTO rel VALUES(?,?,?)", [(r["id"], *x) for x in
                       d.execute("SELECT other_key,type FROM rel WHERE id=?", (r["id"],))])
        t.executemany("INSERT INTO rec VALUES(?,?,?)", [(r["id"], *x) for x in
                       d.execute("SELECT other_key,rating FROM rec WHERE id=?", (r["id"],))])
    if has_table(d, "removed"):
        for (rid,) in d.execute("SELECT id FROM removed"):
            if t.execute("SELECT 1 FROM title WHERE id=?", (rid,)).fetchone():
                removed += 1
            for tbl in ("title", "rel", "rec"):
                t.execute(f"DELETE FROM {tbl} WHERE id=?", (rid,))
    df = {}
    for (blob,) in t.execute("SELECT facets FROM title"):
        for f, _ in unpack_facets(blob or b""):
            df[f] = df.get(f, 0) + 1
    for f in vocab.values():
        t.execute("UPDATE facet_vocab SET df=? WHERE fid=?", (df.get(f, 0), f))
    count = t.execute("SELECT COUNT(*) FROM title").fetchone()[0]
    for k, v in (("snapshot", str(to)), ("count", str(count)), ("built_at", dm.get("built_at", tm.get("built_at", "")))):
        t.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (k, v))
    t.commit()
    t.execute("VACUUM")
    return 0, f"{added} new, {updated} updated, {removed} removed (snapshot {installed} -> {to})"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    code, msg = apply(sys.argv[1], sys.argv[2])
    print(msg)
    sys.exit(code)

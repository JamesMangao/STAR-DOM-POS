#!/usr/bin/env python3
"""Step A -- READ-ONLY export of the retired website tables.

Dumps Products, Categories, ProductImages and PaymentSettings to
supabase/export/*.json and extracts the QR BYTEA columns to
supabase/export/qr_gcash.<ext> and qr_gotyme.<ext>.

This script only ever runs SELECTs against the source database. It never
writes, drops or migrates anything.

Usage:
    python scripts/export.py --dsn-file <path> [--psql <path-to-psql>]

The DSN is read from $SUPABASE_DB_URL, or from the first SUPABASE_DB_URL=
line in --dsn-file. It is never printed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPORT_DIR = ROOT / "supabase" / "export"

MIME_EXT = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/webp": "webp",
    "image/gif": "gif",
}


def read_dsn(dsn_file: str | None) -> str:
    if os.environ.get("SUPABASE_DB_URL"):
        return os.environ["SUPABASE_DB_URL"].strip()
    if dsn_file:
        for line in Path(dsn_file).read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line.lower().startswith("supabase_db_url="):
                return line.split("=", 1)[1].strip()
    sys.exit("No SUPABASE_DB_URL found (env or --dsn-file).")


def psql(psql_bin: str, dsn: str, sql: str) -> str:
    out = subprocess.run(
        [psql_bin, "-X", "-q", "-A", "-t", "-c", sql, dsn],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        sys.exit(f"psql failed:\n{out.stderr}")
    return out.stdout.strip()


def dump_json(psql_bin: str, dsn: str, name: str, sql: str) -> int:
    raw = psql(psql_bin, dsn, sql)
    rows = json.loads(raw) if raw and raw != "" else []
    if not isinstance(rows, list):
        rows = [rows]
    path = EXPORT_DIR / f"{name}.json"
    path.write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{name}.json: {len(rows)} rows, {path.stat().st_size} bytes")
    return len(rows)


def dump_qr(psql_bin: str, dsn: str, channel: str, slug: str) -> None:
    meta = json.loads(
        psql(
            psql_bin,
            dsn,
            "SELECT json_agg(row_to_json(t)) FROM ("
            f"SELECT qrimagemime, length(qrimagedata) AS n "
            f"FROM paymentsettings WHERE upper(channel) = '{channel}'"
            ") t",
        )
    )[0]
    mime = meta["qrimagemime"]
    ext = MIME_EXT.get(mime, "bin")
    b64 = psql(
        psql_bin,
        dsn,
        f"SELECT encode(qrimagedata, 'base64') FROM paymentsettings "
        f"WHERE upper(channel) = '{channel}'",
    )
    data = base64.b64decode(b64)
    path = EXPORT_DIR / f"qr_{slug}.{ext}"
    path.write_bytes(data)
    magic = data[:8].hex()
    digest = hashlib.sha256(data).hexdigest()
    print(
        f"qr_{slug}.{ext}: {len(data)} bytes, mime={mime}, magic={magic}, "
        f"sha256={digest}"
    )
    if len(data) != meta["n"]:
        sys.exit(
            f"size mismatch for {slug}: decoded {len(data)} != db {meta['n']}"
        )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn-file", default=None)
    ap.add_argument("--psql", default=shutil.which("psql") or "psql")
    args = ap.parse_args()

    dsn = read_dsn(args.dsn_file)
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)

    counts = {}
    counts["products"] = dump_json(
        args.psql,
        dsn,
        "products",
        "SELECT json_agg(row_to_json(t)) FROM ("
        "SELECT id, name, baseprice, stockquantity, sku, categoryid, isactive, slug "
        "FROM products ORDER BY id) t",
    )
    counts["categories"] = dump_json(
        args.psql,
        dsn,
        "categories",
        "SELECT json_agg(row_to_json(t)) FROM ("
        "SELECT id, name, slug, displayorder, isactive, parentid "
        "FROM categories ORDER BY displayorder, id) t",
    )
    counts["productimages"] = dump_json(
        args.psql,
        dsn,
        "productimages",
        "SELECT json_agg(row_to_json(t)) FROM ("
        "SELECT id, productid, imagefile, isprimary, sortorder "
        "FROM productimages ORDER BY id) t",
    )
    counts["paymentsettings"] = dump_json(
        args.psql,
        dsn,
        "paymentsettings",
        "SELECT json_agg(row_to_json(t)) FROM ("
        "SELECT id, channel, accountname, accountnumber, qrimagefile, "
        "qrimagemime, isenabled, updatedby, updatedat FROM paymentsettings "
        "ORDER BY id) t",
    )

    dump_qr(args.psql, dsn, "GCASH", "gcash")
    dump_qr(args.psql, dsn, "GOTYME", "gotyme")

    print("counts:", json.dumps(counts))


if __name__ == "__main__":
    main()

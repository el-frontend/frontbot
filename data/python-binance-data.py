#!/usr/bin/env python3
"""Descarga klines mensuales de BTCUSDT (spot) desde data.binance.vision.
Uso: python3 descargar_binance.py [carpeta_destino] [desde AAAA-MM] [hasta AAAA-MM]
Ej.: python3 descargar_binance.py data 2023-01 2026-09
"""
import sys, io, zipfile, hashlib, urllib.request, urllib.error
from pathlib import Path

SYMBOL = "BTCUSDT"
INTERVALS = ["1h", "4h"]
BASE = "https://data.binance.vision/data/spot/monthly/klines"

dest = Path(sys.argv[1] if len(sys.argv) > 1 else "data")
start = sys.argv[2] if len(sys.argv) > 2 else "2023-01"
end = sys.argv[3] if len(sys.argv) > 3 else "2026-09"

def months(a, b):
    y, m = map(int, a.split("-"))
    y2, m2 = map(int, b.split("-"))
    while (y, m) <= (y2, m2):
        yield f"{y}-{m:02d}"
        m += 1
        if m > 12:
            y, m = y + 1, 1

def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()

ok = skip = fail = 0
for iv in INTERVALS:
    out = dest / iv
    out.mkdir(parents=True, exist_ok=True)
    for ym in months(start, end):
        name = f"{SYMBOL}-{iv}-{ym}"
        csv = out / f"{name}.csv"
        if csv.exists():
            skip += 1
            continue
        url = f"{BASE}/{SYMBOL}/{iv}/{name}.zip"
        try:
            data = get(url)
            try:
                expected = get(url + ".CHECKSUM").split()[0].decode()
                if hashlib.sha256(data).hexdigest() != expected:
                    print(f"CHECKSUM MALO: {name}")
                    fail += 1
                    continue
            except urllib.error.URLError:
                print(f"(sin checksum) {name}")
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for member in z.namelist():
                    if member.endswith(".csv"):
                        csv.write_bytes(z.read(member))
            print(f"OK {name}")
            ok += 1
        except urllib.error.HTTPError as e:
            print(f"FALLO {name}: HTTP {e.code}")
            fail += 1
        except Exception as e:
            print(f"FALLO {name}: {e}")
            fail += 1

print(f"\nDescargados: {ok} | Ya existían: {skip} | Fallos: {fail}")

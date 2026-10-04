#!/usr/bin/env python3
"""
fetch_doom.py - fetch the DOOM source and game data into external/

Downloads two things, both free to redistribute:
  * doomgeneric  - DOOM reduced to a few platform hooks (GPL)
  * a WAD        - the shareware DOOM 1 data, or Freedoom with --freedoom

Everything lands in external/, which is git-ignored, so deleting that directory
undoes this completely.
"""
import argparse
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / "external"

DOOMGENERIC_URL = "https://github.com/ozkl/doomgeneric.git"

# Shareware DOOM 1: id Software allowed the shareware episode to be freely
# redistributed. Freedoom is a fully free replacement if you prefer.
WAD_SOURCES = {
    "shareware": [
        "https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad",
        "https://github.com/Akbar30Bill/DOOM_wads/raw/master/doom1.wad",
    ],
    "freedoom": [
        "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip",
    ],
}


def fetch(url: str, dest: Path) -> bool:
    print(f"  {url}")
    try:
        with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
        return True
    except Exception as e:                       # noqa: BLE001 - report and try the next mirror
        print(f"    failed: {e}")
        dest.unlink(missing_ok=True)
        return False


def get_source() -> None:
    target = EXT / "doomgeneric"
    if (target / "doomgeneric").is_dir():
        print("doomgeneric: already present")
        return
    print("doomgeneric: cloning")
    subprocess.run(["git", "clone", "--depth", "1", DOOMGENERIC_URL, str(target)], check=True)


def get_wad(kind: str) -> None:
    if list(EXT.glob("*.wad")) or list(EXT.glob("*.WAD")):
        print("WAD: already present")
        return
    print(f"WAD: downloading ({kind})")
    for url in WAD_SOURCES[kind]:
        if url.endswith(".zip"):
            tmp = EXT / "wad.zip"
            if not fetch(url, tmp):
                continue
            with zipfile.ZipFile(tmp) as z:
                for name in z.namelist():
                    if name.lower().endswith(".wad"):
                        with z.open(name) as src, open(EXT / Path(name).name, "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        print(f"    extracted {Path(name).name}")
                        break
            tmp.unlink()
            return
        if fetch(url, EXT / "doom1.wad"):
            return
    raise SystemExit("could not download a WAD - place one in external/ by hand")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--freedoom", action="store_true", help="use Freedoom instead of shareware DOOM")
    args = ap.parse_args()

    EXT.mkdir(exist_ok=True)
    get_source()
    get_wad("freedoom" if args.freedoom else "shareware")

    for p in sorted(EXT.glob("*.wad")) + sorted(EXT.glob("*.WAD")):
        print(f"ready: {p.name} ({p.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

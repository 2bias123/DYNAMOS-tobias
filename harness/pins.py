#!/usr/bin/env python3
import argparse
import csv
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

AUTH = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull"
MANIFEST = "https://registry-1.docker.io/v2/%s/manifests/%s"
ACCEPT = ", ".join((
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.oci.image.index.v1+json",
))
FIELDS = ["name", "repository", "tag", "digest"]
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
TIMEOUT_S = 30
DEFAULT = pathlib.Path(__file__).resolve().parent / "pins.csv"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def load(path):
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            raise SystemExit(f"{path}: header must be {','.join(FIELDS)}")
        rows = list(reader)
    if not rows:
        raise SystemExit(f"{path}: no rows")
    for number, row in enumerate(rows, start=2):
        if None in row or None in row.values():
            raise SystemExit(f"{path}:{number}: a row must have {len(FIELDS)} fields")
        if not (row["name"] and row["repository"] and row["tag"]):
            raise SystemExit(f"{path}:{number}: name, repository and tag may not be empty")
        if row["tag"] == "latest":
            raise SystemExit(f"{path}:{number}: the tag may not be latest")
    names = [row["name"] for row in rows]
    if len(set(names)) != len(names):
        raise SystemExit(f"{path}: a name appears twice")
    return rows


def select(rows, names):
    if not names:
        return rows
    known = {row["name"] for row in rows}
    unknown = [name for name in names if name not in known]
    if unknown:
        raise SystemExit(f"not in the pins file: {' '.join(unknown)}")
    return [row for row in rows if row["name"] in names]


def registry_digest(repository, tag):
    with OPENER.open(AUTH % repository, timeout=TIMEOUT_S) as response:
        token = json.load(response)["token"]
    request = urllib.request.Request(
        MANIFEST % (repository, tag),
        method="HEAD",
        headers={"Authorization": "Bearer " + token, "Accept": ACCEPT},
    )
    try:
        with OPENER.open(request, timeout=TIMEOUT_S) as response:
            return response.headers.get("Docker-Content-Digest", "")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def absent(rows):
    bad = 0
    for row in rows:
        ref = f"{row['repository']}:{row['tag']}"
        try:
            found = registry_digest(row["repository"], row["tag"])
        except Exception as error:
            print(f"ERROR   {ref} {error}")
            bad += 1
            continue
        if found is None:
            print(f"absent  {ref}")
        else:
            print(f"EXISTS  {ref} {found or '(no digest header)'}")
            bad += 1
    return bad


def check(rows):
    bad = 0
    for row in rows:
        ref = f"{row['repository']}:{row['tag']}"
        pin = row["digest"]
        if not DIGEST.fullmatch(pin):
            print(f"NO-PIN  {ref} digest column holds '{pin}'")
            bad += 1
            continue
        try:
            found = registry_digest(row["repository"], row["tag"])
        except Exception as error:
            print(f"ERROR   {ref} {error}")
            bad += 1
            continue
        if found == pin:
            print(f"ok      {ref} {pin}")
        elif found is None:
            print(f"MISSING {ref} the registry has no such tag (pin {pin})")
            bad += 1
        else:
            print(f"DRIFT   {ref} registry {found or '(no digest header)'} pin {pin}")
            bad += 1
    return bad


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pins", default=str(DEFAULT))
    parser.add_argument("command", choices=["absent", "check"])
    parser.add_argument("names", nargs="*")
    args = parser.parse_args()
    rows = select(load(args.pins), args.names)
    bad = absent(rows) if args.command == "absent" else check(rows)
    print(f"{args.command}: {len(rows) - bad} of {len(rows)} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

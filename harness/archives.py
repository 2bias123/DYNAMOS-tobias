#!/usr/bin/env python3
import argparse
import hashlib
import io
import json
import pathlib
import sys
import tarfile

BLOCK = 1 << 20


class Hashing:
    def __init__(self, raw):
        self.raw = raw
        self.digest = hashlib.sha256()
        self.size = 0

    def read(self, n=-1):
        data = self.raw.read(n)
        self.digest.update(data)
        self.size += len(data)
        return data

    def drain(self):
        while self.read(BLOCK):
            pass


def member_hashes(stream):
    found = {}
    sums = None
    with tarfile.open(fileobj=stream, mode="r|") as tar:
        for member in tar:
            if not member.isfile():
                continue
            digest = hashlib.sha256()
            body = tar.extractfile(member)
            keep = bytearray() if member.name.endswith("/SHA256SUMS") else None
            while True:
                data = body.read(BLOCK)
                if not data:
                    break
                digest.update(data)
                if keep is not None:
                    keep.extend(data)
            found[member.name] = (member.size, digest.hexdigest())
            if keep is not None and (sums is None or member.name.count("/") < sums[0].count("/")):
                sums = (member.name, keep.decode())
    return found, sums


def listed_members(path):
    listed = {}
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        parts = line.split("\t")
        if len(parts) != 3 or not parts[0].isdigit():
            raise ValueError(f"{path.name}:{number}: not size, sha256, path")
        listed[parts[2]] = (int(parts[0]), parts[1])
    return listed


def verify(tar_path):
    sha_path = tar_path.with_name(tar_path.name + ".sha256")
    members_path = tar_path.with_name(tar_path.name + ".members")
    for needed in (sha_path, members_path):
        if not needed.is_file():
            raise ValueError(f"{needed.name} is missing")
    fields = sha_path.read_text().split()
    if len(fields) != 2 or fields[1] != tar_path.name:
        raise ValueError(f"{sha_path.name} does not name {tar_path.name}")
    with open(tar_path, "rb") as raw:
        stream = Hashing(raw)
        found, sums = member_hashes(stream)
        stream.drain()
    if stream.digest.hexdigest() != fields[0]:
        raise ValueError(f"sha256 {stream.digest.hexdigest()} is not the {fields[0]} of {sha_path.name}")
    listed = listed_members(members_path)
    if found != listed:
        differing = sorted(set(found.items()) ^ set(listed.items()))
        raise ValueError(f"{len(differing)} members differ from {members_path.name}, first {differing[0][0]}")
    if sums is None:
        raise ValueError("no SHA256SUMS inside")
    top = sums[0].rsplit("/", 1)[0]
    inside = {}
    for number, line in enumerate(sums[1].splitlines(), start=1):
        digest, _, name = line.partition("  ")
        if len(digest) != 64 or not name:
            raise ValueError(f"{sums[0]}:{number}: not a sha256 line")
        inside[f"{top}/{name.removeprefix('./')}"] = digest
    files = {name: digest for name, (_, digest) in found.items() if name != sums[0]}
    if inside != files:
        differing = sorted(set(inside.items()) ^ set(files.items()))
        raise ValueError(f"{len(differing)} members differ from {sums[0]}, first {differing[0][0]}")
    return {"name": tar_path.name, "size": stream.size, "sha256": fields[0], "members": len(found)}


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while data := f.read(BLOCK):
            digest.update(data)
    return digest.hexdigest()


def make(folder, experiment, name=None):
    folder = pathlib.Path(folder)
    top = folder / experiment
    tar_path = folder / f"{name or experiment}.tar"
    files = sorted(path for path in top.rglob("*") if path.is_file() and path != top / "SHA256SUMS")
    sums = "".join(f"{file_sha256(path)}  {path.relative_to(top)}\n" for path in files).encode()
    members = []
    with tarfile.open(tar_path.with_name(tar_path.name + ".tmp"), "w", format=tarfile.PAX_FORMAT) as tar:
        for path in files:
            info = tar.gettarinfo(path, f"{experiment}/{path.relative_to(top)}")
            info.mtime, info.uid, info.gid, info.uname, info.gname = int(info.mtime), 0, 0, "", ""
            with open(path, "rb") as f:
                tar.addfile(info, f)
            members.append((info.size, file_sha256(path), info.name))
        info = tarfile.TarInfo(f"{experiment}/SHA256SUMS")
        info.size = len(sums)
        tar.addfile(info, io.BytesIO(sums))
        members.append((len(sums), hashlib.sha256(sums).hexdigest(), info.name))
    tar_path.with_name(tar_path.name + ".members").write_text(
        "".join(f"{size}\t{digest}\t{member}\n" for size, digest, member in members))
    tar_path.with_name(tar_path.name + ".sha256").write_text(
        f"{file_sha256(tar_path.with_name(tar_path.name + '.tmp'))}  {tar_path.name}\n")
    tar_path.with_name(tar_path.name + ".tmp").replace(tar_path)
    return verify(tar_path)


def pack(outbox, name, entries):
    outbox = pathlib.Path(outbox)
    tar_path = outbox / f"{name}.tar"
    for leftover in (tar_path.with_name(tar_path.name + suffix) for suffix in (".sha256", ".members")):
        if leftover.exists():
            raise ValueError(f"{leftover.name} exists already")
    files = sorted(entries.items())
    sums = "".join(f"{hashlib.sha256(body).hexdigest() if isinstance(body, bytes) else file_sha256(body)}  {rel}\n"
                   for rel, body in files).encode()
    names = []
    temporary = tar_path.with_name(tar_path.name + ".tmp")
    with tarfile.open(temporary, "w", format=tarfile.PAX_FORMAT) as tar:
        for rel, body in [("SHA256SUMS", sums), *files]:
            if isinstance(body, bytes):
                info = tarfile.TarInfo(f"{name}/{rel}")
                info.size, info.mtime = len(body), 0
                tar.addfile(info, io.BytesIO(body))
            else:
                info = tar.gettarinfo(body, f"{name}/{rel}")
                info.type, info.linkname, info.size = tarfile.REGTYPE, "", pathlib.Path(body).stat().st_size
                info.mtime, info.uid, info.gid, info.uname, info.gname = int(info.mtime), 0, 0, "", ""
                with open(body, "rb") as f:
                    tar.addfile(info, f)
            names.append(info.name)
    digest = file_sha256(temporary)
    with tarfile.open(temporary) as tar:
        if [member.name for member in tar.getmembers()] != names:
            raise ValueError(f"{name}.tar: the members read back differ from those written")
    temporary.replace(tar_path)
    tar_path.with_name(tar_path.name + ".members").write_text("".join(f"{member}\n" for member in names))
    ready = tar_path.with_name(tar_path.name + ".sha256.tmp")
    ready.write_text(f"{digest}  {tar_path.name}\n")
    ready.replace(tar_path.with_name(tar_path.name + ".sha256"))
    return {"name": tar_path.name, "bytes": tar_path.stat().st_size, "sha256": digest, "members": len(names)}


def tars(paths):
    out = []
    for given in paths:
        path = pathlib.Path(given).expanduser()
        if path.is_dir():
            out.extend(sorted(path.rglob("*.tar")))
        elif path.is_file():
            out.append(path)
        else:
            raise SystemExit(f"{path}: no such file or folder")
    if not out:
        raise SystemExit("no archive found")
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["verify"])
    parser.add_argument("--manifest")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    wanted = json.loads(pathlib.Path(args.manifest).expanduser().read_text()) if args.manifest else None
    bad = 0
    verified = set()
    for tar_path in tars(args.paths):
        try:
            got = verify(tar_path)
        except (ValueError, OSError, tarfile.TarError) as error:
            print(f"FAIL    {tar_path} {error}")
            bad += 1
            continue
        verified.add((got["name"], got["size"], got["sha256"]))
        print(f"ok      {tar_path} {got['members']} members")
    if wanted is None:
        print(f"verified: {len(verified)}; failed: {bad}")
        return 1 if bad else 0
    listed = {(row["name"], row["size"], row["sha256"]) for row in wanted}
    for name, size, digest in sorted(listed - verified):
        print(f"MISSING {name} size {size} sha256 {digest}: on the list, no verified copy here")
        bad += 1
    for name, size, digest in sorted(verified - listed):
        print(f"extra   {name} size {size} sha256 {digest}: verified here, not on the list")
    print(f"on the list: {len(listed)}; of those verified here: {len(listed & verified)}; "
          f"verified here and not on the list: {len(verified - listed)}; failed: {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""
Download the packages of the base system from an apt repository.

usage: fetch-repo.py --repo URL --keyring FILE --debs DIR --manifest FILE
                     [--suite SUITE] [--component C]... [--package NAME]...

InRelease must be signed by a key in FILE. sqv checks it, or gpgv if sqv
is missing. Its Suite or Codename must be SUITE. The indexes are fetched
by hash when Release offers that. The components default to the ones
Release names. The base system is every darwin-arm64 or all package that
is Essential or has Priority required, important or standard, plus each
--package NAME, plus everything their Depends and Pre-Depends need. A NAME
the repository does not have is an error. Each package's newest version
is used.
The debs go into DIR, checked against the SHA-256 in Packages, and FILE
lists them: package, version and SHA-256.
"""
import argparse
import hashlib
import lzma
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ARCHES = ("darwin-arm64", "all")
PRIORITIES = ("required", "important", "standard")


def die(msg):
    sys.exit("fetch-repo: " + msg)


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "fetch-repo"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def verified(inrelease, keyring):
    with tempfile.TemporaryDirectory() as tmp:
        signed = os.path.join(tmp, "InRelease")
        with open(signed, "wb") as f:
            f.write(inrelease)
        out = os.path.join(tmp, "Release")
        if shutil.which("sqv"):
            cmd = ["sqv", "--keyring", keyring, "--cleartext", "--output", out, signed]
        elif shutil.which("gpgv"):
            cmd = ["gpgv", "--quiet", "--keyring", os.path.abspath(keyring), "--output", out, signed]
        else:
            die("neither sqv nor gpgv is installed")
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode != 0:
            die("InRelease is not signed by a key in %s:\n%s" % (keyring, res.stderr.decode(errors="replace")))
        with open(out) as f:
            return f.read()


def stanzas(text):
    for block in re.split(r"\n\s*\n", text.strip()):
        fields, key = {}, None
        for line in block.split("\n"):
            if line[:1] in (" ", "\t") and key:
                fields[key] += "\n" + line
            elif ":" in line:
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        if fields:
            yield fields


def release_hashes(release):
    fields = next(stanzas(release))
    hashes = {}
    for line in fields.get("SHA256", "").split("\n"):
        parts = line.split()
        if len(parts) == 3:
            hashes[parts[2]] = (parts[0], int(parts[1]))
    return fields, hashes


def compare(a, op, b):
    return subprocess.run(["dpkg", "--compare-versions", a, op, b]).returncode == 0


def newest(versions):
    best = versions[0]
    for v in versions[1:]:
        if compare(v["Version"], "gt", best["Version"]):
            best = v
    return best


def relations(value):
    clauses = []
    for clause in value.split(","):
        alts = []
        for alt in clause.split("|"):
            m = re.match(r"\s*([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?\s*(?:\(\s*(<<|<=|=|>=|>>)\s*([^)\s]+)\s*\))?", alt)
            if m:
                alts.append((m.group(1), m.group(2), m.group(3)))
        if alts:
            clauses.append(alts)
    return clauses


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--keyring", required=True)
    ap.add_argument("--debs", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--suite", default="blueberry-pie-os")
    ap.add_argument("--component", action="append")
    ap.add_argument("--package", action="append", default=[])
    args = ap.parse_args()
    repo = args.repo.rstrip("/") + "/"

    release, hashes = release_hashes(verified(get("%sdists/%s/InRelease" % (repo, args.suite)), args.keyring))
    if args.suite not in (release.get("Suite"), release.get("Codename")):
        die("InRelease is for %s, not %s" % (release.get("Suite"), args.suite))
    components = args.component or release.get("Components", "").split()
    print("fetch-repo: %s %s (%s)" % (repo, args.suite, release.get("Date", "no date")))

    by_name, provides = {}, {}
    for comp in components:
        path = "%s/binary-darwin-arm64/Packages.xz" % comp
        if path not in hashes:
            die("Release lists no %s" % path)
        url = "%sdists/%s/%s" % (repo, args.suite, path)
        if release.get("Acquire-By-Hash") == "yes":
            url = "%s/by-hash/SHA256/%s" % (os.path.dirname(url), hashes[path][0])
        data = get(url)
        if hashlib.sha256(data).hexdigest() != hashes[path][0] or len(data) != hashes[path][1]:
            die("%s does not match Release" % path)
        for p in stanzas(lzma.decompress(data).decode()):
            if p.get("Architecture") in ARCHES:
                by_name.setdefault(p["Package"], []).append(p)
    pkgs = {name: newest(vs) for name, vs in by_name.items()}
    for p in pkgs.values():
        for alts in relations(p.get("Provides", "")):
            for name, op, ver in alts:
                provides.setdefault(name, []).append((p["Package"], ver))

    def satisfies(name, op, ver):
        found = []
        p = pkgs.get(name)
        if p and (not op or compare(p["Version"], op, ver)):
            found.append(name)
        for real, pver in provides.get(name, []):
            if not op or (pver and compare(pver, op, ver)):
                found.append(real)
        return found

    chosen, queue = set(), []
    for name, p in sorted(pkgs.items()):
        if p.get("Essential") == "yes" or p.get("Priority") in PRIORITIES:
            chosen.add(name)
            queue.append(name)
    if not chosen:
        die("the repository has no required or standard packages")
    for name in args.package:
        options = satisfies(name, None, None)
        if not options:
            die("the repository has no package %s" % name)
        if not any(n in chosen for n in options):
            chosen.add(options[0])
            queue.append(options[0])
    missing = []
    while queue:
        p = pkgs[queue.pop(0)]
        for field in ("Pre-Depends", "Depends"):
            for alts in relations(p.get(field, "")):
                options = [n for a in alts for n in satisfies(*a)]
                if not options:
                    missing.append("%s %s: %s" % (p["Package"], field, " | ".join(
                        a[0] + (" (%s %s)" % (a[1], a[2]) if a[1] else "") for a in alts)))
                elif not any(n in chosen for n in options):
                    chosen.add(options[0])
                    queue.append(options[0])
    if missing:
        die("nothing in the repository satisfies:\n  " + "\n  ".join(missing))

    os.makedirs(args.debs, exist_ok=True)
    lines = []
    for name in sorted(chosen):
        p = pkgs[name]
        deb = os.path.join(args.debs, os.path.basename(p["Filename"]))
        data = get(repo + p["Filename"])
        digest = hashlib.sha256(data).hexdigest()
        if digest != p["SHA256"] or len(data) != int(p["Size"]):
            die("%s does not match Packages" % p["Filename"])
        with open(deb, "wb") as f:
            f.write(data)
        lines.append("%s %s %s\n" % (name, p["Version"], digest))
    with open(args.manifest, "w") as f:
        f.writelines(lines)
    print("fetch-repo: %d packages" % len(lines))


if __name__ == "__main__":
    main()

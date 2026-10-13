#!/bin/sh
# Installs a Swift toolchain on Linux (cloud sessions) so the language-server
# tests run there: `make test-languages` (D55). download.swift.org is often
# blocked by sandbox proxies; Docker Hub's official image layer isn't.
set -eu
VERSION="${SWIFT_VERSION:-6.2-noble}"
PREFIX="${SWIFT_PREFIX:-/opt/swift}"
[ -x "$PREFIX/usr/bin/swift" ] && { "$PREFIX/usr/bin/swift" --version; exit 0; }

registry=https://registry-1.docker.io/v2/library/swift
token=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/swift:pull" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
get() { curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $1" "$2"; }

index=$(get "application/vnd.oci.image.index.v1+json" "$registry/manifests/$VERSION")
manifest=$(echo "$index" | python3 -c 'import json,sys
print(next(m["digest"] for m in json.load(sys.stdin)["manifests"] if m["platform"] == {"architecture": "amd64", "os": "linux"}))')
# The largest layer is the toolchain; the others are Ubuntu and apt packages.
layer=$(get "application/vnd.oci.image.manifest.v1+json" "$registry/manifests/$manifest" |
    python3 -c 'import json,sys; print(max(json.load(sys.stdin)["layers"], key=lambda l: l["size"])["digest"])')

mkdir -p "$PREFIX"
get "*/*" "$registry/blobs/$layer" | tar -xz -C "$PREFIX"
"$PREFIX/usr/bin/swift" --version

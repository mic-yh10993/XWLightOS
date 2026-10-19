#!/usr/bin/env bash
# Fetch pinned third-party binary packages for DclawOS 1.0 (PeaZip and
# ONLYOFFICE DesktopEditors).
# DclawOS no longer builds its own desktop components: the desktop is stock
# GNOME and the only binary-package inputs are the pinned release DEBs below.
# This script deliberately does not compile anything and never touches the
# network except for the locked URLs in packages/binaries.lock.tsv.
set -euo pipefail

ROOT="${ROOT:-/workspace}"
OUT="${OUT:-$ROOT/artifacts}"
PKGS="${PKGS:-$OUT/packages}"
BINARY_LOCK="$ROOT/packages/binaries.lock.tsv"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

fetch_binary_locked() {
    local id="$1" row filename url digest license
    row="$(awk -F '\t' -v id="$id" '$1 == id { print; exit }' "$BINARY_LOCK")"
    [ -n "$row" ] || die "binary lock has no entry for $id"
    IFS=$'\t' read -r _ filename url digest license <<<"$row"
    curl --fail --location --retry 3 --output "$PKGS/$filename" "$url"
    printf '%s  %s\n' "$digest" "$filename" | (cd "$PKGS" && sha256sum -c -)
}

[ -f "$BINARY_LOCK" ] || die "missing binary source lock: $BINARY_LOCK"
rm -rf "$PKGS"
mkdir -p "$PKGS"

log "downloading fixed release DEBs described by the binary lock"
fetch_binary_locked peazip
fetch_binary_locked onlyoffice

(
    cd "$PKGS"
    sha256sum *.deb > SHA256SUMS
)
log "fetched binary packages"
ls -lh "$PKGS"

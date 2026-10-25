#!/usr/bin/env bash
# Validate XWLightOS binary packages before staging them into a Live ISO.
# XWLightOS carries only pinned third-party binary packages (currently
# ONLYOFFICE DesktopEditors; PeaZip was removed 2026-10-25).
# (AI stack removed for the education edition.)
set -euo pipefail

ROOT="${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
PKGS="${PKGS:-$ROOT/artifacts/packages}"
[ -f "$PKGS/SHA256SUMS" ] || { echo "missing SHA256SUMS" >&2; exit 1; }
compgen -G "$PKGS/*.deb" >/dev/null || { echo "no binary DEBs" >&2; exit 1; }

(
    cd "$PKGS"
    sha256sum -c SHA256SUMS
)
# The pinned ONLYOFFICE release DEB is the only third-party binary package.
compgen -G "$PKGS/onlyoffice-desktopeditors_*.deb" >/dev/null || { echo "missing pinned ONLYOFFICE package" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for deb in "$PKGS"/*.deb; do
    pkg="$(dpkg-deb -f "$deb" Package)"
    ver="$(dpkg-deb -f "$deb" Version)"
    arch="$(dpkg-deb -f "$deb" Architecture)"
    [ "$arch" = amd64 ] || { echo "$deb has unexpected architecture: $arch" >&2; exit 1; }
    root="$TMP/$pkg"
    dpkg-deb -x "$deb" "$root"
    while IFS= read -r -d '' desktop; do
        desktop-file-validate "$desktop"
        grep -q '^Exec=' "$desktop" || { echo "$desktop has no Exec" >&2; exit 1; }
        ! grep -qE '^Exec=.*(explorer\.exe|nautilus[[:space:]]+%[fFuUdD])' "$desktop" || {
            echo "$desktop contains an invalid file-manager launch fallback" >&2; exit 1;
        }
    done < <(find "$root/usr/share/applications" -type f -name '*.desktop' -print0 2>/dev/null)
    printf 'validated %s %s\n' "$pkg" "$ver"
done

[ -f "$PKGS/XWLIGHTOS-1.0-COMPONENTS.txt" ] || {
    echo "missing component lock manifest" >&2; exit 1;
}
[ -f "$PKGS/XWLIGHTOS-1.0-BUILD-MANIFEST.json" ] || {
    echo "missing JSON build manifest" >&2; exit 1;
}
echo "XWLightOS 1.0 binary package validation passed"

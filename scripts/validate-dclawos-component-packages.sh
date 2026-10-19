#!/usr/bin/env bash
# Validate DclawOS binary packages before staging them into a Live ISO.
# DclawOS no longer builds its own desktop components; the package layer now
# carries only pinned third-party binary packages (currently PeaZip) plus the
# dclawos-ai-tools DEB built by scripts/build-dclawos-ai.sh.
set -euo pipefail

ROOT="${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
PKGS="${PKGS:-$ROOT/artifacts/packages}"
[ -f "$PKGS/SHA256SUMS" ] || { echo "missing SHA256SUMS" >&2; exit 1; }
compgen -G "$PKGS/*.deb" >/dev/null || { echo "no binary DEBs" >&2; exit 1; }

(
    cd "$PKGS"
    sha256sum -c SHA256SUMS
)
# The pinned PeaZip release DEB is the only third-party binary package.
compgen -G "$PKGS/peazip_*.deb" >/dev/null || { echo "missing pinned PeaZip package" >&2; exit 1; }
# The AI stack must have produced its tools package.
compgen -G "$PKGS/dclawos-ai-tools_*.deb" >/dev/null || { echo "missing dclawos-ai-tools package" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for deb in "$PKGS"/*.deb; do
    pkg="$(dpkg-deb -f "$deb" Package)"
    ver="$(dpkg-deb -f "$deb" Version)"
    arch="$(dpkg-deb -f "$deb" Architecture)"
    [ "$arch" = amd64 ] || { echo "$deb has unexpected architecture: $arch" >&2; exit 1; }
    root="$TMP/$pkg"
    dpkg-deb -x "$deb" "$root"
    if [ "$pkg" = dclawos-ai-tools ]; then
        [ -s "$root/usr/share/doc/$pkg/copyright" ] || {
            echo "$pkg lacks /usr/share/doc/$pkg/copyright" >&2; exit 1;
        }
    fi
    while IFS= read -r -d '' desktop; do
        desktop-file-validate "$desktop"
        grep -q '^Exec=' "$desktop" || { echo "$desktop has no Exec" >&2; exit 1; }
        ! grep -qE '^Exec=.*(explorer\.exe|nautilus[[:space:]]+%[fFuUdD])' "$desktop" || {
            echo "$desktop contains an invalid file-manager launch fallback" >&2; exit 1;
        }
    done < <(find "$root/usr/share/applications" -type f -name '*.desktop' -print0 2>/dev/null)
    printf 'validated %s %s\n' "$pkg" "$ver"
done

[ -f "$PKGS/DCLAWOS-1.0-COMPONENTS.txt" ] || {
    echo "missing component lock manifest" >&2; exit 1;
}
[ -f "$PKGS/DCLAWOS-1.0-BUILD-MANIFEST.json" ] || {
    echo "missing JSON build manifest" >&2; exit 1;
}
echo "DclawOS 1.0 binary package validation passed"

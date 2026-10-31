#!/bin/sh
# Build the Plymouth theme-script parser checker into the directory given
# as $1 (default: ./ply-script-check next to this script).
#
# The checker is Plymouth 22.02.122's OWN script parser (the exact code
# plymouthd runs at boot to parse a script theme), wrapped by a 15-line
# main() that calls script_parse_file() and reports NULL/non-NULL.
# It exists because this product shipped a theme script for months that
# the real parser rejects (an `and` keyword where the grammar only knows
# `&&`), while every static gate kept passing: asset-presence checks
# cannot see a grammar error. See README.md for provenance.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/ply-script-check}"
CC="${CC:-cc}"

"$CC" -O1 -o "$OUT" -I"$HERE" -DHAVE_CONFIG_H -D_GNU_SOURCE \
    "$HERE/main.c" \
    "$HERE/script.c" "$HERE/script-scan.c" "$HERE/script-parse.c" \
    "$HERE/script-object.c" "$HERE/script-execute.c" "$HERE/script-debug.c" \
    "$HERE/ply-list.c" "$HERE/ply-hashtable.c" "$HERE/ply-bitarray.c" \
    "$HERE/ply-logger.c" "$HERE/ply-utils.c" "$HERE/ply-array.c" \
    "$HERE/ply-buffer.c" \
    -lm

echo "built $OUT"

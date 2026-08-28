#!/bin/sh
# Runs the real map.sh over the fixtures in test/fixtures and compares the result with
# test/expected/geonames.nt. No downloads: the fixtures are already chunked and carry the header
# row map.sh's queries expect, which is the part download.sh would otherwise produce.
#
# map.sh resolves everything from $PWD -- data, config, bin, sparql-anything.env -- so the test
# needs no hooks in it: it assembles a working directory of that shape in a temporary directory and
# runs map.sh there. bin is symlinked rather than copied so the SPARQL Anything jar is downloaded
# once and reused.
#
# Run ./test.sh --bless after deliberately changing a query, and read the diff before committing:
# the expected file is small enough to review line by line, and that review is the actual test.
set -eu

REPO="$PWD"
: "${PARALLELISM:=2}"
export PARALLELISM

bless=false
[ "${1:-}" = "--bless" ] && bless=true

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for path in config bin sparql-anything.env map.sh; do
    ln -s "$REPO/$path" "$work/$path"
done
mkdir "$work/data"
cp "$REPO"/test/fixtures/*.csv "$REPO"/test/fixtures/ontology.rdf "$work/data/"

echo "Mapping fixtures..."
( cd "$work" && OUTPUT_DIR="$work/output" ./map.sh >"$work/map.log" 2>&1 ) || {
    echo "map.sh failed:" >&2
    tail -30 "$work/map.log" >&2
    exit 1
}

# Chunks are mapped in parallel, so line order in the concatenated output is not stable. Sort in
# the C locale: collation is locale-dependent, and the ontology’s mixed-case IRIs sort differently
# on macOS than on the Linux CI runner, which would fail the diff on the developer’s machine or CI
# depending on where the expected file was blessed. Byte order is the same everywhere.
LC_ALL=C sort "$work/output/geonames.nt" > "$work/actual.nt"

if $bless; then
    cp "$work/actual.nt" "$REPO/test/expected/geonames.nt"
    echo "Blessed $(wc -l < "$REPO/test/expected/geonames.nt") triples into test/expected/geonames.nt"
    exit 0
fi

if diff -u "$REPO/test/expected/geonames.nt" "$work/actual.nt"; then
    echo "OK: $(wc -l < "$work/actual.nt") triples match test/expected/geonames.nt"
else
    echo "FAIL: output differs from test/expected/geonames.nt (- expected, + actual)." >&2
    echo "If the change is intended, re-run with --bless and review the diff." >&2
    exit 1
fi

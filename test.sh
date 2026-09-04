#!/bin/sh
# Runs the mapping over the fixtures in test/fixtures and compares the result with
# test/expected/geonames.nt. No downloads: the fixtures are already chunked and carry the header
# row the queries expect, which is the part download.sh and lde/download.ts would otherwise produce.
#
# There are two mappers, map.sh and lde/map.ts, and both are run against the same expected file:
# that one diff is the proof that the LDE port reproduces the shell pipeline's output. Name one to
# run only that mapper: ./test.sh map.sh, or ./test.sh lde.
#
# Each mapper resolves everything from $PWD -- data, config, bin, sparql-anything.env -- so the test
# needs no hooks in it: it assembles a working directory of that shape in a temporary directory and
# runs the mapper there. bin is symlinked rather than copied so the SPARQL Anything jar is downloaded
# once and reused.
#
# Run ./test.sh --bless after deliberately changing a query, and read the diff before committing:
# the expected file is small enough to review line by line, and that review is the actual test.
set -eu

REPO="$PWD"
: "${PARALLELISM:=2}"
export PARALLELISM

bless=false
mappers="map.sh lde"
for arg in "$@"; do
    case "$arg" in
        --bless) bless=true ;;
        map.sh|lde) mappers="$arg" ;;
        *) echo "Usage: ./test.sh [--bless] [map.sh|lde]" >&2; exit 2 ;;
    esac
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Runs one mapper over the fixtures and leaves its sorted output in $work/<mapper>.nt.
map_fixtures() {
    mapper="$1"
    dir="$work/$mapper"
    mkdir -p "$dir/data"
    for path in config bin sparql-anything.env map.sh lde node_modules; do
        ln -s "$REPO/$path" "$dir/$path"
    done
    cp "$REPO"/test/fixtures/*.csv "$REPO"/test/fixtures/ontology.rdf "$dir/data/"

    echo "Mapping fixtures with $mapper..."
    case "$mapper" in
        map.sh)
            ( cd "$dir" && OUTPUT_DIR="$dir/output" ./map.sh >"$dir/map.log" 2>&1 ) ;;
        lde)
            # The fixtures are chunked the way download.sh names chunks; lde/download.ts names them
            # the way @lde/sparql-anything's chunk() does, which is what lde/map.ts looks for.
            for fixture in "$dir"/data/*_aa.csv; do
                mv "$fixture" "$(echo "$fixture" | sed 's/_aa\.csv$/-0000.csv/')"
            done
            ( cd "$dir" && OUTPUT_DIR="$dir/output" node lde/map.ts >"$dir/map.log" 2>&1 ) ;;
    esac || {
        echo "$mapper failed:" >&2
        tail -30 "$dir/map.log" >&2
        exit 1
    }

    # Chunks are mapped in parallel, so line order in the concatenated output is not stable. Sort in
    # the C locale: collation is locale-dependent, and the ontology’s mixed-case IRIs sort differently
    # on macOS than on the Linux CI runner, which would fail the diff on the developer’s machine or CI
    # depending on where the expected file was blessed. Byte order is the same everywhere. Blank
    # lines are dropped: N-Triples allows them, and the LDE converter writes one between the files
    # it concatenates, but they are not triples and so not part of what is compared.
    LC_ALL=C sort "$dir/output/geonames.nt" | grep -v '^$' > "$work/$mapper.nt"
}

if $bless; then
    map_fixtures map.sh
    cp "$work/map.sh.nt" "$REPO/test/expected/geonames.nt"
    echo "Blessed $(wc -l < "$REPO/test/expected/geonames.nt") triples into test/expected/geonames.nt"
    # The expected file is blessed from map.sh only: the port has to reproduce it, not define it.
    mappers=lde
fi

for mapper in $mappers; do
    map_fixtures "$mapper"
    if diff -u "$REPO/test/expected/geonames.nt" "$work/$mapper.nt"; then
        echo "OK: $mapper: $(wc -l < "$work/$mapper.nt") triples match test/expected/geonames.nt"
    else
        echo "FAIL: $mapper output differs from test/expected/geonames.nt (- expected, + actual)." >&2
        echo "If the change is intended, re-run with --bless and review the diff." >&2
        exit 1
    fi
done

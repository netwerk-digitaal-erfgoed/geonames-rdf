#!/bin/sh
# Abort on the first error so a crashing chunk fails the build loudly instead of
# silently dropping ~1M rows from the output while the job stays green.
set -eu

DATA_DIR="$PWD/data"
BIN_DIR="$PWD/bin"
CONFIG_DIR="$PWD/config"
# SPARQL Anything version/jar are pinned in one place, shared with the Dockerfile.
. "$PWD/sparql-anything.env"
: "${OUTPUT_DIR:=$PWD/output}"

mkdir -p $OUTPUT_DIR

# Download SPARQL Anything CLI.
if [ ! -f "$BIN_DIR/$SPARQL_ANYTHING_JAR" ]; then
    curl -sSL "https://github.com/SPARQL-Anything/sparql.anything/releases/download/$SPARQL_ANYTHING_VERSION/$SPARQL_ANYTHING_JAR" -o $BIN_DIR/$SPARQL_ANYTHING_JAR
fi

# Map admin codes.
java -jar $BIN_DIR/$SPARQL_ANYTHING_JAR -q $CONFIG_DIR/admin-codes.rq > $DATA_DIR/admin-codes.ttl

# Remove stale chunk outputs from a previous run, so the cat below can only pick up .nt files
# this run produced (relevant when map.sh is run standalone without download.sh).
rm -f $DATA_DIR/geonames_*.csv.nt

# Number of chunks to map concurrently. Defaults to the number of CPUs (4 on a GitHub-hosted
# ubuntu runner); override with the PARALLELISM env var. Each worker is a separate JVM holding
# one chunk's result graph in memory (~1 GB for a 1M-row chunk), so PARALLELISM x per-JVM heap
# must fit RAM: -Xmx2g below keeps four concurrent workers well within a 16 GB runner.
PARALLELISM="${PARALLELISM:-$(nproc 2>/dev/null || echo 4)}"

# Map each chunk in its own JVM, PARALLELISM at a time, to use every core. Running one JVM per
# chunk also bounds memory: SPARQL Anything materialises the whole chunk's result graph before
# writing, and each process frees it on exit (a single JVM over the full dataset needs >14 GB
# and OOMs). If any chunk crashes, xargs exits non-zero and set -e aborts the build; SPARQL
# Anything deletes a crashed chunk's output, so the cat below would otherwise silently omit it.
# The "Processing" lines identify chunks (interleaved under parallelism).
export BIN_DIR CONFIG_DIR DATA_DIR SPARQL_ANYTHING_JAR
printf '%s\n' $DATA_DIR/geonames_*.csv | xargs -P "$PARALLELISM" -I{} sh -c '
    f="$1"
    echo "Processing $f"
    java -Xmx2g -jar "$BIN_DIR/$SPARQL_ANYTHING_JAR" --query "$(sed "s|{SOURCE}|$f|" "$CONFIG_DIR/places.rq")" --load "$DATA_DIR/admin-codes.ttl" --format NT --output "$f.nt"
' _ {}

# Concatenate the per-chunk N-Triples files. Unlike Turtle, N-Triples has no prefixes or
# document structure: every line is a self-contained triple, so plain cat is always valid.
cat $DATA_DIR/*.csv.nt > $OUTPUT_DIR/geonames.nt

#!/bin/sh
# Abort on the first error so a crashing chunk fails the build loudly instead of
# silently dropping ~1M rows from the output while the job stays green.
set -eu

DATA_DIR="$PWD/data"
BIN_DIR="$PWD/bin"
CONFIG_DIR="$PWD/config"
: "${SPARQL_ANYTHING_VERSION:=v1.1.0}"
: "${SPARQL_ANYTHING_JAR:=sparql-anything-$SPARQL_ANYTHING_VERSION.jar}"
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

# Iterate over chunks and run them through SPARQL Anything individually to prevent OOMs.
# set -e aborts the run if a chunk crashes (SPARQL Anything v1.1.0+ deletes its output on a
# crash, so the cat below would otherwise silently omit it); the "Processing" line above
# identifies the failing chunk.
for f in $DATA_DIR/geonames_*.csv; do
    echo "Processing $f"
    java -jar $BIN_DIR/$SPARQL_ANYTHING_JAR --query "$(sed "s|{SOURCE}|$f|" $CONFIG_DIR/places.rq)" --load $DATA_DIR/admin-codes.ttl --format NT --output $f.nt
done

# Concatenate the per-chunk N-Triples files. Unlike Turtle, N-Triples has no prefixes or
# document structure: every line is a self-contained triple, so plain cat is always valid.
cat $DATA_DIR/*.csv.nt > $OUTPUT_DIR/geonames.nt

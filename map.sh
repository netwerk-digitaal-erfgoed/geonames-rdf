#!/bin/sh
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

# Iterate over chunks and run them through SPARQL Anything individually to prevent OOMs.
trap "exit 1" INT
for f in $DATA_DIR/geonames_*.csv; do
    echo "Processing $f"
    java -jar $BIN_DIR/$SPARQL_ANYTHING_JAR --query "$(sed "s|{SOURCE}|$f|" $CONFIG_DIR/places.rq)" --load $DATA_DIR/admin-codes.ttl --output $f.ttl
done

cat $DATA_DIR/*.csv.ttl > $OUTPUT_DIR/geonames.ttl

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

# Download SPARQL Anything CLI. -f so a missing release fails here instead of writing GitHub’s
# 404 page to the jar path, which surfaces much later as “Invalid or corrupt jarfile”.
if [ ! -f "$BIN_DIR/$SPARQL_ANYTHING_JAR" ]; then
    curl -fsSL "https://github.com/SPARQL-Anything/sparql.anything/releases/download/$SPARQL_ANYTHING_VERSION/$SPARQL_ANYTHING_JAR" -o $BIN_DIR/$SPARQL_ANYTHING_JAR
fi

# Map admin codes.
java -jar $BIN_DIR/$SPARQL_ANYTHING_JAR -q $CONFIG_DIR/admin-codes.rq > $DATA_DIR/admin-codes.ttl

# Remove stale chunk outputs from a previous run, so the cat below can only pick up .nt files
# this run produced (relevant when map.sh is run standalone without download.sh).
rm -f $DATA_DIR/*.csv.nt

# Per-worker JVM heap. A 1M-row chunk's result graph needs ~1.2 GB, so 2g leaves margin.
# Raise JAVA_XMX (and lower PARALLELISM to match) if CHUNK_SIZE in download.sh is increased.
JAVA_XMX="${JAVA_XMX:-2g}"

# Number of chunks to map concurrently. Each chunk runs in its own JVM, which also bounds
# memory: SPARQL Anything materialises the whole chunk's result graph before writing, and
# each process frees it on exit (a single JVM over the full dataset needs >14 GB and OOMs).
# The workers run at once, so PARALLELISM x per-worker memory must fit RAM. Default to the CPU
# count, but cap it to what memory allows -- the cgroup limit inside a container, else physical
# RAM -- so we don't over-subscribe on a host with many cores but little memory (e.g. a
# memory-limited pod running the published image). Set PARALLELISM explicitly to override.
if [ -z "${PARALLELISM:-}" ]; then
    PARALLELISM=$(nproc 2>/dev/null || echo 4)
    mem_mb=0
    if [ -r /sys/fs/cgroup/memory.max ]; then                           # cgroup v2
        max=$(cat /sys/fs/cgroup/memory.max)
        [ "$max" != max ] && mem_mb=$((max / 1048576))
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then       # cgroup v1
        max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        [ "$max" -lt 9000000000000000000 ] 2>/dev/null && mem_mb=$((max / 1048576))
    fi
    [ "$mem_mb" -eq 0 ] && [ -r /proc/meminfo ] &&                      # non-container host
        mem_mb=$(awk '/^MemTotal:/{print int($2 / 1024); exit}' /proc/meminfo)
    # Budget ~3 GB per worker (JAVA_XMX=2g heap + non-heap and OS headroom).
    if [ "$mem_mb" -gt 0 ]; then
        mem_cap=$((mem_mb / 3072))
        [ "$mem_cap" -lt 1 ] && mem_cap=1
        [ "$mem_cap" -lt "$PARALLELISM" ] && PARALLELISM=$mem_cap
    fi
fi
echo "Mapping chunks with PARALLELISM=$PARALLELISM, -Xmx$JAVA_XMX per worker"

# Map each chunk. If a chunk crashes, its worker prints a marker naming it and exits non-zero,
# so xargs exits non-zero and set -e aborts the build before the cat below (SPARQL Anything
# deletes a crashed chunk's output, so cat would otherwise silently ship a short file). Note
# xargs still starts the remaining queued chunks before aborting; --output lines interleave.
#
# Both chunk sets go through one worker pool, which packs the cores better than draining them in
# two phases: an alternate-names chunk is roughly a quarter of the work of a geonames chunk (one
# triple per row, no admin-codes join). The geonames chunks are listed first so the long jobs
# start first and the short ones fill the tail.
export BIN_DIR CONFIG_DIR DATA_DIR SPARQL_ANYTHING_JAR JAVA_XMX
# Skip an unmatched glob rather than feeding the pattern itself to a worker, which would fail the
# whole run after every real chunk had already been mapped. Relevant when map.sh runs standalone
# against a data/ directory that predates one of the two chunk sets.
for chunk in $DATA_DIR/geonames_*.csv $DATA_DIR/alternate-names_*.csv; do
    if [ -f "$chunk" ]; then printf '%s\n' "$chunk"; fi
done | xargs -P "$PARALLELISM" -I{} sh -c '
    chunk="$1"
    echo "Processing $chunk"
    case "$chunk" in
        # Alternate names key on geonameid, so they need neither the admin-codes graph nor a join.
        */alternate-names_*) query="$CONFIG_DIR/alternate-names.rq"; set -- ;;
        *)                   query="$CONFIG_DIR/places.rq"; set -- --load "$DATA_DIR/admin-codes.ttl" ;;
    esac
    java -Xmx"$JAVA_XMX" -jar "$BIN_DIR/$SPARQL_ANYTHING_JAR" --query "$(sed "s|{SOURCE}|$chunk|" "$query")" "$@" --format NT --output "$chunk.nt" \
        || { echo "Failed to map chunk: $chunk" >&2; exit 1; }
' _ {}

# Choose one name per feature per language, as nde:preferredName. Done here rather than per chunk
# because it is an aggregate over every name a feature has, and the table is ordered by
# alternateNameId, so a feature's rows are scattered across chunks: North Korea's two Dutch official
# names are 1,562,765 and 2,421,725. Sorting 0.78 GB by a numeric key costs a couple of minutes
# against a run that already takes ~40, and it keeps the awk streaming with no per-feature state.
#
# The chunks carry a header row each, which sorts out of the way of the numeric ids but would still
# reach awk, so drop it by field: the header's geonameid column is the literal 'geonameid'.
printf "\nChoosing a preferred name per language...\n"
cat $DATA_DIR/alternate-names_*.csv \
    | awk -F'\t' '$2 != "geonameid"' \
    | LC_ALL=C sort -t"$(printf '\t')" -k2,2n -k3,3 \
    | awk -f $CONFIG_DIR/preferred-names.awk > $DATA_DIR/preferred-names.nt

# Concatenate the per-chunk N-Triples files. Unlike Turtle, N-Triples has no prefixes or
# document structure: every line is a self-contained triple, so plain cat is always valid.
cat $DATA_DIR/*.csv.nt $DATA_DIR/preferred-names.nt > $OUTPUT_DIR/geonames.nt

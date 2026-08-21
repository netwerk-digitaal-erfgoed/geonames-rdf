#!/bin/sh
# Abort on the first error, as map.sh does. Without this a failed download leaves an empty input
# for the chunking below, which then writes a header-only chunk and the run stays green while
# publishing a file that is silently missing a whole table.
set -eu

CONFIG_DIR="$PWD/config"
DATA_DIR="$PWD/data"
: "${CHUNK_SIZE:=1000000}"
mkdir -p $DATA_DIR

# Split a TSV into CHUNK_SIZE-row chunks, each prefixed with the header row the mapping queries
# expect. Chunking is what bounds the mapping's memory: SPARQL Anything materialises a chunk's
# whole result graph before writing it, and each chunk runs in its own JVM that frees it on exit.
chunk_with_header() {
    input="$1"
    prefix="$2"
    header="$3"
    rm -rf $prefix*
    split -l $CHUNK_SIZE "$input" "$prefix"
    for f in $prefix*; do
        # split produced nothing, so the glob is unmatched and $f is the pattern itself.
        [ -f "$f" ] || { echo "No chunks produced for $input" >&2; exit 1; }
        echo $f
        csvfile="${f}.csv"
        cat "$header" > $csvfile
        cat $f >> $csvfile
        rm $f
    done
}

# specify countries to download
#country_files="NL BE DE "
country_files="allCountries"
rm -rf $DATA_DIR/geonames.csv temp
for cfile in $country_files; do
    mkdir temp
    printf "\nDownloading $cfile... "
    (cd temp && curl -fsSO "https://download.geonames.org/export/dump/$cfile.zip" && unzip "$cfile.zip")
    cat "temp/$cfile.txt" >> $DATA_DIR/geonames.csv
    rm -rf temp
done

# create foreign keys 'adm1' and 'adm2' for the admin1code and admin2code tables
# $9=country code, $11=admin1 code, $12=admin2 code
# Explicit NONE so we don't need OPTIONAL joins, which speeds up the mapping process.
printf "\nCreating foreign keys... "
awk 'BEGIN{FS=OFS="\t"} {print $0, $9"."$11, ($12 != "" ? $9"."$11"."$12 : "NONE" )}' $DATA_DIR/geonames.csv > $DATA_DIR/geonamesplus.csv
rm $DATA_DIR/geonames.csv

## Cut into chunks.
printf "\nChunking...\n"
chunk_with_header $DATA_DIR/geonamesplus.csv $DATA_DIR/geonames_ $CONFIG_DIR/headers-gn.csv

# The alternate names table, which unlike the main table's comma-separated 'alternatenames' column
# carries a language code per name. Mapped by its own query against its own chunks: a row keys on
# geonameid, so it needs no join with the main table.
printf "\nDownloading alternateNamesV2... "
rm -rf temp
mkdir temp
(cd temp && curl -fsSO "https://download.geonames.org/export/dump/alternateNamesV2.zip" && unzip "alternateNamesV2.zip")
mv temp/alternateNamesV2.txt $DATA_DIR/alternate-names.tsv
rm -rf temp

# places.rq keeps only features that have a country code, plus continents; the alternate names
# table has no country code to filter on, so drop the excluded ids here instead. Otherwise their
# names become orphan subjects in the output: a URI carrying a name but no gn:Feature, no
# coordinates and no gn:name. Listing the ~7k EXCLUDED ids rather than the ~13.5M kept ones keeps
# the awk hash tiny. $7=feature class, $8=feature code, $9=country code.
printf "\nDropping alternate names of out-of-scope features... "
awk -F'\t' '$9 == "" && !($7 == "L" && $8 == "CONT") {print $1}' $DATA_DIR/geonamesplus.csv > $DATA_DIR/excluded-ids.txt
awk -F'\t' 'NR==FNR {excluded[$1]; next} !($2 in excluded)' $DATA_DIR/excluded-ids.txt $DATA_DIR/alternate-names.tsv > $DATA_DIR/alternate-names-scoped.tsv
rm $DATA_DIR/alternate-names.tsv $DATA_DIR/excluded-ids.txt

printf "\nChunking alternate names...\n"
chunk_with_header $DATA_DIR/alternate-names-scoped.tsv $DATA_DIR/alternate-names_ $CONFIG_DIR/headers-alternate-names.csv
rm $DATA_DIR/alternate-names-scoped.tsv

printf "\nDownload supporting files... "
cp $CONFIG_DIR/headers-admin1-codes.csv $DATA_DIR/admin1-codes.csv
curl -fsS "https://download.geonames.org/export/dump/admin1CodesASCII.txt" >> $DATA_DIR/admin1-codes.csv

cp $CONFIG_DIR/headers-admin2-codes.csv $DATA_DIR/admin2-codes.csv
curl -fsS "https://download.geonames.org/export/dump/admin2Codes.txt" >> $DATA_DIR/admin2-codes.csv

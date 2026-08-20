#!/bin/sh
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
    (cd temp && curl -sSO "https://download.geonames.org/export/dump/$cfile.zip" && unzip "$cfile.zip")
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
(cd temp && curl -sSO "https://download.geonames.org/export/dump/alternateNamesV2.zip" && unzip "alternateNamesV2.zip")
mv temp/alternateNamesV2.txt $DATA_DIR/alternate-names.tsv
rm -rf temp

printf "\nChunking alternate names...\n"
chunk_with_header $DATA_DIR/alternate-names.tsv $DATA_DIR/alternate-names_ $CONFIG_DIR/headers-alternate-names.csv
rm $DATA_DIR/alternate-names.tsv

printf "\nDownload supporting files... "
cp $CONFIG_DIR/headers-admin1-codes.csv $DATA_DIR/admin1-codes.csv
curl -sS "https://download.geonames.org/export/dump/admin1CodesASCII.txt" >> $DATA_DIR/admin1-codes.csv

cp $CONFIG_DIR/headers-admin2-codes.csv $DATA_DIR/admin2-codes.csv
curl -sS "https://download.geonames.org/export/dump/admin2Codes.txt" >> $DATA_DIR/admin2-codes.csv

# GeoNames RDF

This repository contains shell scripts that download [GeoNames data dumps](https://download.geonames.org/export/dump/)
and convert them to RDF using [SPARQL Anything](https://github.com/SPARQL-Anything/sparql.anything),
resulting in a `geonames.nt` file that you can load into a SPARQL server.

You can download a periodically updated RDF file from
https://geonames.ams3.digitaloceanspaces.com/geonames.nt.gz (~770 MB). SPARQL servers generally
read gzip directly – Jena infers it from the `.gz` extension – so you can load it without
unpacking, which saves staging ~14 GB of plain text. The same data is also
published as https://geonames.ams3.digitaloceanspaces.com/geonames.zip for existing consumers.

## Running

You can run the transform process in a Docker container or directly on your host machine.

### In Docker

To run the transform process in a Docker container, run:

```shell
docker run -v $(pwd)/output:/output --rm ghcr.io/netwerk-digitaal-erfgoed/geonames-rdf
```

### Directly

To run the scripts directly, run:

```shell
./download.sh
```

Then start the mapping process with:

```shell
./map.sh
```

This will download SPARQL Anything if not already available.

## Output

After running the transform process, you’ll find a `output/geonames.nt` file 
that you can load into a SPARQL server.

Names come from GeoNames’ [alternateNamesV2](https://download.geonames.org/export/dump/alternateNamesV2.zip)
table, so they carry a language tag. Following GeoNames’ own RDF, a preferred name becomes
`gn:officialName` and a short name `gn:shortName`; unlike that RDF, colloquial and historic names
keep their distinction as `gn:colloquialName` and `gn:historicalName` instead of being flattened
into `gn:alternateName`. `gn:name` remains the untagged main name from the dump’s `name` column. 

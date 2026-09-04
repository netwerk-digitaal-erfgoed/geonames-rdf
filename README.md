# GeoNames RDF

This repository downloads [GeoNames data dumps](https://download.geonames.org/export/dump/)
and converts them to RDF using [SPARQL Anything](https://github.com/SPARQL-Anything/sparql.anything),
resulting in a `geonames.nt` file that you can load into a SPARQL server.

The conversion exists twice, side by side, and you can run either: as shell scripts (`download.sh`
and `map.sh`), and as a port to the [LDElements](https://ldelements.org) packages
(`lde/download.ts` and `lde/map.ts`). Both run the same SPARQL queries in `config/` and produce the
same output; see [Two implementations](#two-implementations) for what differs.

You can download a periodically updated RDF file from
https://geonames.ams3.digitaloceanspaces.com/geonames.nt.gz (~770 MB). SPARQL servers generally
read gzip directly – Jena infers it from the `.gz` extension – so you can load it without
unpacking, which saves staging ~14 GB of plain text. The same data is also
published as https://geonames.ams3.digitaloceanspaces.com/geonames.zip for existing consumers.

## Running

You can run the transform process in a Docker container or directly on your host machine.

### In Docker

The published image runs the shell scripts. To run the transform process in a Docker container, run:

```shell
docker run -v $(pwd)/output:/output --rm ghcr.io/netwerk-digitaal-erfgoed/geonames-rdf
```

### Directly, with the shell scripts

To run the scripts directly, run:

```shell
./download.sh
```

Then start the mapping process with:

```shell
./map.sh
```

This will download SPARQL Anything if not already available.

### Directly, with LDE

The LDE port needs Node.js 24 or later, which runs the TypeScript files as they are, without a
build step:

```shell
npm ci
node lde/download.ts
node lde/map.ts
```

The same environment variables apply to both: `CHUNK_SIZE` (rows per chunk, default 1,000,000),
`PARALLELISM` (chunks mapped at once, default: CPU count capped by memory), `JAVA_XMX` (heap per
chunk process, default `2g`) and `OUTPUT_DIR` (default `output`).

### In GitHub Actions

The weekly [harvest workflow](.github/workflows/harvest.yml) runs the shell scripts. Start it by
hand and it asks which of the two conversions to run; everything after `output/geonames.nt` –
compression and publication – is shared.

## Two implementations

The shell scripts and the LDE port are meant to be read next to each other. They share every
piece that is about GeoNames: the queries in `config/`, the header rows, the pinned SPARQL Anything
build in `sparql-anything.env` and the environment variables above. Both produce the same
`geonames.nt`, which `test.sh` checks by diffing both against one expected file. What differs is
where the generic parts live.

Measured on a laptop over the full dumps, `lde/download.ts` takes 95 s where `download.sh` takes
228 s, because it reads the 2 GB table twice instead of five times. Mapping takes the same time in
both, since the work is the JVMs either way. The port is about twice as many lines.

| Concern | Shell scripts | LDE port |
| --- | --- | --- |
| Downloading | `curl -fsSO` and `unzip` in a `temp` directory | `LastModifiedDownloader` from `@lde/distribution-downloader`, given a `Distribution` per dump |
| Chunking a 2 GB table | `split -l`, then a loop prepending the header to each chunk | `chunk()` from `@lde/sparql-anything`, with the header and the `.csv` extension as options |
| Synthesising the `adm1`/`adm2` foreign keys | `awk` | A line transform in `lde/download.ts` |
| Dropping alternate names of out-of-scope features | Two `awk` passes through a temporary id file | The same transform notes the excluded ids as it goes; a second one filters on them |
| One JVM per chunk, N at a time | `xargs -P` over a `sh -c` worker that substitutes `{SOURCE}` with `sed` | `SparqlAnythingConverter.convert()` with `concurrency` |
| A crashed chunk must fail the run | `set -e`, a marker line and a non-zero exit from the worker | `convert()` rejects, and stops the chunks still running |
| SPARQL Anything exiting 0 on an unreadable `--load` | An explicit `[ -s … ]` check after the ontology step | `convert()` rejects on any empty output |
| Concatenating in a stable order | `cat data/*.csv.nt data/ontology.nt` | `convert()` concatenates in the order the jobs were given |
| Sizing the worker pool | `nproc`, the cgroup limit and `/proc/meminfo` | The same arithmetic in `lde/map.ts`: the converter cannot see the machine its task runner uses |

The rows that moved into a package are the ones any tabular-to-RDF conversion needs: running
chunks a few at a time, concatenating them in order, stopping everything when one fails, and the
two guards against a run that stays green with triples missing. The rows that stayed in this
repository are GeoNames policy (which dumps, which ontology version, the foreign keys `places.rq`
joins on, which features are in scope) and the deployment arithmetic that only the caller can do.
`map.sh` is the original: `test.sh --bless` regenerates the expected output from it, and the port
has to reproduce that output.

## Tests

`./test.sh` maps the fixtures in `test/fixtures` with both `map.sh` and `lde/map.ts` and compares
each result with `test/expected/geonames.nt`; name one of them (`./test.sh lde`) to run only that
mapper. It downloads nothing: the fixtures are already chunked and carry the header row the queries
expect, which is what `download.sh` or `lde/download.ts` would otherwise produce.

The fixtures are rows lifted from the GeoNames dumps, plus a four-term excerpt of the GeoNames
ontology, each chosen for a rule the mapping depends on – a name flagged both preferred and
historic, an `fr_1793` code that is not a language tag, a feature with no country code, a name
containing a double quote, an ontology label wrapped across two source lines. After deliberately
changing a query, re-run with `./test.sh --bless` and read the diff: the expected file is small
enough to review line by line, and that review is the actual test.

## Output

After running the transform process, you’ll find a `output/geonames.nt` file 
that you can load into a SPARQL server.

Names come from GeoNames’ [alternateNamesV2](https://download.geonames.org/export/dump/alternateNamesV2.zip)
table, so they carry a language tag wherever GeoNames records one – about 62% of them do; the rest
are emitted as plain literals. Following GeoNames’ own RDF, a preferred name becomes
`gn:officialName` and a short name `gn:shortName`; unlike that RDF, colloquial and historic names
keep their distinction as `gn:colloquialName` and `gn:historicalName` instead of being flattened
into `gn:alternateName`. A name flagged both historic (or colloquial) and preferred is published as
historic, so an obsolete name never lands on `gn:officialName`, which the GeoNames ontology defines
as a `skos:prefLabel`. `gn:name` remains the untagged main name from the dump’s `name` column.

The same table aligns 1,111,266 in-scope features to Wikidata, in rows whose language code is the
pseudo-code `wkdt`. Each becomes a `schema:sameAs` to the Wikidata entity:

```
<https://sws.geonames.org/2921044/> <https://schema.org/sameAs> <http://www.wikidata.org/entity/Q183> .
```

The predicate is deliberately weaker than `owl:sameAs`. 340 QIDs are claimed by more than one
feature, because Wikidata models the three Tihange reactors as one power station and Batifa’s town,
ADM3 and district as one place, and 16 features carry more than one QID. An entailing predicate
would merge their coordinates, populations and feature codes; `schema:sameAs` states the identity
GeoNames asserts without entailing it, so every row is published and none of them is false. Neither
GeoNames nor Wikidata asserts identity here either – GeoNames’ own `about.rdf` publishes no Wikidata
link at all, and Wikidata links back with `wdtn:P1566`.

The object keeps the `http` scheme although the predicate is `https`. That is not a typo:
`http://www.wikidata.org/entity/` is the only form Wikidata’s dumps and its SPARQL endpoint use, and
RDF compares URIs as strings, so the `https` variant is a different node that joins with nothing.

GeoNames’ own [ontology](https://www.geonames.org/ontology/ontology_v3.3.rdf) is republished
alongside the features, because it is what defines the feature-class and feature-code IRIs the
mapping mints. `gn:featureCode` points at IRIs such as
`https://www.geonames.org/ontology#P.PPLA`, and without the ontology those are bare subjects that
carry no triple at all, so a consumer can dereference the code but never label it. The file adds
690 `gn:Code` instances – one per feature code, each with `skos:prefLabel` and `skos:notation`,
and most with a `skos:definition` (621 of them) and a `skos:inScheme` to its `gn:Class` (689) –
plus the nine classes and the property axioms, ~6,800 triples next to 13.5M features.

Labels are in en, ru, sv, bg and no; there is no Dutch, so a scope note derived from them stays
English. Note that they are `skos:prefLabel` and `skos:definition`, **not** `gn:name`: a consumer
reading `gn:featureCode/gn:name` gets nothing and has to move to `gn:featureCode/skos:prefLabel`.

The triples are copied verbatim except for literal whitespace, which is collapsed to single spaces
and trimmed. That changes 27 literals in v3.3: two arrive wrapped across two lines, carrying a
newline and its indentation – one is `gn:P.PPLA`’s English `skos:prefLabel`, the label of the term
consumers most often show – and 25 carry a stray double space.

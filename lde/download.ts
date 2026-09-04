// The LDE counterpart of download.sh: downloads the GeoNames dumps and prepares them for mapping.
// Same inputs, same outputs, same environment variables; what differs is that downloading and
// chunking come from LDE packages, and the row transformations are Node streams rather than awk.
//
// What this file keeps for itself is GeoNames policy that no library should own: which dumps to
// fetch and at which pinned ontology version, the synthesised adm1/adm2 foreign keys that let
// places.rq join non-OPTIONALly, and dropping alternate names of out-of-scope features.
import { Distribution } from '@lde/dataset';
import { LastModifiedDownloader } from '@lde/distribution-downloader';
import { chunk } from '@lde/sparql-anything';
import StreamZip from 'node-stream-zip';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { pipeline } from 'node:stream/promises';

const dataDir = 'data';
const downloadsDir = `${dataDir}/downloads`;
const chunkRows = Number(process.env.CHUNK_SIZE ?? 1_000_000);

// The ontology version is pinned because GeoNames publishes each one under its own filename and
// there is no “latest” alias; bump it here when a v3.4 appears. Fetched first, so that when the
// bump is due the run aborts in seconds rather than after the whole dataset has been prepared.
const ontology = new Distribution(
  new URL('https://www.geonames.org/ontology/ontology_v3.3.rdf'),
  'application/rdf+xml',
);
const allCountries = new Distribution(
  new URL('https://download.geonames.org/export/dump/allCountries.zip'),
  'application/zip',
);
const alternateNames = new Distribution(
  new URL('https://download.geonames.org/export/dump/alternateNamesV2.zip'),
  'application/zip',
);
const admin1Codes = new Distribution(
  new URL('https://download.geonames.org/export/dump/admin1CodesASCII.txt'),
  'text/tab-separated-values',
);
const admin2Codes = new Distribution(
  new URL('https://download.geonames.org/export/dump/admin2Codes.txt'),
  'text/tab-separated-values',
);

await mkdir(downloadsDir, { recursive: true });
const downloader = new LastModifiedDownloader(dataDir);

console.log('Downloading the GeoNames ontology...');
await downloader.download(ontology, `${dataDir}/ontology.rdf`);

console.log('Downloading allCountries...');
const allCountriesZip = await downloader.download(
  allCountries,
  `${downloadsDir}/allCountries.zip`,
);

// Create foreign keys ‘adm1’ and ‘adm2’ for the admin1 and admin2 code tables, in one pass that
// also notes which features places.rq will leave out. An explicit NONE rather than an empty
// column, so the query can join without OPTIONAL, which is markedly faster.
// Columns: $7 feature class, $8 feature code, $9 country code, $11 admin1 code, $12 admin2 code.
console.log('Creating foreign keys...');
const excludedIds = new Set<string>();
await transformLines(
  await zipEntry(allCountriesZip.path, 'allCountries.txt'),
  `${dataDir}/geonames.tsv`,
  (line) => {
    const columns = line.split('\t');
    const [featureClass, featureCode, countryCode] = columns.slice(6, 9);
    const [admin1Code, admin2Code] = columns.slice(10, 12);
    // places.rq keeps only features that have a country code, plus continents.
    if (countryCode === '' && !(featureClass === 'L' && featureCode === 'CONT')) {
      excludedIds.add(columns[0]);
    }
    const adm1 = `${countryCode}.${admin1Code}`;
    const adm2 = admin2Code === '' ? 'NONE' : `${adm1}.${admin2Code}`;
    return `${line}\t${adm1}\t${adm2}`;
  },
);

console.log('Chunking...');
await chunkTable(`${dataDir}/geonames.tsv`, 'config/headers-gn.csv');

// The alternate names table, which unlike the main table’s comma-separated ‘alternatenames’ column
// carries a language code per name. A row keys on geonameid, so it needs no join with the main
// table, but the table has no country code to filter on either: drop the names of the features
// places.rq excludes here, or they become orphan subjects carrying a name but no gn:Feature.
console.log('Downloading alternateNamesV2...');
const alternateNamesZip = await downloader.download(
  alternateNames,
  `${downloadsDir}/alternateNamesV2.zip`,
);
console.log('Dropping alternate names of out-of-scope features...');
await transformLines(
  await zipEntry(alternateNamesZip.path, 'alternateNamesV2.txt'),
  `${dataDir}/alternate-names.tsv`,
  (line) => (excludedIds.has(line.split('\t', 2)[1]) ? undefined : line),
);

console.log('Chunking alternate names...');
await chunkTable(`${dataDir}/alternate-names.tsv`, 'config/headers-alternate-names.csv');

console.log('Downloading supporting files...');
for (const [distribution, name] of [
  [admin1Codes, 'admin1-codes'],
  [admin2Codes, 'admin2-codes'],
] as const) {
  const { path } = await downloader.download(distribution, `${downloadsDir}/${name}.tsv`);
  await prependHeader(path, `config/headers-${name}.csv`, `${dataDir}/${name}.csv`);
}

/**
 * Splits a header-less table into chunks of CHUNK_SIZE rows, each starting with the header row
 * the mapping queries expect, and removes the table itself: the chunks are what map.ts reads.
 */
async function chunkTable(tablePath: string, headerFile: string): Promise<void> {
  const chunks = await chunk(tablePath, {
    rows: chunkRows,
    into: dataDir,
    header: (await readFile(headerFile, 'utf-8')).trimEnd(),
    // SPARQL Anything reads the format from the file name.
    extension: '.csv',
  });
  console.log(`Wrote ${chunks.length} chunks of ${tablePath}`);
  await rm(tablePath);
}

/** Streams one entry of a zip archive; GeoNames ships every dump as a zip holding one table. */
async function zipEntry(zipPath: string, entryName: string): Promise<NodeJS.ReadableStream> {
  const archive = new StreamZip.async({ file: zipPath });
  const entry = await archive.stream(entryName);
  entry.on('end', () => archive.close());
  return entry;
}

/**
 * Writes every line of `input` to `outputPath` through `transform`, which returns the line to
 * write or `undefined` to drop it. Streams both ends, so the 2 GB tables never sit in memory.
 */
async function transformLines(
  input: NodeJS.ReadableStream,
  outputPath: string,
  transform: (line: string) => string | undefined,
): Promise<void> {
  const lines = createInterface({ input, crlfDelay: Infinity });
  async function* transformed(): AsyncGenerator<string> {
    for await (const line of lines) {
      const result = transform(line);
      if (result !== undefined) {
        yield `${result}\n`;
      }
    }
  }
  await pipeline(transformed(), createWriteStream(outputPath));
}

/** The GeoNames code tables carry no header row; the queries need the one from config/. */
async function prependHeader(
  tablePath: string,
  headerFile: string,
  outputPath: string,
): Promise<void> {
  const output = createWriteStream(outputPath);
  await pipeline(createReadStream(headerFile), output, { end: false });
  await pipeline(createReadStream(tablePath), output);
}

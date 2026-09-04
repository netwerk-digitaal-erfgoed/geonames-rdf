// The LDE counterpart of map.sh: runs the config/*.rq queries over the chunks download.ts
// prepared and writes output/geonames.nt. Same queries, same environment variables, same output;
// what map.sh does with xargs, per-chunk JVMs, --load and cat is what SparqlAnythingConverter
// does, and what it guards against – a crashed chunk silently dropped from the output, a --load
// that SPARQL Anything could not read and exited 0 on – it guards against for every caller.
import { SparqlAnythingConverter } from '@lde/sparql-anything';
import { NativeTaskRunner } from '@lde/task-runner-native';
import { createWriteStream, readFileSync } from 'node:fs';
import { access, mkdir, readdir, readFile } from 'node:fs/promises';
import { availableParallelism, totalmem } from 'node:os';
import { pipeline } from 'node:stream/promises';

const dataDir = 'data';
const outputDir = process.env.OUTPUT_DIR ?? 'output';
await mkdir(outputDir, { recursive: true });

const jarPath = await sparqlAnythingJar();
const heap = process.env.JAVA_XMX ?? '2g';
const concurrency = parallelism();

const converter = new SparqlAnythingConverter({
  jarPath,
  // Every path in this file and in the queries is relative to the repository root, so that is the
  // task runner’s working directory and hence the converter’s.
  workDir: '.',
  taskRunner: new NativeTaskRunner({ cwd: '.' }),
  // Per-chunk JVM heap. A 1M-row chunk’s result graph needs ~1.2 GB, so 2g leaves margin. Raise
  // JAVA_XMX (and lower PARALLELISM to match) if CHUNK_SIZE in download.ts is increased.
  heap,
  concurrency,
});

// The admin code lookup table the places query joins against. It reads its own two inputs, so
// it takes no chunks, and its output is --load’ed by the places jobs below, which is why it is a
// conversion of its own rather than one more job in the call after it.
await converter.convert(
  [{ queryFile: 'config/admin-codes.rq' }],
  `${dataDir}/admin-codes.nt`,
);

// Everything else is one call: the converter runs the chunks of all jobs through one pool, so the
// short alternate-names chunks fill in behind the long places chunks instead of waiting for them,
// and concatenates the outputs in the order given. The places job comes first so the long jobs
// start first. GeoNames’ own ontology is included whole: it defines the gn:featureClass and
// gn:featureCode IRIs places.rq mints, which nothing else in the output describes.
console.log(`Mapping chunks with concurrency ${concurrency}, -Xmx${heap} per worker`);
await converter.convert(
  [
    {
      queryFile: 'config/places.rq',
      chunks: await chunksNamed('geonames'),
      load: `${dataDir}/admin-codes.nt`,
    },
    {
      queryFile: 'config/alternate-names.rq',
      chunks: await chunksNamed('alternate-names'),
    },
    { queryFile: 'config/ontology.rq', load: `${dataDir}/ontology.rdf` },
  ],
  `${outputDir}/geonames.nt`,
);

/** The chunks download.ts wrote for a table, in order. */
async function chunksNamed(table: string): Promise<string[]> {
  const chunkName = new RegExp(`^${table}-\\d{4}\\.csv$`);
  const names = (await readdir(dataDir)).filter((name) => chunkName.test(name));
  return names.sort().map((name) => `${dataDir}/${name}`);
}

/**
 * How many chunks to map at once. Each runs in its own JVM, so this multiplies against the heap:
 * default to the CPU count, capped to what memory allows – the cgroup limit inside a container,
 * else physical RAM – budgeting ~3 GB per worker (2g heap plus non-heap and OS headroom). The
 * converter cannot size this itself: it does not know the machine its task runner spawns on.
 */
function parallelism(): number {
  if (process.env.PARALLELISM !== undefined) {
    return Number(process.env.PARALLELISM);
  }
  const memoryCap = Math.max(1, Math.floor(memoryBytes() / (3 * 1024 ** 3)));
  return Math.min(availableParallelism(), memoryCap);
}

function memoryBytes(): number {
  // os.totalmem() reports the host’s memory, not a container’s limit, so ask the cgroup first.
  for (const limitFile of [
    '/sys/fs/cgroup/memory.max', // cgroup v2
    '/sys/fs/cgroup/memory/memory.limit_in_bytes', // cgroup v1
  ]) {
    try {
      const limit = Number(readFileSync(limitFile, 'utf-8').trim());
      if (Number.isFinite(limit) && limit < 2 ** 62) {
        return limit;
      }
    } catch {
      // No such cgroup file, or no limit: fall through.
    }
  }
  return totalmem();
}

/**
 * The SPARQL Anything jar, downloaded to bin/ if it is not there yet. The version is pinned in
 * sparql-anything.env, shared with map.sh and the Dockerfile, so both approaches convert with the
 * same build; this reads the `: "${NAME:=value}"` defaults that file sets for the shell.
 */
async function sparqlAnythingJar(): Promise<string> {
  const pins = Object.fromEntries(
    [...(await readFile('sparql-anything.env', 'utf-8')).matchAll(/\$\{(\w+):=([^}]+)\}/g)].map(
      ([, name, value]) => [name, process.env[name] ?? value],
    ),
  );
  const jarPath = `bin/${pins.SPARQL_ANYTHING_JAR}`;
  try {
    await access(jarPath);
  } catch {
    const url = `https://github.com/SPARQL-Anything/sparql.anything/releases/download/${pins.SPARQL_ANYTHING_VERSION}/${pins.SPARQL_ANYTHING_JAR}`;
    console.log(`Downloading ${url}...`);
    const response = await fetch(url);
    // Fail here rather than writing GitHub’s 404 page to the jar path, which would surface much
    // later as “Invalid or corrupt jarfile”.
    if (!response.ok || response.body === null) {
      throw new Error(`Could not download SPARQL Anything: ${response.status} ${response.statusText}`);
    }
    await pipeline(response.body, createWriteStream(jarPath));
  }
  return jarPath;
}

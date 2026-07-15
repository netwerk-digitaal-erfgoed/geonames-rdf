FROM eclipse-temurin:21-jre
LABEL org.opencontainers.image.source="https://github.com/netwerk-digitaal-erfgoed/geonames-rdf"
ENV OUTPUT_DIR=/output
WORKDIR /app
RUN mkdir bin

RUN apt-get update && apt-get install zip -y && rm -rf /var/lib/apt/lists/*
# Pre-download the SPARQL Anything jar, using the version pinned in sparql-anything.env
# (the single source of truth shared with map.sh).
COPY sparql-anything.env ./
RUN . ./sparql-anything.env && curl -L https://github.com/SPARQL-Anything/sparql.anything/releases/download/$SPARQL_ANYTHING_VERSION/$SPARQL_ANYTHING_JAR -o bin/$SPARQL_ANYTHING_JAR
COPY . .
ENTRYPOINT ["./entrypoint.sh"]

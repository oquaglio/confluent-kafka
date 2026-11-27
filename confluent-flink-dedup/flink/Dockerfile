# syntax=docker/dockerfile:1
# One image for the JobManager, TaskManager, SQL client and job-submit container.
# Build context is the project root (see docker-compose.yml).
#
# Official Flink image + connectors in /opt/flink/lib, which is where the classloader picks them up.
# Connector versions must match the Flink minor (the "-2.2" suffix); checksums are from Maven Central.
FROM flink:2.2.1-scala_2.12-java17

ARG MAVEN=https://repo1.maven.org/maven2

# Kafka SQL connector (fat jar, includes kafka-clients)
ADD --chmod=644 \
    --checksum=sha256:f3db8802b23523d6dbc2142ac6c6a5fecdc99881b24d5e1db82256aa32568b6e \
    ${MAVEN}/org/apache/flink/flink-sql-connector-kafka/5.1.0-2.2/flink-sql-connector-kafka-5.1.0-2.2.jar \
    /opt/flink/lib/
# JDBC connector: core + Postgres dialect (split into modules since 3.3/4.0)
ADD --chmod=644 \
    --checksum=sha256:f8357ab799095e6486315db4019edf63ced762bc8c2eaa63614c7b962755564b \
    ${MAVEN}/org/apache/flink/flink-connector-jdbc-core/4.1.0-2.2/flink-connector-jdbc-core-4.1.0-2.2.jar \
    /opt/flink/lib/
ADD --chmod=644 \
    --checksum=sha256:ae6da5769d932123606f1b9e03d90d57cde9c1d0144df6ffa64a9701afb86d6b \
    ${MAVEN}/org/apache/flink/flink-connector-jdbc-postgres/4.1.0-2.2/flink-connector-jdbc-postgres-4.1.0-2.2.jar \
    /opt/flink/lib/
# JDBC connector 4.x calls OpenLineage's JdbcExtractor when it plans a JDBC table (ClassNotFoundException
# without it). Version matches the connector's pom (openlineage.version).
ADD --chmod=644 \
    --checksum=sha256:d575b68bf72996e34d59013c9e877c19c0eea876fcccd49e246287048d09a54b \
    ${MAVEN}/io/openlineage/openlineage-java/1.32.0/openlineage-java-1.32.0.jar \
    /opt/flink/lib/
# Postgres JDBC driver
ADD --chmod=644 \
    --checksum=sha256:9776fca62dfc84f312d5c1aff9791f6f3cf56d518a8eca4a3a8dca7a95ef8881 \
    ${MAVEN}/org/postgresql/postgresql/42.7.15/postgresql-42.7.15.jar \
    /opt/flink/lib/

# SQL and the submit script (baked in, not bind-mounted: see README)
COPY flink-sql/ /opt/flink-sql/
COPY --chmod=755 scripts/submit-job.sh /opt/scripts/submit-job.sh

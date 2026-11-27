# syntax=docker/dockerfile:1
# Build context is the project root (see docker-compose.yml).
#   target flink       jobmanager/taskmanager: cnfldemos/flink-kafka + JDBC connector + Postgres driver
#   target sql-client  SQL client + the same jars + flink-sql/*.sql + scripts/submit-job.sh
# The jars go in /opt/flink/lib, which is where Flink's classloader picks them up.
ARG FLINK_BASE=cnfldemos/flink-kafka:1.19.1-scala_2.12-java17
ARG SQL_CLIENT_BASE=cnfldemos/flink-sql-client-kafka:1.19.1-scala_2.12-java17

FROM ${FLINK_BASE} AS flink
ADD --chmod=644 \
    --checksum=sha256:28134190494fcef3981f536035cfa7c4f12ab78342ac1acaa2e0c23c63484158 \
    https://repo1.maven.org/maven2/org/apache/flink/flink-connector-jdbc/3.2.0-1.19/flink-connector-jdbc-3.2.0-1.19.jar \
    /opt/flink/lib/
ADD --chmod=644 \
    --checksum=sha256:a2644cbfba1baa145ff7e8c8ef582a6eed7a7ec4ca792f7f054122bdec756268 \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar \
    /opt/flink/lib/

FROM ${SQL_CLIENT_BASE} AS sql-client
COPY --from=flink /opt/flink/lib/flink-connector-jdbc-3.2.0-1.19.jar /opt/flink/lib/postgresql-42.7.3.jar /opt/flink/lib/
COPY flink-sql/ /opt/flink-sql/
COPY --chmod=755 scripts/submit-job.sh /opt/scripts/submit-job.sh

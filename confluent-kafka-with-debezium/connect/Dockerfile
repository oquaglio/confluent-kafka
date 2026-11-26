# Kafka Connect worker with the Debezium plugins and connector configs baked in.
# Baked in (not bind-mounted) so the project works when Docker runs in another WSL2 distro.

# Stage 1: fetch the Debezium plugins. Debezium 3.x isn't on Confluent Hub, so the plugin archives come
# from Maven Central. Done in Alpine because the Connect image has no `tar`.
FROM alpine:3.20 AS plugins
ARG DEBEZIUM_VERSION=3.7.1.Final
ARG MAVEN=https://repo1.maven.org/maven2/io/debezium
WORKDIR /plugins
# Debezium PostgreSQL source connector + Debezium JDBC sink connector (bundles the Postgres driver).
RUN for p in postgres jdbc; do \
      wget -qO /tmp/$p.tgz "$MAVEN/debezium-connector-$p/$DEBEZIUM_VERSION/debezium-connector-$p-$DEBEZIUM_VERSION-plugin.tar.gz" \
      && tar xzf /tmp/$p.tgz || exit 1; \
    done

# Stage 2: the Connect worker.
FROM confluentinc/cp-kafka-connect:8.1.0
COPY --from=plugins /plugins/ /usr/share/confluent-hub-components/

# Connector configs + the script that registers them (run by the connect-init service).
COPY connectors/ /etc/connectors/
COPY scripts/register-connectors.sh /usr/local/bin/register-connectors.sh

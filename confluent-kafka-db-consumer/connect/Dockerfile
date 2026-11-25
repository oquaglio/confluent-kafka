# Kafka Connect worker with the connector plugins and connector configs baked in.
# Baked in (not bind-mounted) so the project works when Docker runs in another WSL2 distro.
FROM confluentinc/cp-kafka-connect:8.1.0

# JDBC connector (source + sink, bundles the PostgreSQL driver) and Datagen (demo data source).
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:10.9.10 \
 && confluent-hub install --no-prompt confluentinc/kafka-connect-datagen:0.7.4

# Connector configs + the script that registers them (run by the connect-init service).
COPY connectors/ /etc/connectors/
COPY scripts/register-connectors.sh /usr/local/bin/register-connectors.sh

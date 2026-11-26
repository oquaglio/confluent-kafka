# Kafka Connect worker with the connector plugins baked in (no bind mounts: Docker may run in another WSL2 distro).
FROM confluentinc/cp-kafka-connect:8.1.0

# JDBC connector (bundles the PostgreSQL driver) and Datagen (generates Avro records from a schema).
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:10.9.10 \
 && confluent-hub install --no-prompt confluentinc/kafka-connect-datagen:0.7.4

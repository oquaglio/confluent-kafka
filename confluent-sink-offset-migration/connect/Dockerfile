# Kafka Connect worker with the Confluent JDBC connector (bundles the PostgreSQL driver).
# The same image runs as connect-a and connect-b; only CONNECT_BOOTSTRAP_SERVERS differs.
FROM confluentinc/cp-kafka-connect:8.1.0
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:10.9.10

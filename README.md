# confluent-kafka

Confluent Kafka examples, each a self-contained Docker Compose project. Every folder has its own
README with concepts, start/stop commands and things to try.

## Projects

| Project | What it shows | Key pieces |
| --- | --- | --- |
| [confluent-basic](confluent-basic/) | One Kafka broker in KRaft mode (no ZooKeeper) for learning core concepts with the CLI tools | `cp-kafka` |
| [confluent-kafka-ui](confluent-kafka-ui/) | `confluent-basic` plus a web console for topics, messages and consumer groups | `cp-kafka`, Kafka UI (:8082) |
| [confluent-kafka-ui-sasl](confluent-kafka-ui-sasl/) | The same broker + UI with client authentication via SASL/SCRAM-SHA-512 | `cp-kafka`, Kafka UI, JAAS |
| [confluent-kafka-cluster](confluent-kafka-cluster/) | Multi-node KRaft cluster: 1 controller, 2 brokers, topic `orders` with 4 partitions and RF 2 | `cp-kafka` ×3, init job, Kafka UI |
| [confluent-kafka-db-consumer](confluent-kafka-db-consumer/) | Topic → database without code: a Datagen source connector feeds a JDBC sink into Postgres | Connect, Schema Registry, Postgres, pgAdmin (:5050) |
| [confluent-kafka-with-debezium](confluent-kafka-with-debezium/) | CDC: Postgres row changes captured by Debezium and applied to a second Postgres | Debezium source + JDBC sink, Schema Registry |
| [confluent-kafka-avro](confluent-kafka-avro/) | Schema-first Avro: your `.avsc` is registered before anything produces, plus a schema evolution demo (compatible v2/v3, breaking v4 refused) | Schema Registry, Datagen, JDBC sink, Postgres |
| [confluent-flink-dedup](confluent-flink-dedup/) | Flink SQL PoC: deduplicates sensor readings from Kafka into Postgres, fully automated (`just up`) | cp-all-in-one 8.4, Flink 2.2, Postgres 19, Kafka UI (:8080), Python producer |

The table runs roughly from basic to more involved. The Kafka projects publish overlapping host
ports (9092, 8081–8083, 5432), so run only one at a time. `docker-compose-watch` only uses 8090.

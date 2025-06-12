# Basic Kafka Broker

Confluent Kafka Broker example.

## Docs
https://developer.confluent.io/confluent-tutorials/kafka-on-docker/

## Start the Kafka Container
```SH
docker-compose up -d
```
```SH
docker logs kafka-broker
```
```SH
docker exec -it kafka-broker kafka-storage.sh random-uuid
```
```SH
docker exec -it kafka-broker kafka-topics.sh --create --topic test-topic --bootstrap-server localhost:9092 --partitions 1 --replication-factor 1
```

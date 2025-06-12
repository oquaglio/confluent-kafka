# confluent-kafka
Local container-based environment for Confluent Kafka

https://developer.confluent.io/confluent-tutorials/kafka-on-docker/


## Start the Kafka Container

docker-compose up -d

docker logs kafka-broker


docker exec -it kafka-broker kafka-storage.sh random-uuid



docker exec -it kafka-broker kafka-topics.sh --create --topic test-topic --bootstrap-server localhost:9092 --partitions 1 --replication-factor 1

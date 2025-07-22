#!/bin/bash
echo "kafka-storage format --ignore-formatted --cluster-id \$CLUSTER_ID --config /etc/kafka/kafka.properties --add-scram 'SCRAM-SHA-512=[name=admin,password=admin-secret]'" >> /etc/confluent/docker/ensure

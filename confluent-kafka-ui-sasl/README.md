#

Confluent Broker + Kafka UI at localhost:8082

## Test SASL

Install kcat:

```SH
sudo apt-get install kafkacat
brew install kcat
...
```

Validate SASL:

```SH
kcat -b localhost:9092 \
     -X security.protocol=SASL_PLAINTEXT \
     -X sasl.mechanism=SCRAM-SHA-512 \
     -X sasl.username=admin \
     -X sasl.password=admin-secret \
     -L
```

# One-shot init job: registers the Avro schemas in Schema Registry, then the connectors in Kafka Connect.
# schemas/ and connectors/ are copied in (not bind-mounted); `docker compose watch` rebuilds this image and
# re-runs the job whenever you edit them.
FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY schemas/ /etc/schemas/
COPY connectors/ /etc/connectors/
COPY scripts/register-schemas.sh scripts/register-connectors.sh scripts/init.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/init.sh"]

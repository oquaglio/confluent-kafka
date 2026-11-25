# Kafka → Kafka Connect → PostgreSQL

A Confluent Kafka stack that loads topic data into a database with **Kafka Connect**, no code needed:

- A **Datagen source connector** generates fake orders into topic `orders` (Avro), about one per 0.5 s.
- A **JDBC sink connector** reads `orders` and upserts each record into table `orders` in **PostgreSQL**.
  It creates the table itself from the Avro schema.

```text
 datagen-orders ──▶ topic `orders` ──▶ postgres-sink ──▶ Postgres demo.public.orders
 (source connector)   (Avro, schema in     (JDBC sink connector,
                       Schema Registry)     upsert on orderid)
```

| Service | Container | Where |
|---|---|---|
| `kafka` | `kafka-broker` | `localhost:9092` from your machine, `kafka:29092` from containers |
| `schema-registry` | `schema-registry` | http://localhost:8081 |
| `connect` | `kafka-connect` | REST API http://localhost:8083 |
| `connect-init` | `kafka-connect-init` | One-shot: registers the connectors in `connectors/`, then exits |
| `postgres` | `postgres` | `localhost:5432`, database `demo`, user/password `demo`/`demo` |
| `kafka-ui` | `kafka-ui` | http://localhost:8082 (topics, schemas, connectors) |

## Start / Stop

With the scripts:

```sh
scripts/up.sh          # build, start, wait for connectors, show the first rows in Postgres
scripts/status.sh      # containers, connector/task state, row count
scripts/query.sh       # latest 10 rows (or pass your own SQL)
scripts/down.sh        # stop, data kept
scripts/down.sh -v     # stop AND delete Kafka + Postgres data
```

Or with plain Docker:

```sh
docker compose up -d --build      # connect-init registers the connectors automatically
docker logs kafka-connect-init    # shows RUNNING for each connector
docker exec -it postgres psql -U demo -d demo -c 'SELECT count(*) FROM orders'
docker compose down               # add -v to wipe data
```

The first `up` builds the Connect image (downloads the plugins from Confluent Hub), so it needs internet
and takes a minute. Later starts reuse the image.

## Files

```text
docker-compose.yml               all services
connect/Dockerfile               cp-kafka-connect + JDBC 10.9.10 + Datagen 0.7.4 plugins,
                                 with connectors/ and the register script copied in
connectors/datagen-orders.json   source connector config (file name = connector name)
connectors/postgres-sink.json    sink connector config
scripts/register-connectors.sh   PUTs every connectors/*.json to the Connect REST API
scripts/*.sh                     up / down / status / query / produce helpers
```

Nothing is bind-mounted. Plugins and connector configs are copied into the image at build time, so the
project also works when Docker runs in a different WSL2 distro.

## How the sink maps Kafka to the table

`connectors/postgres-sink.json`:

| Setting | What it does |
|---|---|
| `topics: orders` | Topic to read. The table gets the same name |
| `auto.create`, `auto.evolve` | Create the table from the Avro schema; add columns if the schema gains fields |
| `insert.mode: upsert`, `pk.mode: record_value`, `pk.fields: orderid` | `orderid` is the primary key. A record with an existing `orderid` updates that row, so replays don't create duplicates |
| `transforms.flatten` (`Flatten$Value`) | The `address` field is a nested record, which a JDBC table can't hold. Flatten turns it into `address_city`, `address_state`, `address_zipcode` |
| `errors.tolerance: all` + `errors.deadletterqueue.*` | A record that can't be written goes to topic `orders-dlq` instead of stopping the connector |

Resulting table:

```text
 ordertime bigint | orderid integer (PK) | itemid text | orderunits double precision
 address_city text | address_state text | address_zipcode bigint
```

The sink needs a schema for every record. That's why values are **Avro** (schema in Schema Registry).
Plain JSON without a schema won't work with the JDBC sink.

## Hands-On

Send your own order and watch it land in Postgres:

```sh
scripts/produce.sh 999999 Item_manual 2.5
scripts/query.sh "SELECT * FROM orders WHERE orderid = 999999"

scripts/produce.sh 999999 Item_updated 3     # same key: the row is updated, not duplicated
scripts/query.sh "SELECT * FROM orders WHERE orderid = 999999"
```

Manage connectors with the REST API:

```sh
curl -s localhost:8083/connectors?expand=status          # all connectors + state
curl -s -X PUT localhost:8083/connectors/datagen-orders/pause    # stop generating data
curl -s -X PUT localhost:8083/connectors/datagen-orders/resume
curl -s -X DELETE localhost:8083/connectors/postgres-sink        # remove the sink
curl -s localhost:8083/connector-plugins                  # installed plugins
```

Change a connector: edit its JSON in `connectors/`, then run `scripts/register-connectors.sh`. It PUTs
each file to `/connectors/<name>/config`, which creates or updates the connector. (Rebuild with
`docker compose up -d --build` if you also want `connect-init` to use the new version on the next start.)

Look at the raw topic (Avro decoded). Keys are plain strings, so the key deserializer is overridden;
`-Dlog4j2.level=ERROR` hides the tool's INFO logging:

```sh
docker exec -e SCHEMA_REGISTRY_LOG4J_OPTS=-Dlog4j2.level=ERROR schema-registry \
  kafka-avro-console-consumer --bootstrap-server kafka:29092 --topic orders --from-beginning --max-messages 5 \
  --property schema.registry.url=http://localhost:8081 --property print.key=true \
  --property key.deserializer=org.apache.kafka.common.serialization.StringDeserializer
```

Check how far behind the sink is (its consumer group is `connect-<connector name>`):

```sh
docker exec kafka-broker kafka-consumer-groups --bootstrap-server kafka:29092 \
  --describe --group connect-postgres-sink
```

## Use another database

The JDBC plugin also bundles drivers for SQL Server, Oracle and SQLite. For MySQL, add
the MySQL JDBC driver jar to the JDBC plugin folder in `connect/Dockerfile`. Then swap the `postgres`
service and change `connection.url`, `connection.user` and `connection.password` in
`connectors/postgres-sink.json`.

## Notes

- Image versions are pinned to Confluent Platform **8.1.0**, the same as `confluent-kafka-cluster`.
- Host ports `9092`, `8081`, `8082`, `8083` and `5432` clash with the other projects in this repo and with
  any local Postgres. Stop the other stack first.
- Datagen `orderid` starts at 0 and counts up. Its position is stored in Connect's offsets topic, so a
  restart continues where it left off. After `down -v` it starts again from 0.

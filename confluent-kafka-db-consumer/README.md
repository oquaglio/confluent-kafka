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
| `pgadmin` | `pgadmin` | Postgres web UI, http://localhost:5050 (no login) |

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

Rebuilds:

- docker compose up -d builds the image only if it doesn't exist yet.
- After you edit connect/Dockerfile, connectors/*.json or the register script, use docker compose up -d --build (or docker compose build connect). scripts/up.sh always passes --build, and Docker's layer cache keeps that quick when nothing changed.

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

## Browse the data in pgAdmin

Open http://localhost:5050. There is no login page and the `demo` server is already registered with its
password, so no prompt either. Go to **Servers → demo → Databases → demo → Schemas → public → Tables →
orders**, then right-click → **View/Edit Data → All Rows**, or open **Tools → Query Tool** and run:

```sql
SELECT * FROM orders ORDER BY orderid DESC LIMIT 20;
```

How it's set up (see `pgadmin` and `configs:` in `docker-compose.yml`):

- `PGADMIN_CONFIG_SERVER_MODE=False` runs pgAdmin in desktop mode: one built-in user, no login.
  That's fine on your own machine, but don't expose it.
- `servers.json` (inline `configs`, no bind mount) registers the `demo` server on first start.
- A `pgpass` file supplies the password. It must be owned by pgAdmin's user (uid 5050) and be mode
  `0600`, or libpq ignores it and pgAdmin asks for the password.
- pgAdmin keeps its settings in the `pgadmin-data` volume. `servers.json` is only imported the first
  time, so after editing it run `docker compose down -v` (or `docker volume rm
  confluent-kafka-db-consumer_pgadmin-data`).

## Disk usage: Postgres table vs Kafka topic

Each service stores its data in a named volume:

| Volume | Mounted at | Holds |
|---|---|---|
| `confluent-kafka-db-consumer_kafka-data` | `/var/lib/kafka/data` in `kafka-broker` | Every topic partition, one folder each (`orders-0`, `__consumer_offsets-12`, ...) |
| `confluent-kafka-db-consumer_postgres-data` | `/var/lib/postgresql/data` in `postgres` | The whole Postgres cluster: tables, indexes, WAL |
| `confluent-kafka-db-consumer_pgadmin-data` | `/var/lib/pgadmin` in `pgadmin` | pgAdmin settings only |

### Whole volumes (Docker)

```sh
docker system df -v | grep -E 'VOLUME NAME|db-consumer'
```

> **This overstates the Kafka volume.** It reports *apparent* size. Kafka creates a 10 MB `.index` and
> a 10 MB `.timeindex` file for every partition, but these are *sparse*: they use almost no real disk
> until they fill. With about 85 partitions (mostly the 50 internal `__consumer_offsets` ones), that adds
> up to about 1.7 GB on paper while only about 31 MB is really used. Use `du` for the real number:

```sh
# Real usage of a volume, from a throwaway container (works even if the service is stopped)
docker run --rm -v confluent-kafka-db-consumer_kafka-data:/v:ro alpine du -sh /v
docker run --rm -v confluent-kafka-db-consumer_postgres-data:/v:ro alpine du -sh /v

# Or inside the running container
docker exec kafka-broker du -sh /var/lib/kafka/data
docker exec postgres     du -sh /var/lib/postgresql/data
```

### Kafka topic `orders`

A topic's data is the folder for each of its partitions. `orders` has one partition, `orders-0`.

```sh
# Real size per partition folder, biggest last
docker exec kafka-broker bash -c 'du -sh /var/lib/kafka/data/*/ | sort -h | tail'

# Files inside: the .log segment holds the messages; .index/.timeindex are the sparse indexes
docker exec kafka-broker bash -c 'ls -lh /var/lib/kafka/data/orders-0; du -sh /var/lib/kafka/data/orders-0/*'

# Kafka's own view (bytes of log data per partition, via the broker API; no shell access needed)
docker exec kafka-broker kafka-log-dirs --bootstrap-server kafka:29092 --describe --topic-list orders

# Number of messages, to work out bytes per message
docker exec kafka-broker kafka-get-offsets --bootstrap-server kafka:29092 --topic orders
```

What controls the size: `retention.ms` (default 7 days) and `retention.bytes` (default unlimited).
Kafka only deletes whole, closed **segments**. A segment is closed at 1 GB (`segment.bytes`) or after 7
days (`segment.ms`), whichever comes first. So a slow topic like this one keeps up to about 14 days of
data before the oldest segment goes. Check the settings with:

```sh
docker exec kafka-broker kafka-configs --bootstrap-server kafka:29092 --entity-type topics \
  --entity-name orders --describe --all | grep -E ' (retention\.(ms|bytes)|segment\.(bytes|ms))='
```

### Postgres table `orders`

```sh
docker exec postgres psql -U demo -d demo -c "
  SELECT count(*)                                         AS rows,
         pg_size_pretty(pg_relation_size('orders'))       AS table_data,
         pg_size_pretty(pg_indexes_size('orders'))        AS indexes,
         pg_size_pretty(pg_total_relation_size('orders')) AS total_incl_indexes,
         pg_size_pretty(pg_database_size('demo'))         AS whole_db
  FROM orders"

# Where the table lives on disk, and its files (main data, free-space map _fsm, visibility map _vm)
docker exec postgres bash -c 'cd /var/lib/postgresql/data &&
  f=$(psql -U demo -d demo -tAc "SELECT pg_relation_filepath('\''orders'\'')") && ls -lh $f*'

# How the volume splits: table/index files (base) vs write-ahead log (pg_wal)
docker exec postgres bash -c 'cd /var/lib/postgresql/data && du -sh base pg_wal'
```

The same queries also work in pgAdmin's **Query Tool**. pgAdmin also shows table size under **orders →
Properties / Statistics**.

### With Portainer

Portainer's **Volumes** page lists each volume with its driver, mount point and the containers using
it. It doesn't show sizes, so use a container console to measure:

1. **Containers** → `kafka-broker` (or `postgres`) → **>_ Console**.
2. Command `/bin/bash`, then **Connect**. Leave the user as is: `appuser` for Kafka, `root` for
   Postgres.
3. Run the same commands as above without the `docker exec <container>` prefix, for example:
   - Kafka: `du -sh /var/lib/kafka/data/orders-0` or
     `kafka-log-dirs --bootstrap-server kafka:29092 --describe --topic-list orders`
   - Postgres: `psql -U demo -d demo -c "SELECT pg_size_pretty(pg_total_relation_size('orders'))"`

To measure a stopped service's volume: **Containers → Add container**, image `alpine`, command
`du -sh /v`, add a volume mapping of `/v` to `confluent-kafka-db-consumer_kafka-data` (read-only), deploy.
Then read the result in the container's **Logs**.

### Example numbers (about 124k orders after about 17 h)

| Where | Size | Per row/message |
|---|---|---|
| Kafka `orders-0`, real (`du`) | 21 MB (log 20.5 MB + small indexes) | ~170 B |
| Kafka volume, real / apparent | 31 MB / 1.7 GB | |
| Postgres `orders` table + PK index | 10 MB + 2.7 MB = 13 MB | ~105 B |
| Postgres volume (`base` 43 MB + `pg_wal` 33 MB) | 76 MB | |

The Kafka copy is bigger per record because every message also stores its key, timestamp and batch
headers. The Postgres volume is much bigger than the table because it also holds the write-ahead log
and the system catalogs.

## Use another database

The JDBC plugin also bundles drivers for SQL Server, Oracle and SQLite. For MySQL, add
the MySQL JDBC driver jar to the JDBC plugin folder in `connect/Dockerfile`. Then swap the `postgres`
service and change `connection.url`, `connection.user` and `connection.password` in
`connectors/postgres-sink.json`.

## Notes

- Image versions are pinned to Confluent Platform **8.1.0**, the same as `confluent-kafka-cluster`.
- Host ports `9092`, `8081`, `8082`, `8083`, `5432` and `5050` clash with the other projects in this repo and with
  any local Postgres. Stop the other stack first.
- Datagen `orderid` starts at 0 and counts up. Its position is stored in Connect's offsets topic, so a
  restart continues where it left off. After `down -v` it starts again from 0.

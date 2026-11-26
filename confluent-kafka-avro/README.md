# Avro + Schema Registry → Kafka Connect → PostgreSQL

A schema-first Confluent Kafka stack. You write one Avro schema file; everything else is wired automatically:

1. **Schema**: `schemas/transactions-value.avsc` defines a `Transaction` record.
2. **Schema Registry**: an init container registers that schema under subject `transactions-value`
   (compatibility `BACKWARD`) *before* anything produces.
3. **Avro data source**: a **Datagen source connector** generates fake transactions from the same file
   and serializes them as Avro **against the registered schema**. It isn't allowed to register schemas itself.
4. **Sink**: a **JDBC sink connector** reads the Avro records and upserts them into table `transactions`
   in **PostgreSQL**. It creates and evolves the table from the Avro schema.

```text
 schemas/transactions-value.avsc
        │  init: strip Datagen hints, register            ┌──────────────────────────────┐
        ▼                                                 │ Schema Registry              │
 subject transactions-value  v1, v2, ...  ◀───────────────│ (stored in Kafka `_schemas`) │
        ▲ look up latest            ▲ look up by id       └──────────────────────────────┘
        │                           │
 datagen-transactions ──▶ topic `transactions` ──▶ postgres-sink ──▶ Postgres demo.public.transactions
 (Avro source connector)  key: string               (JDBC sink,
                          value: Avro bytes          upsert on transaction_id)
                          [magic byte][schema id][data]
```

| Service | Container | Where |
|---|---|---|
| `kafka` | `kafka-broker` | `localhost:9092` from your machine, `kafka:29092` from containers |
| `schema-registry` | `schema-registry` | http://localhost:8081 |
| `postgres` | `postgres` | `localhost:5432`, database `demo`, user/password `demo`/`demo` |
| `connect` | `kafka-connect` | REST API http://localhost:8083 (Datagen 0.7.4 + JDBC 10.9.10 plugins) |
| `init` | `avro-init` | One-shot: registers `schemas/*.avsc`, then `connectors/*.json`, then exits |
| `kafka-ui` | `kafka-ui` | http://localhost:8082 (topics with decoded Avro, schemas, connectors) |

All images are Confluent Platform 8.1.0, like the other projects in this repo. They use the same host
ports too, so only run one of these projects at a time.

## Quick start

```sh
scripts/up.sh          # build, start, wait for init, show the first rows in Postgres
```

Or with plain Docker:

```sh
docker compose up -d --build     # init registers the schema and connectors automatically
docker logs avro-init            # schema id/version + RUNNING for each connector
docker exec postgres psql -U demo -d demo -c 'SELECT * FROM transactions LIMIT 5'
```

The first build downloads the connector plugins from Confluent Hub, so it needs internet and takes a
minute or two. Later starts reuse the image.

Stop:

```sh
scripts/down.sh        # stop, data and schemas kept
scripts/down.sh -v     # stop AND delete the Kafka (incl. registered schemas) and Postgres volumes
```

## Live editing with `docker compose watch`

```sh
docker compose up -d --build
docker compose watch --no-up     # leave running in a terminal
```

Watch tracks `schemas/` and `connectors/`. When you save a file there, it rebuilds the small `init` image
and runs `init` again:

- a changed **schema** is registered as a new version, *if* the registry says it's compatible;
- a changed **connector JSON** updates that connector in place (`PUT /connectors/<name>/config`).

Follow along with `docker logs -f avro-init` (or watch's own output). Without watch, run
`scripts/reinit.sh` after an edit. It does the same thing once and exits non-zero if init fails.

Nothing is bind-mounted: schemas, connector configs and scripts are copied into the `init` image, and
plugins are baked into the `connect` image. So the project works when the Docker daemon runs in a
different WSL2 distro, which is why watch rebuilds the image instead of syncing files.

## Files

```text
docker-compose.yml                    all services; `develop.watch` on init
schemas/transactions-value.avsc       THE schema. File name = subject name (<topic>-value)
connectors/datagen-transactions.json  Avro source connector (file name = connector name)
connectors/postgres-sink.json         JDBC sink connector
connect/Dockerfile                    cp-kafka-connect + Datagen + JDBC plugins
init/Dockerfile                       alpine + curl + jq + schemas/ + connectors/ + init scripts
scripts/init.sh                       init entry point: register-schemas.sh, then register-connectors.sh
scripts/register-schemas.sh           POST each .avsc to Schema Registry (sets compatibility first)
scripts/register-connectors.sh        PUT each connector JSON to Connect; resolves "@file:" references
scripts/up.sh down.sh status.sh       lifecycle helpers
scripts/query.sh produce.sh consume.sh  look at / add data
scripts/check-compat.sh reinit.sh     schema evolution helpers
```

## Concepts

### Avro and the schema file

Avro is a compact binary format. Records don't carry field names, only values in schema order, so a
reader needs the **writer's schema** to decode them. The schema is JSON:

| Field | Avro type | Shows | Postgres column |
|---|---|---|---|
| `transaction_id` | `string` | record key / primary key | `text NOT NULL` (PK) |
| `account_id`, `currency` | `string` | | `text NOT NULL` |
| `amount` | `double` | | `double precision NOT NULL` |
| `status` | `enum TransactionStatus {PENDING, COMPLETED, FAILED}` | named type; producers can't send other values | `text NOT NULL` |
| `created_at` | `long` + `logicalType: timestamp-millis` | logical type on a primitive | `timestamp` |
| `note` | `["null","string"]`, `default: null` | optional field = union with null | `text` (nullable) |

`arg.properties` in the file are **Datagen hints** (regex, options, ranges) used by the
[avro-random-generator](https://github.com/confluentinc/avro-random-generator). They must sit on the *type*
object, not on the field. `register-schemas.sh` strips them, so the registry holds only the contract.

### Schema Registry, subjects and the wire format

- A **subject** is a versioned history of schemas. With the default *TopicNameStrategy*, the value schema
  for topic `transactions` lives in subject `transactions-value`.
- Each distinct schema gets a global **id**. Registering an identical schema again returns the existing
  id, with no new version. That's why re-running init is safe.
- Every Kafka message value starts with a 5-byte header: magic byte `0` + 4-byte schema id, then the Avro
  data. Consumers fetch the schema by id (and cache it). `scripts/consume.sh` prints the id per record.
- Schemas are stored in Kafka topic `_schemas`, so they survive restarts. They're only lost with `down -v`.

### Compatibility and evolution

The subject's compatibility is **BACKWARD**: a new schema must be able to *read* data written with the
latest registered version, so consumers can upgrade first. Typical rules:

| Change | BACKWARD? |
|---|---|
| Add a field **with** a default | ✅ |
| Remove a field | ✅ |
| Add a field without a default | ❌ (old data has no value for it) |
| Change a field's type, e.g. `double` → `string` | ❌ |
| Add an enum symbol | ✅ |

Each version is only checked against the *latest* one (use `BACKWARD_TRANSITIVE` to check all of them).
The registry rejects an incompatible schema with HTTP 409. init then exits 1 **before** touching the
connectors, so the running pipeline keeps going on the old version.

### Schema-first producing (the Datagen connector)

Converters in Kafka Connect turn records into bytes. The worker defaults are `StringConverter` for keys
and `AvroConverter` for values. The source connector overrides a few value-converter settings:

| Setting | Why |
|---|---|
| `value.converter.auto.register.schemas=false` | The producer may not create schemas. The registry is governed by `schemas/`, not by whatever a producer sends |
| `value.converter.use.latest.version=true` | Serialize with the latest registered version of `transactions-value` |
| `value.converter.enhanced.avro.schema.support=true` | Keep the Avro `enum` as an enum. Without it Connect turns it into `string`, and the strict "is latest compatible?" check fails |
| `value.converter.connect.meta.data=false` | Don't add `connect.name`/`connect.parameters` properties to the schema |
| `schema.string: "@file:/etc/schemas/transactions-value.avsc"` | Datagen generates from the same file. `register-connectors.sh` inlines the file, so there's one copy of the schema |
| `schema.keyfield: transaction_id` | Use that field as the record key |

### The sink

`connectors/postgres-sink.json`:

| Setting | What it does |
|---|---|
| `topics: transactions` | Topic to read. The table gets the same name |
| `auto.create`, `auto.evolve` | Create the table from the Avro schema, and `ALTER TABLE ADD COLUMN` when the schema gains a field (using its default) |
| `insert.mode: upsert`, `pk.mode: record_value`, `pk.fields: transaction_id` | The primary key comes from the value. Replays and repeated ids update the row instead of duplicating it |
| `errors.tolerance: all` + `errors.deadletterqueue.*` | A record that can't be written goes to topic `transactions-dlq` instead of stopping the sink |

The JDBC sink needs a schema for every record. That's what Avro + Schema Registry provides; schemaless
JSON wouldn't work.

## Hands-on

### Look at the data

```sh
scripts/status.sh                 # containers, schema versions, connector state, row count
scripts/query.sh                  # latest 10 rows (or pass your own SQL)
scripts/consume.sh 5              # raw topic, Avro decoded to JSON, with key and schema id
curl -s localhost:8081/subjects/transactions-value/versions/latest | jq -r .schema | jq .
```

Kafka UI (http://localhost:8082) shows the same: **Topics → transactions → Messages** (decoded),
**Schema Registry → transactions-value** (versions and diff), and **Kafka Connect**.

### Produce your own record

```sh
scripts/produce.sh TX-MANUAL1 42.5 COMPLETED
scripts/query.sh "SELECT * FROM transactions WHERE transaction_id = 'TX-MANUAL1'"

scripts/produce.sh TX-MANUAL1 99 FAILED        # same key: row updated, not duplicated
scripts/produce.sh TX-BAD 1 REFUNDED           # rejected by the producer: not an enum symbol
```

The record is written with the latest schema id, in Avro's JSON encoding: a union value is wrapped in its
branch type, e.g. `"note": {"string": "..."}`.

### Evolve the schema (compatible)

Add an optional field with a default to `schemas/transactions-value.avsc`:

```json
    { "name": "channel", "default": "web",
      "type": { "type": "string", "arg.properties": { "options": ["web", "mobile", "pos"] } } }
```

Then:

```sh
scripts/check-compat.sh        # OK  transactions-value is compatible ...   (dry run, registers nothing)
scripts/reinit.sh              # or just save the file while `docker compose watch` runs
# -> transactions-value  id=2  version=2  compatibility=BACKWARD
scripts/query.sh "SELECT channel, count(*) FROM transactions GROUP BY 1"
```

What happens: the registry stores v2, Datagen is updated with the new `schema.string` and serializes
with v2, and the sink sees a new field and runs `ALTER TABLE ... ADD COLUMN channel text DEFAULT 'web'`.
Rows written before the change show the default.

### Evolve the schema (incompatible)

Change `amount` from `"double"` to `"string"`:

```sh
scripts/check-compat.sh
# FAIL  transactions-value
#   "TYPE_MISMATCH ... reader type: STRING not compatible with writer type: DOUBLE"
scripts/reinit.sh
# !! transactions-value: HTTP 409 {"error_code":409,"message":"Schema being registered is incompatible ...
```

Nothing changes in the pipeline. Revert the edit, or bump the compatibility level if you really mean
it (`curl -X PUT -H 'Content-Type: application/json' -d '{"compatibility":"NONE"}'
localhost:8081/config/transactions-value`). Then expect consumers and the sink to break.

> Note: once you've registered v2, putting back the v1 file adds nothing (v1 already exists), but the
> latest stays v2. Datagen would then produce from v1 while `use.latest.version` points at v2. For a
> clean slate, use `scripts/down.sh -v && scripts/up.sh`.

### Manage connectors

```sh
curl -s localhost:8083/connectors?expand=status | jq
curl -s -X PUT localhost:8083/connectors/datagen-transactions/pause
curl -s -X PUT localhost:8083/connectors/datagen-transactions/resume
docker exec kafka-broker kafka-consumer-groups --bootstrap-server kafka:29092 \
  --describe --group connect-postgres-sink       # sink lag
```

To change a connector, edit its JSON in `connectors/`. Watch or `scripts/reinit.sh` applies it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `avro-init` exited 1 with HTTP 409 | The schema edit is incompatible, see above. `scripts/check-compat.sh` shows why |
| Datagen task `FAILED`, trace says `Incompatible schema ... Set latest.compatibility.strict=false` | The schema Datagen derives from `schema.string` doesn't match the latest registered version, e.g. `enhanced.avro.schema.support` is off, or the file and the registry disagree. Get the trace with `curl -s localhost:8083/connectors/datagen-transactions/status \| jq -r '.tasks[0].trace'` |
| Random garbage values in the table | `arg.properties` were put on the field instead of inside its `type` object |
| `Unknown magic byte!` in a console consumer | Keys are plain strings. Add `--property key.deserializer=org.apache.kafka.common.serialization.StringDeserializer` (as `consume.sh` does) |
| Port already in use | Another project in this repo is running. Stop it first |

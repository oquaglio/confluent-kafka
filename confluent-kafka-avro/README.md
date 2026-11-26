# Avro + Schema Registry → Kafka Connect → PostgreSQL

A schema-first Confluent Kafka stack. You write one Avro schema file; everything else is wired automatically:

1. **Schema**: `schemas/transactions-value.avsc` defines a `Transaction` record.
2. **Schema Registry**: an init container registers that schema under subject `transactions-value`
   (compatibility `BACKWARD`) *before* anything produces.
3. **Avro data source**: a **Datagen source connector** generates fake transactions from the same file
   and serializes them as Avro **with that registered schema**. It isn't allowed to register schemas itself.
4. **Sink**: a **JDBC sink connector** reads the Avro records and upserts them into table `transactions`
   in **PostgreSQL**. It creates and evolves the table from the Avro schema.

**Schema evolution** (v1 → v2 → v3, plus a breaking v4 that gets refused, with old and new producers
writing to the same table) is a one-command demo: `scripts/evolution-demo.sh`. See
[Schema evolution](#schema-evolution).

```text
 schemas/transactions-value.avsc
        │  init: strip Datagen hints, register            ┌──────────────────────────────┐
        ▼                                                 │ Schema Registry              │
 subject transactions-value  v1, v2, ...  ◀───────────────│ (stored in Kafka `_schemas`) │
        ▲ look up id of own schema  ▲ look up by id       └──────────────────────────────┘
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
evolution/v1..v3.avsc, v4-breaking.avsc  the evolution steps (evolve.sh copies one over the file above)
connectors/datagen-transactions.json  Avro source connector (file name = connector name)
connectors/postgres-sink.json         JDBC sink connector
connect/Dockerfile                    cp-kafka-connect + Datagen + JDBC plugins
init/Dockerfile                       alpine + curl + jq + schemas/ + connectors/ + init scripts
scripts/init.sh                       init entry point: register-schemas.sh, then register-connectors.sh
scripts/register-schemas.sh           POST each .avsc to Schema Registry (sets compatibility first)
scripts/register-connectors.sh        PUT each connector JSON to Connect; resolves "@file:" references
scripts/up.sh down.sh status.sh       lifecycle helpers
scripts/query.sh produce.sh consume.sh  look at / add data
scripts/check-compat.sh reinit.sh     dry-run compatibility check / re-run init after an edit
scripts/evolve.sh                     switch the pipeline to evolution/<step>.avsc (rolls back if refused)
scripts/produce-as.sh                 send a record as an app pinned to schema v1, v2 or v3
scripts/evolution-demo.sh             the whole evolution walkthrough
scripts/reset.sh                      back to v1 with empty data (down -v + up)
```

The host needs `docker`, `curl` and `jq`.

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

[Schema evolution](#schema-evolution) below covers the modes in full and has a runnable demo.

### Schema-first producing (the Datagen connector)

Converters in Kafka Connect turn records into bytes. The worker defaults are `StringConverter` for keys
and `AvroConverter` for values. The source connector overrides a few value-converter settings:

| Setting | Why |
|---|---|
| `value.converter.auto.register.schemas=false` | The producer may not create schemas. It looks up the id of *its own* schema and fails (`40403 Schema not found`) if that isn't registered. The registry is governed by `schemas/`, not by whatever a producer sends |
| `value.converter.enhanced.avro.schema.support=true` | Keep the Avro `enum` as an enum. Without it Connect turns it into `string`, so the schema no longer matches the registered one |
| `value.converter.connect.meta.data=false` | Don't add `connect.name`/`connect.parameters` properties to the schema |
| `schema.string: "@file:/etc/schemas/transactions-value.avsc"` | Datagen generates from the same file. `register-connectors.sh` inlines the file, so there's one copy of the schema |
| `schema.keyfield: transaction_id` | Use that field as the record key |

There's also `value.converter.use.latest.version=true`, which serializes with the latest registered
version whatever the producer's own schema is. It isn't used here. A producer still on an older version,
e.g. one rolled back to v1, then fails with `Not a valid schema field: channel`, because a v1 record
can't be written as v3.

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
branch type, e.g. `"note": {"string": "..."}`. After evolving the schema, use `scripts/produce-as.sh`
instead (see [Schema evolution](#schema-evolution)).

### Manage connectors

```sh
curl -s localhost:8083/connectors?expand=status | jq
curl -s -X PUT localhost:8083/connectors/datagen-transactions/pause
curl -s -X PUT localhost:8083/connectors/datagen-transactions/resume
docker exec kafka-broker kafka-consumer-groups --bootstrap-server kafka:29092 \
  --describe --group connect-postgres-sink       # sink lag
```

To change a connector, edit its JSON in `connectors/`. Watch or `scripts/reinit.sh` applies it.

## Schema evolution

### How it normally works

A schema changes because the **producing application** changes: a developer adds a field to the
class or the `.avsc`, and the new version is registered before or when that code ships (often by a CI
step, or `auto.register.schemas=true` on the producer in less strict setups). Schema Registry is the
**gatekeeper**. It doesn't change anything itself, it only says yes or no:

1. The new schema is checked against the subject's compatibility rule (here `BACKWARD`). If it's
   incompatible, registration fails with HTTP 409 and the producer can't use it.
2. If it's accepted, it becomes the next version and gets a global id. Producers built with it start writing
   records stamped with the new id. Producers not yet upgraded keep writing the **old** id. Both are
   valid, and the topic simply contains a mix.
3. Every consumer decodes each record with the schema of the id it carries (the *writer schema*), then
   resolves it to the schema it expects (the *reader schema*), filling in defaults for missing fields and
   ignoring extra ones. That's why defaults matter so much.

**Is it automated? Does a new column at the source become a new column at the target?** Partly:

- **Additive changes, yes.** With the JDBC sink's `auto.evolve=true`, the first record with a new field
  makes the sink run `ALTER TABLE ... ADD COLUMN`, using the Avro default as the column `DEFAULT`
  (or a nullable column for an optional field). No one touches the database. The same holds for a CDC
  pipeline (see `confluent-kafka-with-debezium`): `ALTER TABLE ADD COLUMN` on the source DB → Debezium
  emits a new schema version → the sink adds the column at the target.
- **Everything else, no.** The JDBC sink never drops, renames or retypes a column. A removed field
  leaves its column in place (it must be nullable or have a default, or inserts fail). A rename is a
  new column and an orphaned old one. A type change isn't possible in place.
- **Registry-compatible doesn't mean sink-compatible.** An Avro rename with `aliases` is BACKWARD
  compatible for the registry, but the sink sees a new field name, adds a column, and then fails inserts
  if the old column is `NOT NULL`. Test evolution against the real sink, not just the registry.

### Compatibility modes

| Mode | Guarantees | Upgrade order | Allowed changes (roughly) |
|---|---|---|---|
| `BACKWARD` (default, used here) | new schema can read data written with the previous one | consumers first | add field *with* default, remove any field |
| `FORWARD` | previous schema can read data written with the new one | producers first | add any field, remove field *with* default |
| `FULL` | both | any order | add / remove fields *with* defaults only |
| `*_TRANSITIVE` | same, but checked against **all** versions, not just the latest | | |
| `NONE` | no checks | (you're on your own) | anything |

All the steps below are FULL compatible (every added or removed field has a default), which is the safe
habit to have.

### Run the demo

```sh
scripts/reset.sh             # fresh stack at v1 (DELETES all data)
scripts/evolution-demo.sh    # pauses between steps; -y runs straight through
```

One topic, one subject, one table. The steps live in `evolution/`:

| Step | Schema change | Registry | What the sink does |
|---|---|---|---|
| `v1` | the starting schema | v1 | creates the table |
| `v2` | + `channel` string, default `"web"` | ✅ v2 | `ADD COLUMN channel text DEFAULT 'web'` |
| `v3` | − `note`; + `fee` double, default `0.0` | ✅ v3 | `ADD COLUMN fee double precision DEFAULT 0.0`; `note` **kept**, NULL for v3 rows |
| `v4-breaking` | `amount` double → string | ❌ 409 `TYPE_MISMATCH` | nothing: the pipeline keeps running on v3 |

And between the steps, **producers pinned to different versions** write to the same topic:

```sh
scripts/produce-as.sh v2     # before v2 is registered: REFUSED ... Schema not found; error code: 40403
scripts/evolve.sh v2         # register v2 + switch Datagen to it (sink adds the column)
scripts/produce-as.sh v1     # an old app: still fine, its row gets channel = 'web' from the DEFAULT
scripts/produce-as.sh v2     # a new app: channel = 'mobile'
```

Output, trimmed:

```text
▶ 4. Old and new apps write to the same topic + table side by side
sent TX-DEMO-V1 as v1
sent TX-DEMO-V2 as v2
 transaction_id | account_id |     note      | channel
 TX-DEMO-V1     | ACC-v1     | from a v1 app | web
 TX-DEMO-V2     | ACC-v2     | from a v2 app | mobile

▶ 6. Try v4-breaking ('amount' double -> string): refused, nothing changes
!! transactions-value: HTTP 409 Schema being registered is incompatible ... TYPE_MISMATCH ...
   reader type: STRING not compatible with writer type: DOUBLE ...
== v4-breaking REFUSED by Schema Registry; restoring the previous schemas/transactions-value.avsc
```

How the pieces do it:

- `scripts/evolve.sh <step>` copies `evolution/<step>.avsc` over `schemas/transactions-value.avsc` and
  re-runs init (same as saving the file with `docker compose watch` running). If the registry refuses
  it, the previous file is put back. `evolve.sh v1` "rolls back" Datagen to v1: no new version is
  registered (v1 already exists), and the v1 records still land in the table, using the column defaults.
- `scripts/produce-as.sh v1|v2|v3` plays an application compiled against that one version. It passes the
  exact schema to the serializer with `auto.register.schemas=false`, like the Datagen connector.
- To try your own change, edit `schemas/transactions-value.avsc` (or add `evolution/v5.avsc`), then use
  `scripts/check-compat.sh` for a dry run and `scripts/reinit.sh` / `scripts/evolve.sh v5` to apply.
  `produce.sh` always uses the *latest* schema id with a v1-shaped record, so it stops working once you
  add a field without updating its JSON. Use `produce-as.sh` instead.

### Breaking changes: a new topic instead of a new version

When a change really can't be compatible (a type change, a renamed key, a restructured record), don't
force it into the same subject by setting compatibility to `NONE`: every existing consumer and the
sink's table would break. The usual pattern is to **uplift the endpoint**:

1. Create a new topic + subject, e.g. `transactions.v2` / `transactions.v2-value`, with the new
   schema as its v1.
2. Producers write to the new topic, or write both topics during a migration window. Alternatively,
   one stream job (ksqlDB / Flink / Kafka Streams) reads the old topic, converts, and writes the new one.
3. Add a sink for the new topic into a new table (or a new column layout plus a backfill), and move
   consumers over one by one.
4. Retire the old topic once nothing reads it.

This project doesn't implement that step. The v4 refusal shows why you'd need it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `avro-init` exited 1 with HTTP 409 | The schema edit is incompatible, see [Schema evolution](#schema-evolution). `scripts/check-compat.sh` shows why |
| Datagen task `FAILED` with `Schema not found; error code: 40403` | The schema Datagen derives from `schema.string` isn't exactly a registered version, e.g. `enhanced.avro.schema.support` is off (enum became string), or the file changed without init re-running. Get the trace with `curl -s localhost:8083/connectors/datagen-transactions/status \| jq -r '.tasks[0].trace'` |
| Datagen task `FAILED` with `Not a valid schema field` | `use.latest.version=true` was added, and the latest version has fields Datagen's schema doesn't |
| Sink inserts fail after removing or renaming a field | The old column is `NOT NULL`. Only remove fields that are optional or have a default, or relax the column by hand |
| Random garbage values in the table | `arg.properties` were put on the field instead of inside its `type` object |
| `Unknown magic byte!` in a console consumer | Keys are plain strings. Add `--property key.deserializer=org.apache.kafka.common.serialization.StringDeserializer` (as `consume.sh` does) |
| Port already in use | Another project in this repo is running. Stop it first |

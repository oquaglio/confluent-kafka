# PostgreSQL → Debezium → Kafka → PostgreSQL (CDC)

A Confluent Kafka stack that copies every row change from one database to another with
**Change Data Capture (CDC)**. No application code is involved, only two Kafka Connect connectors:

- A **Debezium PostgreSQL source connector** reads the source database's write-ahead log and publishes
  every `INSERT`, `UPDATE` and `DELETE` on `customers` and `orders` as an event to a Kafka topic.
- A **Debezium JDBC sink connector** reads those topics and applies each change to a second PostgreSQL
  database. It creates the tables, upserts on the primary key, and deletes rows that were deleted.

```text
 source-db: shop          postgres-source            Kafka topics             postgres-sink          sink-db: warehouse
 public.customers ──WAL──▶ (Debezium CDC   ──▶  cdc.public.customers  ──▶  (Debezium JDBC   ──▶  public.customers
 public.orders    pgoutput  source)             cdc.public.orders          sink, upsert/       public.orders
                                                (Avro, schemas in          delete on id)
                                                 Schema Registry)
```

| Service | Container | Where |
|---|---|---|
| `source-db` | `source-db` | Source Postgres, `localhost:5432`, database `shop`, user/password `demo`/`demo` |
| `sink-db` | `sink-db` | Target Postgres, `localhost:5433`, database `warehouse`, user/password `warehouse`/`warehouse` |
| `kafka` | `kafka-broker` | `localhost:9092` from your machine, `kafka:29092` from containers |
| `schema-registry` | `schema-registry` | http://localhost:8081 |
| `connect` | `kafka-connect` | Connect worker with Debezium 3.7.1 plugins, REST API http://localhost:8083 |
| `connect-init` | `kafka-connect-init` | One-shot: registers the connectors in `connectors/`, then exits |
| `kafka-ui` | `kafka-ui` | http://localhost:8082 (topics, schemas, connectors) |
| `pgadmin` | `pgadmin` | http://localhost:5050, no login, both databases pre-registered |

## Quick start

```sh
scripts/up.sh          # build, start, wait for the snapshot, show source vs sink
scripts/change.sh      # make an INSERT, an UPDATE and a DELETE in the source
scripts/compare.sh     # show both tables in both databases (or: scripts/compare.sh orders)
```

Everything else:

```sh
scripts/status.sh                 # containers, connector state, replication slot, row counts
scripts/sql.sh source             # psql on the source (or: scripts/sql.sh source "SELECT ...")
scripts/sql.sh sink               # psql on the sink
scripts/watch-topic.sh orders     # raw Debezium events on cdc.public.orders (Ctrl+C to stop)
scripts/register-connectors.sh    # re-apply connectors/*.json after you edit them
scripts/down.sh                   # stop, data kept
scripts/down.sh -v                # stop AND delete all data (next up starts from scratch)
```

Or with plain Docker:

```sh
docker compose up -d --build      # connect-init registers the connectors automatically
docker logs kafka-connect-init    # shows RUNNING for each connector
docker compose down               # add -v to wipe data
```

The first `up` downloads the images and the Debezium plugins (internet needed, a minute or two).
After you edit `connect/Dockerfile`, `connectors/*.json`, `source-db/*` or the register script, start with
`--build` (`scripts/up.sh` always does). `source-db/init.sql` only runs on an empty volume, so after
changing it run `scripts/down.sh -v` first.

## How the automation works

`docker compose up` does the whole setup, in this order (enforced with `depends_on` + healthchecks):

1. **source-db** starts with `wal_level=logical`. On its first start, `source-db/init.sql` (baked into the
   image) creates the tables, seed rows, the `debezium` user and the `dbz_publication` publication.
2. **sink-db** starts empty. The sink connector creates its tables.
3. **kafka** and **schema-registry** start.
4. **connect** starts once all of the above are healthy. Its image (`connect/Dockerfile`) contains the
   Debezium plugins, the connector configs and the register script.
5. **connect-init** (same image) waits for the Connect REST API, then `PUT`s every `connectors/<name>.json`
   to `/connectors/<name>/config` and prints each connector's state. `PUT` is idempotent, so running it
   again just updates the configs.
6. The source connector takes an **initial snapshot** of both tables, then switches to **streaming** the
   WAL. The sink writes everything to `warehouse`.

Nothing is bind-mounted. Plugins, configs and the init SQL are copied into images at build time, so the
project also works when Docker runs in a different WSL2 distro.

## Concepts

### Change Data Capture with Debezium

Instead of polling tables (`SELECT ... WHERE updated_at > ?`), Debezium reads the database's own
transaction log. That way it sees every change, including deletes and intermediate updates, in commit
order, and adds almost no load to the database.

PostgreSQL pieces involved:

| Piece | What it is | Here |
|---|---|---|
| `wal_level=logical` | Makes the WAL carry enough information to decode row changes | `command:` of `source-db` |
| Logical decoding plugin | Turns WAL records into change messages | `pgoutput`, built into Postgres 10+ (`plugin.name`) |
| Publication | Which tables to send changes for | `dbz_publication`, created in `init.sql` |
| Replication slot | Remembers how far the consumer has read, so Postgres keeps the WAL it hasn't read yet | `debezium_shop` (`slot.name`), created by Debezium |
| Replication user | A user with the `REPLICATION` attribute, plus `SELECT` for the snapshot | `debezium`/`debezium` |

The `debezium` user doesn't own the tables, so it can't create the publication. That's why `init.sql`
creates it and the connector has `publication.autocreate.mode=disabled`. That's how you'd normally run
it in production: Debezium doesn't need superuser rights.

> **Watch the slot.** While a slot exists, Postgres keeps every WAL segment the slot hasn't confirmed.
> If the connector is stopped for a long time, the source disk fills up. `scripts/status.sh` shows
> `confirmed_flush_lsn` against `current_lsn`. If you delete the connector for good, also drop the slot:
> `scripts/sql.sh source "SELECT pg_drop_replication_slot('debezium_shop')"`.

### Snapshot, then streaming

With `snapshot.mode=initial`, on its first start the connector reads the existing rows (`"op":"r"`
events), then streams new changes from the slot. The position it has reached (the LSN) is stored in the
Connect offsets topic `_connect-offsets`. After a restart it resumes from there and doesn't snapshot again.

### The change event

Each topic is named `<topic.prefix>.<schema>.<table>`, here `cdc.public.orders`. The **key** is the
primary key, so all changes to one row land in the same partition, in order. The **value** is an envelope
(from `scripts/watch-topic.sh orders`):

```json
key:   {"id": 1}
value: {
  "before": null,
  "after":  {"id": 1, "customer_id": 1, "product": "Analytical Engine", "quantity": 1, "price": "...", ...},
  "source": {"connector": "postgresql", "db": "shop", "schema": "public", "table": "orders",
             "lsn": 26697488, "txId": 758, "snapshot": "first_in_data_collection", ...},
  "op": "r",
  "ts_ms": 1795663798008
}
```

| `op` | Meaning | `before` / `after` |
|---|---|---|
| `r` | Read during the snapshot | `null` / row |
| `c` | Insert | `null` / new row |
| `u` | Update | `null`\* / new row |
| `d` | Delete | key columns only\* / `null`, then a **tombstone** (same key, `null` value) so log compaction can drop the key |

\* With the default `REPLICA IDENTITY`, Postgres doesn't log the old row. Run
`ALTER TABLE orders REPLICA IDENTITY FULL` to get the full old row in `before` (at the cost of more WAL).

`price` looks like garbage in the console because `NUMERIC` is sent as the Connect `Decimal` type (exact
bytes + scale). The sink turns it back into `numeric(10,2)`. Set `decimal.handling.mode=double` or `string`
on the source if your consumers can't read that type.

### Avro and Schema Registry

The worker uses `AvroConverter` for keys and values. Debezium derives a schema from each table, registers
it in Schema Registry (subjects `cdc.public.orders-key` / `-value`) and sends only a schema id with each
message. The sink needs those schemas to create tables with the right column types. When you
`ALTER TABLE` the source, a new schema version is registered, and with `schema.evolution=basic` the sink
adds the column to the target table:

```sh
scripts/sql.sh source "ALTER TABLE customers ADD COLUMN phone TEXT; UPDATE customers SET phone='555' WHERE id=1"
scripts/compare.sh customers
```

### The sink

`connectors/postgres-sink.json` uses the **Debezium JDBC sink**, which reads the Debezium envelope
directly. The Confluent JDBC sink would need an `ExtractNewRecordState` transform first and has no
built-in delete handling for Debezium events.

| Setting | What it does |
|---|---|
| `topics.regex: cdc\.public\..*` | Consume every CDC topic, including tables you add to the publication later |
| `transforms.route` (`RegexRouter`) | Rename `cdc.public.orders` to `orders`, which becomes the target table name |
| `insert.mode: upsert`, `primary.key.mode: record_key` | `INSERT ... ON CONFLICT (id) DO UPDATE`. Replays don't create duplicates |
| `delete.enabled: true` | A `d` event deletes the row. Tombstones are ignored |
| `schema.evolution: basic` | Create missing tables and add missing columns |

The sink gets eventually consistent copies of the tables: columns and primary keys, but not foreign
keys, defaults, indexes or other constraints.

## Things to try

- **Pipeline outage.** `docker stop kafka-connect`, run `scripts/change.sh` a few times, then
  `docker start kafka-connect`. Nothing is lost: the slot kept the WAL, and the source resumes from its
  stored LSN. While Connect is down, `scripts/status.sh` shows the slot as `active = f`.
- **Add a table.** Create it in the source, then
  `ALTER PUBLICATION dbz_publication ADD TABLE <t>; GRANT SELECT ON <t> TO debezium;`, and add
  `public.<t>` to `table.include.list` in `connectors/postgres-source.json` and run
  `scripts/register-connectors.sh`. The sink picks the new topic up through `topics.regex`.
  Changes made from then on are copied. To copy existing rows too, trigger an incremental snapshot
  (this needs a signalling table; see the Debezium docs).
- **Look at it in a UI.** Kafka UI shows the topics, the registered schemas and both connectors. pgAdmin
  has both databases connected.

## Files

```text
docker-compose.yml                all services, in dependency order
source-db/Dockerfile, init.sql    Postgres 17 + demo schema, seed rows, debezium user, publication
connect/Dockerfile                cp-kafka-connect 8.1.0 + Debezium Postgres source + JDBC sink 3.7.1,
                                  with connectors/ and the register script copied in
connectors/postgres-source.json   CDC source connector config (file name = connector name)
connectors/postgres-sink.json     JDBC sink connector config
scripts/register-connectors.sh    PUTs every connectors/*.json to the Connect REST API
scripts/*.sh                      up / down / status / change / compare / sql / watch-topic helpers
```

## Troubleshooting

| Symptom | Check |
|---|---|
| A connector is `FAILED` | `curl -s localhost:8083/connectors/<name>/status` has the stack trace; `docker logs kafka-connect` |
| Nothing reaches the sink | `scripts/status.sh`: is the slot `active`? `scripts/watch-topic.sh orders`: are events arriving? |
| `init.sql` changes have no effect | It only runs on an empty volume: `scripts/down.sh -v`, then `scripts/up.sh` |
| Port already in use | Another stack in this repo uses the same host ports and container names. Stop it first |

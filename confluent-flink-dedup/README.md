# Flink SQL Dedup PoC: Kafka → Flink → PostgreSQL

A Python producer sends JSON sensor readings to the Kafka topic `sensor-data`. A Flink SQL job
deduplicates them on `(device_id, tag, timestamp)` and upserts the result into the Postgres table
`sensor_readings`.

```text
data_generator.py ──▶ topic sensor-data ──▶ Flink SQL job ──────────────────▶ Postgres flink_demo
(kafka-python,        (JSON, auto-created)   sensor_source (Kafka, JSON)        .sensor_readings
 localhost:9092)                              ROW_NUMBER() dedup                 PK (device_id, tag, timestamp)
                                              sensor_sink (JDBC, upsert)
```

The Kafka side is Confluent's `cp-all-in-one` 7.9.0 compose
([quickstart](https://docs.confluent.io/platform/current/get-started/platform-quickstart.html)),
plus Flink 1.19.1 (Confluent demo images with the JDBC connector added) and Postgres 16.

| Service | Container | Where |
|---|---|---|
| `broker` | `broker` | `localhost:9092` from your machine, `broker:29092` from containers |
| `flink-jobmanager` | `flink-jobmanager` | Flink UI http://localhost:9081 (not 8081, which Schema Registry uses) |
| `flink-taskmanager` | `flink-taskmanager` | 10 task slots |
| `flink-sql-client` | `flink-sql-client` | `docker exec` into it to run SQL. `./flink-sql` is mounted at `/opt/flink-sql` |
| `postgres` | `postgres` | `localhost:5433`, database `flink_demo`, user/password `flink_user`/`flink_pass` |
| `control-center` | `control-center` | http://localhost:9021 |
| `schema-registry`, `connect`, `ksqldb-*`, `rest-proxy`, `ksql-datagen` | same | Come with cp-all-in-one. The pipeline doesn't use them |

The host ports overlap with the other Kafka projects in this repo (9092, 8081–8083), so run only one
of them at a time.

## Files

```text
docker-compose.yml               cp-all-in-one 7.9.0 + Flink 1.19.1 + Postgres
Dockerfile.flink-cnf             jobmanager/taskmanager image: cnfldemos/flink-kafka + jars/*.jar in /opt/flink/lib
Dockerfile.sql-client            SQL client image: cnfldemos/flink-sql-client-kafka + jars/*.jar in /opt/flink/lib
init.sql                         Postgres tables sensor_readings and sensor_duplicates (runs on first start)
flink-sql/flink_sql_source_sink.sql  DDL: sensor_source (Kafka) and sensor_sink (JDBC → sensor_readings)
flink-sql/flink_sql_dedup_job.sql    INSERT INTO sensor_sink ... ROW_NUMBER() dedup
data-generator/data_generator.py     random readings, as fast as it can send, until Ctrl+C
jars/                            connector jars (gitignored, download them below)
```

## Quick start

### 1. Download the connector jars

The jars have to match Flink 1.19 and end up in `/opt/flink/lib`, which is where the classloader
looks. The Dockerfiles copy `jars/*.jar` into that directory, so download the jars **before** you
build. If `jars/` is empty, the build fails.

```sh
wget -P jars https://repo1.maven.org/maven2/org/apache/flink/flink-connector-jdbc/3.2.0-1.19/flink-connector-jdbc-3.2.0-1.19.jar
wget -P jars https://jdbc.postgresql.org/download/postgresql-42.7.3.jar
```

### 2. Build the Flink images and start the stack

```sh
docker build -f Dockerfile.flink-cnf   -t flink-cnf-with-jdbc:1.19.1 .
docker build -f Dockerfile.sql-client  -t flink-sql-client-with-jars:latest .
docker compose up -d
```

Check that it came up:

```sh
docker compose ps
docker exec postgres psql -U flink_user -d flink_demo -c '\d sensor_readings'
docker exec flink-jobmanager ls /opt/flink/lib | grep -E 'jdbc|postgres'
```

The classpath is also listed under http://localhost:9081/#/job-manager/config.

### 3. Submit the Flink job

```sh
docker exec -it flink-sql-client /opt/flink/bin/sql-client.sh \
  -i /opt/flink-sql/flink_sql_source_sink.sql \
  -f /opt/flink-sql/flink_sql_dedup_job.sql
```

`-i` creates the tables in the session and `-f` submits the `INSERT`. The client exits after that,
but the job keeps running on the cluster as a streaming job until you cancel it. You can submit it
before or after you start producing, because the source reads from `earliest-offset`. The job shows
up at http://localhost:9081/#/overview.

The `sensor-data` topic is auto-created on the first produce. If the job starts first, the topic is
created when the source subscribes. To create it explicitly:

```sh
docker exec broker kafka-topics --bootstrap-server broker:29092 --create \
  --topic sensor-data --partitions 1 --replication-factor 1
```

### 4. Produce data

```sh
uv run --with-requirements data-generator/requirements.txt data-generator/data_generator.py
```

The generator only needs `kafka-python`. It sends to `localhost:9092` in a tight loop with no
sleep, so stop it with Ctrl+C after a few seconds.

### 5. Look at the results

```sh
docker exec postgres psql -U flink_user -d flink_demo -c 'SELECT count(*) FROM sensor_readings'
docker exec postgres psql -U flink_user -d flink_demo \
  -c 'SELECT * FROM sensor_readings ORDER BY "timestamp" DESC LIMIT 10'
```

Read the raw topic:

```sh
docker exec broker kafka-console-consumer --bootstrap-server broker:29092 \
  --topic sensor-data --from-beginning --max-messages 10
```

## How the dedup works

**Source.** `sensor_source` reads JSON from `sensor-data`. The producer's `timestamp` is an ISO
string with no timezone (`2026-11-27T10:15:30.123`). The source turns it into the event-time column
`event_time` (`CAST(REPLACE(timestamp, 'T', ' ') AS TIMESTAMP(3))`) and sets a watermark 5 seconds
behind it. Records that don't parse are skipped (`ignore-parse-errors`).

**Dedup.** The job is Flink's
[deduplication pattern](https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/queries/deduplication/):

```sql
ROW_NUMBER() OVER (PARTITION BY device_id, tag, event_time ORDER BY event_time DESC) ... WHERE rownum = 1
```

Flink sees `ORDER BY <time attribute>` with `rownum = 1` and plans a dedicated Deduplicate operator,
not a general Top-N. `DESC` means **keep the last row** per key: a later duplicate replaces the
earlier one, so the job emits updates, not just inserts.

**Sink.** `sensor_sink` uses the JDBC connector and declares `PRIMARY KEY (device_id, tag, timestamp)`,
so it writes in upsert mode (`INSERT ... ON CONFLICT DO UPDATE`). It flushes every 100 rows or every
second. The Postgres table has the same primary key, so duplicates collapse to one row there too.

**What counts as a duplicate.** Two readings are duplicates when device, tag *and* timestamp are
equal. The result is one row per reading, not the "latest value per device/tag". The generator sends
3 devices × 3 tags with millisecond timestamps in a tight loop, so duplicates only come from
collisions within the same millisecond. Those collisions have different `value`s, and the last one
to arrive wins.

### Checking duplicates in Flink SQL

Start an interactive client with the tables defined:

```sh
docker exec -it flink-sql-client /opt/flink/bin/sql-client.sh -i /opt/flink-sql/flink_sql_source_sink.sql
```

```sql
-- total records on the topic
SELECT COUNT(*) AS total_records FROM sensor_source;

-- duplicated keys
SELECT device_id, tag, `timestamp`, COUNT(*) AS cnt
FROM sensor_source
GROUP BY device_id, tag, `timestamp`
HAVING COUNT(*) > 1;

-- number of rows the dedup drops (total minus distinct keys)
SELECT SUM(cnt - 1) AS total_duplicate_rows
FROM (
  SELECT COUNT(*) AS cnt FROM sensor_source
  GROUP BY device_id, tag, `timestamp`
  HAVING COUNT(*) > 1
) t;
```

These are unbounded streaming queries, and the result view keeps updating until you quit (`Q`).
`total_records - total_duplicate_rows` should match `count(*)` in `sensor_readings`.

## Caveats and next steps

- **State grows without limit.** Every distinct `(device_id, tag, timestamp)` stays in dedup state
  forever. For anything long-running, set `SET 'table.exec.state.ttl' = '1 h';` (or similar) before
  the `INSERT`.
- **No checkpointing is configured.** The JDBC sink still flushes on its 1 s interval, but if the job
  restarts it re-reads from `earliest-offset`. The upsert key keeps that idempotent. Turn on
  `execution.checkpointing.interval` for real fault tolerance.
- **`sensor_duplicates` isn't populated.** `init.sql` creates the table, but no job writes to it yet.
  To capture dropped rows, add a second JDBC sink and an `INSERT` with `WHERE rownum > 1`
  (append-only, so keep-first `ORDER BY event_time ASC` fits better there).
- **Keep-first would be cheaper.** `ORDER BY event_time ASC` emits each key once (append-only) instead
  of retract/update pairs. Use it if the first reading should win.
- **Rerunning the DDL file in the same session fails.** It drops `sensor_sink` but not
  `sensor_source`. Each new `sql-client.sh` session starts with an empty in-memory catalog, so
  running the commands above again is fine.
- The `./jars` → `/opt/flink/usrlib` mounts aren't needed, because the jars are baked into the images.
  They're left over from an earlier "copy at startup" approach (commented out in the compose file).
- The credentials (`flink_user`/`flink_pass`) are hardcoded in `docker-compose.yml` and the DDL, and
  all ports bind to every interface. That's fine for a local PoC. Don't reuse it as-is anywhere
  else.

## Cleanup

```sh
docker compose down -v      # stop and delete the Postgres volume (Kafka data is in-container and goes with it)
```

To cancel just the Flink job, use the Flink UI, or run
`docker exec flink-jobmanager flink list -m localhost:9081` and then `flink cancel -m localhost:9081 <job-id>`.

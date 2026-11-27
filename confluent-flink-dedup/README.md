# Flink SQL Dedup PoC: Kafka → Flink → PostgreSQL

A Python producer sends JSON sensor readings to the Kafka topic `sensor-data`. A Flink SQL job
deduplicates them on `(device_id, tag, timestamp)` and upserts the result into the Postgres table
`sensor_readings`.

```text
producer ──▶ topic sensor-data ──▶ Flink SQL job "sensor-dedup" ─────────▶ Postgres flink_demo
(container,  (JSON, 1 partition)    sensor_source (Kafka, JSON)             .sensor_readings
 kafka-python)                      ROW_NUMBER() dedup                      PK (device_id, tag, timestamp)
                                    sensor_sink (JDBC, upsert)
```

`just up` starts everything, including the Flink job. No manual setup is needed:

- **Connector jars:** `flink/Dockerfile` downloads the JDBC connector and Postgres driver from Maven
  Central at build time and checks them against pinned SHA-256s.
- **Postgres tables:** `postgres/Dockerfile` bakes `init.sql` into the image, and it runs on first
  start.
- **Kafka topic:** the one-shot `kafka-init` container creates `sensor-data` once the broker
  answers. The Flink Kafka source fails at startup with `UnknownTopicOrPartitionException` if the
  topic doesn't exist, so the topic has to come first.
- **Flink job:** the one-shot `flink-job-submit` container waits for the JobManager to be healthy (a
  TaskManager has registered), for Postgres, and for `kafka-init`. It then submits the job, and checks through the REST
  API that the job is RUNNING. If the job is already running, it does nothing.
- **Producer:** a container that `just produce` runs, so the host doesn't need Python.

Nothing is bind-mounted. SQL files and scripts are copied into the images, so the project also
works when the Docker daemon runs in another WSL2 distro. **After editing `flink-sql/` or
`scripts/`, run `just up` again** to rebuild.

## Versions

| Component | Version | Notes |
|---|---|---|
| Confluent Platform (`cp-server`, Schema Registry, ksqlDB server, REST Proxy) | 8.4.1 | Based on Confluent's [`cp-all-in-one`](https://github.com/confluentinc/cp-all-in-one) 8.4.1, without Control Center |
| `cp-ksqldb-cli`, `ksqldb-examples` | 8.0.9 | Newest tags published for these images |
| `cnfldemos/cp-server-connect-datagen` | 0.6.7-8.0.0 | Newest tag |
| Flink | 2.2.1 (official `flink:2.2.1-scala_2.12-java17` image) | 2.3 is out, but the JDBC connector only has builds up to Flink 2.2 |
| `flink-sql-connector-kafka` | 5.1.0-2.2 | |
| `flink-connector-jdbc-core` + `-postgres` | 4.1.0-2.2 | |
| `openlineage-java` | 1.32.0 | Required by JDBC 4.x, matches its pom |
| Postgres JDBC driver | 42.7.15 | |
| Postgres | 19 | |
| Python / uv / kafka-python | 3.15 / 0.13.10 / 3.0.13 | Producer image |

Control Center (legacy) is only published up to 7.9.x and doesn't support CP 8. Its replacement,
Control Center next-gen, needs Prometheus and Alertmanager as well, so this project has no Control
Center. Use the Flink UI and the `just` recipes instead.

Connector versions have to match the Flink minor (the `-2.2` suffix). To bump Flink, check that
both connectors have a build for the new minor first, then update the URLs and checksums in
`flink/Dockerfile` together.

| Service | Container | Where |
|---|---|---|
| `broker` | `broker` | `localhost:9092` from your machine, `broker:29092` from containers |
| `flink-jobmanager` | `flink-jobmanager` | Flink UI and REST http://localhost:9081 (not 8081, which Schema Registry uses) |
| `schema-registry` | `schema-registry` | http://localhost:8081 |
| `rest-proxy` | `rest-proxy` | http://localhost:8082 |
| `connect` | `connect` | http://localhost:8083 |
| `ksqldb-server` | `ksqldb-server` | http://localhost:8088 |
| `flink-taskmanager` | `flink-taskmanager` | 10 task slots |
| `flink-sql-client` | `flink-sql-client` | Idle (`sleep infinity`), `just sql` execs into it. SQL files are at `/opt/flink-sql` |
| `kafka-init` | `kafka-init` | One-shot: creates topic `sensor-data`, then exits |
| `flink-job-submit` | `flink-job-submit` | One-shot: submits the job, then exits |
| `producer` | (`compose run`) | Profile `producer`, so `up` doesn't start it. `just produce` runs it |
| `postgres` | `postgres` | `localhost:5433`, database `flink_demo`, user/password `flink_user`/`flink_pass` |
| `ksqldb-cli`, `ksql-datagen` | same | No ports. Use `docker exec` |

Schema Registry, REST Proxy, Connect and ksqlDB come with cp-all-in-one. The pipeline doesn't use
them, but they're there to explore. See [Endpoints](#endpoints).

The host ports overlap with the other Kafka projects in this repo (9092, 8081–8083), so run only one
of them at a time.

## Endpoints

### Web consoles

| Console | Link | What it's for |
|---|---|---|
| Flink Web UI: overview | http://localhost:9081/#/overview | Running and finished jobs, slots, TaskManagers. The `sensor-dedup` job shows up here |
| Flink: running jobs | http://localhost:9081/#/job/running | Click the job to see its graph (Source → Deduplicate → Sink), records in/out per operator, backpressure, exceptions |
| Flink: JobManager config | http://localhost:9081/#/job-manager/config | The effective config, including the `FLINK_PROPERTIES` from compose |
| Flink: JobManager logs | http://localhost:9081/#/job-manager/logs | Startup and job-submission errors |
| Flink: TaskManagers | http://localhost:9081/#/task-manager | Registered TaskManagers, slots, memory, and per-TM logs and stdout |

There's no Kafka web console. Control Center was dropped with the move to CP 8 (see
[Versions](#versions)). Use `just consume`, the REST Proxy below, or the Flink UI.

### HTTP APIs

All of these answer plain `GET`s, so you can open them in a browser or use `curl -s <url> | jq`.

| Service | Link | What it returns |
|---|---|---|
| Flink REST | http://localhost:9081/overview | Cluster summary: TaskManagers, slots, jobs by state. The JobManager healthcheck reads this |
| | http://localhost:9081/jobs/overview | Every job with its name and state. `submit-job.sh` polls this for `sensor-dedup` / `RUNNING` |
| | http://localhost:9081/taskmanagers | TaskManager details |
| | http://localhost:9081/config | Flink version and UI settings |
| REST Proxy (v3) | http://localhost:8082/v3/clusters | The Kafka cluster and its id. Follow the `topics` link for topics, partitions and configs |
| | http://localhost:8082/topics | Topic names (v2 API). `sensor-data` should be listed |
| Schema Registry | http://localhost:8081/subjects | Registered subjects. Empty here, because the pipeline uses plain JSON, not Avro |
| | http://localhost:8081/config | Global compatibility level |
| Kafka Connect | http://localhost:8083/ | Connect worker version and Kafka cluster id |
| | http://localhost:8083/connectors | Deployed connectors (none in this project) |
| | http://localhost:8083/connector-plugins | Installed plugins, including Datagen from the `cp-server-connect-datagen` image |
| ksqlDB | http://localhost:8088/info | Server version and status. Connect with the CLI: `docker exec -it ksqldb-cli ksql http://ksqldb-server:8088` |
| | http://localhost:8088/healthcheck | Health of the server, its metastore and Kafka |

### Non-HTTP ports

| Port | What it is |
|---|---|
| `localhost:9092` | Kafka bootstrap for clients on the host (`just produce-local`). Containers use `broker:29092` |
| `localhost:9101` | Broker JMX (for example `jconsole localhost:9101`) |
| `localhost:5433` | Postgres. `psql -h localhost -p 5433 -U flink_user -d flink_demo` (password `flink_pass`), or `just count` / `just rows` |

## Files

```text
docker-compose.yml                   cp-all-in-one 8.4.1 + Flink 2.2.1 + Postgres 19 + kafka-init + job-submit + producer
justfile                             every command as a recipe
flink/Dockerfile                     one image for JM, TM, SQL client, job-submit: flink:2.2.1 + jars + SQL + script
scripts/submit-job.sh                flink-job-submit entrypoint: skip if running, submit, verify RUNNING
flink-sql/flink_sql_source_sink.sql  DDL: sensor_source (Kafka) and sensor_sink (JDBC → sensor_readings)
flink-sql/flink_sql_dedup_job.sql    INSERT INTO sensor_sink ... ROW_NUMBER() dedup
postgres/Dockerfile, init.sql        postgres:19 + tables sensor_readings and sensor_duplicates
data-generator/                      producer: data_generator.py, requirements.txt, Dockerfile (python + uv)
```

## Quick start

Needs `docker` and [`just`](https://github.com/casey/just). Internet access is needed on the first
build.

```sh
just up           # build, start, wait until the Flink job is RUNNING
just produce      # send readings for 5 s (`just produce 30`, `just produce 0 10` = until Ctrl+C at 10/s)
just count        # rows in Postgres sensor_readings
just rows         # latest 10 rows (`just rows 50`)
just clean        # stop and delete volumes
```

`just` on its own lists every recipe:

| Recipe | Does |
|---|---|
| `up` | `docker compose up -d --build`, then waits for `flink-job-submit` and prints its result |
| `build` | Builds all images, including the producer |
| `status` | `compose ps`, running Flink jobs, `\d sensor_readings` |
| `submit` | Runs `flink-job-submit` again (e.g. after `just cancel`). A no-op if the job is running |
| `sql` | Interactive Flink SQL client with `sensor_source`/`sensor_sink` already defined |
| `produce [secs] [rate]` | Producer container for `secs` (default 5, `0` = until Ctrl+C) at `rate` msgs/s (`0` = max) |
| `produce-local [secs] [rate]` | The same on the host with `uv run`, against `localhost:9092` |
| `count`, `rows [n]` | Query Postgres `sensor_readings` |
| `consume [n]` | First `n` raw messages on `sensor-data` |
| `jobs`, `cancel <id>` | List or cancel Flink jobs |
| `logs [svc]` | Follow logs for all services or one |
| `down` / `clean` | Stop the stack, keeping / deleting the Postgres volume |

The job shows up at http://localhost:9081/#/overview, and the classpath under
http://localhost:9081/#/job-manager/config.

### How the automation works

**Jars.** They have to match Flink 2.2 and end up in `/opt/flink/lib`, which is where the
classloader looks. `flink/Dockerfile` adds the Kafka SQL connector, JDBC core, the JDBC Postgres
dialect, `openlineage-java` and the Postgres driver, each with `ADD --checksum=sha256:...`. The
checksums were checked against the `.sha1` files Maven Central publishes. Leave out
`openlineage-java` and planning the JDBC sink fails with
`ClassNotFoundException: io.openlineage.client.utils.jdbc.JdbcExtractor`.

**Flink config.** All four Flink containers share `FLINK_PROPERTIES` (an anchor in
`docker-compose.yml`), which the image entrypoint writes into `conf/config.yaml`. It also does this
for pass-through commands, which is why `flink-job-submit` sets `command:` and not `entrypoint:`.
Overriding the entrypoint skips the config step, and the SQL client then can't find the JobManager.

**Ordering.** The JobManager's healthcheck passes once `/overview` reports at least one TaskManager,
and Postgres's once `pg_isready` answers over TCP (that only happens after `init.sql` has run).
`kafka-init` retries `kafka-topics --create --if-not-exists` until the broker accepts it.
`flink-job-submit` has `depends_on` on all three: `service_healthy` for the JobManager and Postgres,
`service_completed_successfully` for `kafka-init`.

**Submitting.** `scripts/submit-job.sh` runs
`sql-client.sh -i <SET pipeline.name + flink_sql_source_sink.sql> -f flink_sql_dedup_job.sql`.
`sql-client` exits 0 even when a statement fails, so the script then polls `/jobs/overview` for up to
60 s, until the job named `sensor-dedup` is RUNNING. If it isn't, the script exits 1, and so does
`just up`. The source reads from `earliest-offset`, so it doesn't matter whether you produce before or
after the job starts.

**Producer.** `data_generator.py` reads `BOOTSTRAP_SERVERS` (default `localhost:9092`, the
container uses `broker:29092`), `TOPIC`, `RATE` and `DURATION`. On SIGINT/SIGTERM it flushes
before exiting.

### Without just

```sh
docker compose up -d --build                  # flink-job-submit submits the job
docker logs flink-job-submit | grep '^Job'    # "Job 'sensor-dedup' is RUNNING"
docker compose run --rm -e DURATION=5 producer
docker exec postgres psql -U flink_user -d flink_demo -c 'SELECT count(*) FROM sensor_readings'
docker compose --profile producer down -v
```

## How the dedup works

**Source.** `sensor_source` reads JSON from `sensor-data`. The producer's `timestamp` is an ISO
string with no timezone (`2026-11-27T10:15:30.123`). The source turns it into the event-time column
`event_time` (`CAST(REPLACE(timestamp, 'T', ' ') AS TIMESTAMP(3))`) and sets a watermark 5 seconds
behind it. Records that don't parse are skipped (`ignore-parse-errors`).

**Dedup.** The job is Flink's
[deduplication pattern](https://nightlies.apache.org/flink/flink-docs-release-2.2/docs/dev/table/sql/queries/deduplication/):

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

Start an interactive client with the tables defined (`just sql`), then:

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
  forever. For anything long-running, add `SET 'table.exec.state.ttl' = '1 h';` (or similar) next to the
  `pipeline.name` line in `scripts/submit-job.sh`.
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
- The credentials (`flink_user`/`flink_pass`) are hardcoded in `docker-compose.yml` and the DDL, and
  all ports bind to every interface. That's fine for a local PoC. Don't reuse it as-is anywhere
  else.

## Upgrading an existing checkout

The Postgres volume moved from 16 to 19, and the 18+ image keeps data under
`/var/lib/postgresql/<major>/docker`, so the volume is now mounted at `/var/lib/postgresql`. An old
volume won't work. Run `just clean` (it only holds demo data) and then `just up`. The Flink images
are renamed (`flink-dedup:2.2.1`), so `docker image rm flink-cnf-with-jdbc:1.19.1
flink-sql-client-with-jars:latest` gets rid of the old ones.

## Cleanup

```sh
just down         # stop, keep the Postgres volume
just clean        # stop and delete volumes (Kafka data is in-container and goes either way)
just jobs         # or cancel just the Flink job: find its id,
just cancel <id>  # then cancel it (also possible from the Flink UI). `just submit` starts it again
```

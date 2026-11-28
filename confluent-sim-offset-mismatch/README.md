# confluent-sim-offset-mismatch

Reproduces a sink connector losing its place when it's moved to another Kafka cluster, shows how
to spot it, and how to recover.

**The incident:** a fully-managed Snowflake Sink connector (Snowpipe Streaming) in Confluent Cloud
was moved from one Kafka cluster to another. It kept running, reported no errors, and stopped
delivering records to Snowflake.

**The cause:** the new cluster's topic has different offsets, and the connector's "how far have I
got" state still describes the old cluster. Snowflake isn't available locally, so Postgres plays the
target and a small Python service copies the Snowflake connector's offset handling.

| In this project | In the incident |
| --- | --- |
| `kafka-a` / `kafka-b` | old / new Confluent Cloud cluster |
| `connect-a` / `connect-b` + JDBC sink | a regular (non-Snowflake) sink connector, re-created on the new cluster |
| `sf-emulator-a` / `sf-emulator-b` | the Snowflake connector before and after the move (same connector name) |
| `postgres` | the Snowflake account |
| `orders_sf` table, `kafka_*` columns | the target table and its `RECORD_METADATA` |
| `sf_channels` table | Snowflake channels (`SHOW CHANNELS`) and their offset tokens |
| `sf_update_channel_offset_token()` | `SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN` |

## Two places a sink keeps its progress

```
                       Kafka cluster                               target
                ┌──────────────────────────┐            ┌───────────────────────┐
  producers ──▶ │ orders  0 1 2 ... 999    │──records──▶│ orders_*              │
                │                          │            │                       │
  (1) regular   │ __consumer_offsets:      │            │                       │
      sink      │   connect-<name> → 1000  │            │                       │
                │                          │            │                       │
  (2) Snowflake │ (committed too, but      │            │ channel <NAME>_<TOPIC>_<P>
      sink      │  only as a copy)         │◀──seek ────│   offset_token = 999  │
                └──────────────────────────┘ token + 1  └───────────────────────┘
```

1. **Kafka consumer group offsets.** A regular Connect sink commits offsets to the
   `connect-<connector-name>` group, which lives *on the cluster*. A new cluster has no such group,
   so the connector starts wherever `auto.offset.reset` says: `latest` skips everything already on
   the new topic, `earliest` replays it all. The connector may say RUNNING with lag 0 and still have
   a gap behind it.
2. **Offsets stored in the target.** The Snowflake connector (Snowpipe Streaming) stores an
   **offset token per channel**, with one channel per topic partition, inside Snowflake. When a
   channel opens, the connector moves the Kafka consumer to `token + 1`, *overriding* the consumer
   group offset. It only falls back to the Kafka offset when the token is NULL (or reset to `-1`).
   The channel name is made from connector name, topic and partition. It doesn't include the
   cluster, so a re-created connector reuses the old channels. On the new cluster the topic
   restarts at offset 0, far below the token. The requested offset doesn't exist, Kafka resets the
   position, and every record with `offset <= token` counts as already ingested. Nothing errors, and
   resetting the consumer group doesn't help.

## Run it

Needs `docker` (with compose), `just`, `curl`, `jq` and `envsubst` on the host.

```bash
just up        # build + start everything, create the topics (copies .env.example to .env)
just s1        # scenario 1: reset, break, detect, fix; exits 1 if the gap isn't closed
just s2        # scenario 2: the same
just all       # both
just down      # or `just clean` to drop the volumes as well
```

Each scenario's steps can also be run one at a time (`just s1-break`, `just s1-detect`, `just s1-fix`,
...) after a `just reset`. Inspection recipes, which work at any point:

| Recipe | Shows |
| --- | --- |
| `just count` | rows per table per source cluster |
| `just gaps` | missing and duplicate `seq`s compared with everything produced |
| `just offsets` | log-start/log-end offsets and both consumer groups on both clusters, plus `sf_channels` |
| `just produce b 100` | 100 more records to cluster B |
| `just logs sf-emulator-b` | the emulator's view (seeks, offset resets, skipped records) |
| `just psql` | a shell on the target database |

Records carry a global, gap-free `seq` (key and value), a producer timestamp `ts_ms`, and the
`cluster` they were produced to. That makes every gap and duplicate visible with plain SQL.

## Scenario 1: consumer group offsets lost (JDBC sink)

`just s1-break`

1. The JDBC sink on `connect-a` loads 500 records from cluster A
2. The connector is deleted. Producers cut over to cluster B and send 200 records
3. The connector is re-created on `connect-b` with `consumer.override.auto.offset.reset=latest`. Its
   group `connect-orders-jdbc` is new on cluster B, so it starts at offset 200
4. 50 more records arrive and load normally

`just s1-detect`: the connector is `RUNNING`, the group shows `LAG 0`, and `seq 501..700` is
missing. The records are still on cluster B; nothing is lost yet.

`just s1-fix [datetime|earliest]`: stop the connector (`PUT /connectors/orders-jdbc/stop`), move its
offsets, resume (`PUT .../resume`).

- `datetime` (default): takes `max(ts_ms)` of the rows loaded from the old cluster, finds the first
  offset on B after it with `kafka-get-offsets --time`, and sets it with
  `PATCH /connectors/orders-jdbc/offsets` (KIP-875, Connect 3.6+). This replays only the gap
- `earliest`: `kafka-consumer-groups --reset-offsets --to-earliest` on cluster B. This replays
  everything on B. That's harmless here because the sink upserts on `seq`. With `insert.mode=insert`
  it would duplicate rows

The group can only be reset while it has no members, which is why the connector is *stopped*
rather than paused. A paused task keeps its consumer in the group.

## Scenario 2: offset token ahead of the new cluster (Snowflake-like)

`just s2-break`

1. The emulator on cluster A loads 1000 records. The channel `ORDERS_SF_ORDERS_0` token ends at 999
2. The emulator stops. Producers cut over to cluster B and send 300 records (offsets 0-299)
3. The emulator starts on cluster B with the same connector name, so it opens the same channel
4. 50 more records arrive, and they are skipped too

`just s2-detect` shows the signs to look for:

- the emulator is running and logs no errors
- channel token `999` is at or above cluster B's log-end offset `350`. Records stay "already
  ingested" until B passes offset 999
- the consumer group's committed offset (1000) is **past the log end**, so lag is **negative**
  (`-650`). Lag alerts that only fire on positive lag don't see this
- the log shows `Offset out of range` and reset to BEGINNING, followed by `SKIPPED n as already ingested`

`just s2-fix`

1. **Wrong fix:** reset the consumer group to earliest. On restart the channel token wins again.
   0 rows
2. **Right fix:**
   1. stop the connector
   2. set the channel token to `-1` (`sf_update_channel_offset_token`, standing in for
      `SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN`), so the Kafka offset becomes the
      source of truth
   3. set the consumer group on B to the first offset after the last loaded `ts_ms`
   4. start the connector. The 350 missing rows load, and new traffic flows again
3. Duplicates check. `orders_sf` has no primary key, because Snowflake doesn't enforce one. A replay
   that starts too early leaves duplicates, which `just dedupe` removes. The Snowflake version is in
   [scripts/dedupe.sh](scripts/dedupe.sh)

Why not just set the token to cluster B's starting offset minus 1? That works too. But `-1`
followed by an explicit Kafka offset reset is the documented one-off procedure. It also keeps the
Kafka offset, which you can inspect and change with the usual tools, as the single source of truth
for where the replay starts.

## Runbook: the same thing for real

**Detect** (Confluent Cloud + Snowflake):

- Compare the newest row in the target (e.g. `RECORD_METADATA:CreateTime`) with the newest record on
  the topic. A connector that's running while the target has stopped growing is the main sign
- `SHOW CHANNELS IN TABLE <db>.<schema>.<table>;` and compare each channel's `offset_token` with the
  partition's log-end offset on the new cluster. A token >= the log-end offset means records are
  being skipped
- Consumer group lag for the connector's group (`connect-lcc-...`). Negative or
  suspiciously-zero lag right after a move is a warning sign

**Recover**, in order:

1. Pause or stop the connector
2. Decide where the replay should start on the new cluster. Use the timestamp of the last row in
   Snowflake, or the cutover time, and go back a little if unsure. Duplicates can be cleaned up;
   records that were never replayed can't be recovered
3. For each channel:
   `SELECT SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN('<db>.<schema>.<table>', '<channel>', '-1');`
   Only do this while the connector is stopped. Check the result with `SHOW CHANNELS`
4. Set the connector's Kafka offsets on the new cluster. For a fully-managed connector, use the
   Confluent Cloud Connect API (`POST .../connectors/<name>/offsets/request` with a `PATCH` body) or
   `confluent connect offset`. For self-managed Connect, use
   `PATCH /connectors/<name>/offsets` or `kafka-consumer-groups --reset-offsets`
5. Resume, then watch `SHOW CHANNELS`. The tokens should now follow the new cluster's offsets
6. Deduplicate by business key if the replay overlapped what was already loaded

Alternatives: dropping and re-creating the target table also drops its channels, but loses the
data. Re-creating the connector under a different name gets new channels, but only if your
connector version puts the connector name in the channel name. Check `SHOW CHANNELS` before
relying on that.

**Prevent:**

- Move topics with offsets preserved. Confluent **Cluster Linking** mirror topics keep the same
  offsets, so the tokens stay valid. MirrorMaker 2 / Replicator don't keep offsets; they translate
  consumer group offsets, but nothing translates a Snowflake channel token
- If offsets can't be preserved, make the channel reset (step 3 above) part of the cutover runbook,
  together with the Kafka offset for the new cluster
- Alert on "target hasn't grown for X minutes while the topic has", not only on consumer lag

Cluster Linking isn't demoed here: it needs `cp-server` and a licence (trial) on the destination,
which makes the project heavier without showing anything the README can't explain.

## How the emulator matches (and doesn't match) the real connector

[sf-emulator/sf_emulator.py](sf-emulator/sf_emulator.py) copies these rules:

- channel per `(connector, topic, partition)`, named `<CONNECTOR>_<TOPIC>_<PARTITION>`
- on assignment, seek to `token + 1`; NULL or `-1` means use the Kafka group offset
- `auto.offset.reset=earliest` (Connect's sink default) when the offset is missing or out of range
- skip `offset <= token`; rows and the token commit in one transaction; then `token + 1` is
  committed to Kafka

What it doesn't do: buffering and flush thresholds, schematization, multiple tasks, error handling,
channel invalidation, or the 30-day inactive channel cleanup. It is a model of the offset
handling, not a replacement for the connector.

Sources:

- [Snowflake: Kafka connector with Snowpipe Streaming](https://docs.snowflake.com/en/user-guide/data-load-snowpipe-streaming-kafka):
  the latest committed offset token is the source of truth on channel open; NULL falls back to Kafka
- [Snowflake: channels and exactly-once delivery](https://docs.snowflake.com/user-guide/snowpipe-streaming/snowpipe-streaming-channels):
  offset tokens, `SHOW CHANNELS`, inactive channel cleanup
- [Snowflake: SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN](https://docs.snowflake.com/en/sql-reference/functions/system_snowpipe_streaming_update_channel_offset_token)
- [Redpanda support: Snowflake connector offset mismatch after topic recreation](https://support.redpanda.com/hc/en-us/articles/30480566093591-Snowflake-Connector-Offset-Mismatch-After-Topic-Recreation-Issue):
  the same failure, fixed with the `-1` reset
- [Confluent Cloud: manage offsets for fully-managed connectors](https://docs.confluent.io/cloud/current/connectors/offsets.html)
- [KIP-875: first-class offsets support in Kafka Connect](https://cwiki.apache.org/confluence/display/KAFKA/KIP-875%3A+First-class+offsets+support+in+Kafka+Connect)

## Endpoints

### From the host

| Service | Endpoint | Protocol | Notes |
| --- | --- | --- | --- |
| Kafka UI | http://localhost:8080 | HTTP | both clusters and both Connect workers; bound to 127.0.0.1 |
| Kafka cluster A (old) | `localhost:9092` | Kafka (PLAINTEXT) | e.g. `kcat -b localhost:9092 -L` |
| Kafka cluster B (new) | `localhost:9094` | Kafka (PLAINTEXT) | |
| Connect A REST | http://localhost:8083 | HTTP | worker on cluster A |
| Connect B REST | http://localhost:8084 | HTTP | worker on cluster B |
| Postgres | `localhost:5432` | PostgreSQL | `postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:5432/$POSTGRES_DB` (values from `.env`) |

The emulators (`sf-emulator-a`, `sf-emulator-b`) don't listen on any port; use `just logs sf-emulator-b`.

### Inside the compose network

| Service | Address |
| --- | --- |
| kafka-a / kafka-b brokers | `kafka-a:29092` / `kafka-b:29092` |
| kafka-a / kafka-b KRaft controllers | `kafka-a:29093` / `kafka-b:29093` (controller listener, not for clients) |
| connect-a / connect-b REST | `http://connect-a:8083` / `http://connect-b:8083` |
| Postgres | `postgres:5432` (JDBC: `jdbc:postgresql://postgres:5432/$POSTGRES_DB`) |
| Kafka UI | `http://kafka-ui:8080` |

### Connect REST endpoints used by the scripts

The same endpoints exist on both workers (`:8083` = A, `:8084` = B); the connector is `orders-jdbc`.

| Method | Path | Used for |
| --- | --- | --- |
| `GET` | `/connectors?expand=status` | `just status` |
| `PUT` | `/connectors/orders-jdbc/config` | create or update the connector |
| `GET` | `/connectors/orders-jdbc/status` | connector and task state |
| `PUT` | `/connectors/orders-jdbc/stop` | stop the tasks and leave the consumer group (needed before changing offsets) |
| `PUT` | `/connectors/orders-jdbc/resume` | start again after a stop |
| `GET` | `/connectors/orders-jdbc/offsets` | current sink offsets (KIP-875) |
| `PATCH` | `/connectors/orders-jdbc/offsets` | set sink offsets (KIP-875), body `{"offsets":[{"partition":{"kafka_topic":"orders","kafka_partition":0},"offset":{"kafka_offset":0}}]}` |
| `DELETE` | `/connectors/orders-jdbc/offsets` | clear offsets so `auto.offset.reset` applies (not used by the scripts) |
| `DELETE` | `/connectors/orders-jdbc` | delete the connector (`just reset`) |

### Kafka and database objects

| Object | Where | What |
| --- | --- | --- |
| topic `orders` | both clusters | 1 partition, recreated by `just reset` |
| group `connect-orders-jdbc` | both clusters | the JDBC sink's consumer group |
| group `connect-orders-sf` | both clusters | the emulator's consumer group |
| `_connect-configs`, `_connect-offsets`, `_connect-status` | both clusters | each Connect worker's internal topics |
| `orders_jdbc`, `orders_sf` | Postgres | target tables |
| `sf_channels` | Postgres | emulated Snowflake channels (`offset_token` per partition) |
| `sf_update_channel_offset_token(table, channel, token)` | Postgres | stand-in for `SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN` |

## Credentials

The Postgres credentials come from `.env` (gitignored; `just up` creates it from `.env.example`).
Connector configs read them through Connect's `EnvVarConfigProvider` (`${env:POSTGRES_PASSWORD}`),
so they aren't stored in `connectors/orders-jdbc.json` or in Connect's config topic. Everything else
is unauthenticated and meant for localhost only. The project shares host ports with the other
projects in this repo, so run one at a time.

## Files

```
docker-compose.yml        both clusters, both Connect workers, Postgres, emulators (profile), Kafka UI
connect/Dockerfile        cp-kafka-connect + Confluent JDBC connector
connectors/orders-jdbc.json
postgres/init.sql         orders_jdbc, orders_sf, sf_channels, sf_update_channel_offset_token()
sf-emulator/              the Snowpipe Streaming emulator (Python, confluent-kafka, psycopg)
scripts/lib.sh            shared helpers (produce, connector REST, waits)
scripts/s{1,2}-*.sh       the scenarios
justfile                  entry point for everything
```

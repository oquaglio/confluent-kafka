# Manual runsheet

Both scenarios, one command at a time, with a check after each step. This is what `just s1` and
`just s2` do, but spelled out so you can watch every moving part. The outputs shown are from a real
run, trimmed.

`just produce`, `just count` and `just gaps` are used along the way because they keep the `seq`
counter consistent. Everything else is the raw `docker`, `curl` and `psql` command.

## 0. Setup

```sh
cd confluent-sink-offset-migration
just up                         # build, start, create topic `orders` on both clusters (~1 min)
set -a; source .env; set +a     # POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB for the psql commands below
```

Keep **Kafka UI** open at http://localhost:8080. It shows both clusters, their topics and consumer
groups, and both Connect workers.

**Check: a clean slate**

```sh
curl -s localhost:8083/connectors; echo        # connect-a: []
curl -s localhost:8084/connectors; echo        # connect-b: []
docker exec kafka-a kafka-topics --bootstrap-server kafka-a:29092 --describe --topic orders
docker exec kafka-b kafka-topics --bootstrap-server kafka-b:29092 --describe --topic orders
just count                                     # (0 rows)
```

Each cluster has its own `orders` topic with 1 partition. The two topics are completely unrelated.

---

# Scenario 1: consumer group offsets lost (JDBC sink)

The connector's progress lives in a consumer group **on the cluster**. Move the connector and the
progress stays behind.

## 1.1 Create the JDBC sink on cluster A

```sh
curl -s -X PUT -H 'Content-Type: application/json' localhost:8083/connectors/orders-jdbc/config -d '{
  "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
  "topics": "orders",
  "tasks.max": "1",
  "connection.url": "jdbc:postgresql://postgres:5432/${env:POSTGRES_DB}",
  "connection.user": "${env:POSTGRES_USER}",
  "connection.password": "${env:POSTGRES_PASSWORD}",
  "table.name.format": "orders_jdbc",
  "auto.create": "false",
  "insert.mode": "upsert",
  "pk.mode": "record_value",
  "pk.fields": "seq",
  "consumer.override.auto.offset.reset": "earliest"
}' | jq -c '{name, type}'
```

`PUT .../config` creates the connector, or updates it if it already exists. The `${env:...}` values
are filled in by the Connect worker from its own environment. The body is in single quotes so your
shell leaves them alone. The worker starts one task, which is a Kafka consumer in group
`connect-orders-jdbc`.

**Check: running, and in a consumer group on A**

```sh
curl -s localhost:8083/connectors/orders-jdbc/status | jq -c '{c: .connector.state, t: [.tasks[].state]}'
# {"c":"RUNNING","t":["RUNNING"]}
docker exec kafka-a kafka-consumer-groups --bootstrap-server kafka-a:29092 --describe --group connect-orders-jdbc
# CURRENT-OFFSET -   LOG-END-OFFSET 0   CONSUMER-ID connector-consumer-orders-jdbc-0-...
```

`CURRENT-OFFSET -` means the group exists and has a member, but nothing has been committed yet.

## 1.2 Produce 500 records to cluster A

```sh
just produce a 500
```

This sends `seq` 1..500 to A's `orders` topic. The key is the `seq`; the value is JSON with an embedded
schema (that's what the JDBC sink needs to know the column types).

**Check: the topic, one message, the group, the table**

```sh
docker exec kafka-a kafka-get-offsets --bootstrap-server kafka-a:29092 --topic orders
# orders:0:500                  <- topic:partition:log-end-offset

docker exec kafka-a kafka-console-consumer --bootstrap-server kafka-a:29092 --topic orders \
  --from-beginning --max-messages 1 --property print.key=true --property print.offset=true
# Offset:0  1  {"schema":{...},"payload":{"seq":1,"ts_ms":1795845787531,"cluster":"a"}}

docker exec kafka-a kafka-consumer-groups --bootstrap-server kafka-a:29092 --describe --group connect-orders-jdbc
# CURRENT-OFFSET 500   LOG-END-OFFSET 500   LAG 0

just count
# orders_jdbc | a | 500 | 1 | 500
```

Give the group check about 5 seconds: Connect commits sink offsets on an interval
(`CONNECT_OFFSET_FLUSH_INTERVAL_MS=5000`).

## 1.3 Migrate: stop and delete the connector on A

```sh
curl -s -X PUT localhost:8083/connectors/orders-jdbc/stop
curl -s -X DELETE localhost:8083/connectors/orders-jdbc
```

`stop` shuts down the tasks (unlike `pause`, which keeps the consumer in the group). `DELETE` removes
the connector from connect-a.

**Check: connector gone, its progress left behind**

```sh
curl -s localhost:8083/connectors; echo
# []
docker exec kafka-a kafka-consumer-groups --bootstrap-server kafka-a:29092 --describe --group connect-orders-jdbc
# Consumer group 'connect-orders-jdbc' has no active members.
# CURRENT-OFFSET 500   LOG-END-OFFSET 500   LAG 0   CONSUMER-ID -
```

The group, and its offset of 500, is still on cluster A. Deleting a connector doesn't delete its
consumer group, and nothing ever copies it to B.

## 1.4 Producers cut over to B before the connector does

```sh
just produce b 200
```

`seq` 501..700 go to cluster B at offsets 0..199. No sink is running on B yet.

**Check: data on B, no group on B, nothing new in the table**

```sh
docker exec kafka-b kafka-get-offsets --bootstrap-server kafka-b:29092 --topic orders
# orders:0:200
docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 --list
# (empty)
just count
# orders_jdbc | a | 500 | 1 | 500      <- unchanged
```

## 1.5 Re-create the connector on B with `auto.offset.reset=latest`

The same config, sent to connect-b (port **8084**), with `latest`:

```sh
curl -s -X PUT -H 'Content-Type: application/json' localhost:8084/connectors/orders-jdbc/config -d '{
  "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
  "topics": "orders",
  "tasks.max": "1",
  "connection.url": "jdbc:postgresql://postgres:5432/${env:POSTGRES_DB}",
  "connection.user": "${env:POSTGRES_USER}",
  "connection.password": "${env:POSTGRES_PASSWORD}",
  "table.name.format": "orders_jdbc",
  "auto.create": "false",
  "insert.mode": "upsert",
  "pk.mode": "record_value",
  "pk.fields": "seq",
  "consumer.override.auto.offset.reset": "latest"
}' | jq -c '{name, type}'
```

Group `connect-orders-jdbc` doesn't exist on B, so there's no committed offset and the consumer falls
back to `auto.offset.reset`. With `latest`, it starts at the end of the topic, after the 200 records.

**Check: where it started**

```sh
docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 --describe --group connect-orders-jdbc
# CURRENT-OFFSET -   LOG-END-OFFSET 200   CONSUMER-ID connector-consumer-orders-jdbc-0-...

docker logs connect-b 2>&1 | grep 'Resetting offset for partition orders-0'
# ... Resetting offset for partition orders-0 to position FetchPosition{offset=200, ...}
```

That log line is where the gap happens: the consumer was put at offset 200, past the 200 waiting
records.

## 1.6 Traffic continues on B

```sh
just produce b 50
```

`seq` 701..750 at offsets 200..249. These *do* load, because they arrive after the consumer's position.

**Check: everything looks healthy, except the data**

```sh
curl -s localhost:8084/connectors/orders-jdbc/status | jq -c '{c: .connector.state, t: [.tasks[].state]}'
# {"c":"RUNNING","t":["RUNNING"]}                       <- no errors

docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 --describe --group connect-orders-jdbc
# CURRENT-OFFSET 250   LOG-END-OFFSET 250   LAG 0       <- "fully caught up"

just count
# orders_jdbc | a | 500 |   1 | 500
# orders_jdbc | b |  50 | 701 | 750                     <- B starts at 701

just gaps
# orders_jdbc  produced 750  rows 550  ...  missing 200
#   missing seq 501..700 (200)
```

(`just gaps` also reports `orders_sf` as all missing. Ignore that: the emulator isn't used in this
scenario.)

**This is the incident in a nutshell:** connector RUNNING, lag 0, and 200 records never delivered.
The only signal is in the target. The records are still on cluster B, so they can be replayed.

## 1.7 Fix: stop the connector

```sh
curl -s -X PUT localhost:8084/connectors/orders-jdbc/stop
```

Offsets can only be changed while the connector has no running tasks.

**Check**

```sh
curl -s localhost:8084/connectors/orders-jdbc/status | jq -c '{c: .connector.state, t: [.tasks[].state]}'
# {"c":"STOPPED","t":[]}
curl -s localhost:8084/connectors/orders-jdbc/offsets | jq -c .
# {"offsets":[{"partition":{"kafka_partition":0,"kafka_topic":"orders"},"offset":{"kafka_offset":250}}]}
```

## 1.8 Fix: find where the replay should start

The last record that made it from the old cluster marks where to resume. Take its timestamp and ask
cluster B for the first offset after it:

```sh
LAST_TS=$(docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT max(ts_ms) FROM orders_jdbc WHERE cluster = 'a'")
echo $LAST_TS
# 1795845788030

docker exec kafka-b kafka-get-offsets --bootstrap-server kafka-b:29092 --topic orders --time $((LAST_TS + 1))
# orders:0:0                    <- first record on B newer than that is offset 0
```

`--time <epoch-ms>` returns the first offset whose record timestamp is >= that time. In a real
incident, use the cutover time instead, minus a margin if you're unsure.

## 1.9 Fix: set the offset, then resume

```sh
curl -s -X PATCH -H 'Content-Type: application/json' localhost:8084/connectors/orders-jdbc/offsets \
  -d '{"offsets":[{"partition":{"kafka_topic":"orders","kafka_partition":0},"offset":{"kafka_offset":0}}]}' | jq -r .message
# The Connect framework-managed offsets for this connector have been altered successfully. However,
# if this connector manages offsets externally, they will need to be manually altered in the system
# that the connector uses.
```

That second sentence is scenario 2 in one line.

**Check: the new offset is in the consumer group**

```sh
curl -s localhost:8084/connectors/orders-jdbc/offsets | jq -c .
# ... "offset":{"kafka_offset":0}
docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 --describe --group connect-orders-jdbc
# CURRENT-OFFSET 0   LOG-END-OFFSET 250   LAG 250       <- now the lag is honest
```

Resume:

```sh
curl -s -X PUT localhost:8084/connectors/orders-jdbc/resume
```

**Check: gap closed, no duplicates**

```sh
just count
# orders_jdbc | a | 500 |   1 | 500
# orders_jdbc | b | 250 | 501 | 750

scripts/gaps.sh --strict orders_jdbc
# orders_jdbc  produced 750  rows 750  distinct 750  missing 0  duplicates 0
# OK: every produced seq is in orders_jdbc exactly once

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT seq, cluster, loaded_at FROM orders_jdbc WHERE seq IN (500, 501, 700, 701) ORDER BY seq"
#  500 | a | 06:03:08
#  501 | b | 06:04:18     <- backfilled
#  700 | b | 06:04:18
#  701 | b | 06:03:52     <- loaded before 501: a sign that a backfill happened
```

The replay re-sent 701..750 too, but the sink upserts on `seq`, so they were overwritten, not
duplicated.

**Alternative to 1.8–1.9:** with the connector stopped, reset the group with the Kafka CLI instead
of the REST API:

```sh
docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 \
  --group connect-orders-jdbc --topic orders --reset-offsets --to-earliest --execute
```

Add `--dry-run` instead of `--execute` to preview. `--to-datetime 2026-11-28T06:00:00.000` and
`--to-offset N` work too.

---

# Scenario 2: offset token in the target (Snowflake-like)

The emulator keeps its progress **in Postgres** (`sf_channels.offset_token`), and that token
overrides the Kafka consumer group when it starts.

## 2.0 Reset

```sh
just reset
```

**Check**

```sh
just count                                                                              # (0 rows)
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT * FROM sf_channels'   # (0 rows)
```

## 2.1 Start the emulator on cluster A

```sh
docker compose --profile emulator up -d sf-emulator-a
```

`--profile emulator` is needed because the emulators are tagged with that profile, so plain `up`
skips them.

**Check: it opened a channel with no token**

```sh
docker logs sf-emulator-a
# consuming orders from kafka-a:29092 as connect-orders-sf into orders_sf
# open channel ORDERS_SF_ORDERS_0: offset token None -> using the Kafka offset of group connect-orders-sf ...

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT * FROM sf_channels'
# orders_sf | ORDERS_SF_ORDERS_0 | orders | 0 | (null) | ...
```

The channel name is `<CONNECTOR>_<TOPIC>_<PARTITION>`. Nothing in it says which cluster it came from.

## 2.2 Produce 1000 records to A

```sh
just produce a 1000
```

**Check: rows, token, group**

```sh
docker logs sf-emulator-a 2>&1 | tail -2
# partition 0: read offsets 0-499, inserted 500
# partition 0: read offsets 500-999, inserted 500

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT channel_name, offset_token FROM sf_channels'
# ORDERS_SF_ORDERS_0 | 999          <- last offset written

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  'SELECT seq, cluster, kafka_offset FROM orders_sf ORDER BY seq DESC LIMIT 3'
# 1000 | a | 999

docker exec kafka-a kafka-consumer-groups --bootstrap-server kafka-a:29092 --describe --group connect-orders-sf
# CURRENT-OFFSET 1000   LOG-END-OFFSET 1000   LAG 0
```

There are now two copies of the progress: the token 999 in Postgres, and 1000 (token + 1) in the
group on A. They agree, for now.

## 2.3 Migrate: stop the emulator on A

```sh
docker compose --profile emulator stop sf-emulator-a
```

## 2.4 Producers cut over to B

```sh
just produce b 300
```

`seq` 1001..1300 land on B at offsets **0..299**. The offsets restart because it's a different topic
on a different cluster.

**Check**

```sh
docker exec kafka-b kafka-get-offsets --bootstrap-server kafka-b:29092 --topic orders
# orders:0:300
```

## 2.5 Start the emulator on B (same connector name, so same channel)

```sh
docker compose --profile emulator up -d sf-emulator-b
```

**Check: the log tells the whole story**

```sh
docker logs sf-emulator-b
# open channel ORDERS_SF_ORDERS_0: offset token 999 -> seek partition 0 to 1000 (Snowflake token wins ...)
# %4|...|OFFSET| orders [0]: offset reset (at offset 1000) to offset BEGINNING: ... Offset out of range
# WARNING partition 0: asked for offset 1000 but got 0. That offset doesn't exist on this cluster ...
# partition 0: read offsets 0-299, inserted 0, SKIPPED 300 as already ingested (offset <= token 999)
```

1. It reads the token, 999, and seeks to 1000.
2. Offset 1000 doesn't exist on B, so Kafka resets to the beginning (`auto.offset.reset=earliest`).
3. Every record at offsets 0..299 has `offset <= 999`, so it's treated as a duplicate and skipped.

## 2.6 Traffic continues on B

```sh
just produce b 50
```

**Check: silent failure**

```sh
docker logs sf-emulator-b 2>&1 | tail -1
# partition 0: read offsets 300-349, inserted 0, SKIPPED 50 as already ingested (offset <= token 999)

just count
# orders_sf | a | 1000 | 1 | 1000             <- nothing from B at all

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT channel_name, offset_token FROM sf_channels'
# ORDERS_SF_ORDERS_0 | 999                    <- token stuck

docker exec kafka-b kafka-get-offsets --bootstrap-server kafka-b:29092 --topic orders
# orders:0:350                                <- token 999 >= log-end 350

docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 --describe --group connect-orders-sf
# CURRENT-OFFSET 1000   LOG-END-OFFSET 350   LAG -650     <- negative lag
```

The signals, and what each one means:

- **Container running, no errors.** Nothing would alert.
- **Token >= log-end offset.** Every record on B counts as already ingested, and this continues until
  B passes offset 999, another 650 records from now.
- **Negative lag.** The committed offset (token + 1) is past the end of the topic. Most lag alerts
  only look for positive lag.

`just offsets` shows all of this in one go.

## 2.7 The wrong fix: reset the consumer group

This is what you'd try first, and it doesn't work.

```sh
docker compose --profile emulator stop sf-emulator-b
docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 \
  --group connect-orders-sf --topic orders --reset-offsets --to-earliest --execute
# connect-orders-sf  orders  0  NEW-OFFSET 0
docker compose --profile emulator start sf-emulator-b
```

**Check: still nothing**

```sh
docker logs sf-emulator-b 2>&1 | tail -1
# partition 0: read offsets 0-349, inserted 0, SKIPPED 350 as already ingested (offset <= token 999)
just count
# orders_sf | a | 1000 | 1 | 1000
```

On start, the token overrode the group offset you just set. The Kafka-side fix from scenario 1
doesn't reach state that lives in the target.

## 2.8 The right fix, step 1: reset the channel token

```sh
docker compose --profile emulator stop sf-emulator-b
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT sf_update_channel_offset_token('orders_sf', 'ORDERS_SF_ORDERS_0', -1)"
# offset token of ORDERS_SF_ORDERS_0 set to -1
```

`-1` means "no token: use the Kafka consumer offset". The Snowflake equivalent, run while the
connector is stopped:

```sql
SELECT SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN('<db>.<schema>.ORDERS_SF', 'ORDERS_SF_ORDERS_0', '-1');
SHOW CHANNELS IN TABLE <db>.<schema>.ORDERS_SF;
```

**Check**

```sh
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT channel_name, offset_token FROM sf_channels'
# ORDERS_SF_ORDERS_0 | -1
```

## 2.9 The right fix, step 2: put the Kafka offset where the gap starts

Now the Kafka offset is in charge, so it has to be right. The same technique as 1.8:

```sh
LAST_TS=$(docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT max(ts_ms) FROM orders_sf")
docker exec kafka-b kafka-get-offsets --bootstrap-server kafka-b:29092 --topic orders --time $((LAST_TS + 1))
# orders:0:0

docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 \
  --group connect-orders-sf --topic orders:0 --reset-offsets --to-offset 0 --execute
```

In Confluent Cloud, this step is the managed connector's offsets API
(`POST .../connectors/<name>/offsets/request` with a `PATCH` body) or `confluent connect offset`.

## 2.10 The right fix, step 3: start and verify

```sh
docker compose --profile emulator start sf-emulator-b
```

**Check: loading again, token following B's offsets**

```sh
docker logs sf-emulator-b 2>&1 | tail -2
# open channel ORDERS_SF_ORDERS_0: offset token -1 -> using the Kafka offset of group connect-orders-sf ...
# partition 0: read offsets 0-349, inserted 350

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT channel_name, offset_token FROM sf_channels'
# ORDERS_SF_ORDERS_0 | 349          <- now describes cluster B

just count
# orders_sf | a | 1000 |    1 | 1000
# orders_sf | b |  350 | 1001 | 1350
```

New traffic flows too:

```sh
just produce b 50
docker logs sf-emulator-b 2>&1 | tail -1
# partition 0: read offsets 350-399, inserted 50

scripts/gaps.sh --strict orders_sf
# orders_sf  produced 1400  rows 1400  distinct 1400  missing 0  duplicates 0
# OK: every produced seq is in orders_sf exactly once

docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 --describe --group connect-orders-sf
# CURRENT-OFFSET 400   LOG-END-OFFSET 400   LAG 0      <- positive, honest lag again
```

## 2.11 Optional: what replaying too far back does

Choosing the replay start too early is safe, but it creates duplicates, because `orders_sf` (like
Snowflake) has no primary key. To see it, replay all of B again:

```sh
docker compose --profile emulator stop sf-emulator-b
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT sf_update_channel_offset_token('orders_sf', 'ORDERS_SF_ORDERS_0', -1)"
docker exec kafka-b kafka-consumer-groups --bootstrap-server kafka-b:29092 \
  --group connect-orders-sf --topic orders --reset-offsets --to-earliest --execute
docker compose --profile emulator start sf-emulator-b
```

**Check: duplicates, then clean them up**

```sh
just gaps 2>&1 | grep orders_sf
# orders_sf  produced 1400  rows 1800  distinct 1400  missing 0  duplicates 400

docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  'SELECT seq, count(*) FROM orders_sf GROUP BY seq HAVING count(*) > 1 ORDER BY seq LIMIT 3'
# 1001 | 2
# 1002 | 2

just dedupe
# DELETE 400
scripts/gaps.sh --strict orders_sf
# OK: every produced seq is in orders_sf exactly once
```

`scripts/dedupe.sh` keeps the first-loaded row per `seq`. The Snowflake version (`INSERT OVERWRITE …
QUALIFY ROW_NUMBER() …`) is in the script's comment.

---

## Done

```sh
just reset      # empty everything, keep the stack running
just down       # stop (keeps volumes)
```

## Quick reference: the checks

| What | Command |
| --- | --- |
| connector state | `curl -s localhost:808{3,4}/connectors/orders-jdbc/status \| jq` |
| connector offsets | `curl -s localhost:808{3,4}/connectors/orders-jdbc/offsets \| jq` |
| topic log-end offset | `docker exec kafka-{a,b} kafka-get-offsets --bootstrap-server kafka-{a,b}:29092 --topic orders` |
| first offset at a time | the same, plus `--time <epoch-ms>` |
| consumer group | `docker exec kafka-{a,b} kafka-consumer-groups --bootstrap-server kafka-{a,b}:29092 --describe --group connect-orders-{jdbc,sf}` |
| channel tokens | `docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'SELECT * FROM sf_channels'` |
| emulator log | `docker logs sf-emulator-{a,b}` |
| Connect log | `docker logs connect-{a,b}` |
| rows per cluster | `just count` |
| missing / duplicates | `just gaps` |
| everything offset-related | `just offsets` |

In the table, `{a,b}` and `808{3,4}` mean "pick one". Type the actual name or port.

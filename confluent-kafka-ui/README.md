# Kafka Broker + Kafka UI

A single-node Confluent Kafka broker (`confluentinc/cp-kafka`) running in **KRaft mode** (no ZooKeeper),
plus [Kafka UI](https://github.com/provectus/kafka-ui) (`provectuslabs/kafka-ui`), a web console for
browsing topics, messages and consumer groups. Everything starts with Docker Compose.

This is the `confluent-basic` setup with a UI added. Use it to see Kafka's core concepts both from the
CLI and in a browser.

| What | Where |
|---|---|
| Kafka UI | http://localhost:8082 (cluster name `local`) |
| Broker, from your machine | `localhost:9092` |
| Broker, from other containers in this project | `kafka:29092` |

## Docs

- https://developer.confluent.io/confluent-tutorials/kafka-on-docker/
- https://kafka.apache.org/documentation/
- https://docs.kafka-ui.provectus.io/

## Start / Stop

```sh
docker compose up -d            # start broker + UI
docker logs -f kafka-broker     # follow broker logs (Ctrl+C to stop following)
docker logs -f kafka-ui         # follow UI logs
docker compose down             # stop (data is kept in the volume)
docker compose down -v          # stop AND delete all Kafka data
```

The broker is ready once its log shows `Kafka Server started`. The UI may take a few more seconds,
then shows the `local` cluster as **online** on its dashboard.

## How the Pieces Fit

```text
 your machine                         compose network
 ┌──────────────┐  localhost:9092    ┌──────────────────────────┐
 │ CLI / your   │ ─────────────────▶ │ kafka   (kafka-broker)   │
 │ code         │                    │  :9092  PLAINTEXT_HOST   │
 │              │  localhost:8082    │  :29092 PLAINTEXT  ◀─────┼──┐
 │ browser      │ ─────────────────▶ │  :29093 CONTROLLER       │  │ kafka:29092
 └──────────────┘                    └──────────────────────────┘  │
                                     ┌──────────────────────────┐  │
                                     │ kafka-ui  :8080          │──┘
                                     └──────────────────────────┘
```

Kafka UI is just another Kafka client. It runs in its own container, so it connects to the broker
through the **internal** listener `kafka:29092` (`KAFKA_CLUSTERS_0_BOOTSTRAP_SERVERS`), not
`localhost:9092`. Inside the UI container, `localhost` would mean the UI container itself.

## Concepts This Project Covers

### KRaft mode (no ZooKeeper)

Older Kafka versions needed a separate ZooKeeper cluster to store metadata. In KRaft mode, Kafka
stores its own metadata in an internal Raft log (`__cluster_metadata`). This one container plays
**both** roles:

| Setting | Meaning |
|---|---|
| `KAFKA_PROCESS_ROLES: broker,controller` | This node stores data *and* manages cluster metadata |
| `KAFKA_NODE_ID: 1` | Unique ID of this node (`KAFKA_BROKER_ID` is the older name for the same thing) |
| `KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:29093` | The controller quorum: just this node |
| `CLUSTER_ID` | Fixed cluster ID, used to format storage on first start |

To generate your own cluster ID:

```sh
docker exec kafka-broker kafka-storage random-uuid
```

Changing `CLUSTER_ID` after the volume has been formatted makes the broker refuse to start. Run
`docker compose down -v` first.

To check the controller quorum:

```sh
docker exec kafka-broker kafka-metadata-quorum --bootstrap-server localhost:9092 describe --status
```

In the UI: **Brokers** shows the single broker, and clicking it shows its full configuration.

### Listeners (how clients connect)

A Kafka client first connects to a *bootstrap* address. The broker then replies with its
**advertised** address, and the client uses that address for everything after. So the advertised
address must be reachable from wherever the client runs.

| Listener | Bind address | Advertised as | Used by |
|---|---|---|---|
| `PLAINTEXT_HOST` | `0.0.0.0:9092` | `localhost:9092` | Clients on your machine (port 9092 is published) |
| `PLAINTEXT` | `kafka:29092` | `kafka:29092` | Kafka UI and other containers on the compose network; inter-broker traffic |
| `CONTROLLER` | `kafka:29093` | - | KRaft controller traffic only |

So use `localhost:9092` from your machine (or from inside the broker container), and `kafka:29092`
from other containers in this compose project. If the UI were pointed at `localhost:9092`, it would
show the cluster as **offline**.

### Topics, partitions, replication

- A **topic** is a named stream of records (like a table or a log).
- Each topic is split into **partitions**. A partition is an ordered, append-only log, and every
  record in it has an **offset** (0, 1, 2, ...). Ordering is guaranteed *within* a partition only.
- Each partition can be **replicated** across brokers. There's one broker here, so the replication
  factor must be `1`. That's why the compose file sets the internal topics
  (`__consumer_offsets`, transaction state) to `1`.

### Keys and partitioning

The producer picks a record's partition by hashing its **key**. Records with the same key always
go to the same partition, so they stay in order. Records with no key are spread across partitions.

### Pub/sub and consumer groups

- **Producers** publish records to a topic. **Consumers** subscribe to it.
- Consumers join a **consumer group** (`group.id`). Within one group, each partition is read by
  exactly one consumer, which is how work gets shared (**queue** behaviour).
- **Different groups** each get *all* records independently (**pub/sub / broadcast** behaviour).
- Each group's position (its committed **offset** per partition) is stored in the internal topic
  `__consumer_offsets`. **Lag** is how far a group is behind the end of the log.
- Kafka **keeps** records after they are read, until retention expires. Consumers can rewind and
  read them again.

### Auto-created topics

By default the broker creates a topic the first time something produces to (or fetches metadata
for) a name that doesn't exist. It gets the broker defaults: **1 partition**. So a typo in a topic
name silently creates a new topic, and a topic created this way won't show key-based partitioning.
Create topics explicitly (CLI or UI) when partition count matters.

### Persistence

Data is stored in the named Docker volume `kafka-data`, mounted at `/var/lib/kafka/data`
(`KAFKA_LOG_DIRS`). It survives `docker compose down`, and `docker compose down -v` deletes it.
Docker names the volume after the project folder: `confluent-kafka-ui_kafka-data`, so it doesn't
clash with the `kafka-data` volume of other projects in this repo.

Kafka UI keeps no data of its own; everything it shows is read live from the broker.

## Hands-On: Kafka UI

Open http://localhost:8082 and pick the `local` cluster.

| Page | What you can do / learn |
|---|---|
| **Dashboard** | Cluster status (online/offline), broker, partition and topic counts |
| **Brokers** | The single broker, its disk usage and its full config |
| **Topics** | List topics (toggle *Show Internal Topics* to see `__consumer_offsets`); **Add a Topic** with a partition count, retention etc. |
| **Topics → *topic* → Overview** | Partitions with their first/last offsets and message counts |
| **Topics → *topic* → Messages** | Browse records with key, partition, offset and timestamp; filter by partition, start from oldest/newest/an offset/a time; **Live** mode tails new messages |
| **Topics → *topic* → Produce Message** | Publish a record with a key and value, optionally to a chosen partition |
| **Topics → *topic* → Consumers** | Groups reading this topic and their lag |
| **Topics → *topic* → Settings** | Topic configs (retention, cleanup policy, ...) |
| **Consumers** | All consumer groups: state, members, per-partition committed offset and **lag**; **Reset offsets** for a group with no running members |

### See pub/sub in the UI

1. **Topics → Add a Topic**: name `orders`, 3 partitions. (Or use the CLI command below.)
2. Start the two consumers from [See pub/sub live](#see-pubsub-live-use-3-terminals) (groups
   `billing` and `shipping`).
3. In the UI, open `orders` → **Produce Message**. Send a few records with keys `customer1` and
   `customer2`.
4. Watch both terminals: each group gets every record.
5. In `orders` → **Messages**, note that all `customer1` records share one partition.
6. Open **Consumers → billing**: one member, assigned all 3 partitions, lag 0.
7. Stop the `shipping` consumer (Ctrl+C), produce more records in the UI, then open
   **Consumers → shipping**: its lag grows by the number of records it missed. Start it again and
   the lag drops back to 0 as it catches up.

## Hands-On: CLI Cheat Sheet

The Confluent image ships the tools **without** the `.sh` suffix (`kafka-topics`, not
`kafka-topics.sh`). Every command below runs inside the broker container, against `localhost:9092`.
The results appear in the UI too, so you can check each step there.

Use `-it` for commands you type into interactively (producer). For one-shot commands, plain
`docker exec` is enough.

### List / create / describe topics

```sh
# list topics
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 --list

# create a topic with 3 partitions
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --create --topic orders --partitions 3 --replication-factor 1

# describe it (partitions, leader, replicas, in-sync replicas)
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 --describe --topic orders
```

`--list` also shows internal topics such as `__consumer_offsets`, which appears once any consumer
group has committed offsets. Add `--exclude-internal` to hide them.

If `orders` already exists with 1 partition (for example auto-created by an earlier producer),
`--create` fails with `TopicExistsException`. Delete it first or add partitions (see
[Change topic settings](#change-topic-settings)).

### See pub/sub live (use 3 terminals)

**Terminal 1: consumer in group `billing`**

```sh
docker exec -it kafka-broker kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic orders --group billing \
  --formatter-property print.key=true --formatter-property print.partition=true \
  --formatter-property print.offset=true
```

**Terminal 2: consumer in a *different* group `shipping`** (same command, different `--group`)

```sh
docker exec -it kafka-broker kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic orders --group shipping \
  --formatter-property print.key=true --formatter-property print.partition=true
```

**Terminal 3: producer** (type `key:value` lines, Ctrl+D to quit). You can also produce from the UI instead.

```sh
docker exec -it kafka-broker kafka-console-producer --bootstrap-server localhost:9092 \
  --topic orders --reader-property parse.key=true --reader-property key.separator=:
```

```text
> customer1:order-100
> customer2:order-200
> customer1:order-101
```

What you should see:

- **Both** consumers get every message. Each group is an independent subscriber (pub/sub).
- `customer1` messages always land on the same partition (same key → same partition).
- Now start a **second** consumer in group `billing` (repeat the Terminal 1 command in a 4th
  terminal) and produce more messages. The `billing` consumers now **split** the partitions
  between them, and each message goes to only one of them (queue behaviour). The group
  rebalances automatically when a member joins or leaves. **Consumers → billing** in the UI shows
  two members and which partitions each one owns.

### Replay from the beginning

```sh
# a consumer with no group (or a new group) reading everything ever written
docker exec -it kafka-broker kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic orders --from-beginning \
  --formatter-property print.key=true --formatter-property print.timestamp=true
```

`--from-beginning` only applies when a group has **no committed offset** yet. An existing group
carries on from where it left off.

Add `--max-messages N` or `--timeout-ms 5000` to make the consumer exit on its own. On a timeout
it logs `ERROR Error processing message ... TimeoutException`. That's expected and harmless.

The UI equivalent is **Topics → orders → Messages** with *Oldest First*. Browsing in the UI doesn't
join a consumer group, so it doesn't move any group's offsets.

### Consumer groups, offsets and lag

```sh
# list groups
docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 --list

# per-partition committed offset, log-end offset and LAG for a group
docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 \
  --describe --group billing

# latest offset of each partition (partition:offset)
docker exec kafka-broker kafka-get-offsets --bootstrap-server localhost:9092 --topic orders

# rewind a group to the start (the group must have no running consumers)
docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 \
  --group billing --topic orders --reset-offsets --to-earliest --execute
```

Use `--dry-run` instead of `--execute` to preview a reset. In the UI: **Consumers → billing →
Reset offsets**.

### Change topic settings

```sh
# add partitions (you can only increase; existing keys may then map to different partitions)
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --alter --topic orders --partitions 4

# keep records for 1 hour
docker exec kafka-broker kafka-configs --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders --alter --add-config retention.ms=3600000

# show overridden configs
docker exec kafka-broker kafka-configs --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders --describe
```

In the UI, a topic's **Settings** tab shows the same configs, and **Edit settings** changes them.

### Clean up

```sh
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 --delete --topic orders
docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 \
  --delete --group billing --group shipping
```

Or delete everything at once with `docker compose down -v`.

## Connecting From Your Own Code

Point any Kafka client (Python `confluent-kafka`, Java, Go, ...) at `localhost:9092`, for example:

```python
from confluent_kafka import Producer
p = Producer({"bootstrap.servers": "localhost:9092"})
p.produce("orders", key="customer1", value="order-102")
p.flush()
```

From another container in this compose project, use `kafka:29092`. Your records show up in the UI
under **Topics → orders → Messages**.

## Kafka UI Configuration

The UI is configured entirely through environment variables in `docker-compose.yml`:

| Variable | Meaning |
|---|---|
| `KAFKA_CLUSTERS_0_NAME: local` | Display name of the first cluster |
| `KAFKA_CLUSTERS_0_BOOTSTRAP_SERVERS: kafka:29092` | Where the UI connects (internal listener) |
| `DYNAMIC_CONFIG_ENABLED: 'true'` | Lets you add or edit clusters from the UI (**Dashboard → Configure new cluster**) |

More clusters can be added as `KAFKA_CLUSTERS_1_...`, and client settings such as SASL as
`KAFKA_CLUSTERS_0_PROPERTIES_...`. See `../confluent-kafka-ui-sasl` for an example.

The UI has **no login** in this setup: anyone who can reach port 8082 can produce, delete topics and
reset offsets. That's fine for local learning, but don't expose it.

`provectuslabs/kafka-ui:latest` is v0.7.2 (April 2024), and that image hasn't been updated since.
Development continues in the community fork [kafbat/kafka-ui](https://github.com/kafbat/kafka-ui)
(image `ghcr.io/kafbat/kafka-ui`), which uses the same environment variables.

## Troubleshooting

### UI shows the cluster as offline

- Check the broker is up: `docker logs kafka-broker | grep "Kafka Server started"`.
- Check the UI points at `kafka:29092`, not `localhost:9092` (see
  [Listeners](#listeners-how-clients-connect)).
- `docker logs kafka-ui` shows the connection errors.

### Port already allocated / container name already in use

Other projects in this repo also use container names `kafka-broker`/`kafka-ui` and ports
`9092`/`8082`. Run `docker compose down` in the other project first.

### `AccessDeniedException` on startup (bind mounts)

Data uses a **named volume**, not a bind mount like `./kafka-data`. When the Docker daemon runs in a
separate WSL distro, a bind-mounted host path doesn't exist on the daemon's side. The daemon creates
it root-owned, and Kafka's non-root `appuser` (uid 1000) can't write to it. See
`../confluent-basic/prompts/002-how-did-you-know-where-docker-is.out.md` and
`prompts/001-fix-bind-mount.out.md` for details.

### Broker won't start after changing `CLUSTER_ID`

The volume was formatted with the old ID. Run `docker compose down -v`, then `docker compose up -d`.

### `kafka-topics.sh: command not found`

Drop the `.sh` suffix. Confluent images install the tools as `kafka-topics`, `kafka-console-producer`, etc.

### Deprecation warning about `--property`

Newer versions renamed it: `--reader-property` for the producer, `--formatter-property` for the consumer.

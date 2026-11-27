# Basic Kafka Broker

A single-node Confluent Kafka broker (`confluentinc/cp-kafka`) running in **KRaft mode** (no ZooKeeper),
started with Docker Compose, plus [Kafka UI](https://github.com/kafbat/kafka-ui) as a web console. Use it
to learn the core Kafka concepts with the built-in CLI tools, and watch the results in the UI.

## Docs

- <https://developer.confluent.io/confluent-tutorials/kafka-on-docker/>
- <https://kafka.apache.org/documentation/>
- <https://ui.docs.kafbat.io/>

## Endpoints

| Endpoint | URL / address | What |
| --- | --- | --- |
| Kafka UI | <http://localhost:8080> | Web console: topics, messages, consumer groups, brokers |
| Kafka UI health | <http://localhost:8080/actuator/health> | Returns `{"status":"UP"}` when the UI is running |
| Kafka UI REST API | <http://localhost:8080/api/clusters> | The API the UI itself uses (e.g. `/api/clusters/local/topics`) |
| Kafka broker (host) | `localhost:9092` | Kafka protocol, not HTTP. For clients on your machine |
| Kafka broker (compose network) | `kafka:29092` | Kafka protocol, for other containers in this project |

Kafka UI has **no login** and can create/delete topics and produce messages, so it's published
on `127.0.0.1` only. The broker port has no authentication either; both are for local use.

## Start / Stop

Common tasks are wrapped in a [`justfile`](justfile). Run `just` to list the recipes.

```sh
just up             # start, waiting until the broker is healthy
just status         # containers + Kafka UI cluster status
just logs kafka     # follow broker logs (no argument = all services)
just down           # stop (data is kept in the volume)
just clean          # stop AND delete all Kafka data (asks for confirmation)
```

Plain Compose works too: `docker compose up -d --wait`, `docker compose down [-v]`.

The broker has a healthcheck (`kafka-broker-api-versions`), and Kafka UI only starts once it's
healthy. Then open <http://localhost:8080>.

### Recipes

| Area | Recipes |
| --- | --- |
| Stack | `up`, `down`, `clean`, `restart [svc]`, `status`, `logs [svc]`, `pull`, `shell` |
| Cluster | `quorum` (KRaft quorum status), `uuid` (new `CLUSTER_ID`) |
| Topics | `topics`, `create <topic> [partitions=3]`, `describe <topic>`, `partitions <topic> <n>`, `config <topic> <key=value>`, `configs <topic>`, `offsets <topic>`, `delete <topic>` |
| Produce / consume | `produce <topic>` (`key:value` lines), `consume <topic> [group]`, `replay <topic>` |
| Consumer groups | `groups`, `group <group>` (offsets and lag), `reset <group> <topic> [mode=execute\|dry-run]`, `delete-group <group>` |

`clean` and `delete` ask for confirmation first.

## Kafka UI

[kafbat/kafka-ui](https://github.com/kafbat/kafka-ui) (`v1.5.1`) is the maintained fork of
`provectuslabs/kafka-ui`. It's configured with one cluster, `local`, at `kafka:29092`.

Things to look at while you work through the cheat sheet below:

- **Topics**: partitions, replication factor, configs (e.g. `retention.ms` after you change it).
  *Messages* tab shows key, partition, offset and timestamp per record, and you can produce
  from the UI too.
- **Consumers**: each group's members, which partitions each member owns, committed offsets
  and lag. Start a second consumer in a group and watch the partitions get reassigned.
- **Brokers**: the single broker, its configs and log dirs.

The UI refreshes cluster statistics every 30 seconds or so, so a new topic may take a moment
to appear in the list.

## Concepts This Project Covers

### KRaft mode (no ZooKeeper)

Older Kafka versions needed a separate ZooKeeper cluster to store metadata. In KRaft mode, Kafka
stores its own metadata in an internal Raft log (`__cluster_metadata`). This one container plays
**both** roles:

| Setting | Meaning |
| --- | --- |
| `KAFKA_PROCESS_ROLES: broker,controller` | This node stores data *and* manages cluster metadata |
| `KAFKA_NODE_ID: 1` | Unique ID of this node |
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

### Listeners (how clients connect)

A Kafka client first connects to a *bootstrap* address. The broker then replies with its
**advertised** address, and the client uses that address for everything after. So the advertised
address must be reachable from wherever the client runs.

| Listener | Bind address | Advertised as | Used by |
| --- | --- | --- | --- |
| `PLAINTEXT_HOST` | `0.0.0.0:9092` | `localhost:9092` | Clients on your machine (port 9092 is published) |
| `PLAINTEXT` | `kafka:29092` | `kafka:29092` | Other containers on the compose network; inter-broker traffic |
| `CONTROLLER` | `kafka:29093` | - | KRaft controller traffic only |

So use `localhost:9092` from your machine (or from inside the container), and `kafka:29092` from
other containers in this compose project.

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

### Persistence

Data is stored in the named Docker volume `kafka-data`, mounted at `/var/lib/kafka/data`
(`KAFKA_LOG_DIRS`). It survives `docker compose down`, and `docker compose down -v` deletes it.

## Hands-On: CLI Cheat Sheet

The Confluent image ships the tools **without** the `.sh` suffix (`kafka-topics`, not
`kafka-topics.sh`). Every command below runs inside the container, against `localhost:9092`.

Use `-it` for commands you type into interactively (producer). For one-shot commands, plain
`docker exec` is enough.

The raw commands are shown so you can see what's going on. Each one has a shorter `just`
equivalent (see [Recipes](#recipes)). For example, the pub/sub demo below is
`just consume orders billing`, `just consume orders shipping` and `just produce orders`.

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

**Terminal 3: producer** (type `key:value` lines, Ctrl+D to quit)

```sh
docker exec -it kafka-broker kafka-console-producer --bootstrap-server localhost:9092 \
  --topic orders --reader-property parse.key=true --reader-property key.separator=:
```

Now, you can type key:value into the terminal and press enter to send the messages, e.g.:

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
  rebalances automatically when a member joins or leaves.

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

Use `--dry-run` instead of `--execute` to preview a reset.

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

### Clean up

```sh
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 --delete --topic orders
docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 \
  --delete --group billing --group shipping
```

## Connecting From Your Own Code

Point any Kafka client (Python `confluent-kafka`, Java, Go, ...) at `localhost:9092`, for example:

```python
from confluent_kafka import Producer
p = Producer({"bootstrap.servers": "localhost:9092"})
p.produce("orders", key="customer1", value="order-102")
p.flush()
```

From another container in this compose project, use `kafka:29092`.

## Troubleshooting

### `AccessDeniedException` on startup (bind mounts)

Data uses a **named volume**, not a bind mount like `./kafka-data`. In this setup the Docker
daemon runs in a separate WSL distro (Docker context `wsl-shared`, socket
`/mnt/wsl/docker/docker.sock`). The CLI sends the daemon an absolute path, and the daemon resolves
it on **its own** filesystem. It doesn't exist there, so the daemon creates it root-owned, and
Kafka's non-root `appuser` (uid 1000) cannot write to it. Running `chown` on your side has no
effect. See `prompts/002-how-did-you-know-where-docker-is.out.md` for details and workarounds.

Quick check of whether a directory is visible to the daemon:

```sh
touch ./probe && docker run --rm -v "$PWD":/x alpine ls -la /x/probe; rm -f ./probe
```

### Broker won't start after changing `CLUSTER_ID`

The volume was formatted with the old ID. Run `docker compose down -v`, then `docker compose up -d`.

### Kafka UI shows the cluster as offline

Kafka UI connects to `kafka:29092` (the in-network listener), not `localhost:9092`. Check
`docker compose ps` shows the broker as `(healthy)`, then `docker logs kafka-ui`.

### `kafka-topics.sh: command not found`

Drop the `.sh` suffix. Confluent images install the tools as `kafka-topics`, `kafka-console-producer`, etc.

### Deprecation warning about `--property`

Newer versions renamed it: `--reader-property` for the producer, `--formatter-property` for the consumer.

# Kafka Cluster (2 Brokers) + Kafka UI

A multi-node Confluent Kafka cluster in **KRaft mode** (no ZooKeeper):

- 1 dedicated **controller** (`kafka-controller`): holds cluster metadata and stores no topic data.
- 2 **brokers** (`kafka-broker-1`, `kafka-broker-2`): store and serve the data.
- A one-shot `kafka-init-topics` job creates topic `orders` with **4 partitions, replication factor 2**,
  so every partition has a copy on both brokers.
- [Kafka UI](https://github.com/provectus/kafka-ui) to see it all in a browser.

| What | Where |
|---|---|
| Kafka UI | http://localhost:8082 (cluster name `cluster`) |
| Brokers, from your machine | `localhost:9092,localhost:9094` |
| Brokers, from containers (incl. `docker exec`) | `kafka-1:29092,kafka-2:29092` |

## Start / Stop

```sh
docker compose up -d                 # start everything
docker logs kafka-init-topics        # shows the created `orders` topic layout
docker compose down                  # stop (data kept in volumes)
docker compose down -v               # stop AND delete all data
```

## Layout

```text
                          ┌────────────────────────────┐
                          │ controller (node 100)      │  KRaft metadata only
                          │  controller:29093          │
                          └─────────────┬──────────────┘
                     metadata           │           metadata
               ┌────────────────────────┴───────────────────────┐
 ┌─────────────▼──────────────┐                   ┌─────────────▼──────────────┐
 │ kafka-1 (node 1)           │  replication      │ kafka-2 (node 2)           │
 │  kafka-1:29092 internal    │ ◀───────────────▶ │  kafka-2:29092 internal    │
 │  localhost:9092 host       │                   │  localhost:9094 host       │
 │  orders P1,P3 leader       │                   │  orders P0,P2 leader       │
 │  orders P0,P2 follower     │                   │  orders P1,P3 follower     │
 └────────────────────────────┘                   └────────────────────────────┘
```

## Image version

All Kafka containers are pinned to `confluentinc/cp-kafka:8.1.0`. With `:latest` (8.4.1 in Nov 2026), a
controller-only node can't start: Kafka requires `advertised.listeners`, but the image's startup script
exits if `KAFKA_ADVERTISED_LISTENERS` is set on a controller.

The 8.1.0 console tools still use `--property` (newer versions use `--reader-property` and
`--formatter-property`).

## Hands-On

Run the CLI inside a broker container, but bootstrap against the **internal** listeners. Inside
`kafka-broker-1`, `localhost:9094` means broker-1 itself, not broker-2, so `localhost` bootstrap fails
as soon as the client needs broker 2.

```sh
BS=kafka-1:29092,kafka-2:29092

# where each partition's leader and replicas live; Isr = in-sync replicas
docker exec kafka-broker-1 kafka-topics --bootstrap-server $BS --describe --topic orders

# produce key:value lines (Ctrl+D to quit)
docker exec -it kafka-broker-1 kafka-console-producer --bootstrap-server $BS --topic orders \
  --producer-property acks=all --property parse.key=true --property key.separator=:

# consume everything, showing key and partition
docker exec -it kafka-broker-1 kafka-console-consumer --bootstrap-server $BS --topic orders \
  --from-beginning --property print.key=true --property print.partition=true
```

### Simulate a broker failure

```sh
docker stop kafka-broker-2
docker exec kafka-broker-1 kafka-topics --bootstrap-server kafka-1:29092 --describe --topic orders
#   every partition now has Leader: 1 and Isr: 1. Producing and consuming keep working.
docker start kafka-broker-2
#   after a few seconds Isr goes back to 1,2 (broker 2 copied what it missed).
#   Leaders stay on broker 1 until automatic rebalancing (~5 min), or force it now:
docker exec kafka-broker-1 kafka-leader-election --bootstrap-server kafka-1:29092 \
  --election-type preferred --all-topic-partitions
```

Watch it happen in the UI under **Brokers** and **Topics → orders → Overview**.

### Replication settings

| Setting | Value | Meaning |
|---|---|---|
| `--replication-factor 2` | 2 | Each partition has a leader on one broker and a follower on the other |
| `KAFKA_MIN_INSYNC_REPLICAS` | 1 | `acks=all` writes succeed with only 1 in-sync replica, so writes keep working with one broker down. Set it to 2 for no-data-loss guarantees, but then writes stop when either broker is down |
| `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR` etc. | 2 | Internal topics (`__consumer_offsets`, transactions) survive one broker failure too |
| `KAFKA_DEFAULT_REPLICATION_FACTOR`, `KAFKA_NUM_PARTITIONS` | 2, 4 | Defaults for auto-created topics |

### Limits of this setup

- The single controller is a single point of failure for **metadata**. While it's down, existing
  leaders keep serving, but no failover, topic creation or broker join can happen. Production uses 3
  controllers (`KAFKA_CONTROLLER_QUORUM_VOTERS: 100@c1:29093,101@c2:29093,102@c3:29093`).
- With 2 brokers, losing one leaves a single copy of the data. Production typically uses 3+ brokers,
  RF 3 and `min.insync.replicas=2`.

## Troubleshooting

- **Port / container name in use:** `kafka-ui` and port `8082` are shared with other projects in this
  repo. Run `docker compose down` in the other project first.
- **`Connection to node 2 (localhost/127.0.0.1:9094) could not be established`** inside a container:
  use `kafka-1:29092,kafka-2:29092` instead of `localhost`.
- **Broker won't start after changing `CLUSTER_ID`:** run `docker compose down -v`.

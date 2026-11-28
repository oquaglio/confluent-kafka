"""Snowpipe Streaming emulator: a Kafka sink that keeps its progress in the target, like the
Snowflake Kafka connector does.

The rules it copies from the real connector (see the project README for sources):

* One channel per (connector, topic, partition). The channel stores an offset token: the last
  Kafka offset written to the table through it. Here channels live in the sf_channels table.
* When a partition is assigned, the channel's token wins: the consumer is moved to token + 1. Only
  when the token is NULL or -1 is the Kafka consumer group offset used.
* A record whose offset is <= the token counts as already ingested and is skipped.
* Rows and the new token are committed together, then token + 1 is committed back to Kafka
  (the real connector's preCommit does the same).

Nothing here knows which cluster it reads from. Point it at a new cluster with a lower log-end
offset and it will skip everything below the old token without raising an error.
"""

import json
import os
import signal
import sys
import time

import psycopg
from confluent_kafka import Consumer, KafkaException, TopicPartition

BOOTSTRAP = os.environ["BOOTSTRAP_SERVERS"]
CLUSTER = os.environ.get("CLUSTER", "?")
CONNECTOR = os.environ.get("CONNECTOR_NAME", "orders-sf")
TOPIC = os.environ.get("TOPIC", "orders")
TABLE = os.environ.get("TARGET_TABLE", "orders_sf")
GROUP = f"connect-{CONNECTOR}"  # what a Connect sink named CONNECTOR would use

running = True


def log(msg: str) -> None:
    print(f"[sf-emulator cluster={CLUSTER}] {msg}", flush=True)


def channel_name(partition: int) -> str:
    # The real connector derives the channel name from connector, topic and partition. It does NOT
    # include the Kafka cluster, which is why a re-created connector reuses the old channels.
    return f"{CONNECTOR}_{TOPIC}_{partition}".upper().replace("-", "_")


def connect_db() -> psycopg.Connection:
    for _ in range(60):
        try:
            return psycopg.connect("", autocommit=False)  # PG* env vars
        except psycopg.OperationalError as e:
            log(f"waiting for Postgres: {e}")
            time.sleep(2)
    sys.exit("Postgres not reachable")


def fetch_token(db: psycopg.Connection, partition: int) -> int | None:
    """Like getLatestCommittedOffsetToken(): opens (creates) the channel and returns its token."""
    ch = channel_name(partition)
    with db.cursor() as cur:
        cur.execute(
            """INSERT INTO sf_channels (table_name, channel_name, kafka_topic, kafka_partition)
               VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING""",
            (TABLE, ch, TOPIC, partition),
        )
        cur.execute(
            "SELECT offset_token FROM sf_channels WHERE table_name = %s AND channel_name = %s",
            (TABLE, ch),
        )
        token = cur.fetchone()[0]
    db.commit()
    return token


def main() -> None:
    db = connect_db()
    tokens: dict[int, int | None] = {}
    expected_next: dict[int, int] = {}  # where we asked Kafka to start, to spot silent resets

    consumer = Consumer(
        {
            "bootstrap.servers": BOOTSTRAP,
            "group.id": GROUP,
            "enable.auto.commit": False,
            # Connect's default for sink connectors. Used when there is no committed offset, or
            # the requested offset doesn't exist on this cluster (out of range).
            "auto.offset.reset": "earliest",
        }
    )

    def on_assign(c: Consumer, partitions: list[TopicPartition]) -> None:
        for tp in partitions:
            token = fetch_token(db, tp.partition)
            tokens[tp.partition] = token
            ch = channel_name(tp.partition)
            if token is not None and token >= 0:
                tp.offset = token + 1
                expected_next[tp.partition] = token + 1
                log(f"open channel {ch}: offset token {token} -> seek partition {tp.partition} "
                    f"to {token + 1} (Snowflake token wins over the Kafka group offset)")
            else:
                expected_next.pop(tp.partition, None)
                log(f"open channel {ch}: offset token {token} -> using the Kafka offset of group "
                    f"{GROUP} (auto.offset.reset=earliest if none)")
        c.assign(partitions)

    consumer.subscribe([TOPIC], on_assign=on_assign)
    log(f"consuming {TOPIC} from {BOOTSTRAP} as {GROUP} into {TABLE}")

    while running:
        msgs = consumer.consume(num_messages=500, timeout=1.0)
        if not msgs:
            continue

        by_partition: dict[int, list] = {}
        for m in msgs:
            if m.error():
                raise KafkaException(m.error())
            by_partition.setdefault(m.partition(), []).append(m)

        to_commit = []
        with db.cursor() as cur:
            for p, batch in by_partition.items():
                first = batch[0].offset()
                if p in expected_next and first != expected_next[p]:
                    log(f"WARNING partition {p}: asked for offset {expected_next[p]} but got {first}. "
                        f"That offset doesn't exist on this cluster, so Kafka reset the position "
                        f"(auto.offset.reset).")
                expected_next.pop(p, None)

                token = tokens.get(p)
                floor = token if token is not None else -1
                fresh = [m for m in batch if m.offset() > floor]
                skipped = len(batch) - len(fresh)

                for m in fresh:
                    v = json.loads(m.value())["payload"]
                    cur.execute(
                        f"""INSERT INTO {TABLE} (seq, ts_ms, cluster, kafka_topic, kafka_partition, kafka_offset)
                            VALUES (%s, %s, %s, %s, %s, %s)""",
                        (v["seq"], v["ts_ms"], v["cluster"], m.topic(), p, m.offset()),
                    )
                if fresh:
                    token = fresh[-1].offset()
                    cur.execute(
                        """UPDATE sf_channels SET offset_token = %s, updated_at = now()
                           WHERE table_name = %s AND channel_name = %s""",
                        (token, TABLE, channel_name(p)),
                    )
                    tokens[p] = token

                msg = (f"partition {p}: read offsets {first}-{batch[-1].offset()}, "
                       f"inserted {len(fresh)}")
                if skipped:
                    msg += f", SKIPPED {skipped} as already ingested (offset <= token {floor})"
                log(msg)

                if token is not None and token >= 0:
                    to_commit.append(TopicPartition(TOPIC, p, token + 1))
        db.commit()  # rows + token in one transaction
        if to_commit:
            consumer.commit(offsets=to_commit, asynchronous=False)

    log("stopping")
    consumer.close()
    db.close()


def stop(*_):
    global running
    running = False


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    main()

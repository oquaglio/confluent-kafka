"""Send random sensor readings as JSON to Kafka.

Environment:
  BOOTSTRAP_SERVERS  default localhost:9092 (use broker:29092 inside the compose network)
  TOPIC              default sensor-data
  RATE               messages per second, 0 = as fast as possible (default 0)
  DURATION           seconds to run, 0 = until Ctrl+C / SIGTERM (default 0)
"""

import json
import os
import random
import signal
import time
from datetime import datetime, timezone

from kafka import KafkaProducer

bootstrap_servers = os.environ.get("BOOTSTRAP_SERVERS", "localhost:9092")
topic = os.environ.get("TOPIC", "sensor-data")
rate = float(os.environ.get("RATE", "0"))
duration = float(os.environ.get("DURATION", "0"))

devices = ["device_1", "device_2", "device_3"]
tags = ["temperature", "humidity", "pressure"]


def generate_sensor_data():
    device_id = random.choice(devices)
    tag = random.choice(tags)
    value = round(random.uniform(20.0, 100.0), 2)
    # ISO timestamp without timezone, e.g. 2026-11-27T10:15:30.123 (parsed by sensor_source)
    timestamp = (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "")
    )
    return {"device_id": device_id, "tag": tag, "value": value, "timestamp": timestamp}


def main():
    # `docker stop` sends SIGTERM: treat it like Ctrl+C so the producer flushes.
    signal.signal(signal.SIGTERM, signal.default_int_handler)

    producer = KafkaProducer(
        bootstrap_servers=bootstrap_servers,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
    )
    deadline = time.monotonic() + duration if duration > 0 else None
    interval = 1 / rate if rate > 0 else 0
    sent = 0

    print(
        f"Producing to '{topic}' on {bootstrap_servers} "
        f"(rate={rate or 'max'}/s, duration={duration or 'until stopped'}s). Ctrl+C to stop."
    )
    try:
        while deadline is None or time.monotonic() < deadline:
            data = generate_sensor_data()
            producer.send(topic, value=data)
            sent += 1
            print(f"Sent: {data}")
            if interval:
                time.sleep(interval)
    except KeyboardInterrupt:
        print("Stopping producer...")
    finally:
        producer.flush()
        producer.close()
        print(f"Sent {sent} messages.")


if __name__ == "__main__":
    main()

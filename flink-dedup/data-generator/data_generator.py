import json
import random
from datetime import datetime, timezone

from kafka import KafkaProducer

bootstrap_servers = "localhost:9092"
topic = "sensor-data"
producer = KafkaProducer(
    bootstrap_servers=bootstrap_servers,
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)
devices = ["device_1", "device_2", "device_3"]
tags = ["temperature", "humidity", "pressure"]


def generate_sensor_data():
    device_id = random.choice(devices)
    tag = random.choice(tags)
    value = round(random.uniform(20.0, 100.0), 2)
    # timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    timestamp = (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "")
    )
    return {"device_id": device_id, "tag": tag, "value": value, "timestamp": timestamp}


try:
    print("Producing sensor data to Kafka topic 'sensor-data'. Press Ctrl+C to stop.")
    while True:
        data = generate_sensor_data()
        producer.send(topic, value=data)
        print(f"Sent: {data}")
        # time.sleep(1)
except KeyboardInterrupt:
    print("Stopping producer...")
finally:
    producer.flush()
    producer.close()

#

## 1 - just up

```sh
just up
```

1. Build the images: docker compose --profile emulator build

It builds the three local images:

- connect: cp-kafka-connect:8.1.0 plus the JDBC connector plugin, used by both connect-a and connect-b
- postgres: postgres:17 with init.sql baked in
- sf-emulator: Python 3.13 with confluent-kafka and psycopg, plus sf_emulator.py

The profile is passed so the emulator image gets built too, even though the emulators aren't started yet. The first build downloads the plugin and the Python packages; later builds come from the cache.

1. Start the stack: docker compose up -d --wait

This starts everything without a profile: kafka-a, kafka-b, postgres, connect-a, connect-b and kafka-ui. --wait blocks until every healthcheck passes. That means both brokers answer, Postgres accepts connections, and both Connect REST APIs respond, which usually takes 30–60 seconds. On a first start with an empty volume, Postgres runs init.sql and creates the tables and the token-reset function.

1. Reset: scripts/reset.sh

This creates topic orders with 1 partition on both clusters, and makes sure there are no leftover connectors, groups, rows or seq counter, in case the volumes still hold data from a previous run.

It then prints the URLs and suggests just s1 or just s2.

What it doesn't do: start the emulators, create any connector, or produce data. The scenario scripts do those, at the moment each step needs them.

Also, before any of this, lib.sh copies .env.example to .env if there's no .env yet. That's where the Postgres credentials come from.

## 2 -

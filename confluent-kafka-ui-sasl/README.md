# Kafka Broker + Kafka UI with SASL/SCRAM

A single-node Confluent Kafka broker (`confluentinc/cp-kafka`) running in **KRaft mode** (no ZooKeeper),
with client **authentication** turned on using **SASL/SCRAM-SHA-512**, plus
[Kafka UI](https://github.com/provectus/kafka-ui) (`provectuslabs/kafka-ui`), which logs in to the
broker with a username and password.

This is `../confluent-kafka-ui` with authentication added. Read that README first for the Kafka basics
(topics, partitions, consumer groups, pub/sub). This one focuses on what changes once clients have to
log in.

| What | Where |
|---|---|
| Kafka UI | http://localhost:8082 (cluster name `local`, no UI login) |
| Broker, SASL listener | `kafka-broker:9092` (port 9092 is published to your machine) |
| Broker, internal listener (no auth) | `kafka-broker:29092` (compose network only) |
| Username / password | `admin` / `admin-secret` |
| SASL mechanism | `SCRAM-SHA-512` over `SASL_PLAINTEXT` |

## Docs

- https://kafka.apache.org/documentation/#security_sasl_scram
- https://docs.confluent.io/platform/current/security/authentication/sasl/scram/overview.html
- https://docs.kafka-ui.provectus.io/configuration/authentication-methods (SASL client settings)

## Start / Stop

```sh
docker compose up -d            # start broker + UI
docker logs -f kafka-broker     # follow broker logs (Ctrl+C to stop following)
docker logs -f kafka-ui         # follow UI logs
docker compose down             # stop (data is kept in the volume)
docker compose down -v          # stop AND delete all Kafka data, including the admin user
```

The broker is ready once its log shows `Kafka Server started`. The UI may take a few more seconds,
then shows the `local` cluster as **online** on its dashboard.

Other projects in this repo use the same container names and ports, so stop them first
(`docker compose down` in their folder).

## What Is SASL?

**SASL** (Simple Authentication and Security Layer, RFC 4422) is a general framework for adding
*authentication* to a network protocol. It defines a handshake, and you plug in a **mechanism** that
decides how the client proves who it is. Kafka supports these mechanisms:

| Mechanism | How the client proves its identity |
|---|---|
| `PLAIN` | Sends username and password as they are. The broker checks them against a list. |
| `SCRAM-SHA-256` / `SCRAM-SHA-512` | Challenge-response: the client proves it knows the password **without sending it**. The broker stores only salted hashes. |
| `GSSAPI` | Kerberos tickets (common in enterprise / Active Directory setups). |
| `OAUTHBEARER` | An OAuth 2 / OIDC token. |

This project uses **SCRAM-SHA-512** (Salted Challenge Response Authentication Mechanism). In short:

1. The client sends its username and a random nonce.
2. The broker replies with the user's salt, an iteration count (4096 here) and its own nonce.
3. The client derives a key from the password + salt and sends back a *proof*.
4. The broker checks the proof against the stored hash, then sends its own signature, so the client
   knows the broker really has the credential too (mutual authentication).

SCRAM credentials live in Kafka's own metadata (the KRaft `__cluster_metadata` log), so you can
add users, remove them and change passwords at runtime with `kafka-configs`. No restart is needed.

### Authentication is not encryption, and not authorization

The words in a Kafka *security protocol* name describe two separate things:

| Security protocol | Authenticated? | Encrypted on the wire? |
|---|---|---|
| `PLAINTEXT` | no | no |
| `SASL_PLAINTEXT` (**this project**) | yes | no |
| `SSL` | optional (mTLS) | yes |
| `SASL_SSL` (what production should use) | yes | yes |

So here the password is never sent (thanks to SCRAM), but every message is still readable by anyone
who can sniff the traffic.

**Authentication** answers "who are you?". **Authorization** (ACLs) answers "what may you do?". This
project only has authentication: any user who logs in can do *everything*. See
[Known quirks](#known-quirks-in-the-compose-file).

## How This Differs From `confluent-kafka-ui`

| | `confluent-kafka-ui` | `confluent-kafka-ui-sasl` (this) |
|---|---|---|
| Client authentication | none | SASL/SCRAM-SHA-512, user `admin` |
| Listener on port 9092 | `PLAINTEXT_HOST`, advertised as `localhost:9092` | `SASL_PLAINTEXT`, advertised as **`kafka-broker:9092`** |
| Internal listener | `PLAINTEXT` on `kafka:29092` | `INTERNAL` (plaintext) on `kafka-broker:29092` |
| Broker address for containers | `kafka:29092` | `kafka-broker:9092` (SASL) |
| How the UI connects | plain bootstrap address | bootstrap + `SECURITY_PROTOCOL`, `SASL_MECHANISM`, `SASL_JAAS_CONFIG` |
| JAAS config | none | `KAFKA_OPTS` points at `/etc/kafka/jaas.conf`, injected with a compose `configs:` entry |
| Startup command | image default | runs `kafka-storage format --add-scram ...` first, to create the `admin` user |
| CLI tools | just `--bootstrap-server` | also need `--command-config` with the credentials |
| Docker network | compose default | explicit `kafka-network` bridge; container `hostname: kafka-broker` |
| Clients on your machine | work out of the box | need a hosts entry for `kafka-broker` to produce/consume (see [From your machine](#from-your-machine-kcat)) |

Everything else is the same: single KRaft node, cluster ID, replication factor 1, named volume
`kafka-data` (here `confluent-kafka-ui-sasl_kafka-data`), and the same Kafka UI pages.

## How the Pieces Fit

```text
 your machine                         kafka-network (compose)
 ┌──────────────┐  localhost:9092    ┌─────────────────────────────────────┐
 │ kcat / your  │ ─────────────────▶ │ kafka   (hostname kafka-broker)     │
 │ code         │  SASL/SCRAM        │  :9092  SASL_PLAINTEXT  ◀───────────┼──┐
 │              │                    │  :29092 INTERNAL (plain, no auth)   │  │ kafka-broker:9092
 │ browser      │  localhost:8082    │  :29093 CONTROLLER                  │  │ user admin
 │              │ ─────────────────▶ └─────────────────────────────────────┘  │
 └──────────────┘                    ┌─────────────────────────────────────┐  │
                                     │ kafka-ui  :8080                     │──┘
                                     └─────────────────────────────────────┘
```

## Concepts This Project Covers

The Kafka basics (KRaft, topics, partitions, keys, pub/sub, consumer groups, offsets, lag, persistence)
are explained in `../confluent-kafka-ui/README.md`. The new concepts are below.

### Listeners and security protocols

Each listener has a name, and `KAFKA_LISTENER_SECURITY_PROTOCOL_MAP` maps each name to a security
protocol:

| Listener | Bind | Advertised as | Protocol | Used by |
|---|---|---|---|---|
| `SASL_PLAINTEXT` | `0.0.0.0:9092` | `kafka-broker:9092` | `SASL_PLAINTEXT` | Kafka UI, CLI tools, your code |
| `INTERNAL` | `0.0.0.0:29092` | `kafka-broker:29092` | `PLAINTEXT` | Broker-to-broker traffic (`KAFKA_INTER_BROKER_LISTENER_NAME`) |
| `CONTROLLER` | `0.0.0.0:29093` | - | `PLAINTEXT` | KRaft controller traffic only |

Two things to notice:

- **The internal listener has no authentication.** Anything on the compose network can connect to
  `kafka-broker:29092` without a password, and it is a full client listener. It isn't published to
  your machine, so it's only reachable from containers. This is a common pattern: authenticate
  external clients, trust the internal network. In production you'd lock it down too.
- **The SASL listener is advertised as `kafka-broker:9092`, not `localhost:9092`.** A client first
  connects to its bootstrap address, then uses the *advertised* address for everything after. That
  works for containers on `kafka-network`. On your machine, `kafka-broker` doesn't resolve unless you
  add it to your hosts file (next section).

### JAAS: where clients and the broker get SASL settings

**JAAS** (Java Authentication and Authorization Service) is how Java picks a login module and its
options. Kafka uses it for SASL settings in two forms:

- A **file** passed with `-Djava.security.auth.login.config=...` (`KAFKA_OPTS` here). The
  `KafkaServer { ... }` section applies to the broker.
- A **property** `sasl.jaas.config`, either per listener on the broker
  (`listener.name.sasl_plaintext.scram-sha-512.sasl.jaas.config`, set by
  `KAFKA_LISTENER_NAME_SASL_PLAINTEXT_SCRAM_SHA_512_SASL_JAAS_CONFIG`) or on a client.

On the broker, the per-listener property takes precedence over the file.

For SCRAM, the broker doesn't read passwords from JAAS. It checks clients against the SCRAM
credentials stored in the cluster metadata. The `username`/`password` in a `KafkaServer` section would
only be used if the broker itself logged in to another broker over SASL, which doesn't happen here
(inter-broker traffic uses the plaintext `INTERNAL` listener).

On a **client**, `sasl.jaas.config` carries the actual username and password:

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="admin-secret";
```

Non-Java clients (kcat, Python `confluent-kafka`, Go, ...) are built on librdkafka and use
`sasl.username` / `sasl.password` instead of a JAAS string.

### Bootstrapping SCRAM users in KRaft mode

SCRAM credentials are stored in the cluster metadata, but you need a working login to add one.
To break that chicken-and-egg problem, KRaft lets you create users when the storage is
**formatted**, before the broker starts. That's what the custom `command:` does:

```sh
/etc/confluent/docker/configure          # turn KAFKA_* env vars into /etc/kafka/kafka.properties
kafka-storage format --config /etc/kafka/kafka.properties --cluster-id $CLUSTER_ID \
  --add-scram "SCRAM-SHA-512=[name=admin,password=admin-secret]" \
  --ignore-formatted                     # skip if the volume is already formatted
/etc/confluent/docker/run                # start the broker as usual
```

`$$CLUSTER_ID` in the compose file is escaped so that the container's shell, not Compose, expands it.

Because of `--ignore-formatted`, the `admin` user is only created on the **first** start with an
empty volume. Changing the password in `docker-compose.yml` later has no effect until you run
`docker compose down -v`. Change it at runtime with `kafka-configs` instead
([Manage users](#manage-scram-users)).

### Kafka UI as a SASL client

Kafka UI passes any `KAFKA_CLUSTERS_0_PROPERTIES_*` variable straight to its Kafka clients
(`SECURITY_PROTOCOL` → `security.protocol`, and so on):

| Variable | Meaning |
|---|---|
| `KAFKA_CLUSTERS_0_BOOTSTRAP_SERVERS: kafka-broker:9092` | Connect to the SASL listener |
| `KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL: SASL_PLAINTEXT` | Authenticate, don't encrypt |
| `KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM: SCRAM-SHA-512` | Must be one of the broker's `KAFKA_SASL_ENABLED_MECHANISMS` |
| `KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG: ...` | The username and password |

If the credentials are wrong, the UI shows the cluster as **offline** and `docker logs kafka-ui`
shows `SaslAuthenticationException`. The UI has **no login page of its own**: anyone who can reach
port 8082 uses the broker as `admin`.

## Hands-On: Kafka UI

Open http://localhost:8082 and pick the `local` cluster. Everything works the same as in
`confluent-kafka-ui`. See that README for a page-by-page table and a step-by-step pub/sub
walkthrough. In short:

- **Topics**: list topics (toggle *Show Internal Topics*), **Add a Topic**.
- **Topics → *topic* → Produce Message**: publish a record. **Messages**: browse records, or tail
  them in **Live** mode.
- **Consumers**: consumer groups, their members, committed offsets and **lag**.
- **Brokers → 1 → Configs**: search for `sasl` or `listener` to see this project's security settings
  as the broker sees them.

## Hands-On: CLI Inside the Broker Container

The Confluent image ships the tools **without** `.sh` (`kafka-topics`, not `kafka-topics.sh`). On the
SASL listener, every tool needs the client settings in a properties file. Create it once inside the
container (it's lost when the container is recreated):

```sh
docker exec kafka-broker bash -c 'cat > /tmp/client.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="admin-secret";
EOF'
```

Then pass it with `--command-config` (older tutorials use `--consumer.config` / `--producer.config`;
those still work).

### See authentication in action

```sh
# with credentials: works
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --list

# without credentials on the SASL port: hangs with no output (Ctrl+C). The broker logs
# "Unexpected Kafka request of type METADATA during SASL handshake".
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 --list

# wrong password: fails fast
docker exec kafka-broker bash -c \
  'sed s/admin-secret/wrong/ /tmp/client.properties > /tmp/bad.properties'
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/bad.properties --list
#   ... SaslAuthenticationException: Authentication failed during authentication
#       due to invalid credentials with SASL mechanism SCRAM-SHA-512

# the internal listener: no credentials needed
docker exec kafka-broker kafka-topics --bootstrap-server localhost:29092 --list
```

Failed logins show up in the broker log:

```sh
docker logs kafka-broker 2>&1 | grep "Failed authentication"
```

### List / create / describe topics

```sh
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --list

docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties \
  --create --topic orders --partitions 3 --replication-factor 1

docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --describe --topic orders
```

### See pub/sub live (use 3 terminals)

**Terminal 1: consumer in group `billing`**

```sh
docker exec -it kafka-broker kafka-console-consumer --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --topic orders --group billing \
  --formatter-property print.key=true --formatter-property print.partition=true
```

**Terminal 2: consumer in a *different* group `shipping`** (same command, different `--group`)

```sh
docker exec -it kafka-broker kafka-console-consumer --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --topic orders --group shipping \
  --formatter-property print.key=true --formatter-property print.partition=true
```

**Terminal 3: producer** (type `key:value` lines, Ctrl+D to quit). Or use **Produce Message** in the UI.

```sh
docker exec -it kafka-broker kafka-console-producer --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --topic orders \
  --reader-property parse.key=true --reader-property key.separator=:
```

```text
> customer1:order-100
> customer2:order-200
> customer1:order-101
```

Both groups get every message (pub/sub). Start a second `billing` consumer and the two split the
partitions between them (queue behaviour). **Consumers** in the UI shows both groups and their
members.

### Consumer groups, offsets and lag

```sh
docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --list

docker exec kafka-broker kafka-consumer-groups --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --describe --group billing

docker exec kafka-broker kafka-get-offsets --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --topic orders
```

### Manage SCRAM users

```sh
# list users that have SCRAM credentials
docker exec kafka-broker kafka-configs --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --describe --entity-type users
#   SCRAM credential configs for user-principal 'admin' are SCRAM-SHA-512=iterations=4096

# add a user (or change their password): takes effect immediately, no restart
docker exec kafka-broker kafka-configs --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --alter --entity-type users --entity-name alice \
  --add-config 'SCRAM-SHA-512=[password=alice-secret]'

# remove a user
docker exec kafka-broker kafka-configs --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --alter --entity-type users --entity-name alice \
  --delete-config 'SCRAM-SHA-512'
```

Only the salted hash and iteration count are stored, so the password itself can't be read back.

With no authorizer configured, `alice` can do everything `admin` can, including deleting topics.

### Clean up

```sh
docker exec kafka-broker kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/client.properties --delete --topic orders
```

Or delete everything with `docker compose down -v`.

## From Your Machine (kcat)

[kcat](https://github.com/edenhill/kcat) (formerly `kafkacat`) is a small command-line Kafka client.

```sh
sudo apt-get install kcat      # Debian 12+ / Ubuntu 22.04+ (older releases: package and command "kafkacat")
brew install kcat              # macOS
```

Don't use the `edenhill/kcat:1.7.1` Docker image: its bundled librdkafka fails SCRAM login against
this broker with "invalid credentials", even when the password is right. The `kcat` package from
current Debian/Ubuntu works.

Save typing with a shell variable:

```sh
KCAT_SASL="-X security.protocol=SASL_PLAINTEXT -X sasl.mechanism=SCRAM-SHA-512 \
  -X sasl.username=admin -X sasl.password=admin-secret"
```

### List metadata (brokers, topics, partitions)

```sh
kcat -b localhost:9092 $KCAT_SASL -L
```

```text
Metadata for all topics (from broker -1: sasl_plaintext://localhost:9092/bootstrap):
 1 brokers:
  broker 1 at kafka-broker:9092 (controller)
 1 topics:
  topic "orders" with 3 partitions:
```

This works without any extra setup, because `-L` only talks to the bootstrap address. But notice
`broker 1 at kafka-broker:9092`: that's the advertised address, and producing or consuming needs
it.

### Make `kafka-broker` resolvable

Without a hosts entry, produce/consume fails with
`Failed to resolve 'kafka-broker:9092': Name or service not known`. Fix it by mapping the name to
your machine:

```sh
echo "127.0.0.1 kafka-broker" | sudo tee -a /etc/hosts
```

On WSL, `/etc/hosts` is regenerated at startup unless `/etc/wsl.conf` has
`[network]` / `generateHosts = false`. Add the entry to the Windows hosts file
(`C:\Windows\System32\drivers\etc\hosts`) instead, and WSL copies it over.

The alternative is to advertise `localhost:9092` as `confluent-kafka-ui` does, with a separate
SASL listener for the containers. That changes the compose file, so it isn't done here.

### Produce and consume

```sh
# produce key:value lines (Ctrl+D to finish)
kcat -b localhost:9092 $KCAT_SASL -P -t orders -K:

# read everything and exit, showing partition, offset and key
kcat -b localhost:9092 $KCAT_SASL -C -t orders -e -f 'p=%p o=%o key=%k value=%s\n'

# consume as part of consumer group "billing" (shows up under Consumers in the UI)
kcat -b localhost:9092 $KCAT_SASL -G billing -X auto.offset.reset=earliest orders
```

kcat and Python `confluent-kafka` use librdkafka's default partitioner, which hashes keys
differently from the Java client. The same key always lands on the same partition *within* one
client type, but kcat and `kafka-console-producer` may put it on different partitions.

### Your own code

```python
from confluent_kafka import Producer

p = Producer({
    "bootstrap.servers": "localhost:9092",
    "security.protocol": "SASL_PLAINTEXT",
    "sasl.mechanism": "SCRAM-SHA-512",
    "sasl.username": "admin",
    "sasl.password": "admin-secret",
})
p.produce("orders", key="customer1", value="order-102")
p.flush()
```

From a container on `kafka-network`, use `bootstrap.servers: kafka-broker:9092` and no hosts entry is
needed.

## Files

| File | Used? | Purpose |
|---|---|---|
| `docker-compose.yml` | yes | Broker + UI. The broker's JAAS file is defined inline under `configs: jaas:`. |
| `jaas.conf` | no | Same content as the inline config. Left over from when it was bind-mounted. |
| `update_format.sh` | no | Earlier attempt at adding the SCRAM user by appending to the image's `ensure` script. Replaced by the `command:` override. |

The inline `configs:` entry replaced a bind mount, because bind mounts fail when Docker runs in a
different WSL distro (see `../confluent-kafka-ui/README.md`, Troubleshooting).

## Known Quirks in the Compose File

These don't break anything, but they're worth knowing when you copy this setup:

- **`KAFKA_SUPER_USERS: User:admin` has no effect.** Super users only matter when an authorizer is
  enabled (`KAFKA_AUTHORIZER_CLASS_NAME: org.apache.kafka.metadata.authorizer.StandardAuthorizer`),
  and none is. Every authenticated user can do everything. If you enable the authorizer, also give
  the inter-broker and controller principals access (or make them super users), or the broker
  can't start.
- **`KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAINTEXT` isn't a valid mechanism.** Valid values
  are `PLAIN`, `SCRAM-SHA-256`, `SCRAM-SHA-512`, etc. It's ignored because inter-broker traffic uses
  the plaintext `INTERNAL` listener.
- **The internal listener on 29092 needs no password**, and so is a way around SASL for anything on
  `kafka-network`.
- **Passwords are in plain text** in `docker-compose.yml`. Fine for local learning. Real setups use
  secrets or environment files kept out of git.
- **`provectuslabs/kafka-ui:latest` is v0.7.2 (April 2024)** and no longer updated. The maintained fork
  is [kafbat/kafka-ui](https://github.com/kafbat/kafka-ui) (`ghcr.io/kafbat/kafka-ui`), with the same
  environment variables.

## Troubleshooting

### UI shows the cluster as offline

- `docker logs kafka-ui | grep -i sasl`: `SaslAuthenticationException` means wrong credentials or
  mechanism.
- Changed `admin-secret` in the compose file after the first start? The stored password is still the
  old one. Run `docker compose down -v` or change it with `kafka-configs`.

### CLI command hangs with no output

You connected to port 9092 without `--command-config`. The broker waits for a SASL handshake that
never comes.

### `Failed to resolve 'kafka-broker:9092'` from your machine

Add the hosts entry, see [Make `kafka-broker` resolvable](#make-kafka-broker-resolvable).

### Port already allocated / container name already in use

Other projects in this repo use the same names (`kafka-broker`, `kafka-ui`) and ports (9092, 8082).
Run `docker compose down` there first.

### `kafka-topics.sh: command not found`

Drop the `.sh` suffix.

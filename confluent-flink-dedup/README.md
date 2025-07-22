# Flink Dedup PoC

## Confluent
https://docs.confluent.io/platform/current/get-started/platform-quickstart.html

git clone https://github.com/confluentinc/cp-all-in-one
cd cp-all-in-one/cp-all-in-one
OR:
wget https://raw.githubusercontent.com/confluentinc/cp-all-in-one/7.9.1-post/cp-all-in-one/docker-compose.yml

Control Center: http://localhost:9021
The Flink Job Manager is available at [http://localhost:9081](http://localhost:9081)

## Download JARs for Connector
NOTE: Don't do it this way. Just run the wgets below.
```SH
chmod +x flink_setup.sh
./flink_setup.sh
```
## Get JARs
NOTE: Jars need to be the correct versions for Flink and they must be in /opt/flink/lib so they get loaded
by the classloader.
```SH
# JDBC connector (Flink 1.18+)
wget https://repo1.maven.org/maven2/org/apache/flink/flink-connector-jdbc/3.2.0-1.19/flink-connector-jdbc-3.2.0-1.19.jar -P jars

# PostgreSQL JDBC driver
wget https://jdbc.postgresql.org/download/postgresql-42.7.3.jar -P ./jars
```
## Build Images
```SH
docker build -f Dockerfile.sql-client -t flink-sql-client-with-jars:latest .
docker build -f Dockerfile.flink-cnf -t flink-cnf-with-jdbc:1.19.1 .
```

## Start Compose
``` SH
docker compose up -d
```
Check logs:
```SH
docker compose logs -f broker
docker compose logs -f postgres
```
Check postgres starts ok:
```SH
docker logs postgres
```

Check postgres table created ok:
```SH
docker exec -it postgres psql -U flink_user -d flink_demo -c "\d sensor_readings"
```
Or using psql:
```SH
psql -h localhost -p 5433 -U flink_user -d flink_demo -c "\d sensor_readings"
```



```SH
docker cp jars/flink-connector-jdbc-3.3.0-1.19.jar flink-sql-client:/opt/flink/lib/
docker cp jars/postgresql-42.7.4.jar flink-sql-client:/opt/flink/lib/

docker cp jars/flink-connector-jdbc-3.3.0-1.19.jar flink-jobmanager:/opt/flink/lib/
docker cp jars/postgresql-42.7.4.jar flink-jobmanager:/opt/flink/lib/

docker cp jars/flink-connector-jdbc-3.3.0-1.19.jar flink-taskmanager:/opt/flink/lib/
docker cp jars/postgresql-42.7.4.jar flink-taskmanager:/opt/flink/lib/
```
Verify:
```SH
docker exec -it flink-sql-client ls -l /opt/flink/lib
docker exec -it flink-jobmanager ls -l /opt/flink/lib
docker exec -it flink-taskmanager ls -l /opt/flink/lib
```
Restart:
```SH
docker compose restart
```
Check what's on the classpath in: http://localhost:9081/#/job-manager/config
Check for startup errors:
```SH
docker logs flink-sql-client
docker logs flink-jobmanager
docker logs flink-taskmanager
```

## Create Kafka Topic
NOTE: You don't need this step; as soon as you start producing data to the topic it will automatically be created.
```SH
docker exec broker kafka-topics --create \
  --bootstrap-server broker:9092 \
  --topic sensor-data \
  --partitions 1 --replication-factor 1
```

## Init Flink SQL Client
Launch the Flink SQL CLI:
```SH
docker exec -it flink-sql-client /opt/flink/bin/sql-client.sh
```
## Run the Flink SQLs
NOTE: You might need to run the insert after you start generating data or it will finish? TBC
In the SQL client, execute the SQL script:
``` SH
SET 'execution.checkpointing.interval' = '1000ms';
SOURCE '/opt/flink-sql/flink_sql_streaming_pipeline.sql';
SOURCE '/opt/flink-sql/flink_sql_dedup.sql';
```
Or:
```SH
docker exec -it flink-sql-client /opt/flink/bin/sql-client.sh -f /opt/flink-sql/flink_sql_streaming_pipeline.sql
```
Or:
Just run the flink SQLs directly.

## Create Virt Env and Install Python Deps
```SH
py_ver=3.12.11; env_name=confluent-kafka
pyenv virtualenv $py_ver $env_name; pyenv activate $env_name; pip install -r data-generator/requirements.txt
pip install pipdeptree
pipdeptree
```
Activate existing:
```SH
env_name=confluent-kafka;
pyenv activate $env_name;
```

## Run Data Producer
In a terminal, run the Python producer:
```SH
python data-generator/data_generator.py
```
This generates sensor data and sends it to the sensor-data topic.
Check results at: http://localhost:9081/#/overview

## Verify Results
Query PostgreSQL to see deduplicated data:
``` SH
docker exec -it postgres psql -h localhost -p 5432 -U flink_user -d flink_demo -c "SELECT * FROM sensor_readings;"
```
Each device_id and tag combination will have only the latest value and timestamp.


## Check Data is on the Topic
```SH
docker exec -it broker kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic sensor-data \
  --from-beginning
```

## Run Flink Queries to Verify Topic Data
Get total record count:
```SQL
SELECT COUNT(*) AS total_records
FROM sensor_source;
```
Return duplicates by (device_id, tag, timestamp):
```SQL
SELECT
  device_id,
  tag,
  `timestamp`,
  COUNT(*) AS cnt
FROM sensor_source
GROUP BY device_id, tag, `timestamp`
HAVING COUNT(*) > 1;
```
Get total duplicates (-1 for the original unique record):
```SQL
SELECT SUM(cnt - 1) AS total_duplicate_rows
FROM (
  SELECT COUNT(*) AS cnt
  FROM sensor_source
  GROUP BY device_id, tag, `timestamp`
  HAVING COUNT(*) > 1
) t;

```

## Verify Output
Consume messages from the deduped_tag_data topic to verify the deduplication:
kafka_container_id=''
docker exec -it $kafka_container_id kafka-console-consumer --bootstrap-server kafka:9092 --topic deduped_tag_data --from-beginning


## Cleanup
```SH
docker compose down -v
docker volume rm postgres_data
docker volume rm kafka_data
```

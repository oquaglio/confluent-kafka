-- Create source table for Kafka topic
CREATE TABLE sensor_source (
    device_id STRING,
    tag STRING,
    `value` DOUBLE,  -- Escaped reserved keyword
    `timestamp` STRING,
    event_time AS CAST(REPLACE(`timestamp`, 'T', ' ') AS TIMESTAMP(3)),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'sensor-data',
    'properties.bootstrap.servers' = 'broker:29092',
    'scan.startup.mode' = 'earliest-offset',
    'value.format' = 'json',
    'value.json.fail-on-missing-field' = 'false',
    'value.json.ignore-parse-errors' = 'true'
);

DROP TABLE IF EXISTS sensor_sink;

-- Create sink table for PostgreSQL
CREATE TABLE sensor_sink (
    device_id STRING,
    tag STRING,
    `value` DOUBLE,  -- Escaped reserved keyword
    `timestamp` TIMESTAMP(3),
    PRIMARY KEY (device_id, tag, `timestamp`) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://postgres:5432/flink_demo',
    'table-name' = 'sensor_readings',
    'username' = 'flink_user',
    'password' = 'flink_pass',
    'sink.buffer-flush.max-rows' = '100',
    'sink.buffer-flush.interval' = '1s'
);

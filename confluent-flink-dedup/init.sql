CREATE TABLE sensor_readings (
    device_id VARCHAR(50),
    tag VARCHAR(50),
    value DOUBLE PRECISION,
    timestamp TIMESTAMP,
    PRIMARY KEY (device_id, tag, timestamp)
);

CREATE TABLE sensor_duplicates (
    device_id VARCHAR(50),
    tag VARCHAR(50),
    value DOUBLE PRECISION,
    timestamp TIMESTAMP
);

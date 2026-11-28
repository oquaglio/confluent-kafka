-- Target tables for both sinks, plus the emulated Snowflake channel metadata.

-- Scenario 1: written by the Confluent JDBC sink (upsert on seq).
CREATE TABLE orders_jdbc (
    seq       BIGINT PRIMARY KEY,
    ts_ms     BIGINT NOT NULL,   -- producer timestamp (epoch ms)
    cluster   TEXT   NOT NULL,   -- which cluster the record was produced to: a | b
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Scenario 2: written by the Snowpipe Streaming emulator. No primary key on purpose: Snowflake
-- doesn't enforce one either, so a replay shows up as duplicates you have to clean up yourself.
-- kafka_* columns play the role of the connector's RECORD_METADATA column.
CREATE TABLE orders_sf (
    seq             BIGINT NOT NULL,
    ts_ms           BIGINT NOT NULL,
    cluster         TEXT   NOT NULL,
    kafka_topic     TEXT   NOT NULL,
    kafka_partition INT    NOT NULL,
    kafka_offset    BIGINT NOT NULL,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per channel, i.e. per (connector, topic, partition), like Snowflake's SHOW CHANNELS.
-- offset_token is the last Kafka offset committed into the table through this channel.
-- NULL = never written; -1 = explicitly reset (both mean "use the Kafka consumer offset").
CREATE TABLE sf_channels (
    table_name      TEXT   NOT NULL,
    channel_name    TEXT   NOT NULL,
    kafka_topic     TEXT   NOT NULL,
    kafka_partition INT    NOT NULL,
    offset_token    BIGINT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (table_name, channel_name)
);

-- Stand-in for Snowflake's SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN(table, channel, token).
-- Only safe while the connector is stopped, exactly as for the real function.
CREATE FUNCTION sf_update_channel_offset_token(p_table TEXT, p_channel TEXT, p_token BIGINT)
RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    UPDATE sf_channels SET offset_token = p_token, updated_at = now()
     WHERE table_name = p_table AND channel_name = p_channel;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'channel % on table % does not exist', p_channel, p_table;
    END IF;
    RETURN format('offset token of %s set to %s', p_channel, p_token);
END $$;

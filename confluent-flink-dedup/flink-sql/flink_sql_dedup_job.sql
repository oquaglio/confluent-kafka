-- Deduplication query using ROW_NUMBER
INSERT INTO sensor_sink
SELECT
    device_id,
    tag,
    `value`,  -- Escaped reserved keyword
    event_time AS `timestamp`
FROM (
    SELECT
        device_id,
        tag,
        `value`,  -- Escaped reserved keyword
        event_time,
        ROW_NUMBER() OVER (
            PARTITION BY device_id, tag, event_time
            ORDER BY event_time DESC
        ) AS rownum
    FROM sensor_source
) WHERE rownum = 1;

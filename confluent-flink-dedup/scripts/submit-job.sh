#!/usr/bin/env bash
# One-shot: submit the dedup job unless it's already running, then wait until Flink reports it RUNNING.
# Runs in the SQL client image, whose flink-conf.yaml already points at flink-jobmanager:9081.
set -euo pipefail

JOB_NAME="${JOB_NAME:-sensor-dedup}"
REST="${FLINK_REST:-http://flink-jobmanager:9081}"
WAIT_SECS="${WAIT_SECS:-60}"

job_running() {
  local jobs
  jobs=$(curl -fsS "$REST/jobs/overview") || { echo "Can't reach Flink REST API at $REST" >&2; exit 1; }
  # {"jobs":[{...},{...}]}: one job per line, then match name and state on the same line.
  tr '}' '\n' <<<"$jobs" | grep "\"name\":\"$JOB_NAME\"" | grep -q '"state":"RUNNING"'
}

if job_running; then
  echo "Job '$JOB_NAME' is already running, nothing to do."
  exit 0
fi

# Session settings first, then the table DDL.
init=/tmp/init.sql
{
  echo "SET 'pipeline.name' = '$JOB_NAME';"
  cat /opt/flink-sql/flink_sql_source_sink.sql
} > "$init"

echo "Submitting job '$JOB_NAME'..."
# sql-client exits 0 even when a statement fails, so check the result through the REST API below.
/opt/flink/bin/sql-client.sh -i "$init" -f /opt/flink-sql/flink_sql_dedup_job.sql

for ((i = 0; i < WAIT_SECS; i += 2)); do
  if job_running; then
    echo "Job '$JOB_NAME' is RUNNING. Flink UI: http://localhost:9081/#/overview"
    exit 0
  fi
  sleep 2
done
echo "Job '$JOB_NAME' not RUNNING after ${WAIT_SECS}s. Check the output above and http://localhost:9081" >&2
exit 1

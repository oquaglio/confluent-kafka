FROM postgres:19
# Runs once, on first start with an empty data volume
COPY init.sql /docker-entrypoint-initdb.d/init.sql

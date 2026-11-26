# Source database: PostgreSQL with the demo schema + seed data baked in.
# Baked in (not bind-mounted) so the project works when Docker runs in another WSL2 distro.
FROM postgres:17
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql

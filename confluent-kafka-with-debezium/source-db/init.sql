-- Runs once, on the first start of an empty data volume (docker-entrypoint-initdb.d).
-- wal_level=logical is set on the postgres command line in docker-compose.yml.

-- Demo schema ---------------------------------------------------------------
CREATE TABLE customers (
  id          SERIAL PRIMARY KEY,
  first_name  TEXT NOT NULL,
  last_name   TEXT NOT NULL,
  email       TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id           SERIAL PRIMARY KEY,
  customer_id  INT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  product      TEXT NOT NULL,
  quantity     INT NOT NULL,
  price        NUMERIC(10,2) NOT NULL,
  status       TEXT NOT NULL DEFAULT 'NEW',
  updated_at   TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO customers (first_name, last_name, email) VALUES
  ('Ada',    'Lovelace', 'ada@example.com'),
  ('Alan',   'Turing',   'alan@example.com'),
  ('Grace',  'Hopper',   'grace@example.com');

INSERT INTO orders (customer_id, product, quantity, price, status) VALUES
  (1, 'Analytical Engine', 1, 9999.99, 'SHIPPED'),
  (2, 'Enigma Rotor',      3,   49.50, 'NEW'),
  (3, 'COBOL Manual',      2,   19.95, 'PAID');

-- CDC setup -------------------------------------------------------------------
-- A least-privilege user for Debezium: it may stream the WAL (REPLICATION) and read the tables
-- (SELECT, needed for the initial snapshot). It doesn't own the tables, so it can't create the
-- publication itself, which is why we create it here and set publication.autocreate.mode=disabled.
CREATE ROLE debezium WITH LOGIN REPLICATION PASSWORD 'debezium';
GRANT SELECT ON customers, orders TO debezium;

-- The publication = which tables pgoutput sends change events for.
CREATE PUBLICATION dbz_publication FOR TABLE customers, orders;

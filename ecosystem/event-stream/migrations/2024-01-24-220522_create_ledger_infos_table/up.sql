CREATE SCHEMA IF NOT EXISTS event_stream;
CREATE TABLE IF NOT EXISTS event_stream.ledger_infos (chain_id BIGINT UNIQUE PRIMARY KEY NOT NULL);

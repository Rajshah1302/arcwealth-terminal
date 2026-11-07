-- ARCWEALTH Postgres schema (portable; no extensions required)
CREATE TABLE IF NOT EXISTS price_history (
  symbol      TEXT        NOT NULL,
  ts          TIMESTAMPTZ NOT NULL,
  price       NUMERIC(38,8) NOT NULL,
  regime      TEXT        NOT NULL DEFAULT 'normal',
  tier        TEXT        NOT NULL DEFAULT 'SIMULATED-OFFCHAIN',
  PRIMARY KEY (symbol, ts)
);

CREATE TABLE IF NOT EXISTS chain_events (
  tx_hash      TEXT    NOT NULL,
  log_index    INTEGER NOT NULL,
  block_number BIGINT  NOT NULL,
  block_time   TIMESTAMPTZ,
  emitter      TEXT    NOT NULL,
  event_name   TEXT    NOT NULL,
  args         JSONB   NOT NULL DEFAULT '{}',
  PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS chain_events_emitter_idx ON chain_events (emitter, block_number);
CREATE INDEX IF NOT EXISTS chain_events_name_idx ON chain_events (event_name);

CREATE TABLE IF NOT EXISTS indexer_state (
  id           TEXT PRIMARY KEY,
  last_block   BIGINT NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS strategies (
  id            TEXT PRIMARY KEY,           -- s1 | s2 | s3
  name          TEXT NOT NULL,
  vault         TEXT NOT NULL,
  risk_label    TEXT NOT NULL,
  config_json   JSONB NOT NULL,
  config_hash   TEXT NOT NULL,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS nav_snapshots (
  strategy_id  TEXT NOT NULL,
  ts           TIMESTAMPTZ NOT NULL,
  nav_usdc     NUMERIC(38,6) NOT NULL,
  total_shares NUMERIC(38,12) NOT NULL,
  share_price  NUMERIC(38,8) NOT NULL,
  idle_usdc    NUMERIC(38,6) NOT NULL,
  PRIMARY KEY (strategy_id, ts)
);

CREATE TABLE IF NOT EXISTS strategy_events (
  id           BIGSERIAL PRIMARY KEY,
  strategy_id  TEXT,
  kind         TEXT NOT NULL,                -- price|nav|expiry|coupon|roll|regime|error
  detail       JSONB NOT NULL DEFAULT '{}',
  tx_hash      TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_log (
  id         BIGSERIAL PRIMARY KEY,
  actor      TEXT NOT NULL,
  action     TEXT NOT NULL,
  reason     TEXT,
  before     JSONB,
  after      JSONB,
  tx_hash    TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS simulated_lending (
  id         BIGSERIAL PRIMARY KEY,
  account    TEXT NOT NULL,
  kind       TEXT NOT NULL,                  -- supply|borrow|repay|liquidation-sim
  amount     NUMERIC(38,6) NOT NULL,
  tier       TEXT NOT NULL DEFAULT 'SIMULATED-OFFCHAIN',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

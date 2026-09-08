CREATE TABLE IF NOT EXISTS links (
  id          BIGSERIAL PRIMARY KEY,
  url         TEXT        NOT NULL,
  title       TEXT        NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS links_created_at_idx ON links (created_at DESC);

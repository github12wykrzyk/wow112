CREATE TABLE events (
    event_id TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL,
    ts_utc TEXT NOT NULL,
    type TEXT NOT NULL,
    session_id TEXT,
    request_id TEXT,
    customer TEXT,
    destination TEXT,
    state TEXT,
    amount_copper INTEGER NOT NULL CHECK(amount_copper >= 0),
    correlation_id TEXT,
    severity TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    ingested_at_utc TEXT NOT NULL
);

CREATE TABLE requests (
    request_id TEXT PRIMARY KEY,
    correlation_id TEXT UNIQUE,
    session_id TEXT,
    customer TEXT COLLATE NOCASE,
    destination TEXT,
    summon_state TEXT NOT NULL DEFAULT 'pending' CHECK(summon_state IN ('pending','started','completed','failed')),
    payment_state TEXT NOT NULL DEFAULT 'pending' CHECK(payment_state IN ('pending','paid','unpaid','uncertain')),
    expected_copper INTEGER NOT NULL DEFAULT 0 CHECK(expected_copper >= 0),
    paid_copper INTEGER NOT NULL DEFAULT 0 CHECK(paid_copper >= 0),
    started_at_utc TEXT,
    completed_at_utc TEXT,
    failed_at_utc TEXT,
    last_payment_at_utc TEXT,
    last_event_at_utc TEXT,
    updated_at_utc TEXT NOT NULL
);

CREATE INDEX idx_events_request_ts ON events(request_id, ts_utc, event_id);
CREATE INDEX idx_events_correlation ON events(correlation_id);
CREATE INDEX idx_events_customer_ts ON events(customer COLLATE NOCASE, ts_utc DESC);
CREATE INDEX idx_events_type_ts ON events(type, ts_utc DESC);
CREATE INDEX idx_events_session_type_ts ON events(session_id, type, ts_utc DESC);
CREATE INDEX idx_requests_customer_last ON requests(customer COLLATE NOCASE, last_event_at_utc DESC);
CREATE INDEX idx_requests_payment_state_last ON requests(payment_state, last_event_at_utc DESC);
CREATE INDEX idx_requests_session ON requests(session_id);

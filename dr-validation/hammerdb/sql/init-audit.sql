-- Audit trail for DR validation on PostgreSQL (HammerDB workload).
CREATE TABLE IF NOT EXISTS dr_validation_audit (
    seq BIGINT PRIMARY KEY,
    committed_at TIMESTAMPTZ NOT NULL,
    hostname TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'db_audit'
);

CREATE INDEX IF NOT EXISTS dr_validation_audit_committed_at_idx
    ON dr_validation_audit (committed_at);

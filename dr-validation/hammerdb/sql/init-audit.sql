-- Audit trail for DR validation on PostgreSQL (HammerDB workload).
-- Lives on the OS-disk tablespace; TPC-C tables use the default tablespace on the data disk.
CREATE TABLE IF NOT EXISTS dr_validation_audit (
    seq BIGINT PRIMARY KEY,
    committed_at TIMESTAMPTZ NOT NULL,
    hostname TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'db_audit'
) TABLESPACE ramendr_os;

CREATE INDEX IF NOT EXISTS dr_validation_audit_committed_at_idx
    ON dr_validation_audit (committed_at);

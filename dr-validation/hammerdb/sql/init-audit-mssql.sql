-- Audit trail for DR validation on SQL Server (HammerDB TPC-C workload).
-- Stored on the ramendr_os filegroup (OS disk); TPC-C tables use the PRIMARY filegroup on the data disk.
IF OBJECT_ID(N'dbo.dr_validation_audit', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.dr_validation_audit (
        seq BIGINT NOT NULL PRIMARY KEY,
        committed_at DATETIME2 NOT NULL,
        hostname NVARCHAR(256) NOT NULL,
        source NVARCHAR(64) NOT NULL DEFAULT N'db_audit'
    ) ON ramendr_os;
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = N'dr_validation_audit_committed_at_idx'
      AND object_id = OBJECT_ID(N'dbo.dr_validation_audit')
)
BEGIN
    CREATE INDEX dr_validation_audit_committed_at_idx
        ON dbo.dr_validation_audit (committed_at);
END;

# HammerDB PostgreSQL schema (default DR validation mode)

HammerDB **TPC-C** builds a production-style OLTP database on the DR-protected edge VM
(`rhel9-node-001` by default). There is no separate literal `users` table; **`customer`**
serves that role with numeric IDs and profile fields.

## Storage layout (dual-disk HammerDB)

HammerDB uses one logical `tpcc` database split across two DR-protected disks so
post-DR validation exercises both PVCs:

| Workload | PostgreSQL (Linux) | SQL Server (Windows) |
|----------|-------------------|----------------------|
| TPC-C tables (`warehouse`, `orders`, …) | Default tablespace on **data disk** (`PGDATA` under `/mnt/ramendr-data`) | `PRIMARY` filegroup on **data disk** (`D:\MSSQL`) |
| `dr_validation_audit` | `ramendr_os` tablespace on **OS disk** | `ramendr_os` filegroup on **OS disk** |

Both the OS-disk PVC (VM name) and the `{vm}-data` PVC must be listed in the
`gitops-vm-protection` VolumeReplicationGroup. Post-DR checks compare audit sequence
and TPC-C transactional counters against the pre-DR baseline to detect split-brain
recovery where only one disk survived failover.

## Application tables (HammerDB TPC-C)

| Table | Role | Key identifiers / data |
|-------|------|------------------------|
| `warehouse` | Sites / datacenters | `w_id` |
| `district` | Sub-regions per warehouse | `d_id`, `d_w_id` |
| `customer` | **Customers (“users”)** | `c_id`, `c_d_id`, `c_w_id`, `c_first`, `c_middle`, `c_last`, `c_phone`, balances |
| `stock` | Inventory | `s_i_id`, `s_w_id`, quantities |
| `item` | Product catalog | `i_id`, `i_name`, `i_price` |
| `orders` | Orders | `o_id`, `o_c_id`, `o_d_id`, timestamps |
| `order_line` | Order line items | `ol_o_id`, `ol_d_id`, `ol_i_id`, amounts |
| `new_order` | Pending order queue | `no_o_id`, `no_d_id`, `no_w_id` |
| `history` | Payment history from OLTP load | `h_c_id`, `h_d_id`, `h_amount`, `h_date` |

Default build uses **1 warehouse**, which loads **3,000 customers**, **10 districts**,
**100,000 items**, and related stock rows before HammerDB autopilot adds ongoing
transactions.

## DR validation table

| Table | Role | Columns |
|-------|------|---------|
| `dr_validation_audit` | Continuous DR audit trail (OS disk in dual-disk mode) | `seq`, `committed_at`, `hostname`, `source` |

Snapshot exporters support two modes:

- **status-only** — audit summary + exact counts on fixed buildschema tables only
  (`warehouse`, `customer`, `item`, …). Used by health checks after long runs when
  `orders` / `order_line` are too large for timely `COUNT(*)`.
- **dr** — audit tail (default last 5000 rows via `DR_VALIDATION_AUDIT_TAIL_ROWS`) plus
  planner/partition estimates for mutable OLTP tables. Used for pre/post-DR baselines.

Post-DR checks validate audit sequence continuity, TPC-C row-count regression vs the
automatic baseline, cross-disk coherence between audit and TPC-C growth, and RPO relative
to the DR initiation timestamp.

See `ramendr_dr_validation/tpcc_schema.py` for programmatic minimum row counts used
in smoke tests and redeploy verification.

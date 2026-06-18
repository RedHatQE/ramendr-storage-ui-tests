# HammerDB PostgreSQL schema (default DR validation mode)

HammerDB **TPC-C** builds a production-style OLTP database on the DR-protected edge VM
(`edgenode-0` by default). There is no separate literal `users` table; **`customer`**
serves that role with numeric IDs and profile fields.

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
| `dr_validation_audit` | Continuous DR audit trail on replicated PostgreSQL data | `seq`, `committed_at`, `hostname`, `source` |

Post-DR checks validate audit sequence continuity, TPC-C row-count regression vs the
automatic baseline, and RPO relative to the DR initiation timestamp.

See `ramendr_dr_validation/tpcc_schema.py` for programmatic minimum row counts used
in smoke tests and redeploy verification.

# TASK-P03-007 runner enabler

The Catalog defines P03-007 modes but no executable task adapter. The local
runner now invokes the real PostgreSQL RLS suite and binds CT-007 to exact
machine assertions: ten policies, ten `FORCE ROW LEVEL SECURITY` tables, three
runtime reader roles across two tenants, zero leakage/unexpected grants, and
zero `rolsuper/rolbypassrls` application roles.

Rollback verification is deliberately forward-fix-only. It proves an attempted
downgrade is rejected and the RLS revision/policies remain active; it never
disables a policy to manufacture reversibility. The adapter and test fixture are
local-only, create no production role, and do not modify Catalog bytes.

"""Force Runtime RLS and apply pre-provisioned least-privilege role grants.

Revision ID: p03_007_runtime_rls
Revises: p03_006_outbox_receipts
Create Date: 2026-08-01 07:20:00+08:00

Roles are infrastructure-owned identities. This migration validates them and
grants object privileges but never creates login/service roles.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "p03_007_runtime_rls"
down_revision: str | Sequence[str] | None = "p03_006_outbox_receipts"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"
BEHAVIOR_SCHEMA = "agent_behavior"
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANT_TABLES = (
    "threads",
    "runs",
    "events",
    "idempotency_records",
    "jobs",
    "leases",
    "checkpoint_metadata",
    "outbox_messages",
)
DERIVED_TENANT_TABLES = ("delivery_receipts", "dead_letters")


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    role_list = ",".join(f"'{role}'" for role in ROLES)
    _execute(
        f"""
        DO $$
        DECLARE role_count integer; bypass_count integer;
        BEGIN
          SELECT count(*), count(*) FILTER (WHERE rolbypassrls OR rolsuper)
            INTO role_count, bypass_count
            FROM pg_roles WHERE rolname IN ({role_list});
          IF role_count <> {len(ROLES)} THEN
            RAISE EXCEPTION 'rls.required_roles_missing' USING ERRCODE = '42501';
          END IF;
          IF bypass_count <> 0 THEN
            RAISE EXCEPTION 'rls.bypass_role_forbidden' USING ERRCODE = '42501';
          END IF;
        END;
        $$
        """
    )
    _execute("REVOKE ALL ON SCHEMA agent_runtime FROM PUBLIC")
    _execute("REVOKE ALL ON SCHEMA agent_behavior FROM PUBLIC")
    _execute("REVOKE ALL ON ALL TABLES IN SCHEMA agent_runtime FROM PUBLIC")
    _execute("REVOKE ALL ON ALL TABLES IN SCHEMA agent_behavior FROM PUBLIC")
    _execute("ALTER DEFAULT PRIVILEGES IN SCHEMA agent_runtime REVOKE ALL ON TABLES FROM PUBLIC")
    _execute("ALTER DEFAULT PRIVILEGES IN SCHEMA agent_behavior REVOKE ALL ON TABLES FROM PUBLIC")
    _execute(
        "GRANT USAGE ON SCHEMA agent_runtime TO "
        "gonow_agent_api, gonow_agent_worker, gonow_command_service, gonow_observer"
    )
    _execute(
        "GRANT USAGE ON SCHEMA agent_behavior TO "
        "gonow_agent_api, gonow_agent_worker, gonow_release_operator"
    )
    _execute(
        """
        CREATE FUNCTION agent_runtime.current_tenant_id()
        RETURNS text LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp
        AS $$ SELECT NULLIF(current_setting('app.tenant_id', true), '') $$
        """
    )
    for table_name in TENANT_TABLES:
        _execute(f"ALTER TABLE agent_runtime.{table_name} ENABLE ROW LEVEL SECURITY")
        _execute(f"ALTER TABLE agent_runtime.{table_name} FORCE ROW LEVEL SECURITY")
        _execute(
            f"""
            CREATE POLICY tenant_isolation ON agent_runtime.{table_name}
            USING (tenant_id = agent_runtime.current_tenant_id())
            WITH CHECK (tenant_id = agent_runtime.current_tenant_id())
            """
        )
    for table_name in DERIVED_TENANT_TABLES:
        _execute(f"ALTER TABLE agent_runtime.{table_name} ENABLE ROW LEVEL SECURITY")
        _execute(f"ALTER TABLE agent_runtime.{table_name} FORCE ROW LEVEL SECURITY")
        _execute(
            f"""
            CREATE POLICY tenant_isolation ON agent_runtime.{table_name}
            USING (
              EXISTS (
                SELECT 1 FROM agent_runtime.outbox_messages AS scoped_outbox
                WHERE scoped_outbox.outbox_id = {table_name}.outbox_id
                  AND scoped_outbox.tenant_id = agent_runtime.current_tenant_id()
              )
            )
            WITH CHECK (
              EXISTS (
                SELECT 1 FROM agent_runtime.outbox_messages AS scoped_outbox
                WHERE scoped_outbox.outbox_id = {table_name}.outbox_id
                  AND scoped_outbox.tenant_id = agent_runtime.current_tenant_id()
              )
            )
            """
        )

    _execute("GRANT SELECT, INSERT ON agent_runtime.threads TO gonow_agent_api")
    _execute("GRANT SELECT, INSERT, UPDATE ON agent_runtime.runs TO gonow_agent_api")
    _execute("GRANT SELECT, INSERT ON agent_runtime.events TO gonow_agent_api")
    _execute("GRANT SELECT, INSERT ON agent_runtime.idempotency_records TO gonow_agent_api")
    _execute("GRANT SELECT, INSERT ON agent_runtime.jobs TO gonow_agent_api")
    _execute(
        "GRANT SELECT ON ALL TABLES IN SCHEMA agent_runtime TO "
        "gonow_agent_worker, gonow_observer"
    )
    _execute(
        "GRANT INSERT, UPDATE ON agent_runtime.runs, agent_runtime.events, "
        "agent_runtime.jobs, agent_runtime.leases, agent_runtime.checkpoint_metadata, "
        "agent_runtime.outbox_messages, agent_runtime.delivery_receipts, "
        "agent_runtime.dead_letters TO gonow_agent_worker"
    )
    _execute(
        "GRANT SELECT, INSERT, UPDATE ON agent_runtime.events, "
        "agent_runtime.outbox_messages, agent_runtime.delivery_receipts, "
        "agent_runtime.dead_letters TO gonow_command_service"
    )
    _execute(
        "GRANT SELECT ON ALL TABLES IN SCHEMA agent_behavior TO "
        "gonow_agent_api, gonow_agent_worker, gonow_release_operator"
    )
    _execute(
        "GRANT INSERT ON agent_behavior.revisions, agent_behavior.certifications, "
        "agent_behavior.releases, agent_behavior.deployments, "
        "agent_behavior.deployment_history TO gonow_release_operator"
    )
    _execute(
        "GRANT UPDATE ON agent_behavior.deployments TO gonow_release_operator"
    )


def downgrade() -> None:
    raise RuntimeError(
        "p03_007_runtime_rls is forward-fix only; disabling FORCE RLS is a forbidden rollback"
    )

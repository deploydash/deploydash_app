"""Shared fixtures and base case for the managed PostgreSQL helper tests.

Extracted by T-3.6.2 from `postgres_helpers_test.py` (2,122 lines, 56 tests in
one class). The four files that replace it split by what the helper does:
agent-access query validation, backup and restore, the project-database
operations, and the pure parsers and SQL builders.

The name deliberately does not end in `_test.py`, so `unittest discover` does
not collect it.
"""

import tempfile  # noqa: F401
import unittest
from unittest.mock import patch

from orchestrator import engine_postgres_ops
from orchestrator.postgres_parts import (  # noqa: F401
    PostgresConfigValidationError,
    parse_postgres_service_config,
)
from orchestrator.postgres_runtime_parts import (  # noqa: F401
    agent_access,
    backup_operations,
    local_sql_import,
    project_inventory,
    users_and_grants,
)
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeHost:
    def __init__(self, status_output=None):
        self.status_output = status_output or _FakeOutput()

    def run_shell_command(self, command, *_args, **_kwargs):
        if "CONFIGURED='false'" in command:
            return True, self.status_output
        if "SELECT project_slug FROM deploydash.managed_" in command:
            # Every name these tests use is registered to their project,
            # "test", so flows pass the ownership gate (#127).
            return True, _FakeOutput(stdout_lines=["test"])
        return True, _FakeOutput()


class _FakeSession:
    def __init__(self, host=None, disconnect_error=None):
        self.host = host or _FakeHost()
        self._disconnect_error = disconnect_error

    def close(self):
        return {"disconnect_error": self._disconnect_error}


def _error_result(code, msg, stage=None, details=None, extra=None):
    return {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
        "extra": extra or {},
    }


def _config(**settings):
    payload = {"settings": {"postgres_version": "17", "superuser_password": "secret"}}
    payload["settings"].update(settings)
    return parse_postgres_service_config(payload)


class PostgresHelpersTestCase(unittest.TestCase):
    """The session and operation runner every PostgreSQL helper test uses."""

    def _run_project_operation(
        self,
        operation_id,
        *,
        settings,
        query_handler,
        status_output=None,
        serve_lazy_ensure=True,
        captured_sql=None,
    ):
        host = _FakeHost(
            status_output=status_output
            or _FakeOutput(
                stdout_lines=[
                    '{"running":true,"health":"healthy","version":"17.8","configured":true}',
                ],
            ),
        )
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=host),
            },
        )

        def _dispatch(*args, **kwargs):
            sql_text = str(args[2]) if len(args) > 2 else str(kwargs.get("sql", ""))
            if captured_sql is not None:
                captured_sql.append(sql_text)
            if serve_lazy_ensure:
                # The agent-reader lazy ensure is preamble infrastructure, like
                # the service status above: served here so operation tests only
                # model their own queries. Failure-path tests for the ensure
                # itself pass serve_lazy_ensure=False (#83). The registry
                # bootstrap inside the ensure bypasses this fake: it runs
                # through project_registry's own import of the query runner,
                # which the fake host answers with success.
                if "CONNECTION LIMIT" in sql_text and "deploydash_agent_reader_" in sql_text:
                    return True, _FakeOutput(stdout_lines=["DO"])
                if "INSERT INTO deploydash.managed_roles" in sql_text and (
                    "'agent_reader'" in sql_text
                ):
                    return True, _FakeOutput(stdout_lines=["INSERT 0 1"])
            return query_handler(*args, **kwargs)

        with (
            patch.object(
                project_inventory,
                "_run_postgres_psql_query_impl",
                side_effect=lambda _ctx, *args, **kwargs: _dispatch(*args, **kwargs),
            ),
            patch.object(
                agent_access,
                "_run_postgres_psql_query_impl",
                side_effect=lambda _ctx, *args, **kwargs: _dispatch(*args, **kwargs),
            ),
        ):
            return engine_postgres_ops.run_postgres_project_operation(
                ctx,
                operation_id,
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={"settings": settings},
            )

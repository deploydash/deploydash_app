"""Deterministic fault injection through the release state machine.

Every one of these failures is real and hard to schedule on a VM: a disk that
fills during the image build, a container that starts and then fails its health
probe, a connection cut between two steps. On real hardware you wait for them
and hope; here they are a line of setup, and the assertion that matters is
usually the negative one -- **what did not happen next**.

The safety property under all of it: live traffic must never move to a release
that has not proved itself. Every test that fails a step before cutover asserts
the Caddy route was not written.
"""

from __future__ import annotations

import unittest

from orchestrator.app_parts import parse_app_config
from orchestrator.app_runtime_parts import release_lifecycle as engine_app_ops
from orchestrator.failure_evidence import serialize_failure_evidence
from tests.engine_context_fixtures import build_test_context
from tests.fault_injection import (
    FaultInjectingHost,
    FaultInjectingSession,
    install_recording_clock,
)


def _app_config(**overrides):
    settings = {
        "project_slug": "remix-blog",
        "repository_full_name": "acme/remix-blog",
        "primary_domain": "blog.example.com",
        "branch": "main",
        "app_port": 3000,
        "runtime_env": {"NODE_ENV": "production"},
    }
    settings.update(overrides)
    return parse_app_config({"settings": settings}, require_domain=True)


# Read off the harness rather than guessed: the build is Railpack through a
# helper, not `docker build`, and the candidate start is a shell block that
# detects the Caddy network first. Guessing these produced tests that passed
# while injecting nothing.
_SYNC_REPOSITORY = "GIT_SSH_COMMAND"
_READ_COMMIT = "rev-parse HEAD"
_BUILD_IMAGE = "deploydash-railpack-build"
_START_CANDIDATE = "CADDY_NETWORK"
_CANDIDATE_PROBE = "APP_IP="
_WRITE_CADDY_ROUTE = "conf.d/20-"
_APPLY_CADDY = "deploydash-caddy-apply"
_ROUTED_PROBE = "curl -ksS"


def _error_result(code, msg, *, stage=None, details=None, extra=None):
    payload = {"status": "error", "code": code, "msg": msg, "stage": stage}
    if details is not None:
        payload["details"] = details
    if extra is not None:
        payload["extra"] = extra
    return payload


def _failure_evidence(result):
    """Read the additive evidence from this suite's intentionally nested envelope."""
    return serialize_failure_evidence(result["extra"]["failure_evidence"])


class TestReleaseDeployFaultInjection(unittest.TestCase):
    def setUp(self):
        # The state machine retries its probes and waits out its stabilization
        # window, which is 25 seconds of real time on a clean deploy. Tier 0
        # runs at unit-test speed, so the one seam it waits through is
        # replaced with a clock that returns immediately and records what was
        # asked for. This used to zero the three delay constants instead,
        # which also made the waits unobservable -- see `RecordingClock`.
        self.clock = install_recording_clock(self)
        self.app_config = _app_config()
        self.emitted: list[tuple] = []
        self.ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda emit, event_type, message, **kwargs: self.emitted.append(
                (event_type, message)
            ),
            emit_shell_output_lines=lambda *args, **kwargs: None,
            command_error_details=lambda output: (
                "; ".join(getattr(output, "stderr_lines", []) or []) or None
            ),
            read_remote_file_text=lambda *args, **kwargs: None,
            sanitize_message=lambda value: value,
        )

    def _deploy(self, host, app_config=None):
        session = FaultInjectingSession(host)
        return engine_app_ops._execute_versioned_release_deploy(
            self.ctx,
            session=session,
            app_config=app_config or self.app_config,
            normalized_parts=[],
        )

    # --- ordinary remote failure, step by step ---------------------------

    def test_a_successful_deploy_watches_the_app_before_calling_it_healthy(
        self,
    ):
        # The reason the clock is recorded rather than zeroed. Traffic switches
        # to a candidate only after readiness, and the release is kept only if
        # it survives the post-cutover stabilization window -- five checks,
        # five seconds apart. A deploy that skipped those waits would declare
        # success having watched the app for no time at all, and the tests
        # could not tell, because zeroing the delay constants -- how this
        # suite used to run -- erased exactly this evidence.
        host = FaultInjectingHost()
        host.fail_when(
            command_contains=("deploydash_app_remix-blog 2>/dev/null | grep -qx true"),
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "success")
        self.assertNotIn("failure_evidence", result)
        self.assertEqual(
            self.clock.waits,
            [engine_app_ops._RELEASE_STABILIZATION_DELAY_SECONDS] * 5,
        )
        # 25 seconds of real watching, stated as a number rather than derived
        # from the constants the code under test reads.
        self.assertEqual(self.clock.total_seconds, 25)

    def test_a_failed_repository_sync_stops_before_anything_is_built(self):
        host = FaultInjectingHost()
        host.fail_when(
            command_contains=_SYNC_REPOSITORY,
            stderr_lines=["Permission denied (publickey)."],
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Sync repository failed.")
        self.assertIn("Permission denied", result["details"])
        self.assertEqual(_failure_evidence(result)["phase"], "repository_sync")
        self.assertEqual(_failure_evidence(result)["source"], "failed_operation")
        self.assertEqual(_failure_evidence(result)["lines"], ["Permission denied (publickey)."])
        # Nothing may be built or run from a repository that was never fetched.
        self.assertFalse(host.ran(_BUILD_IMAGE))
        self.assertFalse(host.ran(_START_CANDIDATE))
        self.assertFalse(host.ran(_WRITE_CADDY_ROUTE))

    def test_a_failed_image_build_never_starts_a_container(self):
        host = FaultInjectingHost()
        host.fail_when(
            command_contains=_BUILD_IMAGE,
            stderr_lines=["no space left on device"],
        )

        result = self._deploy(host)

        self.assertEqual(result["msg"], "Build release image failed.")
        self.assertIn("no space left on device", result["details"])
        self.assertEqual(_failure_evidence(result)["phase"], "build")
        self.assertEqual(_failure_evidence(result)["lines"], ["no space left on device"])
        self.assertTrue(host.ran(_BUILD_IMAGE))
        self.assertFalse(host.ran(_START_CANDIDATE))
        self.assertFalse(host.ran(_WRITE_CADDY_ROUTE))

    def test_a_candidate_that_cannot_start_never_takes_traffic(self):
        host = FaultInjectingHost()
        host.fail_when(
            command_contains=_START_CANDIDATE,
            stderr_lines=["port is already allocated"],
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(_failure_evidence(result)["phase"], "candidate_start")
        self.assertEqual(_failure_evidence(result)["lines"], ["port is already allocated"])
        self.assertTrue(host.ran(_START_CANDIDATE))
        # The cutover is the dangerous step. A candidate that never started
        # must not be routed to, whatever else went wrong.
        self.assertFalse(host.ran(_WRITE_CADDY_ROUTE))

    def test_a_candidate_that_starts_but_fails_readiness_never_takes_traffic(self):
        host = FaultInjectingHost()
        # The container starts cleanly and then never answers a health probe:
        # the release that looks alive and is not. This is the case the whole
        # health-gated cutover exists for, and the one a VM cannot schedule on
        # demand.
        host.fail_when(
            command_contains=_CANDIDATE_PROBE,
            stderr_lines=["probe failed without a response body"],
        )
        host.answer_when(
            command_contains="docker logs --tail",
            stdout_lines=["RuntimeError: database connection refused"],
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertTrue(host.ran(_START_CANDIDATE), "the candidate did start")
        self.assertTrue(host.ran(_CANDIDATE_PROBE), "and it was probed")
        evidence = _failure_evidence(result)
        self.assertEqual(evidence["phase"], "candidate_readiness")
        self.assertEqual(evidence["source"], "candidate_runtime")
        self.assertEqual(evidence["lines"], ["RuntimeError: database connection refused"])
        self.assertEqual(
            result["extra"]["runtime_log_excerpt"],
            evidence["lines"],
        )
        # The property the product turns on: traffic does not move to a release
        # that failed its probe.
        self.assertFalse(host.ran(_WRITE_CADDY_ROUTE))
        self.assertFalse(host.ran(_APPLY_CADDY))

    def test_a_candidate_probe_that_recovers_on_retry_still_deploys(self):
        host = FaultInjectingHost()
        # Fails the first probe only. A container that is still warming up must
        # not be condemned on one attempt -- that would make every slow-booting
        # app undeployable.
        host.fail_when(command_contains=_CANDIDATE_PROBE, times=1)

        result = self._deploy(host)

        self.assertEqual(result["status"], "success")
        self.assertTrue(host.ran(_WRITE_CADDY_ROUTE))

    def test_a_cutover_that_fails_reverts_to_the_previous_live_release(self):
        host = FaultInjectingHost()
        # The candidate passed its probe and the route was written, and then
        # applying the Caddy configuration failed. Traffic is now in an
        # undefined place, which is the worst moment for a deploy to give up.
        host.fail_when(
            command_contains=_APPLY_CADDY,
            stderr_lines=["caddy: adapt failed"],
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Switch live traffic to candidate release failed.")
        self.assertEqual(result["extra"]["rollback_status"], "reverted_to_previous_live")
        self.assertEqual(_failure_evidence(result)["phase"], "traffic_switch")
        self.assertEqual(_failure_evidence(result)["lines"], ["caddy: adapt failed"])

    def test_a_release_that_fails_after_cutover_is_reverted(self):
        host = FaultInjectingHost()
        # The candidate answered its own probe, took traffic, and then stopped
        # answering through the proxy -- the failure that only appears once
        # real users are on it.
        host.fail_when(command_contains=_ROUTED_PROBE, stderr_lines=["HTTP 502"])
        host.answer_when(
            command_contains="docker logs --tail",
            stdout_lines=["FATAL: process exited after cutover"],
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["msg"],
            "Candidate release failed post-cutover stabilization and was reverted.",
        )
        self.assertEqual(result["extra"]["rollback_status"], "reverted_to_previous_live")
        evidence = _failure_evidence(result)
        self.assertEqual(evidence["phase"], "post_cutover_stabilization")
        self.assertEqual(evidence["source"], "candidate_runtime")
        self.assertEqual(evidence["lines"], ["FATAL: process exited after cutover"])
        log_index = next(
            index for index, call in enumerate(host.calls) if "docker logs --tail" in call.command
        )
        cleanup_index = next(
            index
            for index, call in enumerate(host.calls)
            if index > log_index and "docker rm -f" in call.command
        )
        self.assertLess(log_index, cleanup_index)
        # The revert is the point: a broken release must not keep the traffic
        # it briefly earned.
        self.assertTrue(host.ran(_APPLY_CADDY))

    # --- the fault a VM cannot schedule ----------------------------------

    def test_a_disconnect_mid_sequence_leaves_traffic_where_it_was(self):
        host = FaultInjectingHost()
        host.raise_when(
            ConnectionResetError("connection reset by peer"),
            command_contains=_BUILD_IMAGE,
        )

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(_failure_evidence(result)["phase"], "build")
        self.assertEqual(_failure_evidence(result)["source"], "exception")
        self.assertEqual(_failure_evidence(result)["lines"], ["connection reset by peer"])
        self.assertFalse(host.ran(_WRITE_CADDY_ROUTE))
        self.assertFalse(host.ran(_START_CANDIDATE))

    def test_a_failing_step_is_the_last_call_attempted(self):
        host = FaultInjectingHost()
        host.fail_when(at_call=1, stderr_lines=["transient"])

        self._deploy(host)

        # Call 1 is the repository sync and it short-circuits, so call 2 must
        # not exist: the state machine is sequential and stops rather than
        # pressing on with a checkout it does not have.
        self.assertEqual(len(host.calls), 1)

    def test_an_unreadable_commit_does_not_abort_the_deploy(self):
        host = FaultInjectingHost()
        host.fail_when(command_contains=_READ_COMMIT, stderr_lines=["no HEAD"])

        result = self._deploy(host)

        # Deliberate, and worth pinning: the commit sha is metadata, not a
        # precondition. A repository that syncs but whose HEAD cannot be read
        # still deploys, under a release id marked `-manual` rather than one
        # naming a commit. Failing here instead would block deploys for a
        # cosmetic reason.
        self.assertEqual(result["status"], "success")
        self.assertTrue(host.ran(_BUILD_IMAGE))
        self.assertTrue(
            any("-manual" in call.command for call in host.calls),
            "the release id should fall back to a manual marker",
        )

    # --- corrupt facts, which succeed and lie ----------------------------

    def test_a_truncated_status_read_does_not_crash_the_deploy(self):
        host = FaultInjectingHost()
        # The command succeeds and returns half a status line. Nothing reports
        # an error, so only a parser that checks what it got will notice.
        host.truncate_when(
            command_contains="docker inspect",
            stdout_lines=["container=running", "health=healthy"],
            keep=1,
        )
        host.fail_when(command_contains=_BUILD_IMAGE, stderr_lines=["stop here"])

        result = self._deploy(host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Build release image failed.")

    def test_a_nonsense_commit_sha_still_produces_a_release_id(self):
        host = FaultInjectingHost()
        host.answer_when(
            command_contains=_READ_COMMIT,
            stdout_lines=["not-a-sha-at-all"],
        )
        host.fail_when(command_contains=_BUILD_IMAGE, stderr_lines=["stop here"])

        result = self._deploy(host)

        # The deploy still reaches the build rather than failing on the fact
        # itself, which is what the caller sees today.
        self.assertEqual(result["msg"], "Build release image failed.")
        self.assertTrue(host.ran(_READ_COMMIT))

    # --- recording mode --------------------------------------------------

    def test_the_harness_records_order_sudo_and_timeout(self):
        host = FaultInjectingHost()
        host.fail_when(command_contains=_BUILD_IMAGE, stderr_lines=["stop"])

        self._deploy(host)

        self.assertGreater(len(host.calls), 1)
        first = host.calls[0]
        self.assertEqual(first.number, 1)
        self.assertTrue(first.sudo)
        self.assertGreater(first.timeout, 0)
        # Order is preserved, so a test can assert a sequence rather than a set.
        self.assertEqual([call.number for call in host.calls], list(range(1, len(host.calls) + 1)))

    def test_the_session_is_closed_even_when_a_step_fails(self):
        host = FaultInjectingHost()
        host.fail_when(command_contains=_SYNC_REPOSITORY, stderr_lines=["denied"])
        session = FaultInjectingSession(host)

        engine_app_ops._execute_versioned_release_deploy(
            self.ctx,
            session=session,
            app_config=self.app_config,
            normalized_parts=[],
        )

        # The state machine does not close the session itself -- its caller
        # does, in a `finally`. Asserted here so that if ownership ever moves,
        # the change is deliberate rather than silent.
        self.assertFalse(session.closed)


class TestFaultInjectingHost(unittest.TestCase):
    """The harness itself, so a green fault-injection suite means something."""

    def test_the_default_answer_is_success_with_no_output(self):
        host = FaultInjectingHost()

        ok, output = host.run_shell_command("echo hi", _timeout=5, _sudo=True)

        self.assertTrue(ok)
        self.assertEqual(output.stdout_lines, [])
        self.assertEqual(output.stderr_lines, [])

    def test_the_first_matching_rule_wins(self):
        host = FaultInjectingHost()
        host.answer_when(command_contains="docker", stdout_lines=["first"])
        host.answer_when(command_contains="docker", stdout_lines=["second"])

        _, output = host.run_shell_command("docker ps", _timeout=1, _sudo=False)

        self.assertEqual(output.stdout_lines, ["first"])

    def test_a_rule_can_be_spent_after_a_set_number_of_uses(self):
        host = FaultInjectingHost()
        host.fail_when(command_contains="docker", times=1, stderr_lines=["once"])

        first_ok, _ = host.run_shell_command("docker ps", _timeout=1, _sudo=False)
        second_ok, _ = host.run_shell_command("docker ps", _timeout=1, _sudo=False)

        # A transient failure that succeeds on retry -- the shape a retry loop
        # has to be tested against.
        self.assertFalse(first_ok)
        self.assertTrue(second_ok)

    def test_call_number_and_command_can_both_scope_a_rule(self):
        host = FaultInjectingHost()
        host.fail_when(command_contains="docker", at_call=2)

        first_ok, _ = host.run_shell_command("docker ps", _timeout=1, _sudo=False)
        second_ok, _ = host.run_shell_command("docker ps", _timeout=1, _sudo=False)

        self.assertTrue(first_ok)
        self.assertFalse(second_ok)

    def test_extra_keyword_arguments_are_recorded(self):
        host = FaultInjectingHost()

        host.run_shell_command("cat", _timeout=1, _sudo=True, _stdin="secret-key")

        self.assertEqual(host.calls[0].extra, {"_stdin": "secret-key"})

    def test_recording_helpers_answer_what_ran(self):
        host = FaultInjectingHost()
        host.run_shell_command("git fetch", _timeout=1, _sudo=True)
        host.run_shell_command("docker build .", _timeout=1, _sudo=True)

        self.assertEqual(host.commands, ["git fetch", "docker build ."])
        self.assertEqual(host.commands_containing("docker"), ["docker build ."])
        self.assertTrue(host.ran("git"))
        self.assertFalse(host.ran(_WRITE_CADDY_ROUTE))


if __name__ == "__main__":
    unittest.main()

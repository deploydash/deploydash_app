"""Connect-time enforcement of the on-disk layout version.

Written before `orchestrator.server_layout` existed (T-1.1.6, discipline D1).

A version marker that nothing reads is decoration. These tests pin the four
branches that turn it into a compatibility mechanism, and in particular the
one that is easy to get wrong: a *newer* layout must be refused outright.
Operating on a layout written by a newer client means writing to paths whose
meaning this release does not know, on a machine that is already working.
"""

import unittest
from unittest import mock

from orchestrator import server_layout, server_paths


class TestLayoutClassification(unittest.TestCase):
    def test_no_marker_and_no_legacy_root_is_an_unprovisioned_server(self):
        outcome = server_layout.classify_layout(marker_text=None, legacy_root_present=False)
        self.assertTrue(outcome.ok)
        self.assertIsNone(outcome.code)
        self.assertTrue(outcome.unprovisioned)

    def test_no_marker_but_a_legacy_root_is_a_pre_layout_1_server(self):
        # The dangerous case. This machine has real state on it, written by a
        # build that predates the marker, and the new paths would silently
        # create a second empty layout beside the running one.
        outcome = server_layout.classify_layout(marker_text=None, legacy_root_present=True)
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_UNVERSIONED")

    def test_a_matching_version_proceeds(self):
        outcome = server_layout.classify_layout(
            marker_text=f"{server_paths.LAYOUT_VERSION}\n",
            legacy_root_present=False,
        )
        self.assertTrue(outcome.ok)
        self.assertEqual(outcome.version, server_paths.LAYOUT_VERSION)
        self.assertFalse(outcome.unprovisioned)

    def test_a_newer_version_is_refused_rather_than_tolerated(self):
        outcome = server_layout.classify_layout(
            marker_text=f"{server_paths.LAYOUT_VERSION + 1}\n",
            legacy_root_present=False,
        )
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_TOO_NEW")
        self.assertIn("update", outcome.message.lower())

    def test_an_older_version_asks_for_a_migration(self):
        outcome = server_layout.classify_layout(marker_text="0\n", legacy_root_present=False)
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_MIGRATION_REQUIRED")

    def test_version_comparison_is_numeric_not_lexicographic(self):
        # "10" sorts BEFORE "9" as text. A textual comparison would read a
        # layout-10 server as older than a layout-9 client and offer to
        # migrate it downwards, which is the exact failure the too-new branch
        # exists to prevent.
        #
        # This has to be exercised at version 9, not at the current version:
        # at LAYOUT_VERSION = 1 the string and numeric comparisons agree on
        # every input, so a test written against today's constant passes
        # against a lexicographic implementation and proves nothing. That was
        # confirmed by mutation -- str() around both sides of the comparison
        # left the original version of this test green.
        with mock.patch.object(server_paths, "LAYOUT_VERSION", 9):
            self.assertEqual(
                server_layout.classify_layout(marker_text="10\n", legacy_root_present=False).code,
                "ENGINE_LAYOUT_TOO_NEW",
            )
            self.assertTrue(
                server_layout.classify_layout(marker_text="9\n", legacy_root_present=False).ok
            )
            self.assertEqual(
                server_layout.classify_layout(marker_text="8\n", legacy_root_present=False).code,
                "ENGINE_LAYOUT_MIGRATION_REQUIRED",
            )

    def test_a_marker_that_is_not_an_integer_is_refused(self):
        for text in ("", "   ", "abc", "1.5", "1 2", "-1"):
            with self.subTest(marker=text):
                outcome = server_layout.classify_layout(marker_text=text, legacy_root_present=False)
                self.assertFalse(outcome.ok)
                self.assertEqual(outcome.code, "ENGINE_LAYOUT_UNVERSIONED")

    def test_surrounding_whitespace_in_the_marker_is_tolerated(self):
        outcome = server_layout.classify_layout(
            marker_text=f"  {server_paths.LAYOUT_VERSION}  \n\n",
            legacy_root_present=False,
        )
        self.assertTrue(outcome.ok)


class _FakeHost:
    """Records commands and replays a canned result for the probe."""

    def __init__(self, stdout_lines, ok=True):
        self._stdout_lines = stdout_lines
        self._ok = ok
        self.commands = []

    def run_shell_command(self, command, _timeout=None, _sudo=None):
        self.commands.append(command)
        return self._ok, _FakeOutput(self._stdout_lines)


class _FakeOutput:
    def __init__(self, stdout_lines):
        self.stdout_lines = stdout_lines
        self.stderr_lines = []


class _SequenceHost:
    """Replay remote results so migration tests prove every ordered round trip."""

    def __init__(self, results):
        """Keep scripted replies and calls together for atomicity assertions."""
        self._results = iter(results)
        self.commands = []
        self.options = []

    def run_shell_command(self, command, _timeout=None, _sudo=None):
        """Record command options because migration must run through sudo."""
        self.commands.append(command)
        self.options.append((_timeout, _sudo))
        return next(self._results)


class TestLayoutMigration(unittest.TestCase):
    def test_layout_one_migration_atomically_advances_the_marker_to_two(self):
        """The first additive layout change must make existing servers usable."""
        host = _SequenceHost(
            [
                (True, _FakeOutput([])),
                (True, _FakeOutput(["marker=2", "legacy=0"])),
            ]
        )

        outcome = server_layout.migrate_layout(
            host,
            server_layout.LayoutState(marker_text="1", legacy_root_present=False),
        )

        self.assertTrue(outcome.ok)
        self.assertEqual(outcome.version, 2)
        self.assertEqual(len(host.commands), 2)
        self.assertIn("current=", host.commands[0])
        self.assertIn("migrate.$$", host.commands[0])
        self.assertIn("mv -f", host.commands[0])
        self.assertIn("'1'", host.commands[0])
        self.assertIn("'2'", host.commands[0])
        self.assertEqual(host.options[0], (20, True))

    def test_layout_one_migration_failure_stays_fail_closed(self):
        """A failed marker update must never be reported as a current layout."""
        host = _SequenceHost(
            [
                (
                    False,
                    _FakeOutput(
                        [],
                    ),
                )
            ]
        )

        outcome = server_layout.migrate_layout(
            host,
            server_layout.LayoutState(marker_text="1", legacy_root_present=False),
        )

        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_MIGRATION_REQUIRED")
        self.assertEqual(outcome.version, 1)
        self.assertIn("could not", outcome.message.lower())

    def test_unsupported_older_layout_is_not_mutated(self):
        """Only the reviewed one-to-two transition may change a remote marker."""
        host = _SequenceHost([])

        outcome = server_layout.migrate_layout(
            host,
            server_layout.LayoutState(marker_text="0", legacy_root_present=False),
        )

        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_MIGRATION_REQUIRED")
        self.assertEqual(host.commands, [])

    def test_non_migration_states_are_returned_without_remote_mutation(self):
        """Current and unsafe states retain classification without a write."""
        cases = (
            server_layout.LayoutState(marker_text="2", legacy_root_present=False),
            server_layout.LayoutState(marker_text="3", legacy_root_present=False),
            server_layout.LayoutState(marker_text=None, legacy_root_present=False),
            server_layout.LayoutState(
                marker_text="1",
                legacy_root_present=False,
                readable=False,
            ),
        )
        for state in cases:
            with self.subTest(state=state):
                host = _SequenceHost([])
                outcome = server_layout.migrate_layout(host, state)
                self.assertEqual(outcome, server_layout.classify_state(state))
                self.assertEqual(host.commands, [])


class TestLayoutProbe(unittest.TestCase):
    def test_probe_reports_the_marker_and_the_legacy_root_together(self):
        # Both facts must come from one round trip: two probes could observe
        # the machine in two different states if provisioning is in flight.
        host = _FakeHost(["marker=1", "legacy=0"])
        state = server_layout.read_layout_state(host)

        self.assertEqual(state.marker_text, "1")
        self.assertFalse(state.legacy_root_present)
        self.assertEqual(len(host.commands), 1)

    def test_probe_detects_a_legacy_root_with_no_marker(self):
        host = _FakeHost(["marker=", "legacy=1"])
        state = server_layout.read_layout_state(host)

        self.assertIsNone(state.marker_text)
        self.assertTrue(state.legacy_root_present)

    def test_probe_command_reads_the_paths_the_layout_actually_uses(self):
        host = _FakeHost(["marker=1", "legacy=0"])
        server_layout.read_layout_state(host)

        self.assertIn(server_paths.LAYOUT_VERSION_FILE, host.commands[0])
        self.assertIn("/opt/docker-stack", host.commands[0])

    def test_setup_verification_fails_when_the_marker_was_never_written(self):
        # Setup writing the marker and the server having it are different
        # claims. A run that silently failed to write it would look like a
        # success now and like an unversioned pre-layout-1 server forever
        # after -- the one state connect refuses to operate on.
        host = _FakeHost(["marker=", "legacy=0"])
        outcome = server_layout.verify_layout_after_setup(host)

        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_UNVERSIONED")

    def test_setup_verification_passes_when_the_marker_is_current(self):
        host = _FakeHost([f"marker={server_paths.LAYOUT_VERSION}", "legacy=0"])
        outcome = server_layout.verify_layout_after_setup(host)

        self.assertTrue(outcome.ok)
        self.assertEqual(outcome.version, server_paths.LAYOUT_VERSION)

    def test_probe_ignores_output_lines_it_does_not_recognise(self):
        # sudo banners, MOTD fragments, and shell warnings all land on
        # stdout on real machines. An unrecognised line must not be mistaken
        # for a marker, and must not abort the parse of the lines that are.
        host = _FakeHost(["sudo: unable to resolve host", "marker=1", "", "legacy=0"])
        state = server_layout.read_layout_state(host)

        self.assertEqual(state.marker_text, "1")
        self.assertFalse(state.legacy_root_present)

    def test_a_failed_probe_is_not_read_as_an_unprovisioned_server(self):
        # Treating an unreachable or permission-denied probe as "no marker"
        # would let the caller proceed to provision over a live server.
        host = _FakeHost([], ok=False)
        state = server_layout.read_layout_state(host)

        self.assertFalse(state.readable)
        outcome = server_layout.classify_state(state)
        self.assertFalse(outcome.ok)
        self.assertEqual(outcome.code, "ENGINE_LAYOUT_UNREADABLE")


if __name__ == "__main__":
    unittest.main()

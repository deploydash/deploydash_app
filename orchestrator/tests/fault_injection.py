"""Tier 0 fault injection at the one seam every remote call crosses.

Every command Deploy Dash runs on a customer's machine goes through a
``host.run_shell_command`` call -- the ``runtime_ops.Host`` Protocol. That is
the whole network surface, and it is a single injectable object, which is what
§2.2's dependency-injection work bought and what T-3.6.3 spends.

The value is not that a fake is faster than a VM. It is that a VM cannot
reliably produce the failures that matter. Filling a disk during the third
Docker command, cutting the connection between a container starting and its
health probe, or returning a status line one field short are all easy here and
nearly impossible to schedule on real hardware. Those are exactly the paths
where a defect leaves a customer's server half-configured, so they are the
paths that have to be executed rather than reasoned about.

A `FaultInjectingHost` answers every command with a default result until a rule
says otherwise. Rules are matched in the order they were added, first match
wins, and each can be scoped by what the command contains, by which call it is,
or both::

    host = FaultInjectingHost()
    host.answer_when(command_contains="git rev-parse", stdout_lines=["abc123"])
    host.fail_when(
        command_contains="docker run",
        stderr_lines=["no space left on device"],
    )

Every call is recorded regardless, so a test can assert what ran, in what
order, and what did *not* run after a failure -- which is usually the real
question. See `app_release_fault_injection_test.py`.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field


class FakeCommandOutput:
    """A command's captured output, satisfying `runtime_ops.ShellCommandOutput`.

    Structural rather than a subclass: pyinfra's own output type and this one
    both satisfy the Protocol without either knowing about the other.
    """

    def __init__(
        self,
        stdout_lines: Iterable[str] = (),
        stderr_lines: Iterable[str] = (),
    ) -> None:
        self.stdout_lines = list(stdout_lines)
        self.stderr_lines = list(stderr_lines)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return (
            f"FakeCommandOutput(stdout_lines={self.stdout_lines!r}, "
            f"stderr_lines={self.stderr_lines!r})"
        )


@dataclass(frozen=True)
class RecordedCommand:
    """One command the code under test asked the host to run."""

    number: int
    command: str
    timeout: int
    sudo: bool
    extra: dict[str, object] = field(default_factory=dict)

    def contains(self, needle: str) -> bool:
        """Whether the command text contains [needle]."""
        return needle in self.command


@dataclass
class _Rule:
    command_contains: str | None
    at_call: int | None
    ok: bool
    stdout_lines: tuple[str, ...]
    stderr_lines: tuple[str, ...]
    raises: BaseException | None
    times: int | None
    used: int = 0

    def matches(self, command: str, call_number: int) -> bool:
        if self.times is not None and self.used >= self.times:
            return False
        if self.at_call is not None and self.at_call != call_number:
            return False
        return self.command_contains is None or self.command_contains in command


class FaultInjectingHost:
    """A `runtime_ops.Host` that can be told to misbehave, and records everything.

    The default answer is success with no output, so a test only has to describe
    the failure it cares about rather than script an entire deploy.
    """

    def __init__(
        self,
        *,
        default_ok: bool = True,
        default_stdout_lines: Iterable[str] = (),
        default_stderr_lines: Iterable[str] = (),
    ) -> None:
        self._default_ok = default_ok
        self._default_stdout = tuple(default_stdout_lines)
        self._default_stderr = tuple(default_stderr_lines)
        self._rules: list[_Rule] = []
        self.calls: list[RecordedCommand] = []

    # --- programming -----------------------------------------------------

    def answer_when(
        self,
        *,
        command_contains: str | None = None,
        at_call: int | None = None,
        stdout_lines: Iterable[str] = (),
        stderr_lines: Iterable[str] = (),
        ok: bool = True,
        times: int | None = None,
    ) -> FaultInjectingHost:
        """Answers a matching command with [stdout_lines].

        Use it for the facts a deploy reads back -- a commit sha, a container
        status line, a manifest. Returning a *wrong* fact here is the "corrupt
        facts" mode: the command succeeds and the parser is handed nonsense,
        which is a different failure from the command failing.
        """
        self._rules.append(
            _Rule(
                command_contains=command_contains,
                at_call=at_call,
                ok=ok,
                stdout_lines=tuple(stdout_lines),
                stderr_lines=tuple(stderr_lines),
                raises=None,
                times=times,
            )
        )
        return self

    def fail_when(
        self,
        *,
        command_contains: str | None = None,
        at_call: int | None = None,
        stderr_lines: Iterable[str] = ("remote command failed",),
        stdout_lines: Iterable[str] = (),
        times: int | None = None,
    ) -> FaultInjectingHost:
        """Fails a matching command the way a real one fails: `ok` false.

        This is the ordinary remote failure. A command that exits non-zero does
        not raise -- pyinfra returns `(False, output)` -- so anything that
        models a failed command as an exception is testing a shape production
        never produces.
        """
        self._rules.append(
            _Rule(
                command_contains=command_contains,
                at_call=at_call,
                ok=False,
                stdout_lines=tuple(stdout_lines),
                stderr_lines=tuple(stderr_lines),
                raises=None,
                times=times,
            )
        )
        return self

    def truncate_when(
        self,
        *,
        stdout_lines: Sequence[str],
        keep: int,
        command_contains: str | None = None,
        at_call: int | None = None,
        times: int | None = None,
    ) -> FaultInjectingHost:
        """Succeeds, but returns only the first [keep] lines of [stdout_lines].

        A connection that drops mid-stream, or a command killed after printing
        part of its answer. The command reports success, so only a parser that
        checks what it received will notice.
        """
        return self.answer_when(
            command_contains=command_contains,
            at_call=at_call,
            stdout_lines=tuple(stdout_lines)[:keep],
            times=times,
        )

    def raise_when(
        self,
        error: BaseException,
        *,
        command_contains: str | None = None,
        at_call: int | None = None,
        times: int | None = None,
    ) -> FaultInjectingHost:
        """Raises [error] instead of answering.

        The mid-sequence disconnect: the transport itself fails rather than the
        command. Nothing in the release state machine catches per-command
        exceptions, so this reaches the operation-level handler -- which is the
        behaviour under test.
        """
        self._rules.append(
            _Rule(
                command_contains=command_contains,
                at_call=at_call,
                ok=False,
                stdout_lines=(),
                stderr_lines=(),
                raises=error,
                times=times,
            )
        )
        return self

    # --- the seam --------------------------------------------------------

    def run_shell_command(
        self,
        command: str,
        _timeout: int = 0,
        _sudo: bool = False,
        **extra: object,
    ) -> tuple[bool, FakeCommandOutput]:
        """Records the call, then answers per the first matching rule."""
        call_number = len(self.calls) + 1
        self.calls.append(
            RecordedCommand(
                number=call_number,
                command=command,
                timeout=_timeout,
                sudo=_sudo,
                extra=dict(extra),
            )
        )
        for rule in self._rules:
            if not rule.matches(command, call_number):
                continue
            rule.used += 1
            if rule.raises is not None:
                raise rule.raises
            return rule.ok, FakeCommandOutput(rule.stdout_lines, rule.stderr_lines)
        return self._default_ok, FakeCommandOutput(self._default_stdout, self._default_stderr)

    # --- recording -------------------------------------------------------

    @property
    def commands(self) -> list[str]:
        """Every command run, in order."""
        return [call.command for call in self.calls]

    def commands_containing(self, needle: str) -> list[str]:
        """Every command run whose text contains [needle]."""
        return [call.command for call in self.calls if call.contains(needle)]

    def ran(self, needle: str) -> bool:
        """Whether any command containing [needle] was run.

        The negative is usually the interesting assertion: after a failure, the
        steps that should not have happened must not have happened.
        """
        return any(call.contains(needle) for call in self.calls)


class RecordingClock:
    """The release state machine's clock, replaced and recorded.

    The counterpart of `FaultInjectingHost`: the host records what was run,
    this records what was waited for. It returns immediately, so a deploy that
    would take 25 seconds of real waiting runs at unit-test speed, and the
    waits are still *observable* -- which zeroing the delay constants threw
    away. With the constants at zero a test cannot tell a deploy that gave its
    candidate the full readiness window from one that skipped the wait
    entirely, and that difference is a customer's site staying up.

    Install it with `install_recording_clock`, which restores the previous
    value on cleanup.
    """

    def __init__(self) -> None:
        self.waits: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.waits.append(seconds)

    @property
    def total_seconds(self) -> float:
        """Everything the machine asked to wait for, added up."""
        return sum(self.waits)

    def waits_of(self, seconds: float) -> int:
        """How many times it asked to wait exactly [seconds]."""
        return sum(1 for wait in self.waits if wait == seconds)


def install_recording_clock(test_case) -> RecordingClock:
    """Replace the release state machine's clock for the duration of a test.

    Restores the previous value through `addCleanup`, so a test that fails
    part-way does not leave the next one running with a stubbed clock.
    """

    from orchestrator.app_runtime_parts import _shared

    clock = RecordingClock()
    previous = _shared.release_sleep_override_for_tests
    _shared.release_sleep_override_for_tests = clock
    test_case.addCleanup(
        setattr,
        _shared,
        "release_sleep_override_for_tests",
        previous,
    )
    return clock


class FaultInjectingSession:
    """The `session` the release state machine threads around.

    It carries the host and records whether it was closed, which is how a test
    checks that a failure path still releases the connection.
    """

    def __init__(self, host: FaultInjectingHost) -> None:
        self.host = host
        self.closed = False

    def close(self) -> dict[str, object]:
        """Closes the session, reporting no disconnect error."""
        self.closed = True
        return {"disconnect_error": None}

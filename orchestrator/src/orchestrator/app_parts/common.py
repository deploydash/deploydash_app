from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ..pyinfra_runtime import PyinfraRuntimeSession
from ..setup_parts.common import StepAction

StepRegistrar = Callable[["PyinfraRuntimeSession"], None]


@dataclass
class AppAction(StepAction):
    """Keep the app action name while sharing the workflow action representation."""


@dataclass
class AppStep:
    id: str
    title: str
    commands: list[str]
    part: str
    notes: str | None = None
    actions: list[AppAction] = field(default_factory=list)
    register: StepRegistrar | None = field(
        default=None,
        compare=False,
        repr=False,
    )

    def to_dict(self):
        payload = {
            "id": self.id,
            "title": self.title,
            "commands": list(self.commands),
            "part": self.part,
        }
        if self.notes:
            payload["notes"] = self.notes
        payload["actions"] = [action.to_dict() for action in self.actions]
        return payload

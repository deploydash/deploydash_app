from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ..pyinfra_runtime import PyinfraRuntimeSession


StepRegistrar = Callable[["PyinfraRuntimeSession"], None]


@dataclass
class StepAction:
    id: str
    label: str
    description: str
    failure_phase: str = "unknown"

    def to_dict(self):
        return {
            "id": self.id,
            "label": self.label,
            "description": self.description,
        }


@dataclass
class SetupStep:
    id: str
    title: str
    commands: list[str]
    part: str
    notes: str | None = None
    actions: list[StepAction] = field(default_factory=list)
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

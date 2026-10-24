"""Compatibility exports for web-app deployment and runtime operations.

Implementations live in ``app_runtime_parts`` grouped by responsibility;
callers continue to import this legacy module while the engine contract
remains stable.
"""

# ruff: noqa: F403

from .app_runtime_parts._shared import *
from .app_runtime_parts.command_execution import *
from .app_runtime_parts.deployment import *
from .app_runtime_parts.release_lifecycle import *
from .app_runtime_parts.runtime_operations import *

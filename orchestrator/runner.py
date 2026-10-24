import sys as _sys
from importlib import import_module as _import_module

_module = _import_module("orchestrator.runner")
_sys.modules[__name__] = _module

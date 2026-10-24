#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_ROOT / "src"))

# Import after sys.path is extended above so the local package resolves
# without an install step.
from orchestrator.runtime_bundle import main  # noqa: E402

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_ROOT / "src"))

# Import after sys.path is extended above so the local package resolves
# without an install step.
from orchestrator.release_helpers import resolve_build_metadata, write_github_env  # noqa: E402


def main() -> None:
    values = resolve_build_metadata(
        input_build_name=os.environ.get("INPUT_BUILD_NAME"),
        input_build_number=os.environ.get("INPUT_BUILD_NUMBER"),
        github_run_number=os.environ.get("GITHUB_RUN_NUMBER"),
        github_ref_type=os.environ.get("GITHUB_REF_TYPE"),
        github_ref_name=os.environ.get("GITHUB_REF_NAME"),
    )

    github_env_path = (os.environ.get("GITHUB_ENV") or "").strip()
    if github_env_path:
        write_github_env(Path(github_env_path), values)

    for key, value in values.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()

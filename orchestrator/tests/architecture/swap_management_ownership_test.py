"""Architecture invariant: managed swap mutation has one source owner."""

import unittest
from pathlib import Path


class SwapManagementOwnershipTest(unittest.TestCase):
    def test_swap_mutation_commands_exist_only_in_the_shared_owner(self):
        """Prevent setup and runtime workflows from growing separate swap logic."""
        source_root = Path(__file__).resolve().parents[2] / "src" / "orchestrator"
        owner = source_root / "swap_management.py"
        forbidden = ("swapoff /swapfile", "mkswap /swapfile")
        offenders = []

        for path in sorted(source_root.rglob("*.py")):
            if path == owner:
                continue
            text = path.read_text(encoding="utf-8")
            if any(command in text for command in forbidden):
                offenders.append(str(path.relative_to(source_root)))

        self.assertEqual(
            offenders,
            [],
            "Managed swap mutation commands must live only in swap_management.py.",
        )


if __name__ == "__main__":
    unittest.main()

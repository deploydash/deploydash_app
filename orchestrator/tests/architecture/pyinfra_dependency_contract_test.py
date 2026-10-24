"""Guard the pyinfra capability floor required by first-party operations."""

import unittest

from pyinfra.operations import docker


class TestPyinfraDependencyContract(unittest.TestCase):
    """Keep the locked dependency aligned with operations used by Deploy Dash."""

    def test_runtime_exposes_required_pyinfra_operations(self) -> None:
        """Require container exec before callers migrate from raw shell commands."""
        self.assertTrue(
            hasattr(docker, "container_exec"),
            "pyinfra must expose docker.container_exec",
        )


if __name__ == "__main__":
    unittest.main()

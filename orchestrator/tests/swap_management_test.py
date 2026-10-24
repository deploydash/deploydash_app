import pathlib
import subprocess
import tempfile
import unittest

from orchestrator.swap_management import (
    render_initial_swap_command,
    render_swap_reconcile_command,
    swap_size_changed,
)


class SwapManagementTest(unittest.TestCase):
    def test_size_comparison_uses_a_small_mib_tolerance(self):
        """Avoid resizing for display noise while detecting a real size request."""
        self.assertFalse(swap_size_changed(2.0, 2.0009))
        self.assertTrue(swap_size_changed(2.0, 2.002))

    def test_resize_guards_resources_and_preserves_swap_until_new_is_active(self):
        """A resize must fail safely before the old active swap file is removed."""
        command = render_swap_reconcile_command(4)

        self.assertIn("MemAvailable", command)
        self.assertIn("current swap use exceeds the available RAM margin", command)
        self.assertIn("df --output=avail -B1 /", command)
        self.assertIn("insufficient disk space", command)
        self.assertIn("trap cleanup_new_swap EXIT", command)
        self.assertIn("trap 'exit 1' INT TERM", command)
        self.assertNotIn("trap cleanup_new_swap EXIT INT TERM", command)
        self.assertNotIn("dd if=/dev/zero", command)
        self.assertIn("fallocate -l 512M /swapfile.new", command)
        self.assertLess(
            command.index("mkswap /swapfile.new"),
            command.index("swapon /swapfile.new"),
        )
        self.assertLess(
            command.index("swapon /swapfile.new"),
            command.index("swapoff /swapfile;"),
        )
        self.assertLess(
            command.index("swapoff /swapfile;"),
            command.index("fallocate -l 4096M /swapfile;"),
        )
        self.assertLess(
            command.index("mkswap /swapfile >/dev/null"),
            command.index("swapon /swapfile;"),
        )
        self.assertLess(
            command.index("swapon /swapfile;"), command.rindex("swapoff /swapfile.new;")
        )
        self.assertIn('if [ "${ROLLBACK_FAILED}" -eq 0 ]; then', command)
        self.assertIn("Swap resize rollback failed", command)

    def test_disable_checks_ram_and_never_swallows_active_swapoff_failure(self):
        """Removing swap must refuse unsafe memory pressure and surface swapoff errors."""
        command = render_swap_reconcile_command(0)

        self.assertIn("MemAvailable", command)
        self.assertIn("swapoff /swapfile;", command)
        self.assertNotIn("swapoff /swapfile >/dev/null 2>&1 || true", command)
        self.assertNotIn("/swapfile.new", command)

    def test_resize_leaves_temporary_swap_active_when_old_swap_restore_fails(self):
        """Failed rollback must preserve temporary swap and replace the original error."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            main_swap = root / "swapfile"
            old_swap = root / "swapfile.old"
            temporary_swap = root / "swapfile.new"
            active_main = root / "active-main"
            active_temporary = root / "active-temporary"
            fstab = root / "fstab"
            meminfo = root / "meminfo"
            trace = root / "trace"
            main_swap.write_text("old", encoding="utf-8")
            active_main.touch()
            fstab.write_text(f"{main_swap} none swap sw 0 0\n", encoding="utf-8")
            meminfo.write_text("MemAvailable: 8388608 kB\n", encoding="utf-8")

            command = render_swap_reconcile_command(4)
            replacements = {
                "/swapfile.new": "__TEMP_SWAP__",
                "/swapfile.old": "__OLD_SWAP__",
                "/swapfile": "__MAIN_SWAP__",
                "/etc/fstab": "__FSTAB__",
                "/proc/meminfo": "__MEMINFO__",
            }
            for original, placeholder in replacements.items():
                command = command.replace(original, placeholder)
            command = (
                command.replace("__TEMP_SWAP__", str(temporary_swap))
                .replace("__OLD_SWAP__", str(old_swap))
                .replace("__MAIN_SWAP__", str(main_swap))
                .replace("__FSTAB__", str(fstab))
                .replace("__MEMINFO__", str(meminfo))
            )
            fake_commands = f"""
df() {{ printf '99999999999\\n'; }}
chmod() {{ return 0; }}
mkswap() {{ return 0; }}
fallocate() {{
  target="${{@: -1}}"
  if [ "$target" = "{main_swap}" ]; then return 1; fi
  : > "$target"
}}
swapon() {{
  if [[ "$*" == *"--show=USED,NAME"* ]]; then
    [ -e "{active_main}" ] && printf '0 {main_swap}\\n'
    return 0
  fi
  if [[ "$*" == *"--show=NAME"* ]]; then
    [ -e "{active_main}" ] && printf '{main_swap}\\n'
    [ -e "{active_temporary}" ] && printf '{temporary_swap}\\n'
    return 0
  fi
  if [ "$1" = "{temporary_swap}" ]; then touch "{active_temporary}"; return 0; fi
  if [ "$1" = "{main_swap}" ]; then
    printf 'old restore attempted\\n' >> "{trace}"
    return 1
  fi
  return 1
}}
swapoff() {{
  if [ "$1" = "{main_swap}" ]; then rm -f "{active_main}"; return 0; fi
  if [ "$1" = "{temporary_swap}" ]; then rm -f "{active_temporary}"; return 0; fi
  return 1
}}
"""

            result = subprocess.run(
                ["bash", "-c", fake_commands + command],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rollback failed", result.stderr.lower())
            self.assertTrue(main_swap.is_file())
            self.assertTrue(temporary_swap.is_file())
            self.assertTrue(active_temporary.is_file())
            self.assertIn("old restore attempted", trace.read_text(encoding="utf-8"))

    def test_initial_setup_sizes_from_ram_and_free_disk_without_dd(self):
        """First-run setup must cap allocation and clean partial swap on failure."""
        command = render_initial_swap_command()

        self.assertIn("MemTotal", command)
        self.assertIn("df --output=avail -B1 /", command)
        self.assertIn("AVAILABLE_DISK_BYTES / 4", command)
        self.assertIn("Swap setup skipped: insufficient free disk space", command)
        self.assertIn("trap cleanup_initial_swap EXIT", command)
        self.assertIn("trap 'exit 1' INT TERM", command)
        self.assertNotIn("trap cleanup_initial_swap EXIT INT TERM", command)
        self.assertIn("case \"${MEM_TOTAL_KIB}\" in ''|*[!0-9]*)", command)
        self.assertIn("case \"${AVAILABLE_DISK_BYTES}\" in ''|*[!0-9]*)", command)
        self.assertNotIn("''*|", command)
        self.assertNotIn("dd if=/dev/zero", command)


if __name__ == "__main__":
    unittest.main()

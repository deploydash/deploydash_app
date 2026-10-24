"""Render the single managed swap-file lifecycle used across server workflows."""

_MIB_PER_GIB = 1024
_SWAP_SIZE_TOLERANCE_MIB = 1
_RAM_MARGIN_KIB = 256 * 1024
_DISK_MARGIN_BYTES = 256 * 1024 * 1024


def swap_size_changed(current_gb: float, requested_gb: float) -> bool:
    """Compare in MiB so display rounding cannot trigger a destructive resize."""
    current_mib = round(float(current_gb) * _MIB_PER_GIB)
    requested_mib = round(float(requested_gb) * _MIB_PER_GIB)
    return abs(current_mib - requested_mib) > _SWAP_SIZE_TOLERANCE_MIB


def render_swap_reconcile_command(swap_gb: float) -> str:
    """Resize managed swap transactionally while preserving the active old file."""
    target_mib = max(0, round(float(swap_gb) * _MIB_PER_GIB))
    ram_guard = (
        'OLD_SWAP_USED_BYTES="$(swapon --noheadings --bytes --show=USED,NAME '
        '2>/dev/null | awk \'$2=="/swapfile" {print $1; exit}\' || true)"; '
        'OLD_SWAP_USED_BYTES="${OLD_SWAP_USED_BYTES:-0}"; '
        "MEM_AVAILABLE_KIB=\"$(awk '/^MemAvailable:/ {print $2; exit}' "
        '/proc/meminfo)"; '
        f"REQUIRED_RAM_KIB=$((OLD_SWAP_USED_BYTES / 1024 + {_RAM_MARGIN_KIB})); "
        'if [ -z "${MEM_AVAILABLE_KIB}" ] || '
        '[ "${MEM_AVAILABLE_KIB}" -lt "${REQUIRED_RAM_KIB}" ]; then '
        "echo 'Swap resize refused: current swap use exceeds the available RAM margin.' >&2; "
        "exit 1; fi; "
    )
    if target_mib == 0:
        return (
            "set -eu; "
            + ram_guard
            + "if swapon --noheadings --show=NAME | grep -Fxq /swapfile; then "
            "swapoff /swapfile; fi; "
            "rm -f /swapfile; "
            "sed -i -E '/^\\/swapfile[[:space:]]/d' /etc/fstab; "
        )

    target_bytes = target_mib * 1024 * 1024
    temporary_mib = min(target_mib, 512)
    required_disk_bytes = target_bytes + (temporary_mib * 1024 * 1024) + _DISK_MARGIN_BYTES
    return (
        "set -eu; " + ram_guard + f"TARGET_SWAP_BYTES={target_bytes}; "
        "AVAILABLE_DISK_BYTES=\"$(df --output=avail -B1 / | tail -n1 | tr -d '[:space:]')\"; "
        f"REQUIRED_DISK_BYTES={required_disk_bytes}; "
        "case \"${AVAILABLE_DISK_BYTES}\" in ''|*[!0-9]*) "
        "echo 'Swap resize refused: free disk space could not be measured.' >&2; exit 1 ;; "
        "esac; "
        'if [ "${AVAILABLE_DISK_BYTES}" -lt "${REQUIRED_DISK_BYTES}" ]; then '
        "echo 'Swap resize refused: insufficient disk space for the requested size and safety margin.' >&2; "
        "exit 1; fi; "
        "if grep -q '^/swapfile[[:space:]]' /etc/fstab; then "
        "sed -i -E 's|^/swapfile[[:space:]].*$|/swapfile none swap sw 0 0|' /etc/fstab; "
        "else echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi; "
        "OLD_SWAP_WAS_ACTIVE=0; "
        "OLD_SWAP_RENAMED=0; "
        "TEMP_SWAP_ACTIVE=0; "
        "NEW_SWAP_ACTIVE=0; "
        "cleanup_new_swap() { "
        'ORIGINAL_STATUS="$?"; '
        "trap - EXIT INT TERM; "
        "ROLLBACK_FAILED=0; "
        'if [ "${NEW_SWAP_ACTIVE}" -eq 1 ]; then '
        "if swapoff /swapfile >/dev/null 2>&1; then "
        "rm -f /swapfile; NEW_SWAP_ACTIVE=0; "
        "else ROLLBACK_FAILED=1; fi; fi; "
        'if [ "${OLD_SWAP_RENAMED}" -eq 1 ] && [ -e /swapfile.old ]; then '
        'if [ "${NEW_SWAP_ACTIVE}" -eq 0 ]; then '
        "rm -f /swapfile; "
        "if mv /swapfile.old /swapfile; then "
        "if swapon /swapfile >/dev/null 2>&1; then "
        "OLD_SWAP_RENAMED=0; OLD_SWAP_WAS_ACTIVE=0; "
        "else ROLLBACK_FAILED=1; fi; "
        "else ROLLBACK_FAILED=1; fi; "
        "else ROLLBACK_FAILED=1; fi; "
        'elif [ "${OLD_SWAP_WAS_ACTIVE}" -eq 1 ] && [ -e /swapfile ]; then '
        "if ! swapon --noheadings --show=NAME | grep -Fxq /swapfile; then "
        "if ! swapon /swapfile >/dev/null 2>&1; then ROLLBACK_FAILED=1; fi; fi; "
        'elif [ "${NEW_SWAP_ACTIVE}" -eq 0 ]; then rm -f /swapfile; fi; '
        'if [ "${TEMP_SWAP_ACTIVE}" -eq 1 ]; then '
        'if [ "${ROLLBACK_FAILED}" -eq 0 ]; then '
        "if swapoff /swapfile.new >/dev/null 2>&1; then "
        "TEMP_SWAP_ACTIVE=0; rm -f /swapfile.new; "
        "else ROLLBACK_FAILED=1; fi; fi; "
        "else rm -f /swapfile.new; fi; "
        'if [ "${ROLLBACK_FAILED}" -ne 0 ]; then '
        "echo 'Swap resize rollback failed; temporary swap was left active when possible.' >&2; "
        "exit 2; fi; "
        'exit "${ORIGINAL_STATUS}"; '
        "}; "
        "trap cleanup_new_swap EXIT; "
        "trap 'exit 1' INT TERM; "
        "rm -f /swapfile.new; "
        f"fallocate -l {temporary_mib}M /swapfile.new; "
        "chmod 600 /swapfile.new; "
        "mkswap /swapfile.new >/dev/null; "
        "swapon /swapfile.new; "
        "TEMP_SWAP_ACTIVE=1; "
        "if swapon --noheadings --show=NAME | grep -Fxq /swapfile; then "
        "OLD_SWAP_WAS_ACTIVE=1; "
        "swapoff /swapfile; "
        "mv /swapfile /swapfile.old; "
        "OLD_SWAP_RENAMED=1; "
        "else rm -f /swapfile; fi; "
        f"fallocate -l {target_mib}M /swapfile; "
        "chmod 600 /swapfile; "
        "mkswap /swapfile >/dev/null; "
        "swapon /swapfile; "
        "NEW_SWAP_ACTIVE=1; "
        "swapoff /swapfile.new; "
        "TEMP_SWAP_ACTIVE=0; "
        "rm -f /swapfile.new; "
        'if [ "${OLD_SWAP_RENAMED}" -eq 1 ]; then '
        "rm -f /swapfile.old; "
        "OLD_SWAP_RENAMED=0; "
        "OLD_SWAP_WAS_ACTIVE=0; fi; "
        "trap - EXIT INT TERM; "
    )


def render_initial_swap_command() -> str:
    """Provision conservative first-run swap without risking a full root disk."""
    return (
        "set -eu; "
        "if swapon --noheadings --show=NAME | grep -Fxq /swapfile; then exit 0; fi; "
        "MEM_TOTAL_KIB=\"$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)\"; "
        "AVAILABLE_DISK_BYTES=\"$(df --output=avail -B1 / | tail -n1 | tr -d '[:space:]')\"; "
        "case \"${MEM_TOTAL_KIB}\" in ''|*[!0-9]*) "
        "echo 'Swap setup skipped: server memory could not be measured.' >&2; exit 0 ;; esac; "
        "case \"${AVAILABLE_DISK_BYTES}\" in ''|*[!0-9]*) "
        "echo 'Swap setup skipped: free disk space could not be measured.' >&2; exit 0 ;; esac; "
        "TARGET_SWAP_MIB=$((MEM_TOTAL_KIB / 1024)); "
        'if [ "${TARGET_SWAP_MIB}" -gt 4096 ]; then TARGET_SWAP_MIB=4096; fi; '
        "DISK_CAP_MIB=$((AVAILABLE_DISK_BYTES / 4 / 1024 / 1024)); "
        'if [ "${TARGET_SWAP_MIB}" -gt "${DISK_CAP_MIB}" ]; then '
        'TARGET_SWAP_MIB="${DISK_CAP_MIB}"; fi; '
        'if [ "${TARGET_SWAP_MIB}" -lt 512 ]; then '
        "echo 'Swap setup skipped: insufficient free disk space for a safe swap file.' >&2; "
        "exit 0; fi; "
        "cleanup_initial_swap() { "
        "if swapon --noheadings --show=NAME | grep -Fxq /swapfile; then "
        "swapoff /swapfile; fi; "
        "rm -f /swapfile; "
        "}; "
        "trap cleanup_initial_swap EXIT; "
        "trap 'exit 1' INT TERM; "
        "rm -f /swapfile; "
        'fallocate -l "${TARGET_SWAP_MIB}M" /swapfile; '
        "chmod 600 /swapfile; "
        "mkswap /swapfile >/dev/null; "
        "swapon /swapfile; "
        "trap - EXIT INT TERM; "
        "if grep -q '^/swapfile[[:space:]]' /etc/fstab; then "
        "sed -i -E 's|^/swapfile[[:space:]].*$|/swapfile none swap sw 0 0|' /etc/fstab; "
        "else echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi; "
    )

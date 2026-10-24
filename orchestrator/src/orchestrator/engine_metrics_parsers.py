import json
from datetime import UTC, datetime

from . import shell_output
from .container_status import container_status_from_payload, normalize_container_status


def _get_primary_disk_gb(block_devices):
    if not isinstance(block_devices, dict):
        return None

    root_blocks = None
    total_blocks = 0

    for device_data in block_devices.values():
        if not isinstance(device_data, dict):
            continue
        blocks_raw = device_data.get("blocks")
        try:
            blocks = int(blocks_raw)
        except (TypeError, ValueError):
            continue

        total_blocks += blocks
        if device_data.get("mount") == "/":
            root_blocks = blocks

    chosen_blocks = root_blocks if root_blocks is not None else total_blocks
    if chosen_blocks <= 0:
        return None

    return round(chosen_blocks / (1024 * 1024))


def _parse_positive_int(value):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    if parsed < 0:
        return None
    return parsed


def _parse_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _parse_percent(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("%"):
        text = text[:-1]
    return _parse_float(text)


def _parse_docker_stats_output(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    for raw_line in reversed(stdout_lines):
        line = str(raw_line).strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        normalized = {}
        for key, value in parsed.items():
            if value is None:
                continue
            normalized[str(key)] = str(value)
        if normalized:
            normalized["collected_at"] = datetime.now(UTC).isoformat()
            return normalized
    return None


def _parse_http_service_status_output(output):
    parsed = shell_output.parse_key_values(output)
    if parsed:
        container_status = container_status_from_payload(parsed, "container")
        return {
            "running": container_status["running"],
            "health": container_status["health"],
            "container_status": container_status,
        }
    # Fallback: some builds answer with a single JSON line instead of the
    # KEY=value protocol, so the raw lines are still needed here.
    for raw_line in reversed(getattr(output, "stdout_lines", None) or []):
        line = str(raw_line).strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        container_status = parsed.get("container_status")
        if not isinstance(container_status, dict):
            container_status = normalize_container_status(
                present=bool(parsed.get("running")),
                docker_state="running" if parsed.get("running") else "exited",
                running=bool(parsed.get("running")),
            )
        return {
            "running": bool(parsed.get("running")),
            "health": container_status.get("health", "unknown"),
            "container_status": container_status,
        }
    return {
        "running": False,
        "health": "unknown",
        "container_status": normalize_container_status(),
    }


def _parse_server_overview_metrics_output(output):
    metrics = {
        "collected_at": datetime.now(UTC).isoformat(),
        "system": {},
        "cpu": {},
        "memory": {},
        "disk": {},
        "network": {
            "interfaces": [],
        },
        "io": {
            "devices": [],
        },
        "collection": {
            "retention_days": 90,
        },
    }

    # Line-at-a-time, not `parse_key_values`: this protocol repeats keys --
    # one `network_*` and one `io_*` group per interface and per device --
    # and a dictionary keeps only the last of each. Dispatching per line is
    # what makes the repetition meaningful.
    for raw_line in getattr(output, "stdout_lines", None) or []:
        parsed_line = shell_output.split_key_value(raw_line)
        if parsed_line is None:
            continue
        key, value = parsed_line

        if key == "uptime_seconds":
            uptime_seconds = _parse_positive_int(value)
            if uptime_seconds is not None:
                metrics["system"]["uptime_seconds"] = uptime_seconds
            continue

        if key == "booted_at":
            if value:
                metrics["system"]["booted_at"] = value
            continue

        if key == "cpu_idle":
            idle = _parse_float(value)
            if idle is not None:
                metrics["cpu"]["idle_percent"] = max(0.0, min(100.0, idle))
            continue

        if key == "load_avg":
            parts = value.split()
            if len(parts) >= 3:
                load1 = _parse_float(parts[0])
                load5 = _parse_float(parts[1])
                load15 = _parse_float(parts[2])
                if load1 is not None:
                    metrics["cpu"]["load_1m"] = load1
                if load5 is not None:
                    metrics["cpu"]["load_5m"] = load5
                if load15 is not None:
                    metrics["cpu"]["load_15m"] = load15
            continue

        if key == "mem":
            parts = value.split()
            if len(parts) >= 4:
                total_mb = _parse_positive_int(parts[0])
                used_mb = _parse_positive_int(parts[1])
                free_mb = _parse_positive_int(parts[2])
                available_mb = _parse_positive_int(parts[3])
                if total_mb is not None:
                    metrics["memory"]["total_mb"] = total_mb
                if used_mb is not None:
                    metrics["memory"]["used_mb"] = used_mb
                if free_mb is not None:
                    metrics["memory"]["free_mb"] = free_mb
                if available_mb is not None:
                    metrics["memory"]["available_mb"] = available_mb
            continue

        if key == "swap":
            parts = value.split()
            if len(parts) >= 3:
                total_mb = _parse_positive_int(parts[0])
                used_mb = _parse_positive_int(parts[1])
                free_mb = _parse_positive_int(parts[2])
                if total_mb is not None:
                    metrics["memory"]["swap_total_mb"] = total_mb
                if used_mb is not None:
                    metrics["memory"]["swap_used_mb"] = used_mb
                if free_mb is not None:
                    metrics["memory"]["swap_free_mb"] = free_mb
            continue

        if key == "disk_root":
            parts = value.split()
            if len(parts) >= 4:
                total_bytes = _parse_positive_int(parts[0])
                used_bytes = _parse_positive_int(parts[1])
                free_bytes = _parse_positive_int(parts[2])
                used_percent = _parse_percent(parts[3])
                if total_bytes is not None:
                    metrics["disk"]["root_total_bytes"] = total_bytes
                if used_bytes is not None:
                    metrics["disk"]["root_used_bytes"] = used_bytes
                if free_bytes is not None:
                    metrics["disk"]["root_free_bytes"] = free_bytes
                if used_percent is not None:
                    metrics["disk"]["root_used_percent"] = max(
                        0.0,
                        min(100.0, used_percent),
                    )
            continue

        if key == "inode_root":
            inode_used_percent = _parse_percent(value)
            if inode_used_percent is not None:
                metrics["disk"]["root_inode_used_percent"] = max(
                    0.0,
                    min(100.0, inode_used_percent),
                )
            continue

        if key == "net_dev":
            parts = value.split(",")
            if len(parts) >= 3:
                name = parts[0].strip()
                rx_kbps = _parse_float(parts[1].strip())
                tx_kbps = _parse_float(parts[2].strip())
                if name and rx_kbps is not None and tx_kbps is not None:
                    metrics["network"]["interfaces"].append(
                        {
                            "name": name,
                            "rx_kbps": max(0.0, rx_kbps),
                            "tx_kbps": max(0.0, tx_kbps),
                        }
                    )
            continue

        if key == "disk_dev":
            parts = value.split(",")
            if len(parts) >= 4:
                name = parts[0].strip()
                read_kbps = _parse_float(parts[1].strip())
                write_kbps = _parse_float(parts[2].strip())
                util_percent = _parse_float(parts[3].strip())
                if (
                    name
                    and read_kbps is not None
                    and write_kbps is not None
                    and util_percent is not None
                ):
                    metrics["io"]["devices"].append(
                        {
                            "name": name,
                            "read_kbps": max(0.0, read_kbps),
                            "write_kbps": max(0.0, write_kbps),
                            "util_percent": max(0.0, min(100.0, util_percent)),
                        }
                    )
            continue

        if key == "sysstat_files":
            count = _parse_positive_int(value)
            if count is not None:
                metrics["collection"]["sysstat_file_count"] = count
            continue

        if key == "sysstat_oldest":
            if value:
                metrics["collection"]["oldest_file"] = value
            continue

        if key == "sysstat_newest":
            if value:
                metrics["collection"]["newest_file"] = value
            continue

        if key == "retention_days":
            retention_days = _parse_positive_int(value)
            if retention_days is not None and retention_days > 0:
                metrics["collection"]["retention_days"] = retention_days
            continue

    cpu_idle = metrics["cpu"].get("idle_percent")
    if isinstance(cpu_idle, (int, float)):
        metrics["cpu"]["usage_percent"] = max(0.0, min(100.0, 100.0 - cpu_idle))

    memory_total = metrics["memory"].get("total_mb")
    memory_used = metrics["memory"].get("used_mb")
    if isinstance(memory_total, int) and isinstance(memory_used, int) and memory_total > 0:
        metrics["memory"]["used_percent"] = round((memory_used / memory_total) * 100.0, 2)

    swap_total = metrics["memory"].get("swap_total_mb")
    swap_used = metrics["memory"].get("swap_used_mb")
    if isinstance(swap_total, int) and isinstance(swap_used, int) and swap_total > 0:
        metrics["memory"]["swap_used_percent"] = round(
            (swap_used / swap_total) * 100.0,
            2,
        )

    root_total = metrics["disk"].get("root_total_bytes")
    root_used = metrics["disk"].get("root_used_bytes")
    root_free = metrics["disk"].get("root_free_bytes")
    if isinstance(root_total, int):
        metrics["disk"]["root_total_gb"] = round(root_total / (1024**3), 2)
    if isinstance(root_used, int):
        metrics["disk"]["root_used_gb"] = round(root_used / (1024**3), 2)
    if isinstance(root_free, int):
        metrics["disk"]["root_free_gb"] = round(root_free / (1024**3), 2)

    interfaces = metrics["network"]["interfaces"]
    if isinstance(interfaces, list) and interfaces:
        total_rx = 0.0
        total_tx = 0.0
        top_interface = None
        for interface in interfaces:
            rx = interface.get("rx_kbps", 0.0)
            tx = interface.get("tx_kbps", 0.0)
            total_rx += rx
            total_tx += tx
            score = rx + tx
            if top_interface is None or score > (
                top_interface["rx_kbps"] + top_interface["tx_kbps"]
            ):
                top_interface = interface
        metrics["network"]["total_rx_kbps"] = round(total_rx, 2)
        metrics["network"]["total_tx_kbps"] = round(total_tx, 2)
        metrics["network"]["top_interface"] = top_interface

    devices = metrics["io"]["devices"]
    if isinstance(devices, list) and devices:
        total_read = 0.0
        total_write = 0.0
        top_device = None
        for device in devices:
            read_kbps = device.get("read_kbps", 0.0)
            write_kbps = device.get("write_kbps", 0.0)
            util_percent = device.get("util_percent", 0.0)
            total_read += read_kbps
            total_write += write_kbps
            if top_device is None or util_percent > top_device["util_percent"]:
                top_device = device
        metrics["io"]["total_read_kbps"] = round(total_read, 2)
        metrics["io"]["total_write_kbps"] = round(total_write, 2)
        metrics["io"]["top_device"] = top_device

    return metrics

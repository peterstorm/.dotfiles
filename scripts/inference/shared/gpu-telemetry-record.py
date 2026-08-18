#!/usr/bin/env python3
"""Durably sample per-physical-GPU health for Xid 79 diagnosis."""

import argparse
import csv
import os
import signal
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import pynvml as nvml

MIB = 1024 * 1024
CSV_FIELDS = [
    "recorded_at",
    "epoch_ms",
    "boot_id",
    "index",
    "uuid",
    "serial",
    "pci_bus_id",
    "pstate",
    "temperature_c",
    "fan_speeds_pct",
    "power_w",
    "power_limit_w",
    "gpu_utilization_pct",
    "memory_utilization_pct",
    "memory_used_mib",
    "memory_total_mib",
    "sm_clock_mhz",
    "memory_clock_mhz",
    "pcie_generation",
    "pcie_width",
    "pcie_replay_counter",
    "throttle_reasons_hex",
    "ecc_uncorrected_volatile",
    "errors",
]


def text(value):
    return value.decode() if isinstance(value, bytes) else str(value)


def number(value, divisor=1, digits=2):
    return f"{value / divisor:.{digits}f}"


def read_boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def optional(call, default=""):
    try:
        return call()
    except (nvml.NVMLError, AttributeError):
        return default


@dataclass(frozen=True)
class Device:
    index: int
    handle: object
    uuid: str
    serial: str
    pci_bus_id: str
    fan_count: int
    memory_total_mib: str


def discover_devices():
    devices = []
    for index in range(nvml.nvmlDeviceGetCount()):
        handle = nvml.nvmlDeviceGetHandleByIndex(index)
        pci = nvml.nvmlDeviceGetPciInfo(handle)
        memory = nvml.nvmlDeviceGetMemoryInfo(handle)
        devices.append(
            Device(
                index=index,
                handle=handle,
                uuid=text(nvml.nvmlDeviceGetUUID(handle)),
                serial=text(optional(lambda: nvml.nvmlDeviceGetSerial(handle))),
                pci_bus_id=text(pci.busId),
                fan_count=optional(lambda: nvml.nvmlDeviceGetNumFans(handle), 0),
                memory_total_mib=number(memory.total, MIB),
            )
        )
    return devices


def sample_device(device, recorded_at, epoch_ms, boot_id, slow_values, refresh_slow):
    errors = []

    def required(name, call, transform=str):
        try:
            return transform(call())
        except nvml.NVMLError as error:
            errors.append(f"{name}:{type(error).__name__}")
            return ""

    utilization = required("utilization", lambda: nvml.nvmlDeviceGetUtilizationRates(device.handle), lambda value: value)
    memory = required("memory", lambda: nvml.nvmlDeviceGetMemoryInfo(device.handle), lambda value: value)
    fan_speeds = ";".join(
        str(optional(lambda fan=fan: nvml.nvmlDeviceGetFanSpeed_v2(device.handle, fan)))
        for fan in range(device.fan_count)
    )

    if refresh_slow:
        slow_values.update(
            {
                "pstate": required("pstate", lambda: nvml.nvmlDeviceGetPowerState(device.handle)),
                "power_limit_w": required(
                    "power_limit",
                    lambda: nvml.nvmlDeviceGetEnforcedPowerLimit(device.handle),
                    lambda value: number(value, 1000),
                ),
                "sm_clock_mhz": required(
                    "sm_clock",
                    lambda: nvml.nvmlDeviceGetClockInfo(device.handle, nvml.NVML_CLOCK_SM),
                ),
                "memory_clock_mhz": required(
                    "memory_clock",
                    lambda: nvml.nvmlDeviceGetClockInfo(device.handle, nvml.NVML_CLOCK_MEM),
                ),
                "pcie_generation": required(
                    "pcie_generation",
                    lambda: nvml.nvmlDeviceGetCurrPcieLinkGeneration(device.handle),
                ),
                "pcie_width": required("pcie_width", lambda: nvml.nvmlDeviceGetCurrPcieLinkWidth(device.handle)),
                "pcie_replay_counter": optional(lambda: nvml.nvmlDeviceGetPcieReplayCounter(device.handle)),
                "throttle_reasons_hex": required(
                    "throttle_reasons",
                    lambda: nvml.nvmlDeviceGetCurrentClocksThrottleReasons(device.handle),
                    lambda value: f"0x{value:x}",
                ),
                "ecc_uncorrected_volatile": optional(
                    lambda: nvml.nvmlDeviceGetTotalEccErrors(
                        device.handle,
                        nvml.NVML_MEMORY_ERROR_TYPE_UNCORRECTED,
                        nvml.NVML_VOLATILE_ECC,
                    )
                ),
            }
        )

    return {
        "recorded_at": recorded_at,
        "epoch_ms": epoch_ms,
        "boot_id": boot_id,
        "index": device.index,
        "uuid": device.uuid,
        "serial": device.serial,
        "pci_bus_id": device.pci_bus_id,
        "pstate": slow_values.get("pstate", ""),
        "temperature_c": required(
            "temperature",
            lambda: nvml.nvmlDeviceGetTemperature(device.handle, nvml.NVML_TEMPERATURE_GPU),
        ),
        "fan_speeds_pct": fan_speeds,
        "power_w": required("power", lambda: nvml.nvmlDeviceGetPowerUsage(device.handle), lambda value: number(value, 1000)),
        "power_limit_w": slow_values.get("power_limit_w", ""),
        "gpu_utilization_pct": "" if utilization == "" else utilization.gpu,
        "memory_utilization_pct": "" if utilization == "" else utilization.memory,
        "memory_used_mib": "" if memory == "" else number(memory.used, MIB),
        "memory_total_mib": device.memory_total_mib,
        "sm_clock_mhz": slow_values.get("sm_clock_mhz", ""),
        "memory_clock_mhz": slow_values.get("memory_clock_mhz", ""),
        "pcie_generation": slow_values.get("pcie_generation", ""),
        "pcie_width": slow_values.get("pcie_width", ""),
        "pcie_replay_counter": slow_values.get("pcie_replay_counter", ""),
        "throttle_reasons_hex": slow_values.get("throttle_reasons_hex", ""),
        "ecc_uncorrected_volatile": slow_values.get("ecc_uncorrected_volatile", ""),
        "errors": ";".join(errors),
    }


class DailyCsv:
    def __init__(self, directory, fsync_interval):
        self.directory = directory
        self.fsync_interval = fsync_interval
        self.day = None
        self.stream = None
        self.writer = None
        self.last_fsync = 0.0

    def write(self, rows, now):
        day = now.strftime("%Y-%m-%d")
        if day != self.day:
            self.close()
            path = self.directory / f"gpu-samples-{day}.csv"
            empty = not path.exists() or path.stat().st_size == 0
            self.stream = path.open("a", newline="", buffering=1)
            self.writer = csv.DictWriter(self.stream, fieldnames=CSV_FIELDS)
            self.day = day
            if empty:
                self.writer.writeheader()
                self.sync()
        self.writer.writerows(rows)
        self.stream.flush()
        if time.monotonic() - self.last_fsync >= self.fsync_interval:
            self.sync()

    def sync(self):
        if self.stream is not None:
            self.stream.flush()
            os.fsync(self.stream.fileno())
            self.last_fsync = time.monotonic()

    def close(self):
        if self.stream is not None:
            self.sync()
            self.stream.close()
        self.day = None
        self.stream = None
        self.writer = None


def append_event(directory, boot_id, event, details):
    path = directory / "events.csv"
    empty = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="") as stream:
        writer = csv.writer(stream)
        if empty:
            writer.writerow(["recorded_at", "epoch_ms", "boot_id", "event", "details"])
        now = datetime.now().astimezone()
        writer.writerow([now.isoformat(timespec="milliseconds"), time.time_ns() // 1_000_000, boot_id, event, details])
        stream.flush()
        os.fsync(stream.fileno())


def prune(directory, retention_days):
    cutoff = time.time() - retention_days * 86400
    for path in directory.glob("gpu-samples-*.csv"):
        if path.stat().st_mtime < cutoff:
            path.unlink()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", default=os.environ.get("GPU_TELEMETRY_DIR", "/var/lib/gpu-telemetry"))
    parser.add_argument("--interval", type=float, default=float(os.environ.get("GPU_TELEMETRY_INTERVAL", "1")))
    parser.add_argument("--slow-interval", type=float, default=float(os.environ.get("GPU_TELEMETRY_SLOW_INTERVAL", "10")))
    parser.add_argument("--fsync-interval", type=float, default=float(os.environ.get("GPU_TELEMETRY_FSYNC_INTERVAL", "1")))
    parser.add_argument("--retention-days", type=int, default=14)
    args = parser.parse_args()
    if args.interval < 0.2:
        parser.error("--interval must be at least 0.2 seconds")
    if args.slow_interval < args.interval:
        parser.error("--slow-interval must be at least --interval")
    if args.fsync_interval <= 0:
        parser.error("--fsync-interval must be positive")
    if args.retention_days < 1:
        parser.error("--retention-days must be positive")
    return args


def main():
    args = parse_args()
    directory = Path(args.directory)
    directory.mkdir(parents=True, exist_ok=True)
    boot_id = read_boot_id()
    running = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    nvml.nvmlInit()
    log = DailyCsv(directory, args.fsync_interval)
    try:
        devices = discover_devices()
        if not devices:
            raise RuntimeError("NVML reported no GPUs")
        identity = ";".join(f"index={d.index},bus={d.pci_bus_id},serial={d.serial},uuid={d.uuid}" for d in devices)
        append_event(directory, boot_id, "start", identity)
        prune(directory, args.retention_days)
        next_sample = time.monotonic()
        next_slow_sample = next_sample
        slow_values = {device.index: {} for device in devices}
        next_prune = next_sample + 3600
        last_error = None
        last_error_event = 0.0

        while running:
            wall_time = datetime.now().astimezone()
            epoch_ms = time.time_ns() // 1_000_000
            recorded_at = wall_time.isoformat(timespec="milliseconds")
            monotonic = time.monotonic()
            refresh_slow = monotonic >= next_slow_sample
            rows = [
                sample_device(
                    device,
                    recorded_at,
                    epoch_ms,
                    boot_id,
                    slow_values[device.index],
                    refresh_slow,
                )
                for device in devices
            ]
            log.write(rows, wall_time)
            if refresh_slow:
                next_slow_sample = monotonic + args.slow_interval

            errors = ";".join(f"gpu{row['index']}={row['errors']}" for row in rows if row["errors"])
            if errors and (errors != last_error or monotonic - last_error_event >= 60):
                append_event(directory, boot_id, "sample_error", errors)
                last_error = errors
                last_error_event = monotonic
            if monotonic >= next_prune:
                prune(directory, args.retention_days)
                next_prune = monotonic + 3600

            next_sample += args.interval
            delay = next_sample - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_sample = time.monotonic()
    except Exception as error:
        append_event(directory, boot_id, "fatal", f"{type(error).__name__}: {error}")
        raise
    finally:
        log.close()
        append_event(directory, boot_id, "stop", "telemetry recorder stopped")
        nvml.nvmlShutdown()


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Contract and synthetic smoke test for GPU crash diagnostics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDER="$ROOT/scripts/inference/shared/gpu-telemetry-record.py"
LAUNCHER="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-sglang.sh"
MACHINE="$ROOT/machines/desktop/default.nix"
TRIAGE="$ROOT/docs/runbooks/gpu-inference-crash-triage.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$LAUNCHER"
PYTHON="$(nix build --no-link --print-out-paths nixpkgs#python3)/bin/python3"
"$PYTHON" -m py_compile "$RECORDER"

for marker in \
  'GPU_ORDER="${GPU_ORDER:-0,1}"' \
  '0,1|1,0' \
  '--label io.peterstorm.inference.gpu-order="$GPU_ORDER"' \
  '-e CUDA_VISIBLE_DEVICES="$GPU_ORDER"' \
  'container-archives' \
  'docker logs --timestamps' \
  'Config.Env' \
  'MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"' \
  '--query-gpu=index,power.limit' \
  'ARCHIVE_MAX_COUNT="${ARCHIVE_MAX_COUNT:-20}"'; do
  grep -Fq -- "$marker" "$LAUNCHER" || fail "launcher missing: $marker"
done

for marker in \
  'gpuPowerLimitWatts = 450;' \
  'pythonPackages.nvidia-ml-py' \
  'systemd.services.gpu-telemetry-record' \
  'StateDirectory = "gpu-telemetry";' \
  'DynamicUser = true;' \
  'CapabilityBoundingSet = "";' \
  'GPU_TELEMETRY_INTERVAL = "1";' \
  'GPU_TELEMETRY_SLOW_INTERVAL = "10";' \
  'GPU_TELEMETRY_FSYNC_INTERVAL = "1";'; do
  grep -Fq -- "$marker" "$MACHINE" || fail "desktop configuration missing: $marker"
done

for marker in \
  'third dropout' \
  'GPU_ORDER=1,0' \
  '/var/lib/gpu-telemetry' \
  'Seasonic 1600 W Platinum'; do
  grep -Fq -- "$marker" "$TRIAGE" || fail "triage documentation missing: $marker"
done

# Exercise rotation/output/signal handling without requiring NVIDIA hardware.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$ROOT/scripts/inference/shared/__pycache__"' EXIT
cat > "$tmp/pynvml.py" <<'PY'
class NVMLError(Exception):
    pass

NVML_TEMPERATURE_GPU = 0
NVML_CLOCK_SM = 1
NVML_CLOCK_MEM = 2
NVML_MEMORY_ERROR_TYPE_UNCORRECTED = 1
NVML_VOLATILE_ECC = 0

class Pci:
    def __init__(self, index):
        self.busId = f"00000000:0{index + 1}:00.0".encode()

class Utilization:
    gpu = 99
    memory = 42

class Memory:
    used = 80 * 1024 * 1024
    total = 96 * 1024 * 1024

def nvmlInit(): pass
def nvmlShutdown(): pass
def nvmlDeviceGetCount(): return 2
def nvmlDeviceGetHandleByIndex(index): return index
def nvmlDeviceGetPciInfo(handle): return Pci(handle)
def nvmlDeviceGetUUID(handle): return f"GPU-fake-{handle}".encode()
def nvmlDeviceGetSerial(handle): return f"serial-{handle}".encode()
def nvmlDeviceGetUtilizationRates(handle): return Utilization()
def nvmlDeviceGetMemoryInfo(handle): return Memory()
def nvmlDeviceGetNumFans(handle): return 2
def nvmlDeviceGetFanSpeed_v2(handle, fan): return 40 + handle + fan
def nvmlDeviceGetPowerState(handle): return 1
def nvmlDeviceGetTemperature(handle, sensor): return 70 + handle
def nvmlDeviceGetPowerUsage(handle): return 450000
def nvmlDeviceGetEnforcedPowerLimit(handle): return 450000
def nvmlDeviceGetClockInfo(handle, clock): return 2500 if clock == NVML_CLOCK_SM else 7000
def nvmlDeviceGetCurrPcieLinkGeneration(handle): return 5
def nvmlDeviceGetCurrPcieLinkWidth(handle): return 8
def nvmlDeviceGetPcieReplayCounter(handle): return 0
def nvmlDeviceGetCurrentClocksThrottleReasons(handle): return 0
def nvmlDeviceGetTotalEccErrors(handle, error_type, counter_type): return 0
PY

set +e
PYTHONPATH="$tmp" timeout 1s "$PYTHON" "$RECORDER" \
  --directory "$tmp/output" --interval 0.2 --fsync-interval 0.2 --retention-days 1
status=$?
set -e
[ "$status" -eq 0 ] || [ "$status" -eq 124 ] || fail "synthetic recorder exited $status"

sample="$(find "$tmp/output" -name 'gpu-samples-*.csv' -print -quit)"
[ -n "$sample" ] || fail "synthetic recorder wrote no sample file"
grep -Fq 'fan_speeds_pct' "$sample" || fail "sample header lacks fan telemetry"
grep -Fq '40;41' "$sample" || fail "sample rows lack per-fan values"
[ "$(wc -l < "$sample")" -ge 5 ] || fail "synthetic recorder wrote too few rows"
grep -Fq ',start,' "$tmp/output/events.csv" || fail "start event missing"
grep -Fq ',stop,' "$tmp/output/events.csv" || fail "stop event missing"

echo "PASS: GPU crash diagnostics are wired and telemetry records durably"

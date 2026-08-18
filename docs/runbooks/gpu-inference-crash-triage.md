# GPU / inference crash triage (desktop)

Triage playbook for "inference crashed / GPU died" on the desktop, plus the incident
record that motivated it. The machine:

- **Desktop** (`ssh desktop`, 192.168.0.80) — NixOS 26.11, kernel 6.18.x
- **CPU**: AMD Ryzen 9 9950X (16c/32t) — cooler currently **undersized** (known)
- **PSU**: Seasonic 1600 W Platinum — ample aggregate capacity at the 450 W operational GPU caps (350 W during the 2026-08-16 diagnostic)
- **GPUs**: 2× NVIDIA RTX PRO 6000 Blackwell Workstation (GB202GL, 96 GB), driver 595.91.07
  - GPU0: PCI `01:00.0`, serial `1794425022466` (display attached)
  - GPU1: PCI `03:00.0`, serial `1791526036417`
- **Inference**: sglang in docker, `qwen38-27b-bf16-dspark-sglang`, TP=2,
  restart policy `unless-stopped` (crashed containers come back ~90 s after a reboot —
  **don't mistake that for it never having crashed**)
- PCIe: both GPU slots are **natively Gen5 x8** (upstream CPU ports are x8).
  `Width x8 (downgraded)` in `lspci -vvv` is the *normal* state here, not a fault.

## Incident record: 2026-08-16 ~01:40 local (Xid 79, GPU0 off the bus)

| Time (CEST) | Event |
|---|---|
| 01:06 | sglang container up (Qwen3.8-27B bf16, TP=2, DSPARK speculative decoding) |
| ~01:39 | Saturated load: 8/8 concurrent reqs, ~200k tokens queued, KV 55–71%, one 294k-token cached prefill |
| 01:40:26 | **`Xid (PCI:0000:01:00): 79, GPU has fallen off the bus`** (GPU0). Same instant: NCCL watchdog rank 0 `CUDA error: unspecified launch failure` |
| 01:41:45–55 | GSP-firmware RPCs to GPU0 all fail (`status 0xf`), reset asserts, kernel oops in `nvidia_modeset` teardown |
| 01:41:58 | Clean `systemd-shutdown` → reboot |
| 01:43:21 | Docker restarts container (`unless-stopped`); 01:44:13 serving again |

**Observed failure**: GPU0 became inaccessible over PCIe under full load (drawn 451 W,
at its 450 W cap). Xid 79 strongly favors the physical card/power/slot path, but it does
not by itself exclude a driver/GSP failure that wedges one TP rank. Root cause remains
unproven until the logical-rank and physical-swap tests identify what the failure follows.

**Ruled out** (with evidence):

- OOM: no OOM kills; VRAM ~86/98 GB, within `mem_fraction_static=0.85` plan
- ordinary sglang process failure: scheduler SIGABRT was fallout from the GPU vanishing
  mid-NCCL collective; a repeatable rank-0 runtime/driver trigger is still not ruled out
- PCIe link downgrade: slots are natively x8; AER clean on following boot; no retimer errors
- Thermals (GPU): 80 °C at crash — fine for this card
- VRAM degradation: 0 retired pages, 0 pending row-remaps, no remap failures
- CPU heat: crash signature is a GPU PCIe dropout; a CPU overheat would show
  `mce`/thermal-trip logs, not Xid 79. (Still worth a temp check — see step 6 —
  because the cooler is undersized and CPU heat *can* degrade PCIe signal margin.)

## Incident record: 2026-08-16 ~02:26 local (second dropout, GPU0, at 400 W cap)

| Time (CEST) | Event |
|---|---|
| 01:42:38 | Boot after incident 1; sglang container back up, same model/TP=2 |
| ~02:20–02:25 | `nvidia-smi -pl 400` applied as a test; both GPUs verified alive at the 400 W cap (86/73 °C, 2542/2610 MHz, 99 % util) |
| 02:26:09–12 | GPU0 RPCs fail with `status 0xf`, `NV_ERR_GPU_IS_LOST (0x0000000F)`, "GPU lost from the bus" — same signature as incident 1, this time **while capped at 400 W** (last observed draw 400.1 W) |
| 02:26:14 | Clean `systemd-shutdown` → power off → back up 02:28:22; container serving again |

**What changes**: the first read — "450 W cap = overdraw" — is weakened. GPU0 fell off
the bus at both 450 W and 400 W. The retained DS4 container log provides a real control:
about 19.4 hours of scheduler samples, including about 46 minutes at eight concurrent
requests, contain no CUDA launch failure or GPU-loss signature. That proves the Qwen
SGLang profile is the trigger, but not whether the trigger exposes marginal hardware or
a rank-0 driver/runtime defect. Historical DS4 power was not recorded, so the earlier
claim that it necessarily drew less power was unsupported.

## Incident record: 2026-08-16 02:45 local (third dropout, GPU0, at 400 W cap)

| Time (CEST) | Event |
|---|---|
| 02:28:22 | Boot after incident 2; same container and model return |
| 02:45:35–50 | Mixed prefill/decode load, 2–5 requests; chunked prefills include 40K–93K cached prefixes and up to 123K pending tokens; KV usage only 12–25% |
| 02:45:50 | Physical GPU0 (`01:00.0`, serial `1794425022466`) reports Xid 79; SGLang rank 0 immediately receives `CUDA error: unspecified launch failure` |
| 02:47:36 | Reboot after the driver marks node reboot required |

All three failures follow the same physical GPU *and* TP rank 0 because the default CUDA
order maps rank 0 to physical GPU0. Their phases differ: incident 1 was saturated mixed
prefill/decode, incident 2 failed during decode at low KV use, and incident 3 failed during
chunked prefill. There is no single reproducible kernel phase yet. A Seasonic 1600 W
Platinum PSU makes aggregate capacity unlikely; individual card power delivery remains
possible. Both cards report two firmware-controlled fans operating normally, and no host
configuration pins GPU fan speed.

**Discriminators, in order**:

1. Keep both cards at the 350 W diagnostic cap and record one-second NVML telemetry.
2. Relaunch with `GPU_ORDER=1,0` so physical GPU1 becomes logical device / TP rank 0.
   Failure moving to `03:00.0` implicates rank-0 software/driver behavior; failure staying
   at `01:00.0` implicates the physical GPU0/card/connector/slot path.
3. If failure stays physical, cold-power-off, inspect/reseat GPU0 and its native PSU cable,
   then swap the two cards while keeping slot-associated cabling fixed. Following serial
   `1794425022466` means card/RMA; staying at slot 1 means slot/root/cable path.
4. If failure follows rank 0, test target-only SGLang (no DSpark), then disable CUDA graphs,
   then compare the plain Qwen BF16 vLLM control before changing hardware. The concurrent
   Qwen + Muse profile is a stronger isolation probe: Qwen vLLM TP1 is restricted to
   physical GPU1 while Muse SGLang TP1 is restricted to physical GPU0, so there is no NCCL
   rank coupling. A GPU0 Xid while the GPU1 server remains healthy favors the physical
   GPU0/card/connector/slot path over a TP-rank interaction.
5. Watch CPU/package and GPU temperatures throughout; GPU0 has been 10–14 °C hotter than
   GPU1 under equal board-power caps even though no thermal-slowdown flag was active.

## Triage playbook (fastest first)

Run everything over ssh: `ssh desktop '<cmd>'`. Note: **container logs are UTC, host
journal is local time (CEST = UTC+2)**. Docker keeps logs across `docker restart` but not
across container *recreation*; the Qwen launcher archives safe metadata and compressed
logs before removing an old container.

### 0. Preserve telemetry and container evidence

`gpu-telemetry-record.service` writes one row per physical GPU per second. Samples rotate
daily, fsync every second, survive reboots, and are retained for 14 days:

```bash
systemctl status gpu-telemetry-record.service
sudo tail -10 /var/lib/gpu-telemetry/gpu-samples-$(date +%F).csv
sudo tail -20 /var/lib/gpu-telemetry/events.csv
ls -lh ~/.local/state/qwen38/container-archives/
```

Every row carries serial, UUID, PCI bus, both fan percentages, power, cap, temperature,
utilization, clocks, PCIe generation/width/replay counter, throttle mask, and ECC state.
Power, temperature, fans, utilization, and memory are sampled at 1 Hz; slower control-plane
fields are refreshed every 10 seconds to limit observer load on the GSP/NVML path. This is
the source of truth for the seconds before the next Xid; Prometheus's 15-second
scrape is too coarse. Container archives intentionally exclude `Config.Env` so the API
key is never copied into diagnostic metadata.

### 1. Did the container actually crash, and when?

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}'
docker inspect <ctr> --format 'created={{.Created}} started={{.State.StartedAt}} exited={{.State.FinishedAt}} exitcode={{.State.ExitCode}} restarts={{.RestartCount}}'
```

`StartedAt ≈ now` + `exitcode 0` = it restarted after dying. The old crash is still in
`docker logs <ctr>` if the container wasn't recreated.

### 2. Read the crash out of the container log

```bash
docker logs <ctr> 2>&1 | grep -nE "Traceback|CUDA error|RuntimeError|Watchdog|NCCL|Abort|Killed|crashed" | head -40
```

- `Subprocess scheduler_N (pid=...) crashed with exit code -6` = SIGABRT, usually fallout from #3
- `CUDA error: unspecified launch failure` / `cudaErrorLaunchFailure` = a kernel died; the
  *first* occurrence is the trigger, everything after is teardown noise
- Check the last batch lines before it: was the server saturated (`#running-req` at max,
  huge `#pending-token`, high `full token usage`)? Correlate with power draw.

### 3. Find the Xid in the kernel journal (the real smoking gun)

If the crash happened on the **previous** boot, use `-b -1`:

```bash
journalctl -b -1 -k --no-pager | grep -nE "Xid|NVRM|BUG|Call Trace|page fault" | head -30
journalctl --list-boots   # to know which boot the crash was in
```

Key Xids:

| Xid | Meaning |
|---|---|
| **79** | GPU fallen off the bus → power/hardware; reboot recovers |
| 48/63/64/94/95 | GPU memory page/row errors → VRAM degradation, check row-remap |
| 31 | GPU memory page access error (often recoverable, watch frequency) |
| 13/43 | MMU faults → software/driver side |

Companion signatures for a bus dropout: `krcRcAndNotifyAllChannels_IMPL: RC all channels
for critical error 79`, `_threadNodeCheckTimeout: API_GPU_ATTACHED_SANITY_CHECK failed`
(repeated), `rpcSendMessage failed with status 0x0000000f` (GSP firmware unresponsive),
`nvAssertFailedNoLog ... NV_ERR_GPU_IN_FULLCHIP_RESET` (reset attempted, failed).

### 4. Is it healthy *now*?

```bash
nvidia-smi   # both GPUs present, temps, power
nvidia-smi --query-gpu=name,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.width.current,clocks_throttle_reasons.active --format=csv
journalctl -b 0 -k | grep -icE "xid"          # expect 0
journalctl -b 0 -k | grep -iE "aer|unrecovered" # PCIe AER errors
```

### 5. Rule out PCIe as the culprit

```bash
echo <pw> | sudo -S -p '' lspci -vvv -s 01:00.0 | grep -E "LnkCap|LnkSta"
echo <pw> | sudo -S -p '' lspci -vvv -s 03:00.0 | grep -E "LnkCap|LnkSta"
lspci -t | head -30
```

On this box the **upstream** ports (`00:01.1` for GPU0, `00:01.3` for GPU1) are x8, so
`Width x8 (downgraded)` on the GPU side is normal. A real problem would be Gen5→Gen4/Gen3
speed drops or AER errors. Both links also have `2Retimers+` in the path (normal here).

### 6. Rule out CPU thermals (cooler is undersized!)

```bash
sensors 2>/dev/null || for z in /sys/class/thermal/thermal_zone*/; do echo "$z $(cat $z/temp 2>/dev/null) $(cat $z/type 2>/dev/null)"; done
journalctl -b -1 --no-pager | grep -iE "thermal|throttl|mce|Hardware Error" | tail -20
```

Package temps >95 °C sustained, or thermal-trip/MCE logs around the crash time → improve
cooling before touching GPU hardware. CPU heat does **not** produce Xid 79 by itself, but
a hot VRM/CPU can erode PCIe signal margin, so keep this on the list.

### 7. Rule out VRAM degradation (only if Xid 48/63/64/94/95)

```bash
nvidia-smi -q -d PAGE_RETIREMENT | grep -A5 "Retired Pages"
nvidia-smi -q -d ROW_REMAPPER | grep -E "Pending|Failure"
```

Non-zero retired pages or pending remaps → RMA track.

## Decision summary

- **Xid 79 on this box** → inspect the durable final samples, then logical rank reversal,
  then physical card/slot swap. All three 2026-08-16 dropouts were physical GPU0 at both
  450 W and 400 W; 350 W was diagnostic mitigation only, not a fix. 2026-08-18:
  450 W restored as the operational cap after a clean sustained-load window —
  revert to 350 W if Xid 79 recurs.
- **Xid 48/63/64/94/95** or retired pages → VRAM → RMA
- **Speed/width drops or AER errors** → slot/retimer/cable reseats, try the other slot
- **No Xid, just OOM/413s/timeouts** → server-config problem (mem fraction, context
  length, max_running_requests), not hardware
- **GPU back after reboot and clean ever since** → treat as one-off hardware event, but
  track recurrence per-serial (GPU0 `1794425022466`, GPU1 `1791526036417`)

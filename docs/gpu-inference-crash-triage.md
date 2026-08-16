# GPU / inference crash triage (desktop)

Triage playbook for "inference crashed / GPU died" on the desktop, plus the incident
record that motivated it. The machine:

- **Desktop** (`ssh desktop`, 192.168.0.80) — NixOS 26.11, kernel 6.18.x
- **CPU**: AMD Ryzen 9 9950X (16c/32t) — cooler currently **undersized** (known)
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

**Root cause**: GPU0 dropped off the PCIe bus under full load (drawn 451 W, at its 450 W
cap). Xid 79 under that profile = power delivery or card hardware fault, not software.

**Ruled out** (with evidence):

- OOM: no OOM kills; VRAM ~86/98 GB, within `mem_fraction_static=0.85` plan
- sglang/model bug: scheduler SIGABRT was fallout from the GPU vanishing mid-NCCL-collective
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
the bus at *both* 450 W and 400 W caps, always under saturated qwen3.8-27b TP=2 load.
The smaller `deepseek-v4-flash` workload (lower sustained draw) never reproduced it.
The failure follows **GPU0 under heavy load**, not a specific wattage. The 400 W cap
remains as mitigation (less current through the 12VHPWR path, less VRM stress), and
`gpuPowerLimitWatts` was set to 400 in `machines/desktop/default.nix` — but this is not
the fix. The hardware question (12VHPWR seating/connector heat, GPU0 itself, or slot
`PCIEX16(G5)_1`) is still open.

**Fixes to try in order if it recurs on GPU0**:

1. Reseat 12VHPWR on GPU0; feed all 3 connectors with **separate** PSU cables (no daisy chain).
   While the card is out, inspect the connector and cable for discoloration/heat marks —
   two dropouts in ~1 h of load makes a marginal connection the prime suspect.
2. **Swap test**: move GPU0 and GPU1 (card follows card). Recurrence on the *card* in the
   other slot → RMA GPU0 (serial `1794425022466`). Recurrence on the *slot/cable* →
   power-delivery path for `PCIEX16(G5)_1` / its PSU cable.
3. Check PSU headroom — 2×450 W + 9950X peaks >1100 W (less relevant now that dropouts
   occur at 400 W, but transients still matter).
4. Watch the CPU: undersized cooler; if package temps spike toward 95–105 °C at the
   crash moment, improve cooling before chasing GPU hardware.

## Triage playbook (fastest first)

Run everything over ssh: `ssh desktop '<cmd>'`. Note: **container logs are UTC, host
journal is local time (CEST = UTC+2)**. Docker keeps logs across `docker restart` but not
across container *recreation*.

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

- **Xid 79 + saturation + power at cap** → cables → PSU → RMA (in that order). On this
  box both 2026-08-16 dropouts were GPU0, at *both* 450 W and 400 W caps, so the cap is
  mitigation only — the card/connector/slot swap test decides RMA vs power path.
- **Xid 48/63/64/94/95** or retired pages → VRAM → RMA
- **Speed/width drops or AER errors** → slot/retimer/cable reseats, try the other slot
- **No Xid, just OOM/413s/timeouts** → server-config problem (mem fraction, context
  length, max_running_requests), not hardware
- **GPU back after reboot and clean ever since** → treat as one-off hardware event, but
  track recurrence per-serial (GPU0 `1794425022466`, GPU1 `1791526036417`)

# ComfyUI persistent Assets library

The desktop ComfyUI service enables the upstream Assets subsystem with
`--enable-assets`. Assets are indexed in the existing SQLite database at
`/var/lib/comfyui/user/comfyui.db`; media stays checksum-identical in its
original `input`, `output`, or model directory. The index does not duplicate or
promote generated media.

ComfyUI frontend 1.49.6 has an OSS integration gap: its Assets sidebar still
reads volatile execution History rather than the persistent Assets API. The
local `persistent_output_history` startup extension bridges that gap for video
only. It scans existing output videos, restores deterministic synthetic History
records under the queue lock, and uses embedded MP4 workflow/prompt metadata
when present. It never copies, rewrites, or executes the media.

## What survives a shutdown

Completed media under `/var/lib/comfyui/output` is persistent operational data
and survives service restarts and machine shutdowns. The execution History view
is not the authority for those files and may not retain a prior process's
in-memory queue history. MP4 files written by ComfyUI may additionally embed the
submitted workflow and API prompt as container metadata.

The persistent Assets index remains authoritative for discovery. The startup
bridge makes its existing videos visible in **Assets → Generated** despite the
frontend limitation; ordinary live executions continue to populate History
normally.

## Initial and recovery indexing

On startup, upstream ComfyUI scans the configured model, input, and output roots
in the background. To rescan only saved outputs after importing or recovering
files:

```bash
curl --fail --silent --show-error \
  -X POST 'http://127.0.0.1:8188/api/assets/seed?wait=true' \
  -H 'Content-Type: application/json' \
  --data '{"roots":["output"]}' | jq
```

The endpoint returns final `scanned`, `created`, and `skipped` counts. It is
idempotent: rescanning existing files updates/reuses index records rather than
copying the media.

Verify that the feature and index are available:

```bash
curl --fail --silent --show-error \
  'http://127.0.0.1:8188/api/assets?limit=500&sort=created_at&order=desc' \
  | jq '{total, returned: (.assets | length)}'
```

After enabling the service or completing a scan, refresh the browser. Open the
**Assets** sidebar and select **Generated** to browse and play generated videos.
The output seeder and startup bridge both run when ComfyUI starts; an output-only
API rescan by itself does not repopulate frontend 1.49.6's volatile History.

Verify the startup bridge independently:

```bash
curl --fail --silent --show-error \
  'http://127.0.0.1:8188/history?max_items=1000' \
  | jq '[to_entries[].value.prompt[3] | select(.persistent_output_history == true)] | length'
```

The count should match the existing video outputs that were not already present
as live execution records.

## Safety rules

- Keep ComfyUI loopback-only; the Assets content routes expose local media.
- Do not delete or rewrite output files merely to refresh the index.
- Do not treat Assets indexing as Production promotion or semantic acceptance.
- Native outputs remain authoritative; upscaled files remain finishing derivatives.
- Back up `/var/lib/comfyui/output` and `/var/lib/comfyui/user/comfyui.db`
  independently of the NixOS configuration.

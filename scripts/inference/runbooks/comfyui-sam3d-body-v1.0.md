# ComfyUI SAM 3D Body v1.0

This workflow reconstructs tracked people from video into a smoothed 3D body sequence, renders a review video, previews the mesh in ComfyUI, and exports pose data as GLB or BVH. Blender is optional and consumes the exported files downstream.

## Installed workflow

```text
/var/lib/comfyui/user/default/workflows/sam3d-body-bf16-v1.0/
└── 01 SAM 3D Body v1.0 - BF16 Detection + GLB BVH Export.json
```

The pinned sample input is installed at:

```text
/var/lib/comfyui/input/woman_holding_water_glass.mp4
```

This is a dedicated graph. It does not modify or replace any MiniMax H3 workflow. Workflow versions are immutable: change the filename and destination directory before changing the graph in a future release.

## Models

`download-sam3d-body-models` installs and verifies this profile atomically under `/models/comfyui`:

| Model | Destination | Purpose |
|---|---|---|
| `sam3.1_multiplex_fp16.safetensors` | `checkpoints/` | SAM 3.1 video tracking |
| `sam_3d_body_dinov3_bf16.safetensors` | `detection/` | BF16 SAM 3D Body reconstruction |
| `moge_2_vitl_normal_fp16.safetensors` | `geometry_estimation/` | Metric geometry and field-of-view estimation |
| `rt_detr_v4-x-hgnet_fp32.safetensors` | `diffusion_models/` | Person bounding boxes |

The optional SAM 3D Body ConvRot quantized model is deliberately absent. The downloader checks exact revisions, byte counts, and SHA-256 digests before replacing any installed file.

SAM 3.1 and SAM 3D Body use Meta's `sam-license`; MoGe-2 and RT-DETR are MIT. After reviewing the Meta license, install or re-verify the profile with:

```bash
SAM3D_BODY_ACCEPT_LICENSE=yes download-sam3d-body-models
```

A successful run ends with:

```text
SAM3D_BODY_MODELS_READY: pinned profile
```

## Start ComfyUI

ComfyUI is installed but intentionally not boot-started because other local inference profiles may own the GPUs. Ensure GPU1 is free, then run:

```bash
sudo systemctl start comfyui
systemctl status comfyui --no-pager
```

Open the local ComfyUI frontend and select the workflow from `sam3d-body-bf16-v1.0`.

## Operating procedure

1. In **LoadVideo**, keep the sample clip or choose footage from `/var/lib/comfyui/input`.
2. Use **Video Slice** to select the time range. The template starts at 0 seconds and uses 5 seconds.
3. Keep **RTDETR detect** on `person`; bounding boxes materially improve difficult or crowded clips.
4. Keep **SAM3 VideoTrack** enabled for multiple people. It is optional for simple single-person footage but generally improves temporal tracking.
5. Keep **MoGeInference → MoGeGeometryToFOV** enabled when source-camera alignment matters.
6. Adjust **SAM3DBody FaceExpression** only when face tracking is unstable; this stage uses MediaPipe because the body model does not infer facial expression itself.
7. Use **SAM3DBody Smooth** to reduce temporal jitter. Increase smoothing conservatively so fast movement is not erased.
8. Queue the graph and inspect both **SAM3DBody Render** and **Preview3D** before exporting.
9. In **BuildPoseFile**, choose `glb` for a mesh/animation asset or `bvh` for skeletal motion exchange. The shipped default is `glb` at 24 fps.
10. Preserve the native export and rendered review video before any Blender retargeting or cleanup.

The rendered review video uses the `video/SAM3D_body` output prefix. BuildPoseFile exposes the generated pose asset through the ComfyUI result UI.

## Blender handoff

Blender is not required to run reconstruction. For downstream work:

- import GLB for direct mesh/animation inspection;
- import BVH when retargeting motion to another armature;
- verify scale, axis orientation, rest pose, foot contact, and frame rate after import;
- keep the original export as provenance rather than editing it in place.

## QA

Before accepting an export, review:

- person count and identity continuity across occlusion;
- bounding-box coverage and track swaps;
- field of view and source-camera alignment;
- hand, foot, and ground contacts;
- face-expression stability;
- temporal jitter versus over-smoothing;
- frame rate, scale, and axis orientation in the target DCC.

A successful queue only proves that the reconstruction pipeline ran. The resulting mesh and mocap are spatial evidence, not guarantees about anatomy, interpolation, contact accuracy, or suitability for final production.

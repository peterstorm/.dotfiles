"""Source-latent video editing for MiniMax H3.

The stock ReferenceToVideo node puts reference videos in semantic conditioning but
starts sampling from an empty random latent. This node instead VAE-encodes the full
source carrier into the target H3 AV latent, so a partial-denoise sampler edits the
source trajectory rather than inventing another shot.
"""

import torch

import comfy.nested_tensor
import comfy.utils


FRAME_PATTERN = (1, 4, 4, 4, 4)


def pixel_frame_count(latent_steps):
    return sum(FRAME_PATTERN[index % len(FRAME_PATTERN)] for index in range(int(latent_steps)))


def source_frame_indices(source_count, target_count, device):
    if int(source_count) < 1:
        raise ValueError("AFTERSIGNAL H3 source edit requires at least one source frame")
    if int(target_count) < 1:
        raise ValueError("AFTERSIGNAL H3 source edit requires at least one target frame")
    if int(source_count) == int(target_count):
        return torch.arange(int(source_count), device=device, dtype=torch.long)
    return torch.linspace(
        0,
        int(source_count) - 1,
        int(target_count),
        device=device,
        dtype=torch.float64,
    ).round().to(torch.long)


def h3_streams(latent):
    samples = latent.get("samples")
    if hasattr(samples, "unbind"):
        streams = list(samples.unbind())
    elif isinstance(samples, (tuple, list)):
        streams = list(samples)
    else:
        raise ValueError("AFTERSIGNAL H3 source edit requires a joint H3 AV latent")
    if len(streams) != 2:
        raise ValueError("AFTERSIGNAL H3 source edit requires exactly video and audio streams")
    video, audio = streams
    if video.ndim == 4:
        video = video.unsqueeze(0)
    if audio.ndim == 3:
        audio = audio.unsqueeze(0)
    if video.ndim != 5 or audio.ndim != 4:
        raise ValueError("AFTERSIGNAL H3 source edit received malformed H3 AV streams")
    return video, audio


def resize_frames(frames, width, height, crop, chunk_size=32):
    resized = []
    for start in range(0, int(frames.shape[0]), int(chunk_size)):
        chunk = frames[start : start + int(chunk_size), ..., :3].movedim(-1, 1)
        resized.append(
            comfy.utils.common_upscale(chunk, int(width), int(height), "lanczos", crop).movedim(1, -1)
        )
    return torch.cat(resized, dim=0)


def external_mask(frames, target_shape):
    """Explicit mask video (white = regenerate) pooled onto the latent grid.

    Dilation is the carrier builder's job, so this keeps the mask exact and
    uses max pooling: any regenerate pixel inside a latent cell marks the cell.
    """
    keyed = (frames[..., 0] > 0.5).to(torch.float32).unsqueeze(0).unsqueeze(0)
    return torch.nn.functional.adaptive_max_pool3d(
        keyed, tuple(int(value) for value in target_shape)
    )


def magenta_yellow_key_mask(frames, target_shape):
    red, green, blue = frames[..., 0], frames[..., 1], frames[..., 2]
    magenta = (red > 0.55) & (blue > 0.55) & (green < 0.45)
    yellow = (red > 0.55) & (green > 0.55) & (blue < 0.45)
    keyed = (magenta | yellow).to(torch.float32).unsqueeze(1)
    dilated = torch.nn.functional.max_pool2d(keyed, kernel_size=101, stride=1, padding=50)
    temporal = dilated.permute(1, 0, 2, 3).unsqueeze(0)
    return torch.nn.functional.interpolate(
        temporal,
        size=tuple(int(value) for value in target_shape),
        mode="nearest",
    )


class AFTERSIGNALH3SourceVideoLatent:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "target_latent": ("LATENT", {
                    "tooltip": "Fresh joint H3 AV latent from MiniMax H3 Reference to Video."
                }),
                "vae": ("VAE", {"tooltip": "MiniMax H3 video VAE."}),
                "source_frames": ("IMAGE", {
                    "tooltip": "Complete Blender carrier decoded at 24 fps."
                }),
                "crop": (["disabled", "center"], {"default": "disabled"}),
                "mask_mode": (["all", "magenta-yellow-keys", "external-mask"], {"default": "all"}),
            },
            "optional": {
                "mask_frames": ("IMAGE", {
                    "tooltip": "External mask video at source cadence; white marks the regions to regenerate. Required by external-mask mode."
                }),
            },
        }

    RETURN_TYPES = ("LATENT", "INT", "INT")
    RETURN_NAMES = ("latent", "source_frames", "target_frames")
    FUNCTION = "encode"
    CATEGORY = "conditioning/minimax"
    DESCRIPTION = (
        "VAE-encode the complete source video into the target H3 video latent. "
        "Use BasicScheduler denoise below 1.0 for true source-latent editing."
    )

    def encode(self, target_latent, vae, source_frames, crop="disabled", mask_mode="all", mask_frames=None):
        target_video, target_audio = h3_streams(target_latent)
        if int(target_video.shape[0]) != 1 or int(target_audio.shape[0]) != 1:
            raise ValueError("AFTERSIGNAL H3 source edit supports batch size one")

        target_frames = pixel_frame_count(target_video.shape[2])
        indices = source_frame_indices(source_frames.shape[0], target_frames, source_frames.device)
        conformed = source_frames.index_select(0, indices)
        width = int(target_video.shape[4]) * 16
        height = int(target_video.shape[3]) * 16
        resized = resize_frames(conformed, width, height, crop)
        encoded = vae.encode(resized)

        if tuple(encoded.shape) != tuple(target_video.shape):
            raise ValueError(
                "AFTERSIGNAL H3 source edit encoded shape %s does not match target %s"
                % (tuple(encoded.shape), tuple(target_video.shape))
            )

        output = target_latent.copy()
        output["samples"] = comfy.nested_tensor.NestedTensor((
            encoded.to(device=target_video.device, dtype=target_video.dtype),
            target_audio,
        ))
        if mask_mode == "all":
            output.pop("noise_mask", None)
        elif mask_mode in ("magenta-yellow-keys", "external-mask"):
            if mask_mode == "external-mask":
                if mask_frames is None:
                    raise ValueError("AFTERSIGNAL H3 source edit external-mask mode requires mask_frames")
                mask_indices = source_frame_indices(mask_frames.shape[0], target_frames, mask_frames.device)
                conformed_mask = resize_frames(mask_frames.index_select(0, mask_indices), width, height, crop)
                video_mask = external_mask(conformed_mask, target_video.shape[2:])
            else:
                video_mask = magenta_yellow_key_mask(resized, target_video.shape[2:])
            audio_mask = torch.ones(
                (1, 1, int(target_audio.shape[2]), int(target_audio.shape[3])),
                device=target_audio.device,
                dtype=torch.float32,
            )
            output["noise_mask"] = comfy.nested_tensor.NestedTensor((
                video_mask.to(device=target_video.device, dtype=torch.float32),
                audio_mask,
            ))
        else:
            raise ValueError("AFTERSIGNAL H3 source edit received an unknown mask mode")
        return output, int(source_frames.shape[0]), int(target_frames)


NODE_CLASS_MAPPINGS = {
    "AFTERSIGNALH3SourceVideoLatent": AFTERSIGNALH3SourceVideoLatent,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "AFTERSIGNALH3SourceVideoLatent": "AFTERSIGNAL H3 Source Video Latent",
}

"""Node implementations mirroring the four upstream helper call contracts.

Interfaces (kept identical to the upstream types the graph wires):

* ``MuseHelper: Show Anything``  <- easy showAnything: display sink that also
  exposes an ``output`` passthrough slot; accepts any input shape (list mode).
* ``MuseHelper: Preview Text``   <- iToolsPreviewText: passthrough display that
  writes its text back into the saved-workflow metadata for PNG provenance.
* ``MuseHelper: Save Text With Path`` <- SaveTextWithPath: prompt file sink
  under ComfyUI's output directory, overwrite or numbered-suffix semantics.
* ``MuseHelper: Purge VRAM``     <- LayerUtility: PurgeVRAM: OUTPUT_NODE sink
  that sweeps host cache and, on request, unloads every resident model.

The purge/save/display work is the imperative shell of the graph — I/O sinks
hanging off output nodes. Everything data-shaped stays a parameter, so the unit
tests run without a ComfyUI server or a GPU.
"""

import gc
import os


class AnyType(str):
    """Wildcard input type: compares unequal to nothing, so any declared input
    type (STRING, FLOAT, IMAGE, VHS_FILENAMES) binds to this node."""

    def __ne__(self, other):
        return False


any_type = AnyType("*")

TEXT_EXTENSIONS = (".txt", ".md", ".json", ".csv", ".log", ".xml", ".yaml", ".html")


def _as_list(value):
    """Normalize a (possibly list-shaped) execution input to a plain list."""
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def _display_result(text):
    """The ecosystem's standard display mechanism: the ``ui.text`` dict the
    ComfyUI frontend renders as the node's overlay text."""
    return {"ui": {"text": text}, "result": (text,)}


class MuseHelperShowAnything:
    """Display sink mirroring easy showAnything: shows any value and passes it
    through an ``output`` slot (the upstream slot exists but is unwired)."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "anything": (any_type, {}),
            },
            "hidden": {
                "unique_id": "UNIQUE_ID",
                "extra_pnginfo": "EXTRA_PNGINFO",
            },
        }

    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("output",)
    FUNCTION = "show_anything"
    CATEGORY = "MuseHelper/SystemIO"
    OUTPUT_NODE = True
    INPUT_IS_LIST = True
    OUTPUT_IS_LIST = (True,)

    def show_anything(self, anything, unique_id=None, extra_pnginfo=None):
        text = _as_list(anything)
        return _display_result(text)


class MuseHelperPreviewText:
    """Passthrough display mirroring iToolsPreviewText: shows the incoming
    string and writes it back into the workflow metadata so saved PNGs carry
    the exact text that crossed this node."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "text": ("STRING", {"forceInput": True}),
            },
            "hidden": {
                "unique_id": "UNIQUE_ID",
                "extra_pnginfo": "EXTRA_PNGINFO",
            },
        }

    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("text",)
    FUNCTION = "preview_text"
    CATEGORY = "MuseHelper/SystemIO"
    OUTPUT_NODE = True
    INPUT_IS_LIST = True
    OUTPUT_IS_LIST = (True,)

    def preview_text(self, text, extra_pnginfo=None, unique_id=None):
        items = _as_list(text)
        if unique_id is not None and extra_pnginfo is not None:
            if not isinstance(extra_pnginfo, list):
                print("Error: extra_pnginfo is not a list")
            elif (
                not isinstance(extra_pnginfo[0], dict)
                or "workflow" not in extra_pnginfo[0]
            ):
                print("Error: extra_pnginfo is not a list of workflow dicts")
            else:
                workflow = extra_pnginfo[0]["workflow"]
                node = next(
                    (x for x in workflow["nodes"] if str(x["id"]) == str(_as_list(unique_id)[0])),
                    None,
                )
                if node:
                    node["widgets_values"] = [items[0] if len(items) == 1 else items]
        return {"ui": {"text": items}, "result": (items,)}


class MuseHelperSaveTextWithPath:
    """Prompt file sink mirroring SaveTextWithPath: writes the incoming text to
    ``[output]/[folder_path]/[subfolder_name]/[filename][suffix][extension]``
    under ComfyUI's output directory. ``overwrite=False`` adds a numbered
    ``_001`` suffix instead of replacing an existing file."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "text": ("STRING", {"forceInput": True}),
                "folder_path": ("STRING", {"default": "", "tooltip": "Base folder path to save the text file"}),
                "subfolder_name": ("STRING", {"default": "", "tooltip": "Subfolder name within the base folder"}),
                "filename": (
                    "STRING",
                    {"default": "output", "tooltip": "File name for the text file (without extension)"},
                ),
                "suffix": ("STRING", {"default": "", "tooltip": "Optional suffix appended to filename."}),
                "overwrite": (
                    "BOOLEAN",
                    {
                        "default": True,
                        "tooltip": "If enabled, existing files are overwritten. If disabled, a numbered suffix like _001 is added.",
                    },
                ),
                "extension": (
                    list(TEXT_EXTENSIONS),
                    {"default": ".txt", "tooltip": "File extension for the saved text file."},
                ),
            }
        }

    RETURN_TYPES = ()
    FUNCTION = "save_text"
    CATEGORY = "MuseHelper/Save"
    OUTPUT_NODE = True
    INPUT_IS_LIST = True

    @classmethod
    def IS_CHANGED(cls, **kwargs):
        # NaN != NaN, so the save re-runs on every queue instead of being
        # skipped from the execution cache.
        return float("NaN")

    def save_text(self, text, folder_path, subfolder_name, filename, suffix=None,
                  overwrite=None, extension=None):
        import folder_paths

        base = folder_paths.get_output_directory()
        for one_text, one_folder, one_subfolder, one_filename, one_suffix, one_overwrite, one_extension in zip(
            _as_list(text),
            _as_list(folder_path),
            _as_list(subfolder_name),
            _as_list(filename),
            _as_list(suffix if suffix is not None else ""),
            _as_list(overwrite if overwrite is not None else True),
            _as_list(extension if extension is not None else ".txt"),
        ):
            self._save_one(
                base, one_text, one_folder, one_subfolder, one_filename,
                one_suffix, one_overwrite, one_extension,
            )
        return (None,)

    @staticmethod
    def _save_one(base, text, folder_path, subfolder_name, filename, suffix,
                  overwrite, extension):
        directory = os.path.join(base, str(folder_path), str(subfolder_name))
        os.makedirs(directory, exist_ok=True)
        stem = f"{filename}{suffix or ''}"
        extension = str(extension) if str(extension) in TEXT_EXTENSIONS else ".txt"
        path = os.path.join(directory, f"{stem}{extension}")
        if os.path.isfile(path) and not overwrite:
            counter = 1
            while os.path.isfile(os.path.join(directory, f"{stem}_{counter:03d}{extension}")):
                counter += 1
            path = os.path.join(directory, f"{stem}_{counter:03d}{extension}")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(str(text))
        return path


class MuseHelperPurgeVRAM:
    """VRAM sweep mirroring LayerUtility: PurgeVRAM: fires after each output
    node it hangs off, sweeping the host cache and — on request — unloading
    every resident model so leftovers never stack up render after render."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "anything": (any_type, {}),
                "purge_cache": ("BOOLEAN", {"default": True}),
                "purge_models": ("BOOLEAN", {"default": True}),
            },
            "optional": {},
        }

    RETURN_TYPES = ()
    FUNCTION = "purge_vram"
    CATEGORY = "MuseHelper/SystemIO"
    OUTPUT_NODE = True

    def purge_vram(self, anything, purge_cache, purge_models):
        clear_memory()
        if purge_models:
            import comfy.model_management

            comfy.model_management.unload_all_models()
            comfy.model_management.soft_empty_cache()
        return (None,)


def clear_memory():
    """Host-side sweep: collect Python garbage and release the CUDA caching
    allocator's cached blocks and IPC handles. No model state is touched here —
    that is the ``purge_models`` half's job."""
    import torch

    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.ipc_collect()


NODE_CLASS_MAPPINGS = {
    "MuseHelper: Show Anything": MuseHelperShowAnything,
    "MuseHelper: Preview Text": MuseHelperPreviewText,
    "MuseHelper: Save Text With Path": MuseHelperSaveTextWithPath,
    "MuseHelper: Purge VRAM": MuseHelperPurgeVRAM,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MuseHelper: Show Anything": "MuseHelper: Show Anything",
    "MuseHelper: Preview Text": "MuseHelper: Preview Text",
    "MuseHelper: Save Text With Path": "MuseHelper: Save Text With Path",
    "MuseHelper: Purge VRAM": "MuseHelper: Purge VRAM",
}

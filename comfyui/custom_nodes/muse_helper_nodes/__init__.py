"""Local display/save/purge helpers for the Muse Director V1.4 workstation graph.

The upstream workflow wires four third-party helper types (easy showAnything,
iToolsPreviewText, SaveTextWithPath, LayerUtility: PurgeVRAM) as display sinks,
a compiled-prompt passthrough chain, a prompt file sink, and candidate-boundary
VRAM purges. This local pack carries the same interfaces so the graph keeps its
exact topology without pinning three extra third-party packs for nine sink
nodes. Every upstream call contract is mirrored here rather than imported, so
the graph's behaviour is preserved 1:1.
"""

from .nodes import (
    NODE_CLASS_MAPPINGS,
    NODE_DISPLAY_NAME_MAPPINGS,
)

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]

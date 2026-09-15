#!/bin/sh
# Forward the desktop's loopback-only ComfyUI to this laptop.
# Stop the tunnel with Ctrl-C.
set -eu

exec ssh \
  -N \
  -T \
  -o ExitOnForwardFailure=yes \
  -L 8188:127.0.0.1:8188 \
  desktop

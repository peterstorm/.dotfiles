# syntax=docker/dockerfile:1
# GLM-5.3 v16: NVIDIA Hyperflare (AzallazA fork, tag hyperflare-glm-20261112)
# built exactly as the recipe's EXPORT.md step 2 describes, inside a CUDA 13.1
# devel image because desktop is NixOS (no /usr/local/cuda-13.1, no FHS for
# uv's manylinux wheels). One image does both jobs:
#   - export: .venv/bin/ignition export (needs torch/FlashInfer/nvcc)
#   - serve:  flare-cli/target/release/flare run (pure Rust + the package)
# Every input is pinned: base images by digest, the fork by full commit,
# Python deps by the fork's uv.lock (--locked), Rust deps by Cargo.lock
# (--locked), rustc by version. The FlashInfer patches are the fork's own
# tp3-patches/, byte-identical (git blob ids) to the recipe folder's copy.
FROM ghcr.io/astral-sh/uv:0.11.29@sha256:eb2843a1e56fd9e30c7276ce1a52cba86e64c7b385f5e3279a0e08e02dd058fc AS uv

FROM nvidia/cuda:13.1.1-devel-ubuntu24.04@sha256:9cf8694a27722418a1f175d90f85d5afb5a728fd4a9907d7f0565efecfa14d32

ARG FORK_REPO=https://github.com/AzallazA/spark-local-inference.git
ARG FORK_TAG=hyperflare-glm-20261112
ARG FORK_COMMIT=ac9136b02c7c523f12d6e628e9d94f41006312ea
ARG RUST_VERSION=1.97.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git nasm patch pkg-config \
        protobuf-compiler libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:/usr/local/cuda/bin:$PATH \
    CUDA_HOME=/usr/local/cuda UV_PYTHON_INSTALL_DIR=/opt/uv-python UV_LINK_MODE=copy \
    UV_CACHE_DIR=/tmp/uv-cache
RUN curl -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION" \
    && rustc --version | grep -q "^rustc $RUST_VERSION "

WORKDIR /opt/flare
RUN git clone --quiet --branch "$FORK_TAG" --depth 1 "$FORK_REPO" . \
    && test "$(git rev-parse HEAD)" = "$FORK_COMMIT"

# EXPORT.md step 2: the Python environment, then the flare binary.
RUN uv sync --locked --extra prepare --extra test && rm -rf "$UV_CACHE_DIR"
RUN cargo build --locked --release --manifest-path flare-cli/Cargo.toml \
    && rm -rf flare-cli/target/release/build flare-cli/target/release/deps flare-cli/target/release/incremental \
    && flare-cli/target/release/flare --version

# EXPORT.md step 2: FlashInfer patches into the venv, then the b12x overlay
# (built from the patched copy; at two GPUs it compiles upstream's push gather).
RUN SP="$(.venv/bin/python -c 'import flashinfer, pathlib; print(pathlib.Path(flashinfer.__file__).parents[1])')" \
    && for p in tp3-patches/*.patch; do patch -p1 --forward -d "$SP" < "$p"; done \
    && bash tp3-tools/make-b12x-overlay.sh /opt/flare/.b12x-overlay \
    && .venv/bin/ignition export --help >/dev/null

# Export-time JIT prerequisites the recipe's Ubuntu host had and this image did
# not (first exports, 2026-11-14), in their own layer so the uv/cargo layers
# above stay cached:
#   - liburing-dev: b12x's checkpoint loader JIT-builds an io_uring batch
#     executor at weight load ("io_uring bounce support is unavailable"). The
#     containers also need seccomp=unconfined: Docker's default profile blocks
#     io_uring_setup/enter/register.
#   - ninja-build: torch.utils.cpp_extension builds the graph-catalog operators
#     with ninja (FileNotFoundError: 'ninja' at "Construct graph catalog").
#   - uid 1000's home: the Rust `flare` CLI finds ~/.cache/flare (cores) and
#     ~/.config/flare (signing key, trust) through getpwuid_r, ignoring $HOME,
#     while the Python exporter honors $HOME. Pointing the image's uid-1000
#     user at /flare-home makes both resolve the same mounted store (first
#     serve failed "cannot access core" with the core under /flare-home and
#     the CLI looking in /home/ubuntu). The scripts run as uid 1000 only.
RUN apt-get update \
    && apt-get install -y --no-install-recommends liburing-dev ninja-build \
    && rm -rf /var/lib/apt/lists/* \
    && test "$(getent passwd 1000 | cut -d: -f1)" = ubuntu \
    && usermod -d /flare-home ubuntu \
    && test "$(getent passwd 1000 | cut -d: -f6)" = /flare-home

LABEL ai.peterstorm.inference.profile=glm53-flash-hyperflare-tp2-v16 \
      ai.peterstorm.inference.hyperflare-commit=$FORK_COMMIT \
      ai.peterstorm.inference.cuda=13.1.1

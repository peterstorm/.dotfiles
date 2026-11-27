# syntax=docker/dockerfile:1
# GLM-5.3 v17: upstream NVIDIA Hyperflare (NVIDIA/hyperflare-inference) with the
# official recipes (local-inference-lab/hyperflare-recipes) at PR #55's head and
# Local Inference Lab FlashInfer at PR #151's head: the sequence-parallel
# row-sharded GLM-5.3 Flash prefill. One image does both jobs:
#   - export: /opt/hyperflare-recipes/.venv/bin/ignition export
#   - serve:  /usr/local/bin/flare run (native Rust, no Python)
#
# Every source is a required build argument, passed by
# build-glm53-flash-hyperflare-tp2-v17-image.sh from glm53-v17-hyperflare/pins.sh
# and recorded as a label the export and run scripts check. Base images are
# pinned by digest, Python dependencies by the recipes' uv.lock re-locked onto
# the pinned git sources (asserted below), Rust dependencies by Cargo.lock
# (--locked), rustc by version and rustup-init by version and sha256.
#
# The base image, the first apt layer, uv and rustup are v16's (glm53-v16-hyperflare/
# Dockerfile), same digests and versions. The cargo, uv and maturin build caches
# live on tmpfs mounts, never in a layer: desktop's only NVMe is nearly full and
# the image must hold only what runs.
FROM ghcr.io/astral-sh/uv:0.11.29@sha256:eb2843a1e56fd9e30c7276ce1a52cba86e64c7b385f5e3279a0e08e02dd058fc AS uv

FROM nvidia/cuda:13.1.1-devel-ubuntu24.04@sha256:9cf8694a27722418a1f175d90f85d5afb5a728fd4a9907d7f0565efecfa14d32

ARG RUST_VERSION=1.97.0
ARG RUSTUP_VERSION=1.29.3
ARG RUSTUP_INIT_SHA256=b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55

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
RUN curl -sSfo /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init" \
    && echo "$RUSTUP_INIT_SHA256  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION" \
    && rm /tmp/rustup-init \
    && rustc --version | grep -q "^rustc $RUST_VERSION "

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Upstream's preparation build prerequisites beyond v16's first layer
# (docs/model-preparation.md "Environment setup"): ninja for torch extension and
# graph-catalog builds, liburing headers for b12x's io_uring checkpoint reader.
RUN apt-get update \
    && apt-get install -y --no-install-recommends liburing-dev ninja-build \
    && rm -rf /var/lib/apt/lists/*

ARG HYPERFLARE_INFERENCE_COMMIT
ARG RECIPES_COMMIT
ARG FLASHINFER_COMMIT
RUN for pin in "HYPERFLARE_INFERENCE_COMMIT=$HYPERFLARE_INFERENCE_COMMIT" "RECIPES_COMMIT=$RECIPES_COMMIT" \
                "FLASHINFER_COMMIT=$FLASHINFER_COMMIT"; do \
      grep -Eqx '[0-9a-f]{40}' <<<"${pin#*=}" \
        || { echo "build argument ${pin%%=*} must be a full commit id (use build-glm53-flash-hyperflare-tp2-v17-image.sh)" >&2; exit 1; }; \
    done

# The native server, from the same hyperflare-inference commit the Python side
# is locked to below.
WORKDIR /opt/hyperflare-inference
RUN git init -q . \
    && git fetch -q --depth 1 https://github.com/NVIDIA/hyperflare-inference.git "$HYPERFLARE_INFERENCE_COMMIT" \
    && git checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$HYPERFLARE_INFERENCE_COMMIT"
RUN --mount=type=tmpfs,target=/tmp/cargo-target --mount=type=tmpfs,target=/opt/cargo/registry \
    CARGO_TARGET_DIR=/tmp/cargo-target cargo build --locked --release \
        --manifest-path flare-cli/Cargo.toml --bin flare \
    && install -Dm755 /tmp/cargo-target/release/flare /usr/local/bin/flare \
    && flare --version

# The recipes at PR #55's head.
WORKDIR /opt/hyperflare-recipes
RUN git init -q . \
    && git fetch -q --depth 1 https://github.com/local-inference-lab/hyperflare-recipes.git "$RECIPES_COMMIT" \
    && git checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$RECIPES_COMMIT"

# Re-lock onto the pinned sources. The recipes' own lock resolves ignition (and
# with it heliopause, a path dependency inside hyperflare-inference) to a commit
# that predates the ignition.parameters module every recipe imports, and
# flashinfer-python to main; pins.sh says why each pin is what it is. ignition is
# a direct dependency, so its root source moves from a branch to the exact rev.
# flashinfer-python is NOT: it arrives through ignition[prepare], whose own
# [tool.uv.sources] names flashinfer main and is the one uv honours for it, so
# the recipes' root flashinfer source is inert (the first v17 build proved it:
# the lock stayed on main 8bdfd6c9). It is deleted, and a uv override, which
# replaces every declaration of a package including transitive ones, pins
# flashinfer-python[b12x] to the PR #151 commit by direct URL. `uv lock`
# re-resolves keeping every other locked version it can, and the asserts prove
# every hyperflare-inference and flashinfer source in the lock is exactly the
# pin. The package versions the re-lock moved are recorded in relock.diff
# beside the lock, not hidden.
RUN sed -i -E \
      -e 's|^(ignition = \{ git = "https://github.com/NVIDIA/hyperflare-inference.git"), branch = "main" \}$|\1, rev = "'"$HYPERFLARE_INFERENCE_COMMIT"'" }|' \
      -e '/^flashinfer-python = \{ git = "https:\/\/github.com\/local-inference-lab\/flashinfer.git", branch = "main" \}$/d' \
      pyproject.toml \
    && ! grep -q '^\[tool\.uv\]$' pyproject.toml \
    && printf '\n[tool.uv]\noverride-dependencies = [\n    "flashinfer-python[b12x] @ git+https://github.com/local-inference-lab/flashinfer.git@%s",\n]\n' \
         "$FLASHINFER_COMMIT" >> pyproject.toml \
    && grep -Fq "hyperflare-inference.git\", rev = \"$HYPERFLARE_INFERENCE_COMMIT\" }" pyproject.toml \
    && ! grep -q '^flashinfer-python = ' pyproject.toml \
    && grep -Fq "flashinfer.git@$FLASHINFER_COMMIT\"," pyproject.toml \
    && cp uv.lock /tmp/uv.lock.pr55
RUN --mount=type=tmpfs,target=/tmp/uv-cache \
    uv lock \
    && grep -Fq "hyperflare-inference.git?rev=$HYPERFLARE_INFERENCE_COMMIT#$HYPERFLARE_INFERENCE_COMMIT\"" uv.lock \
    && grep -Fq "hyperflare-inference.git?subdirectory=heliopause&rev=$HYPERFLARE_INFERENCE_COMMIT#$HYPERFLARE_INFERENCE_COMMIT\"" uv.lock \
    && grep -Fq "flashinfer.git?rev=$FLASHINFER_COMMIT#$FLASHINFER_COMMIT\"" uv.lock \
    && { ! grep -oE 'hyperflare-inference\.git[^"]*#[0-9a-f]+' uv.lock | grep -v "#$HYPERFLARE_INFERENCE_COMMIT\$"; } \
    && { ! grep -oE 'flashinfer\.git[^"]*#[0-9a-f]+' uv.lock | grep -v "#$FLASHINFER_COMMIT\$"; } \
    && pairs() { awk '/^\[\[package\]\]/{n=""} /^name = /{n=$3} /^version = /{print n, $3}' "$1" | sort; } \
    && { diff <(pairs /tmp/uv.lock.pr55) <(pairs uv.lock) || true; } > relock.diff \
    && rm /tmp/uv.lock.pr55
RUN --mount=type=tmpfs,target=/tmp/uv-cache --mount=type=tmpfs,target=/tmp/cargo-target \
    --mount=type=tmpfs,target=/opt/cargo/registry \
    CARGO_TARGET_DIR=/tmp/cargo-target uv sync --locked --extra test

# The installed sources are the pinned ones and fit together: PR #151's KDA
# segment kernels import, the recipes import the ignition they need, and the GLM
# recipe declares PR #55's two row-shard parameters.
RUN .venv/bin/python -c "import flashinfer.experimental.b12x.sequence.kda_prefill as k; k.segment_summarize; k.segment_finalize" \
    && .venv/bin/python -c "import dataclasses as d; from hyperflare_recipes.recipes.glm53.recipe import Glm53Parameters as P; f = {x.name for x in d.fields(P)}; assert {'row_shard_prefill', 'row_shard_attention'} <= f, sorted(f)" \
    && .venv/bin/ignition export --help >/dev/null

# uid 1000's home is /flare-home: the Rust flare CLI finds ~/.cache/flare (cores)
# and ~/.config/flare (signing key, trust) through getpwuid_r, ignoring $HOME,
# while the Python exporter honors $HOME (v16, 2026-11-14). The scripts run as
# uid 1000 only and mount the v17 state root there.
RUN test "$(getent passwd 1000 | cut -d: -f1)" = ubuntu \
    && usermod -d /flare-home ubuntu \
    && test "$(getent passwd 1000 | cut -d: -f6)" = /flare-home

LABEL ai.peterstorm.inference.profile=glm53-flash-hyperflare-tp2-v17 \
      ai.peterstorm.inference.hyperflare-commit=$HYPERFLARE_INFERENCE_COMMIT \
      ai.peterstorm.inference.recipes-commit=$RECIPES_COMMIT \
      ai.peterstorm.inference.flashinfer-commit=$FLASHINFER_COMMIT \
      ai.peterstorm.inference.cuda=13.1.1

FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140

ARG SOURCE_DATE_EPOCH=1788134400
LABEL ai.peterstorm.inference.base-image="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140" \
      ai.peterstorm.inference.overlay="glm53-v9-fast-safe" \
      ai.peterstorm.inference.state-bounds="vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f" \
      ai.peterstorm.inference.mamba-overlap="vllm-project/vllm#50729@a02cfccbc6187344325e364f09f6d8c33c4b253b" \
      ai.peterstorm.inference.slot-bounds="vllm-project/vllm#54296@191f82d710493c9a02077d976d8cf0403ab8c96a" \
      ai.peterstorm.inference.persistent-topk="vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3" \
      ai.peterstorm.inference.topk-ties="exact-score-lower-token-index" \
      ai.peterstorm.inference.kpool-tail="persistent-circular-slot-buffer" \
      ai.peterstorm.inference.gdn-mixed-partition="cpu-proven-complete-in-range"

COPY glm53-mtp-prefix-safety/glm53-mtp-prefix-state-safety.patch \
     glm53-v9-fast-safe/glm53-v9-state-graph-safety.patch \
     glm53-v9-fast-safe/glm53-v9-fast-persistent-topk.patch /tmp/
RUN set -eux; \
    root=/opt/infernal-invocation/vllm; \
    echo "936d65f7e9e85e0c67ada8210ce26108cf7868c4f991f76d0ad3bc125c07dc3a  $root/vllm/v1/worker/mamba_utils.py" | sha256sum --check --strict; \
    echo "258280309e3e117480416254361d0911f7eeeeb838a4bcb86a10e18c535b4145  $root/vllm/v1/worker/block_table.py" | sha256sum --check --strict; \
    echo "e66079fcf714bd23781952adab220ce9d05b3ef321dfa559ad24bc99a43483b5  $root/vllm/v1/worker/gpu/block_table.py" | sha256sum --check --strict; \
    echo "05fbd197ab2995b05ae24247f02fe7bdeb8f431fb860fc6fb0a40b8afb8cf665  $root/vllm/v1/attention/backends/mla/indexer.py" | sha256sum --check --strict; \
    echo "fb62021d5e967bdfd8c6124eb13af9cf81c456cc4c81112b87ff4c2768728985  $root/csrc/libtorch_stable/persistent_topk.cuh" | sha256sum --check --strict; \
    echo "0d9d971077256e641aa19cd25eeaeb9a82ad48eab95f3c8591a39cfef2123e5f  $root/csrc/libtorch_stable/topk_histogram_4096.cuh" | sha256sum --check --strict; \
    echo "a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85  /tmp/glm53-mtp-prefix-state-safety.patch" | sha256sum --check --strict; \
    echo "4ecec3de89f52125fc5884e4924ed5fb326bb1d9e6a97fc04a005147e22ea528  /tmp/glm53-v9-state-graph-safety.patch" | sha256sum --check --strict; \
    echo "8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395  /tmp/glm53-v9-fast-persistent-topk.patch" | sha256sum --check --strict; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-mtp-prefix-state-safety.patch; \
    echo "10306573a3b19d816f9066ff7b14679aa07e9eefe347f68952fe5c04f923753d  $root/vllm/v1/worker/mamba_utils.py" | sha256sum --check --strict; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v9-state-graph-safety.patch; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v9-fast-persistent-topk.patch; \
    echo "e0e8140d3b004509ef2345a5f4929f88d14b3fef7446c5bbfdb39c34fe500108  $root/vllm/v1/worker/mamba_utils.py" | sha256sum --check --strict; \
    echo "4ad1e13f0c0f271e1a2a24675454e200b7469c136def742b796b8530357a90ae  $root/vllm/v1/worker/block_table.py" | sha256sum --check --strict; \
    echo "32cfe59bffd1944c3145ff002e47f77c4d9aa859ff0a4a47f780be987ece8c82  $root/vllm/v1/worker/gpu/block_table.py" | sha256sum --check --strict; \
    echo "6a2fe647b54f7d8007550d12d7f42237b8b127bf24603dfc216f3989ff7715cd  $root/vllm/v1/attention/backends/mla/indexer.py" | sha256sum --check --strict; \
    echo "ad1fde7a145c57442d856be2d37d33912109bb007c574b5ad6d42cc1a1176e49  $root/csrc/libtorch_stable/persistent_topk.cuh" | sha256sum --check --strict; \
    echo "d6b447486d8186625e5b7ac196c3d04c5e6f016232d6511df68c3515ac71d078  $root/csrc/libtorch_stable/topk_histogram_4096.cuh" | sha256sum --check --strict; \
    /opt/venv/bin/python -m compileall -q \
      "$root/vllm/v1/worker/mamba_utils.py" \
      "$root/vllm/v1/worker/block_table.py" \
      "$root/vllm/v1/worker/gpu/block_table.py" \
      "$root/vllm/v1/attention/backends/mla/indexer.py"; \
    python_path="$(/opt/venv/bin/python -c 'import sys; print(":".join(sys.path))')"; \
    rm -rf /tmp/vllm-cmake /tmp/vllm-install; \
    cmake -S "$root" -B /tmp/vllm-cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DVLLM_TARGET_DEVICE=cuda \
      -DVLLM_PYTHON_EXECUTABLE=/opt/venv/bin/python \
      -DVLLM_PYTHON_PATH="$python_path" \
      -DFETCHCONTENT_BASE_DIR=/tmp/vllm-fetchcontent \
      -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
      -DCMAKE_CUDA_ARCHITECTURES=120a \
      -DNVCC_THREADS=2; \
    cmake --build /tmp/vllm-cmake --target _C_stable_libtorch -j 2; \
    cmake --install /tmp/vllm-cmake --prefix /tmp/vllm-install --component _C_stable_libtorch; \
    built_so="$(find /tmp/vllm-install -type f -name '_C_stable_libtorch*.so' -print -quit)"; \
    test -n "$built_so"; \
    install -m 0755 "$built_so" "$root/vllm/_C_stable_libtorch.abi3.so"; \
    install -m 0755 "$built_so" /opt/venv/lib/python3.12/site-packages/vllm/_C_stable_libtorch.abi3.so; \
    test "$(sha256sum "$root/vllm/_C_stable_libtorch.abi3.so" | cut -d' ' -f1)" != "852a544186d0a85a478626184b169f9d0cc3a077da20308177ac7be0e4248c7f"; \
    rm -rf /tmp/vllm-cmake /tmp/vllm-install /tmp/vllm-fetchcontent \
      /tmp/glm53-mtp-prefix-state-safety.patch \
      /tmp/glm53-v9-state-graph-safety.patch \
      /tmp/glm53-v9-fast-persistent-topk.patch

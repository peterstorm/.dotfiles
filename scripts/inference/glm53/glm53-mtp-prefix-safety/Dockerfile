FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140

ARG SOURCE_DATE_EPOCH=1788048000
LABEL ai.peterstorm.inference.base-image="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140" \
      ai.peterstorm.inference.overlay="glm53-mtp-prefix-state-safety" \
      ai.peterstorm.inference.overlay-upstream-pr="vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f" \
      ai.peterstorm.inference.overlay-patch-sha256="a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85" \
      ai.peterstorm.inference.exact-topk-issue="vllm-project/vllm#51782" \
      ai.peterstorm.inference.exact-topk-patch-sha256="00254654846b80fc0ff44019ca0641586023b46993bac4af3e579cf8522a3041" \
      ai.peterstorm.inference.gdn-mixed-partition="cpu-proven-complete-in-range"

COPY glm53-mtp-prefix-state-safety.patch glm53-exact-sparse-topk.patch /tmp/
RUN set -eux; \
    root=/opt/infernal-invocation/vllm; \
    echo "044d005cfe59fd0818ed421274e04f3e8dd679b8cdb64fca9f4422f2643484b2  $root/vllm/model_executor/layers/mamba/ops/causal_conv1d.py" | sha256sum --check --strict; \
    echo "a4515ec7895b40ed878cf380445034b25faa61fbaa799d96c49217bbdfd7e400  $root/vllm/model_executor/layers/mamba/ops/mamba_ssm.py" | sha256sum --check --strict; \
    echo "205d07072a2667c6f5ac4baf88c718135dce5de300fa558a1b03b3352b4b3e25  $root/vllm/models/kimi_k3/amd/ops/third_party/kda/fused_recurrent.py" | sha256sum --check --strict; \
    echo "bffe3fc24af947695fd278e62298eec7e00d89db1bbcc405bcb1768f4bc9af54  $root/vllm/models/kimi_k3/nvidia/ops/third_party/kda/fused_recurrent.py" | sha256sum --check --strict; \
    echo "371e7d733e90a7147fbca8dbfe67e62503ba663bd1570424bc0efa22c54f3e2b  $root/vllm/third_party/flash_linear_attention/ops/fused_recurrent.py" | sha256sum --check --strict; \
    echo "000ab8996af9788fdb8843a6a3b91833e7a14c8acc0e1ea073a536330f64cb6f  $root/vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py" | sha256sum --check --strict; \
    echo "0f67bb6f90355b036843415fa63223fa257040a67440e7f1ff5f495437ee3b04  $root/vllm/v1/attention/backends/gdn_attn.py" | sha256sum --check --strict; \
    echo "936d65f7e9e85e0c67ada8210ce26108cf7868c4f991f76d0ad3bc125c07dc3a  $root/vllm/v1/worker/mamba_utils.py" | sha256sum --check --strict; \
    echo "1a6b8440c50937678dca2dd895b6c47ee79e12dcb2755bd8569d6f585cc68aaa  $root/vllm/model_executor/layers/sparse_attn_indexer.py" | sha256sum --check --strict; \
    echo "ac6b64227346e76c5cf7d8c5e5011b4e32d7c2c811982338a6c24513c1304229  $root/vllm/model_executor/layers/sparse_attn_indexer_kpool.py" | sha256sum --check --strict; \
    echo 'a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85  /tmp/glm53-mtp-prefix-state-safety.patch' | sha256sum --check --strict; \
    echo '00254654846b80fc0ff44019ca0641586023b46993bac4af3e579cf8522a3041  /tmp/glm53-exact-sparse-topk.patch' | sha256sum --check --strict; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-mtp-prefix-state-safety.patch; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-exact-sparse-topk.patch; \
    echo "64635e5747a81192005fb67a191fdad591f008031d5415defc687279e98f9c71  $root/vllm/model_executor/layers/mamba/ops/causal_conv1d.py" | sha256sum --check --strict; \
    echo "a76315029a3cb82d7540306d060dddbd6238c7ee2436635210fdfab0494241d8  $root/vllm/model_executor/layers/mamba/ops/mamba_ssm.py" | sha256sum --check --strict; \
    echo "52103e6c1e585c688e694090083998feda5b38108dc8b0548ce0642faba6823d  $root/vllm/models/kimi_k3/amd/ops/third_party/kda/fused_recurrent.py" | sha256sum --check --strict; \
    echo "dd3d2fb684e947e11e5b64fca0cb26d93bf0bc6bc8e6dbde480089a8bbe67620  $root/vllm/models/kimi_k3/nvidia/ops/third_party/kda/fused_recurrent.py" | sha256sum --check --strict; \
    echo "f98f8a5a5cdc3a746637656350d7f72349c5a03b2272657c082086ab86a15135  $root/vllm/third_party/flash_linear_attention/ops/fused_recurrent.py" | sha256sum --check --strict; \
    echo "c45f746199067fb3981ca0e9c136a8109a12666d44a39ea5daae03d19c4be132  $root/vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py" | sha256sum --check --strict; \
    echo "04b1733d7d65ddcaefab59143bc59dbe61f8bc0404c1fcc5cddcd82a1718f697  $root/vllm/v1/attention/backends/gdn_attn.py" | sha256sum --check --strict; \
    echo "10306573a3b19d816f9066ff7b14679aa07e9eefe347f68952fe5c04f923753d  $root/vllm/v1/worker/mamba_utils.py" | sha256sum --check --strict; \
    echo "cc73aebd80723718331b40782623e799e7ba61f143d1ab2f8bfd3f4877c5ce34  $root/vllm/model_executor/layers/sparse_attn_indexer.py" | sha256sum --check --strict; \
    echo "a5345e5703232d61d285a988ca67757d19828ef5b0bcc10e161c17c6a5c2f5d2  $root/vllm/model_executor/layers/sparse_attn_indexer_kpool.py" | sha256sum --check --strict; \
    /opt/venv/bin/python -m compileall -q \
      "$root/vllm/model_executor/layers/sparse_attn_indexer.py" \
      "$root/vllm/model_executor/layers/sparse_attn_indexer_kpool.py" \
      "$root/vllm/model_executor/layers/mamba/ops/causal_conv1d.py" \
      "$root/vllm/model_executor/layers/mamba/ops/mamba_ssm.py" \
      "$root/vllm/models/kimi_k3/amd/ops/third_party/kda/fused_recurrent.py" \
      "$root/vllm/models/kimi_k3/nvidia/ops/third_party/kda/fused_recurrent.py" \
      "$root/vllm/third_party/flash_linear_attention/ops/fused_recurrent.py" \
      "$root/vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py" \
      "$root/vllm/v1/attention/backends/gdn_attn.py" \
      "$root/vllm/v1/worker/mamba_utils.py"; \
    rm /tmp/glm53-mtp-prefix-state-safety.patch /tmp/glm53-exact-sparse-topk.patch

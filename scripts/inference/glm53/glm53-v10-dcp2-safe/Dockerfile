FROM peterstorm/vllm:glm53-v9-fast-safe

ARG SOURCE_DATE_EPOCH=1788134400
LABEL ai.peterstorm.inference.base-image="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2" \
      ai.peterstorm.inference.overlay="glm53-v10-dcp2-safe" \
      ai.peterstorm.inference.dcp="tp2-ep2-dcp2" \
      ai.peterstorm.inference.dcp-attention="b12x-mla-sparse" \
      ai.peterstorm.inference.dcp-transport="ag-rs" \
      ai.peterstorm.inference.mamba-dcp-layout="replicated-full-position-table" \
      ai.peterstorm.inference.block-table-overflow="fail-closed" \
      ai.peterstorm.inference.mtp-position-zero="local-inference-lab/vllm#539@4c1f7b2c37b75d4e8fefed337e82c3771dc5f8a7-adapted" \
      ai.peterstorm.inference.b12x-attention-commit="903667d36aee19320776019a31dd06d1e9255b6a" \
      ai.peterstorm.inference.b12x-moe-lineage="v9-byte-exact-36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8" \
      ai.peterstorm.inference.glm-next-fp8-abi="explicit-model-type-528-byte-record" \
      ai.peterstorm.inference.glm-next-fp8-spec="logical-528-physical-656-hybrid-page" \
      ai.peterstorm.inference.hybrid-page-padding="validated-widening" \
      ai.peterstorm.inference.b12x-padded-page="packed-stride-writer-precompile" \
      ai.peterstorm.inference.graph-shapes="mtp3-c1-c4-dense"

COPY glm53-v10-dcp2-safe/glm53-v10-dcp2-mamba-geometry.patch \
     glm53-v10-dcp2-safe/glm53-v10-mtp-position-zero.patch \
     glm53-v10-dcp2-safe/glm53-v10-b12x-glm-next-fp8.patch \
     glm53-v10-dcp2-safe/glm53-v10-glm-next-fp8-spec.patch \
     glm53-v10-dcp2-safe/glm53-v10-hybrid-page-padding.patch \
     glm53-v10-dcp2-safe/glm53-v10-b12x-padded-page.patch \
     glm53-v10-dcp2-safe/b12x-903667d36aee19320776019a31dd06d1e9255b6a.tar.gz /tmp/
RUN set -eux; \
    root=/opt/infernal-invocation/vllm; \
    b12x_root=/opt/infernal-invocation/b12x; \
    echo "182d09b48eb62cbd7a01bedb6c4264394cb2d962d7a8dc48bf4011a158f2b647  $root/vllm/v1/kv_cache_interface.py" | sha256sum --check --strict; \
    echo "32cfe59bffd1944c3145ff002e47f77c4d9aa859ff0a4a47f780be987ece8c82  $root/vllm/v1/worker/gpu/block_table.py" | sha256sum --check --strict; \
    echo "d459c88c58df05de3cc3057f3a114e28f9b3d75c40433d716b8ded14a0029eed  $root/vllm/models/glm5next/nvidia/ops/fused_eh_norm.py" | sha256sum --check --strict; \
    echo "d07db675349f3372dad16c4d23a692e20b6dfea0e0c5f43315888dc95005df38  $root/vllm/models/glm5next/nvidia/mtp.py" | sha256sum --check --strict; \
    echo "0499c674b6890266b50fa0d5724dcfbb83cba3917714a6787e5dddc6feb65572  $root/vllm/v1/attention/backends/mla/b12x_mla_sparse.py" | sha256sum --check --strict; \
    echo "a070481091d425eddc311e25c0cb770e7ed79d1ee3d196157ad28d789fb5c60c  $root/vllm/model_executor/layers/attention/mla_attention.py" | sha256sum --check --strict; \
    echo "5386a70a5116510a0c25de28a04e038ac405cdbe522a9c97430f2eb09d08adf8  $root/vllm/v1/core/kv_cache_utils.py" | sha256sum --check --strict; \
    echo "2bf12190ef649bd958b33b8cf842e1dd55665137391a44848a66ea638bfb6f5c  $b12x_root/b12x/attention/sparse_mla/__init__.py" | sha256sum --check --strict; \
    echo "2097654986b70e80698cdd4bb69bafcfa136b57361074bba4741b09ec3e3d010  $b12x_root/b12x/moe/fused_moe/api.py" | sha256sum --check --strict; \
    echo "6e4528c26bad40736ad991f8c5877ef12dbffe1c642c06cfc97dff4245f71086  $b12x_root/b12x/attention/nsa_indexer/__init__.py" | sha256sum --check --strict; \
    echo "7ebef333c9ef4f363136fb0f78a622edbf886e0b62bd2e87fba11b17164c705a  /tmp/glm53-v10-dcp2-mamba-geometry.patch" | sha256sum --check --strict; \
    echo "0e723d2978ac6d42ce7963727638a80c984a6111cfbe304d507444005362d253  /tmp/glm53-v10-mtp-position-zero.patch" | sha256sum --check --strict; \
    echo "60bf08b17169dfe65105460790b371035b0109098dce69107edc868b3e70b4e4  /tmp/glm53-v10-b12x-glm-next-fp8.patch" | sha256sum --check --strict; \
    echo "c2f4e4724da7c3f3306030a3ac1406a8d3e304301de92a753df4d56d574f3fbc  /tmp/glm53-v10-glm-next-fp8-spec.patch" | sha256sum --check --strict; \
    echo "c6098ffef5b662dd91820f14485642e8cb94662544e2f18a877ebfc5d6d0eec5  /tmp/glm53-v10-hybrid-page-padding.patch" | sha256sum --check --strict; \
    echo "fc6ae25924cca96c652044abd52166970e9f8057264daa6625e0ff1aa8ab84b8  /tmp/glm53-v10-b12x-padded-page.patch" | sha256sum --check --strict; \
    echo "4a9eafc91967d6e88169522c0db6e234025cc372e205ffa0f354d74e210dba57  /tmp/b12x-903667d36aee19320776019a31dd06d1e9255b6a.tar.gz" | sha256sum --check --strict; \
    rm -rf /tmp/b12x-source; \
    tar -xzf /tmp/b12x-903667d36aee19320776019a31dd06d1e9255b6a.tar.gz -C /tmp; \
    rm -rf "$b12x_root/b12x/attention/sparse_mla" \
      "$b12x_root/b12x/attention/_shared/mla"; \
    cp -a /tmp/b12x-source/b12x/attention/sparse_mla \
      "$b12x_root/b12x/attention/sparse_mla"; \
    cp -a /tmp/b12x-source/b12x/attention/_shared/mla \
      "$b12x_root/b12x/attention/_shared/mla"; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v10-dcp2-mamba-geometry.patch; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v10-mtp-position-zero.patch; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v10-b12x-glm-next-fp8.patch; \
    echo "d89c89ea3c76132d5f7c1a7675d6cb577ffb56c3087bb45133b65ed626461e7f  $root/vllm/v1/kv_cache_interface.py" | sha256sum --check --strict; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v10-glm-next-fp8-spec.patch; \
    echo "42353dcb13f9bc6d6416e5500eb638fa2e8c4b0382843536dd6181e470915a09  $root/vllm/v1/kv_cache_interface.py" | sha256sum --check --strict; \
    echo "87626b13538580e5552c613ae2f6d1a19628bcdf5836dd60df94906a1559d78a  $root/vllm/model_executor/layers/attention/mla_attention.py" | sha256sum --check --strict; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v10-hybrid-page-padding.patch; \
    echo "bbd2f6549cc18af4148bd722cb25d9ccb7da8c571a233c6d181b28121710623e  $root/vllm/v1/core/kv_cache_utils.py" | sha256sum --check --strict; \
    echo "edc3fef19c94d22850f1dbef27566ba41f720c0187743355e24436c475bbf232  $root/vllm/v1/worker/gpu/block_table.py" | sha256sum --check --strict; \
    echo "433190de4bdb5db55f4464b511e4953fe7e22bab9d9b73cc884cc25ffc83c7af  $root/vllm/models/glm5next/nvidia/ops/fused_eh_norm.py" | sha256sum --check --strict; \
    echo "eee15d090d7fbe40fd249ce2726056f2cc42a6ed7a228685f4d928296cc32c7a  $root/vllm/models/glm5next/nvidia/mtp.py" | sha256sum --check --strict; \
    echo "f0a279f309e3dd78c6681e6eb51a3c240be4b76b469eecc01bd934afc9d2f893  $root/vllm/v1/attention/backends/mla/b12x_mla_sparse.py" | sha256sum --check --strict; \
    patch --batch --fuzz=0 -d "$root" -p1 < /tmp/glm53-v10-b12x-padded-page.patch; \
    echo "d9dc3eda5024866711aa352036d0edd87772943eabdc3ce4e3a8b0ad9bf96641  $root/vllm/v1/attention/backends/mla/b12x_mla_sparse.py" | sha256sum --check --strict; \
    echo "a10e95fbf8f9abbaaaf9dafcd3a9d4dfe13cdef1360c22888823ee937510f658  $b12x_root/b12x/attention/sparse_mla/__init__.py" | sha256sum --check --strict; \
    echo "7fa27daa41a2c791444b77406bf2f3a231dfb96f29864551013407ec4a91613b  $b12x_root/b12x/attention/sparse_mla/api.py" | sha256sum --check --strict; \
    echo "5a0f2f5ba15c25569fa081c28f35d8d24662f9f0d206ae7447b914ac65617508  $b12x_root/b12x/attention/_shared/mla/traits.py" | sha256sum --check --strict; \
    echo "394ee7728987037b78e51dd46f8f397e5287cca72f6361b30cc580ca49f7acb7  $b12x_root/b12x/attention/_shared/mla/kv_cache.py" | sha256sum --check --strict; \
    echo "2097654986b70e80698cdd4bb69bafcfa136b57361074bba4741b09ec3e3d010  $b12x_root/b12x/moe/fused_moe/api.py" | sha256sum --check --strict; \
    echo "6e4528c26bad40736ad991f8c5877ef12dbffe1c642c06cfc97dff4245f71086  $b12x_root/b12x/attention/nsa_indexer/__init__.py" | sha256sum --check --strict; \
    /opt/venv/bin/python -m compileall -q \
      "$root/vllm/v1/kv_cache_interface.py" \
      "$root/vllm/v1/worker/gpu/block_table.py" \
      "$root/vllm/v1/core/kv_cache_utils.py" \
      "$root/vllm/model_executor/layers/attention/mla_attention.py" \
      "$root/vllm/models/glm5next/nvidia/ops/fused_eh_norm.py" \
      "$root/vllm/models/glm5next/nvidia/mtp.py" \
      "$root/vllm/v1/attention/backends/mla/b12x_mla_sparse.py" \
      "$b12x_root/b12x"; \
    PYTHONPATH="$root:$b12x_root" /opt/venv/bin/python -c 'from b12x.attention import sparse_mla; from vllm.v1.attention.backends.mla.b12x_mla_sparse import B12xMLASparseBackend; assert hasattr(sparse_mla, "ModelType"); assert hasattr(sparse_mla, "concat_and_cache_glm_next_mla"); assert hasattr(sparse_mla, "compile_glm_next_mla_cache_writer"); assert B12xMLASparseBackend.get_kv_cache_shape(2, 64, 1, 512, "fp8_ds_mla") == (2, 64, 528); from vllm.v1.kv_cache_interface import MLAAttentionSpec; import torch; spec=MLAAttentionSpec(block_size=64,num_kv_heads=1,head_size=512,dtype=torch.uint8,cache_dtype_str="fp8_ds_mla",model_version="glm_next_fp8",page_size_padded=64*656); assert spec.real_page_size_bytes == 64*528; assert spec.page_size_bytes == 64*656'; \
    rm -rf /tmp/b12x-source /tmp/b12x-*.tar.gz /tmp/glm53-v10-*.patch

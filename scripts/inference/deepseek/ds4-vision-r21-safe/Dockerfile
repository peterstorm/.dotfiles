FROM voipmonitor/vllm@sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291

ARG SOURCE_DATE_EPOCH=1788158430
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    PYTHONDONTWRITEBYTECODE=1

COPY base-source-sha256.txt /tmp/ds4-vision/base-source-sha256.txt
COPY final-source-sha256.txt /tmp/ds4-vision/final-source-sha256.txt
COPY ds4-vision-r21.patch /tmp/ds4-vision/ds4-vision-r21.patch
COPY verify.py /opt/ds4-vision-r21/verify.py

WORKDIR /opt/infernal-invocation/vllm
RUN echo '800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469  /tmp/ds4-vision/ds4-vision-r21.patch' | sha256sum -c - \
    && echo '59a763fb58677c327aa5dd8516fed81ced34da4e61b0ac701e0eb572dd38ff82  /tmp/ds4-vision/base-source-sha256.txt' | sha256sum -c - \
    && echo '967c6a451abe7049a66e974148cf8feabbcbbf43511d0c1b32248c8ed0fcf770  /tmp/ds4-vision/final-source-sha256.txt' | sha256sum -c - \
    && sha256sum -c /tmp/ds4-vision/base-source-sha256.txt \
    && test ! -e vllm/models/deepseek_v4/image_processing.py \
    && test ! -e vllm/models/deepseek_v4/multimodal.py \
    && test ! -e vllm/models/deepseek_v4/routing.py \
    && test ! -e vllm/models/deepseek_v4/vision.py \
    && test ! -e vllm/models/deepseek_v4/vision_swa.py \
    && patch --batch --fuzz=0 -p1 < /tmp/ds4-vision/ds4-vision-r21.patch \
    && sha256sum -c /tmp/ds4-vision/final-source-sha256.txt \
    && python3 -m compileall -q \
        vllm/models/deepseek_v4 \
        vllm/model_executor/models/registry.py \
        vllm/transformers_utils/configs/deepseek_v4.py \
        vllm/v1/attention/backend.py \
        vllm/v1/attention/backends/mla/sparse_swa.py \
        vllm/v1/core/sched/scheduler.py \
        vllm/v1/engine/input_processor.py \
        vllm/v1/worker/gpu/attn_utils.py \
        vllm/v1/worker/gpu/model_states/default.py \
        vllm/v1/worker/gpu/spec_decode/dspark/speculator.py \
    && python3 /opt/ds4-vision-r21/verify.py --static

LABEL org.opencontainers.image.title="DeepSeek V4 Flash Vision Infernal Invocation r21" \
      org.opencontainers.image.version="r21-vision-v1" \
      org.opencontainers.image.revision="800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469" \
      local-inference.base.digest="sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291" \
      local-inference.vllm.tree="d6cf36ae0dc30d48fd656a3c34a353ec62074922" \
      local-inference.ds4.vision.model-revision="86f746b36186f0e567729a5c06a8c918caba82a9" \
      local-inference.ds4.vision.synthetic-token-count="5" \
      local-inference.ds4.vision.image-swa="disjoint-natural-lse-merge" \
      local-inference.ds4.vision.dspark-markov-oov="sanitized" \
      local-inference.ds4.vision.prefix-cache="atomic-mm-rewind"

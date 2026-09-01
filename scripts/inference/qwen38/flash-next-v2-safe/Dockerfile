ARG SOURCE_IMAGE=peterstorm/vllm:qwen38-flash-next-v2-source-e126687
FROM ${SOURCE_IMAGE}

ARG SOURCE_DATE_EPOCH=1788208200
LABEL ai.peterstorm.inference.overlay="qwen38-flash-next-v2-safe" \
      ai.peterstorm.inference.source-commit="e126687a9a828d513c01a07cd69f025f27d63280" \
      ai.peterstorm.inference.base-source-overlay-commit="815d965f7ccddd6a2b2da072a4a492115fc3a7e1" \
      ai.peterstorm.inference.source-overlay-commit="c0ac28980016af357df50359d301648352eebbf2" \
      ai.peterstorm.inference.ple-uva="vllm-project/vllm#54371@905219234b0698b1f1ec2ed756de7051b080fb1c-adapted" \
      ai.peterstorm.inference.persistent-topk="vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3" \
      ai.peterstorm.inference.accepted-state-bounds="vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f-adapted" \
      ai.peterstorm.inference.ple-state-bounds="accepted-count-and-state-row-fail-closed" \
      ai.peterstorm.inference.large-topk-ties="deterministic-global-token-index" \
      ai.peterstorm.inference.qsa-order="ascending-compressed-block-index" \
      ai.peterstorm.inference.prefix-cache="disabled-until-equivalence-qualified"

COPY verify.py /opt/qwen38-v2/verify.py

ENV VLLM_PLE_CPU_OFFLOAD=1 \
    PYTHONHASHSEED=0

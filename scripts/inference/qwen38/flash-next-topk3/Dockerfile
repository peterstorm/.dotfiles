FROM vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3

LABEL ai.peterstorm.inference.base-image="vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3" \
      ai.peterstorm.inference.overlay="qwen38-flash-next-qsa-exact-topk3" \
      ai.peterstorm.inference.overlay-source="https://github.com/k3net/docai-evals/tree/522430ac96a4847583c3b0069757338cf27ab7ff/experiments/2026-08-28-qwen38-flash-next-nvfp4-topk-nondeterminism-gb10" \
      ai.peterstorm.inference.overlay-patch-sha256="b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4"

COPY qsa-exact-topk.patch /tmp/qsa-exact-topk.patch
RUN set -eux; \
    qsa=/usr/local/lib/python3.12/dist-packages/vllm/models/qwen3_8_flash_next/nvidia/ops/qsa.py; \
    echo "c4ffe3674cafa0ce2dabc39a39f0ddbb4b594bc358ad210ffce9d04383350c7f  $qsa" | sha256sum --check --strict; \
    echo "b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4  /tmp/qsa-exact-topk.patch" | sha256sum --check --strict; \
    patch --batch --fuzz=0 "$qsa" </tmp/qsa-exact-topk.patch; \
    echo "79d13ab4a3805bd568e3b930cd0cc193fbf5997403f9d4e809838193c14204dc  $qsa" | sha256sum --check --strict; \
    python3 -c 'from pathlib import Path; p = Path("'"$qsa"'"); compile(p.read_text(), str(p), "exec")'; \
    rm /tmp/qsa-exact-topk.patch

ENV VLLM_QSA_EXACT_TOPK=3

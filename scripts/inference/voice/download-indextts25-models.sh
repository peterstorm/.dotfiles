#!/usr/bin/env bash
# Download the exact noncommercial Development-only IndexTTS-2.5 model closure.
set -euo pipefail

IMAGE="${INDEXTTS25_IMAGE:-peterstorm/indextts25:2.5.0-39207d9-cu128}"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice/indextts}"
DESTINATION="$MODELS_ROOT/2.5-c39ce5b"
STAGING="$MODELS_ROOT/.staging-2.5-c39ce5b"
MARKER="$MODELS_ROOT/.indextts25-c39ce5b-complete"
LOCK="$MODELS_ROOT/.indextts25-c39ce5b.lock"
SOURCE_REV="39207d91c30899cad1e7c1b9eb678c241f678e55"
MODEL_REV="c39ce5ba981572cb187443877ff559dfb246ce63"

read -r -d '' MANIFEST <<'EOF' || true
cc7da9ea0f8a97ef15ab3bf0389e636ce79ffca1aef5489520796ac87d87a87b 10553 LICENSE
d21e2ed55013ce0c456b9aa6d4fab7222365bfad10dd839155da0ce36fa93001 4272 README.md
18adf417be3e8f5e2e48e30f7420c719170a6870619436250f360d626877870e 2860 config.yaml
d15cbed16a40f478438c961fb043f68dfa6353bf56c966761315db3433e9722c 607290935 codec.pth
f219cb447d80216ba615666da2ff8d63ac544eee26657f3a7b278692bf7a67c4 57170 feat1.pt
9c4292e96dee535aea9a6206e9a0c856dd578dde9212acdb16dd3ada4d12bf80 374866 feat2.pt
43a8f4c30eccdf201958d3b9713511482c19d56dc20b0b1c4ee1e6b080b19d85 3259599833 gpt.pth
747979631e813193436aabcff7c1c235d37de8097b71c563ec8b63b7a515c718 907395 multilingual_zh_ja_yue_char_del.tiktoken
9b1b0003fc189c94cc349758d7ebc25f903b7eb2de4602879959cc64ce816456 414908601 s2mel.pth
c9c176c2b8850ab2e3ba828bbfa969deaf4566ce55db5f2687b8430b87526ad2 9343 wav2vec2bert_stats.pt
f5572bd5998b68182e9c328a43127ed21fed687f6910497136b91a4e3b0e3675 1874 hf_cache/w2v-bert-2.0/config.json
eb890c9660ed6e3414b6812e27257b8ce5454365d5490d3ad581ea60b93be043 2322063736 hf_cache/w2v-bert-2.0/model.safetensors
8e6281aad64f97e40534135a59dcc5d33571efae376f2a25adf5551951897ab4 275 hf_cache/w2v-bert-2.0/preprocessor_config.json
ec947271175d8cad75ec37e83aa487e27c97a0f72a303393772da5ffa84bddf2 177183712 hf_cache/semantic_codec_model.safetensors
3388cf5fd3493c9ac9c69851d8e7a8badcfb4f3dc631020c4961371646d5ada8 28036335 hf_cache/campplus_cn_common.bin
88a1f47acf747db0b21e97a389d838566147f7a5464583ff5c8d819d870f03ee 1405 hf_cache/bigvgan/config.json
e95ba25972d3de0628d99cd156e9315a9c018899bf739988959ebe3544080ced 449228171 hf_cache/bigvgan/bigvgan_generator.pt
EOF

verify_manifest() {
  local root="$1" expected_sha expected_size relative file actual_sha actual_size
  while read -r expected_sha expected_size relative; do
    [[ -n "$relative" ]] || continue
    file="$root/$relative"
    [[ -f "$file" ]] || { echo "missing: $relative" >&2; return 1; }
    actual_size="$(stat -c %s "$file")"
    [[ "$actual_size" == "$expected_size" ]] || {
      echo "size mismatch: $relative (expected $expected_size, got $actual_size)" >&2
      return 1
    }
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "$actual_sha" == "$expected_sha" ]] || {
      echo "checksum mismatch: $relative" >&2
      return 1
    }
  done <<<"$MANIFEST"
}

write_marker() {
  local image_id="$1" marker_tmp="$MARKER.new"
  {
    printf 'IndexTeam/IndexTTS-2.5@%s\n' "$MODEL_REV"
    printf 'source=index-tts/index-tts@%s\n' "$SOURCE_REV"
    printf 'usage=noncommercial-development-only\n'
    printf 'license-accepted-by-user=2026-08-25\n'
    printf 'image-id=%s\n' "$image_id"
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv "$marker_tmp" "$MARKER"
}

main() {
  local image_id image_rev
  for dependency in docker flock sha256sum stat; do
    command -v "$dependency" >/dev/null 2>&1 || { echo "error: missing command: $dependency" >&2; return 1; }
  done
  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  image_rev="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [[ "$image_rev" == "$SOURCE_REV" ]] || { echo "error: image revision mismatch: $image_rev" >&2; return 1; }

  mkdir -p "$MODELS_ROOT"
  exec 9>"$LOCK"
  flock 9
  if [[ -f "$MARKER" ]] && grep -Fxq "IndexTeam/IndexTTS-2.5@$MODEL_REV" "$MARKER" && verify_manifest "$DESTINATION"; then
    if ! grep -Fxq "image-id=$image_id" "$MARKER"; then
      write_marker "$image_id"
    fi
    echo "INDEXTTS25_MODELS_READY: $DESTINATION"
    return 0
  fi

  mkdir -p "$STAGING"
  docker run --rm --init -i \
    --user "$(id -u):$(id -g)" \
    --entrypoint /opt/index-tts/.venv/bin/python \
    --env HOME=/tmp/home \
    --env HF_HOME=/staging/.hf-home \
    --env HF_HUB_OFFLINE=0 \
    --env TRANSFORMERS_OFFLINE=0 \
    --mount "type=bind,src=$STAGING,dst=/staging" \
    "$image_id" - <<'PY'
from pathlib import Path
import shutil
from huggingface_hub import hf_hub_download

root = Path('/staging')
requests = (
    ('IndexTeam/IndexTTS-2.5', 'c39ce5ba981572cb187443877ff559dfb246ce63', {
        'LICENSE': 'LICENSE', 'README.md': 'README.md', 'config.yaml': 'config.yaml',
        'codec.pth': 'codec.pth', 'feat1.pt': 'feat1.pt', 'feat2.pt': 'feat2.pt',
        'gpt.pth': 'gpt.pth', 'multilingual_zh_ja_yue_char_del.tiktoken': 'multilingual_zh_ja_yue_char_del.tiktoken',
        's2mel.pth': 's2mel.pth', 'wav2vec2bert_stats.pt': 'wav2vec2bert_stats.pt',
    }),
    ('facebook/w2v-bert-2.0', 'da985ba0987f70aaeb84a80f2851cfac8c697a7b', {
        'config.json': 'hf_cache/w2v-bert-2.0/config.json',
        'model.safetensors': 'hf_cache/w2v-bert-2.0/model.safetensors',
        'preprocessor_config.json': 'hf_cache/w2v-bert-2.0/preprocessor_config.json',
    }),
    ('amphion/MaskGCT', '265c6cef07625665d0c28d2faafb1415562379dc', {
        'semantic_codec/model.safetensors': 'hf_cache/semantic_codec_model.safetensors',
    }),
    ('funasr/campplus', 'e4b6ede7ce16997aff4ae69fbca1f0175e2afede', {
        'campplus_cn_common.bin': 'hf_cache/campplus_cn_common.bin',
    }),
    ('nvidia/bigvgan_v2_22khz_80band_256x', '633ff708ed5b74903e86ff1298cf4a98e921c513', {
        'config.json': 'hf_cache/bigvgan/config.json',
        'bigvgan_generator.pt': 'hf_cache/bigvgan/bigvgan_generator.pt',
    }),
)
for repo, revision, files in requests:
    cache = root / '.downloads' / repo.replace('/', '--')
    for remote, relative in files.items():
        source = Path(hf_hub_download(repo_id=repo, filename=remote, revision=revision, local_dir=cache))
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() or destination.stat().st_size != source.stat().st_size:
            shutil.copyfile(source, destination)
PY

  verify_manifest "$STAGING"
  rm -rf "$STAGING/.downloads" "$STAGING/.hf-home"
  printf '%s\n' "$MANIFEST" >"$STAGING/ARTIFACTS.sha256"
  cat >"$STAGING/model-revisions.json" <<EOF
{
  "indexTtsSource": "index-tts/index-tts@$SOURCE_REV",
  "indexTtsModel": "IndexTeam/IndexTTS-2.5@$MODEL_REV",
  "w2vBert": "facebook/w2v-bert-2.0@da985ba0987f70aaeb84a80f2851cfac8c697a7b",
  "semanticCodec": "amphion/MaskGCT@265c6cef07625665d0c28d2faafb1415562379dc",
  "campplus": "funasr/campplus@e4b6ede7ce16997aff4ae69fbca1f0175e2afede",
  "bigvgan": "nvidia/bigvgan_v2_22khz_80band_256x@633ff708ed5b74903e86ff1298cf4a98e921c513",
  "usageGate": "noncommercial-development-only",
  "acceptedByUser": "2026-08-25"
}
EOF

  rm -rf "$DESTINATION.new"
  mv "$STAGING" "$DESTINATION.new"
  chmod -R u=rwX,g=rX,o= "$DESTINATION.new"
  rm -rf "$DESTINATION"
  mv "$DESTINATION.new" "$DESTINATION"
  write_marker "$image_id"
  verify_manifest "$DESTINATION"
  echo "INDEXTTS25_MODELS_READY: $DESTINATION"
}

main "$@"

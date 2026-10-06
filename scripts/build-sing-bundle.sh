#!/usr/bin/env bash
# Build the exact pinned two-second Core ML separator used by Sing and stage it as an app resource.
# Personal CI uses this when the old public model host is unavailable. The model is rebuilt only from
# the MIT sources/checkpoint pinned by harness/sing/model.json, then every compiled payload is checked
# against SGSingModel.m before it can enter the IPA.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/out/SpotifyGlassSing.bundle}"
WORK="${RUNNER_TEMP:-/tmp}/spoti-sing-model-v1"

CONVERSION_REV="5029e6df8100650fe175d3e276fffb0177754ca1"
REFERENCE_REV="25f44ffb55ee3c301281bba21b2d6d311cb69ae2"
CHECKPOINT_REV="ac9b0614ab3cd7f77219e18ba494dfd93956c348"
CHECKPOINT_SHA="87201f4d31afb5bc79993230fc49446918425574db48c01c405e44f365c7559e"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK"

echo "==> Sing: preparing the verified open-source voice model"
python3 -m venv "$WORK/venv"
PY="$WORK/venv/bin/python"
PIP="$WORK/venv/bin/pip"
"$PIP" -q install --upgrade pip
"$PIP" -q install \
  "numpy<2.3" "torch==2.9.0" "coremltools==9.0" \
  "einops==0.6.1" "beartype==0.14.1" "rotary-embedding-torch==0.3.5" \
  librosa pyyaml

git clone -q --filter=blob:none https://github.com/john-rocky/coreai-model-zoo.git "$WORK/zoo"
git -C "$WORK/zoo" checkout -q "$CONVERSION_REV"
git clone -q --filter=blob:none https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model.git "$WORK/reference"
git -C "$WORK/reference" checkout -q "$REFERENCE_REV"

CHECKPOINT="$WORK/MelBandRoformer.ckpt"
curl -fL --retry 4 --retry-all-errors \
  "https://huggingface.co/KimberleyJSN/melbandroformer/resolve/$CHECKPOINT_REV/MelBandRoformer.ckpt" \
  -o "$CHECKPOINT"
ACTUAL="$(shasum -a 256 "$CHECKPOINT" | awk '{print $1}')"
[ "$ACTUAL" = "$CHECKPOINT_SHA" ] || { echo "Sing checkpoint hash mismatch" >&2; exit 1; }

"$PY" "$ROOT/harness/sing/fetch_goldens.py" --output "$WORK/goldens"
"$PY" "$ROOT/harness/sing/export_coreml.py" \
  "$WORK/zoo" "$WORK/reference" "$CHECKPOINT" "$WORK/goldens/golden_raw.f32" "$WORK/export" \
  --unpinned-tools

MODEL="$WORK/export/separator.mlmodelc"
[ -d "$MODEL" ] || { echo "Sing export did not produce separator.mlmodelc" >&2; exit 1; }

check_file() {
  local rel="$1" size="$2" hash="$3" path="$MODEL/$1"
  [ -f "$path" ] || { echo "Sing model missing $rel" >&2; exit 1; }
  [ "$(stat -f '%z' "$path")" = "$size" ] || { echo "Sing model size mismatch: $rel" >&2; exit 1; }
  [ "$(shasum -a 256 "$path" | awk '{print $1}')" = "$hash" ] || { echo "Sing model hash mismatch: $rel" >&2; exit 1; }
}

check_file "weights/weight.bin" 488986336 "970a99fb4b15724bf76d2918ceb177df592c69265d3e2fabaab6e5ba72738e62"
check_file "model.mil" 669061 "966560ed5125174a98f19b94f5de04450a7112ade0e731f2236c202c0280a623"
check_file "metadata.json" 2431 "52a8d5e3f09e33236d495dbed5bbce1c75bac6f2a6b6097637cf214f37c1de53"
check_file "coremldata.bin" 507 "2090acaf7a6df72ec83857cb88d101654023a6baad222a25d0173827d3347e28"
check_file "analytics/coremldata.bin" 243 "f7ee4ec9b5cc1c97171bd5aad93af61e183aa0db1451ef3b775bd4e77f0b7cfd"

mkdir -p "$OUT"
cp -cR "$MODEL" "$OUT/separator.mlmodelc"
cp "$ROOT/harness/sing/NOTICE" "$OUT/NOTICE"
cp "$ROOT/harness/sing/model.json" "$OUT/model.json"
cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>pw.spoti.sing-model</string>
  <key>CFBundleName</key><string>SpotifyGlassSing</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

echo "==> Sing: verified model staged at $OUT"
du -sh "$OUT"

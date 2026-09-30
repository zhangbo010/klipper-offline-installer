#!/usr/bin/env bash
# 在**目标平台**上收集离线依赖（wheel + sdist + 预编译 C 扩展），用于扩展新架构/发行版覆盖
#
# 用法（在目标机上）:  sudo ./tools/collect-wheels.sh
#   然后重新 ./build-package.sh（会自动把 wheels/ 打进去）
#
# 踩过的坑，别重犯：
#  1. 必须用目标机自己的 pip —— 平台 + Python 版本才会匹配
#  2. pycairo / PyGObject 在 PyPI 上没有 manylinux wheel，pip download 只能拿到 sdist；
#     目标机现场编译需要 PEP-517 构建依赖（meson-python/pyproject-metadata/meson/ninja），
#     所以本脚本 a) 预编译成 wheel（目标机直接装、免编译）b) 再把构建依赖也下载进去兜底
#  3. 预编译**必须带 requirements 里的版本约束**：不带约束会取最新版，
#     而 PyGObject>3.51 需要 girepository-2.0（Debian 12 只有 1.0）→ 直接编译失败
set -euo pipefail
cd "$(dirname "$0")/.."

PY_TAG="py$(python3 -c 'import sys;print("%d%d"%sys.version_info[:2])')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  aarch64|arm64) ARCH_TAG="aarch64" ;;
  x86_64|amd64)  ARCH_TAG="x86_64" ;;
  armv7l)        ARCH_TAG="armv7l" ;;
  *)             ARCH_TAG="$ARCH_RAW" ;;
esac
OUT="wheels/${PY_TAG}-${ARCH_TAG}"
mkdir -p "$OUT"
echo "收集目标: $OUT   (Python $PY_TAG / $ARCH_RAW)"

KLIPPY_REQ="payload/src/klipper/scripts/klippy-requirements.txt"
MOON_REQ="payload/src/moonraker/scripts/moonraker-requirements.txt"
KS_REQ="payload/src/KlipperScreen/scripts/KlipperScreen-requirements.txt"
PIP="python3 -m pip"

echo "[1/4] 基础工具与三套运行时依赖"
$PIP download -q -d "$OUT" pip setuptools wheel
$PIP download -q -d "$OUT" -r "$KLIPPY_REQ"
$PIP download -q -d "$OUT" psutil
$PIP download -q -d "$OUT" -r "$MOON_REQ"
$PIP download -q -d "$OUT" -r "$KS_REQ"

echo "[2/4] PEP-517 构建依赖（兜底，供目标机现场编译用）"
$PIP download -q -d "$OUT" meson-python pyproject-metadata meson ninja 2>/dev/null \
  || echo "  (部分构建依赖下载失败；若第 3 步已预编译好 wheel 可忽略)"

echo "[3/4] 预编译需要 C 扩展的包（带 requirements 版本约束）"
PG="$(grep -iE '^PyGObject' "$KS_REQ" | head -1 | sed 's/[[:space:]]*#.*//' | tr -d ' ' || true)"
PC="$(grep -iE '^pycairo'   "$KS_REQ" | head -1 | sed 's/[[:space:]]*#.*//' | tr -d ' ' || true)"
echo "  约束: ${PG:-PyGObject(默认)} / ${PC:-pycairo(默认)}"
# shellcheck disable=SC2086
$PIP wheel --no-deps -w "$OUT" "${PG:-PyGObject}" "${PC:-pycairo}" 2>&1 | tail -3 \
  || echo "  ⚠ 预编译失败：目标机届时需现场编译（需 libgirepository1.0-dev libcairo2-dev pkg-config python3-dev）"

echo "[4/4] 完成"
echo "  $(ls -1 "$OUT" | wc -l) 个包, $(du -sh "$OUT" | cut -f1)"
ls -1 "$OUT" | grep -iE "cairo|gobject" | sed 's/^/    /'
echo "重新 ./build-package.sh 即可把该平台依赖打进安装包"

#!/usr/bin/env bash
# ============================================================================
#  获取 Klipper 全家桶源码到 payload/src/
#  （优先国内可访问的 Gitee 镜像，失败再回退 GitHub）
#
#  用法: ./tools/fetch-sources.sh
#  说明: mainsail 是前端产物，用官方发布 zip；其余用 git clone --depth 1
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p payload/src
cd payload/src

ok=0; fail=0
try_clone() {
  local dir="$1"; shift
  if [[ -d "$dir" ]]; then echo "  ✔ $dir 已存在，跳过"; ok=$((ok+1)); return 0; fi
  for url in "$@"; do
    echo "  → 尝试 $url"
    if git clone --depth 1 "$url" "$dir" 2>/dev/null; then
      echo "  ✔ $dir 获取成功"; ok=$((ok+1)); return 0
    fi
    rm -rf "$dir"
  done
  echo "  ✘ $dir 获取失败 —— 请手动下载后放到 payload/src/$dir"
  fail=$((fail+1)); return 1
}

echo "[1/2] git 仓库"
try_clone klipper \
  https://gitee.com/miroky/klipper.git \
  https://github.com/Klipper3d/klipper.git

try_clone moonraker \
  https://gitee.com/miroky/moonraker.git \
  https://github.com/Arksine/moonraker.git

try_clone KlipperScreen \
  https://gitee.com/miroky/KlipperScreen.git \
  https://github.com/KlipperScreen/KlipperScreen.git

try_clone mainsail-config \
  https://gitee.com/Neko-vecter/mainsail-config.git \
  https://github.com/mainsail-crew/mainsail-config.git

echo "[2/2] Mainsail 前端（发布包，非 git）"
if [[ -d mainsail ]]; then
  echo "  ✔ mainsail 已存在，跳过"
else
  url="https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip"
  echo "  → 下载 $url"
  if curl -fsSL -m 300 -o mainsail.zip "$url"; then
    unzip -q mainsail.zip -d mainsail && rm -f mainsail.zip && echo "  ✔ mainsail 解压完成"
  else
    rm -f mainsail.zip
    echo "  ✘ mainsail 下载失败（GitHub 在国内可能不通）"
    echo "    可手动下载 mainsail.zip 解压到 payload/src/mainsail/"
    fail=$((fail+1))
  fi
fi

echo
echo "完成：成功 $ok 项，失败 $fail 项"
[[ $fail -eq 0 ]] && echo "接下来：./tools/collect-wheels.sh（在目标平台收集依赖）→ ./build-package.sh" \
                  || echo "补齐缺失项后再打包"

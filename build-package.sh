#!/usr/bin/env bash
# ============================================================================
#  把本仓库打包成一个可分发的离线安装包
#
#  用法:
#    ./build-package.sh [版本号]            # 默认 1.0.0
#    ./build-package.sh 1.1.0
#
#  前提:
#    payload/src/ 下有 klipper / moonraker / KlipperScreen / mainsail / mainsail-config
#      —— 没有就先跑 ./tools/fetch-sources.sh 获取
#    wheels/ 下有各平台的离线依赖（用 ./tools/collect-wheels.sh 在目标平台收集）
#      —— 没有也能打包，但目标机安装时需要联网
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
PKG="klipper-stack-$VERSION"
BUILD="build"
DIST="dist"
ROOT="$BUILD/$PKG"

say() { echo -e "\033[36m[build]\033[0m $*"; }
warn() { echo -e "\033[33m[warn ]\033[0m $*"; }

# ---------------------------------------------------------------- 前置检查
for d in klipper moonraker KlipperScreen mainsail mainsail-config; do
  if [[ ! -d "payload/src/$d" ]]; then
    warn "缺少 payload/src/$d"
    MISSING=1
  fi
done
if [[ "${MISSING:-0}" == "1" ]]; then
  echo
  echo "请先获取源码：./tools/fetch-sources.sh"
  echo "或手动把你的源码目录放到 payload/src/ 下。"
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$ROOT" "$DIST"

# ---------------------------------------------------------------- 源码
say "复制源码（排除 .git / 编译产物 / 缓存）"
mkdir -p "$ROOT/payload/src"
for d in klipper moonraker KlipperScreen mainsail mainsail-config; do
  rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='.cache' \
        --exclude='klippy/chelper/*.so' --exclude='out/' \
        \
        "payload/src/$d" "$ROOT/payload/src/"
  printf "  %-16s %s\n" "$d" "$(du -sh "$ROOT/payload/src/$d" | cut -f1)"
done

# 先做一份 MCU SDK 补充包（含完整 lib），供编译真实打印主板固件用
if [[ -d "payload/src/klipper/lib" ]]; then
  say "生成 MCU SDK 补充包（编译真实打印主板固件用）"
  SDK_NAME="$PKG-mcu-libs"
  rm -rf "$BUILD/$SDK_NAME"; mkdir -p "$BUILD/$SDK_NAME/klipper"
  rsync -a payload/src/klipper/lib "$BUILD/$SDK_NAME/klipper/"
  cat > "$BUILD/$SDK_NAME/README.txt" <<'SDKEOF'
MCU 编译 SDK 补充包
===================

用途：把各厂商 MCU 的 SDK 补回 Klipper 源码树，用于编译**真实打印主板**的固件
（STM32 / RP2040 / SAM 等）。主机端部署（含默认安装的 Linux host MCU）不需要它。

用法：
  tar xzf klipper-stack-<版本>-mcu-libs.tar.gz
  cp -a klipper-stack-<版本>-mcu-libs/klipper/lib/. ~/klipper/lib/

之后即可编译固件：
  cd ~/klipper && make menuconfig && make

SDKEOF
  tar czf "$DIST/$SDK_NAME.tar.gz" -C "$BUILD" "$SDK_NAME"
  rm -rf "$BUILD/$SDK_NAME"
  ls -lh "$DIST/$SDK_NAME.tar.gz" | awk '{print "  SDK 包:  "$9"   "$5}'
fi

# klipper/lib 里只有 kconfiglib 是构建系统需要的（Klipper 的 make 依赖它），
# 其余是各厂商 MCU 的编译 SDK（stm32*/pico-sdk/sam* 等，约 200MB），
# 主机端部署用不到 —— 删掉可让发行包从 106MB 降到 ~78MB。
if [[ -d "$ROOT/payload/src/klipper/lib" ]]; then
  find "$ROOT/payload/src/klipper/lib" -mindepth 1 -maxdepth 1 ! -name 'kconfiglib' \
       -exec rm -rf {} + 2>/dev/null || true
  printf "  %-16s %s (仅保留 kconfiglib)\n" " klipper/lib" "$(du -sh "$ROOT/payload/src/klipper/lib" | cut -f1)"
fi

# ---------------------------------------------------------------- 模板
say "复制配置与服务模板"
mkdir -p "$ROOT/payload/config" "$ROOT/payload/system"
cp payload/config/* "$ROOT/payload/config/"
cp payload/system/* "$ROOT/payload/system/"
ls -1 "$ROOT/payload/system/" | sed 's/^/  /'

# ---------------------------------------------------------------- 离线依赖
say "收集离线依赖"
mkdir -p "$ROOT/wheels"
if compgen -G "wheels/*" >/dev/null; then
  cp -a wheels/. "$ROOT/wheels/"
  for w in "$ROOT"/wheels/*/; do
    [[ -d "$w" ]] && printf "  %-18s %s 个包 %s\n" "$(basename "$w")" \
      "$(ls -1 "$w" | wc -l | tr -d ' ')" "$(du -sh "$w" | cut -f1)"
  done
else
  warn "wheels/ 为空 —— 打出来的包在目标机上需要联网安装 Python 依赖"
  warn "想要完全离线：在目标平台跑 ./tools/collect-wheels.sh 后把目录放进 wheels/"
fi

# ---------------------------------------------------------------- 安装器
say "写入安装器与文档"
cp install.sh "$ROOT/install.sh"
chmod +x "$ROOT/install.sh"
mkdir -p "$ROOT/tools"
cp tools/*.sh "$ROOT/tools/" 2>/dev/null || true
chmod +x "$ROOT/tools/"*.sh 2>/dev/null || true
[[ -d docs ]] && cp -a docs "$ROOT/" || true

cat > "$ROOT/VERSION" <<EOF
name=klipper-stack
version=$VERSION
built=$(date '+%F %T')
platforms=$(ls -1 "$ROOT/wheels" 2>/dev/null | tr '\n' ' ')
EOF

cat > "$ROOT/README.md" <<'EOF'
# Klipper 全家桶离线安装包

一个 tar 包装完 Klipper + Moonraker + Mainsail + KlipperScreen：
源码、Python 依赖都在包里，目标机不用 git clone、不用现场编译。

## 快速开始
```bash
tar xf klipper-stack-*.tar.xz
cd klipper-stack-*
sudo ./install.sh                    # 离线优先，缺包可联网兜底
```

## 常用参数
| 参数 | 说明 |
|---|---|
| `--offline` | 强制完全离线，缺任何依赖就报错退出 |
| `--skip-apt` | 跳过 apt 系统依赖（自己已装好系统库时） |
| `--no-host-mcu` | 不装 Linux host MCU（机器已接真实打印主板时用） |
| `--rebuild-envs` | 强制重建 Python 环境（默认 venv 已存在就跳过，重跑很快） |
| `--user <名字>` / `--password <密码>` | 自定义账号，默认 klipper / 1234 |
| `--uninstall` | 卸载服务与系统集成（保留用户数据） |

## 装完怎么用
- 网页：`http://<设备IP>/`
- 账号：`klipper / 1234`（**装完请尽快改密码**：`passwd klipper`）
- SSH：`ssh klipper@<设备IP>`
- 服务：klipper / moonraker / KlipperScreen / klipper-mcu / nginx（全部开机自启，`systemctl status <名>` 查看）

## 没接打印主板也能验证
默认会编译并安装 **Linux host MCU**：不需要任何打印主板，Klipper 就能真正进入
`ready` 状态，网页/触屏/API 全部可用，方便先把整套系统调通。
接上真实主板后，改 `~/printer_data/config/printer.cfg` 里的 `[mcu] serial:` 即可。

## 覆盖平台
见 `wheels/` 下的目录名，格式 `<python版本>-<架构>`，例如 `py311-aarch64`。
未覆盖的平台仍可安装，脚本会自动回落到联网 pip；
要完全离线就在那台机器上跑 `tools/collect-wheels.sh` 补齐依赖后重新打包。

## 卸载
```bash
sudo ./install.sh --uninstall
```
EOF

# ---------------------------------------------------------------- 打包
say "打包"
( cd "$BUILD" && tar czf "../$DIST/$PKG.tar.gz" "$PKG" )
( cd "$DIST" && { shasum -a 256 "$PKG.tar.gz" > "$PKG.tar.gz.sha256" 2>/dev/null \
                  || sha256sum "$PKG.tar.gz" > "$PKG.tar.gz.sha256"; } )

echo
say "完成"
ls -lh "$DIST/$PKG.tar.gz" | awk '{print "  包:      "$9"   "$5}'
echo "  sha256:  $(cut -d' ' -f1 "$DIST/$PKG.tar.gz.sha256")"
echo "  条目数:  $(tar tzf "$DIST/$PKG.tar.gz" | wc -l | tr -d ' ')"

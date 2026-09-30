#!/usr/bin/env bash
# ============================================================================
#  Klipper 全家桶离线安装器 (Klipper + Moonraker + Mainsail + KlipperScreen)
#  install.sh — 幂等、可重复运行、尽量离线
#
#  用法:
#    sudo ./install.sh                     # 标准安装（离线优先，缺包可联网兜底）
#    sudo ./install.sh --offline           # 强制离线（缺任何依赖就报错退出）
#    sudo ./install.sh --skip-apt          # 跳过 apt 依赖（自己已装好系统库）
#    sudo ./install.sh --no-host-mcu       # 不装 Linux host MCU（接了真实主板时）
#    sudo ./install.sh --rebuild-envs      # 强制重建 Python 环境（升级依赖时用；默认已存在则跳过）
#    sudo ./install.sh --no-watchdog       # 不装网络看门狗（掉线自愈）
#    sudo ./install.sh --user klipper --password 1234
#    sudo ./install.sh --uninstall         # 卸载
# ============================================================================
set -euo pipefail

VERSION="1.0.0"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SELF_DIR/payload"
WHEELS_ROOT="$SELF_DIR/wheels"
LOGFILE="/tmp/klipper-stack-install.log"

# ------------------------------ 默认参数 ------------------------------------
KS_USER="klipper"
KS_PASS="1234"
OFFLINE=0
SKIP_APT=0
WITH_HOST_MCU=1
DO_UNINSTALL=0
REBUILD_ENVS=0
WITH_WATCHDOG=1
PIP_INDEX="https://mirrors.aliyun.com/pypi/simple/"
PIP_HOST="mirrors.aliyun.com"

# ------------------------------ 输出helper ----------------------------------
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[36m'
log()  { echo -e "${c_blu}[$(date '+%H:%M:%S')]${c_reset} $*" | tee -a "$LOGFILE"; }
ok()   { echo -e "${c_grn}  ✔${c_reset} $*" | tee -a "$LOGFILE"; }
warn() { echo -e "${c_ylw}  !${c_reset} $*" | tee -a "$LOGFILE"; }
die()  { echo -e "${c_red}  ✘ $*${c_reset}" | tee -a "$LOGFILE"; exit 1; }

banner() {
cat <<'EOF'
 __ __ _ _                          _             _
|  |  | |_|___ ___ ___ ___    ___ _| |_ ___ ___ | |_
|    -| | | . | -_|  _| . |  |_ -| . |  _| .'|  _| '_|
|__|__|_|_|  _|___|_| |___|  |___|___|_| |__,|___|_,_|
          |_|     Klipper 全家桶离线安装器
EOF
echo "  version $VERSION"
}

# ------------------------------ 参数解析 ------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)      OFFLINE=1; shift ;;
    --skip-apt)     SKIP_APT=1; shift ;;
    --no-host-mcu)  WITH_HOST_MCU=0; shift ;;
    --rebuild-envs) REBUILD_ENVS=1; shift ;;
    --no-watchdog)  WITH_WATCHDOG=0; shift ;;
    --user)         KS_USER="$2"; shift 2 ;;
    --password)     KS_PASS="$2"; shift 2 ;;
    --uninstall)    DO_UNINSTALL=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "未知参数: $1 (用 --help 看用法)" ;;
  esac
done

# ------------------------------ 环境探测 ------------------------------------
detect_env() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行：sudo $0 <参数>"

  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    aarch64|arm64)        ARCH_TAG="aarch64" ;;
    x86_64|amd64)         ARCH_TAG="x86_64" ;;
    armv7l|armhf)         ARCH_TAG="armv7l" ;;
    *)                    ARCH_TAG="$ARCH_RAW" ;;
  esac

  [[ -e /run/systemd/system ]] || die "目标系统没有 systemd，本安装器不支持"
  command -v python3 >/dev/null || die "缺少 python3"

  PY_FULL="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
  PY_TAG="py${PY_FULL/./}"            # 3.11 -> py311

  if   [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-0}"; OS_NAME="${PRETTY_NAME:-$ID}"
  else OS_ID=unknown; OS_VER=0; OS_NAME="unknown"; fi

  log "目标环境：$OS_NAME (${OS_ID} ${OS_VER}) | 架构 $ARCH_RAW($ARCH_TAG) | Python $PY_FULL | systemd 就绪"
}

# ------------------------------ 选择离线 wheel 目录 --------------------------
pick_wheel_dir() {
  WHEEL_DIRS=()
  local cand="$WHEELS_ROOT/${PY_TAG}-${ARCH_TAG}"
  [[ -d "$cand" ]] && WHEEL_DIRS+=("$cand")
  cand="$WHEELS_ROOT/any-${ARCH_TAG}"
  [[ -d "$cand" ]] && WHEEL_DIRS+=("$cand")
  cand="$WHEELS_ROOT/${PY_TAG}-any"
  [[ -d "$cand" ]] && WHEEL_DIRS+=("$cand")
  cand="$WHEELS_ROOT/any-any"
  [[ -d "$cand" ]] && WHEEL_DIRS+=("$cand")

  if [[ ${#WHEEL_DIRS[@]} -gt 0 ]]; then
    log "匹配到离线依赖目录: ${WHEEL_DIRS[*]}"
    stage_wheels
  else
    warn "本包没有 ${PY_TAG}-${ARCH_TAG} 的离线依赖，将回退到联网 pip"
    FIND_LINKS_ARG=""
    [[ $OFFLINE -eq 1 ]] && die "--offline 模式下缺少 $WHEELS_ROOT/${PY_TAG}-${ARCH_TAG} 依赖目录"
  fi
}

# 关键：pip 以普通用户身份运行，而包可能解压在 /root 这类 700 权限目录下，
# 直接 --find-links 到那里会读不到（报 "from versions: none" / OSError Errno 2）。
# 所以统一把轮子暂存到普通用户可读的位置。
stage_wheels() {
  STAGE_DIR="$(mktemp -d /var/tmp/klipper-stack-wheels.XXXXXX)"
  for d in "${WHEEL_DIRS[@]}"; do
    cp -a "$d"/. "$STAGE_DIR"/ 2>/dev/null || true
  done
  find "$STAGE_DIR" -type f -exec chmod a+r {} + 2>/dev/null || true
  chmod 755 "$STAGE_DIR"
  WHEEL_DIRS=("$STAGE_DIR")
  FIND_LINKS_ARG="--find-links=$STAGE_DIR"
  log "离线依赖已暂存到 ${STAGE_DIR}（普通用户可读，共 $(ls -1 "$STAGE_DIR" | wc -l | tr -d ' ') 个包）"
}
cleanup_stage() { [[ -n "${STAGE_DIR:-}" && -d "${STAGE_DIR:-}" ]] && rm -rf "$STAGE_DIR" || true; }

# ------------------------------ apt 依赖 ------------------------------------
apt_install() {
  [[ $SKIP_APT -eq 1 ]] && { warn "按要求跳过 apt 依赖安装"; return 0; }

  local PKGS=(
    python3-venv python3-dev python3-pip python3-gi python3-gi-cairo gir1.2-gtk-3.0
    libgirepository1.0-dev libcairo2-dev libsodium-dev libopenjp2-7 libjpeg62-turbo
    nginx xinput x11-xserver-utils fonts-wqy-zenhei
    libmpv-dev librsvg2-common libdbus-glib-1-dev autoconf pkg-config
    fonts-nanum fonts-ipafont mpv git gcc make
    # 交叉编译器：编译真实打印主板固件用（STM32 / RP2040 用 arm-none-eabi；
    # AVR 老主板用 avr）。不装的话 MCU 固件编译会报 arm-none-eabi-gcc: not found
    gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi gcc-avr avr-libc
    # X 服务器与输入驱动：KlipperScreen 的 ExecStart 是 /usr/bin/xinit，
    # 必须有 xinit + xserver-xorg-core 才能起图形界面；libinput/evdev 是
    # 触摸屏能被 X 接管的必要条件 —— 缺这两个驱动时，X 只在日志里"发现"了
    # 触摸设备却不会接管它，xinput 里看不到设备，触摸完全无响应。
    xserver-xorg-core xinit xserver-xorg-input-libinput xserver-xorg-input-evdev
  )
  # 树莓派系需要 xserver-xorg-legacy 才能让非 console 用户起 X
  local EXTRA=()
  dpkg -l 2>/dev/null | grep -q "xserver-xorg-core" && EXTRA+=(xserver-xorg-legacy)

  log "安装系统依赖 (${#PKGS[@]}+ 个包，联网走国内镜像)…"
  if [[ $OFFLINE -eq 0 ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | tail -2 | sed 's/^/    /' || warn "apt update 有告警，继续"
  else
    warn "--offline: 仅使用本机已缓存的 apt 包（不联网）"
  fi
  export DEBIAN_FRONTEND=noninteractive
  # DPkg::Lock::Timeout：无人值守升级等可能占着 dpkg 锁，等它而不是直接失败
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq "${PKGS[@]}" "${EXTRA[@]}" 2>&1 | tail -3 | sed 's/^/    /' \
    || warn "部分 apt 包安装失败（可能已装或源不可用），继续"
  ok "系统依赖处理完毕"
}

# ------------------------------ 用户 ---------------------------------------
setup_user() {
  if id "$KS_USER" >/dev/null 2>&1; then
    log "用户 $KS_USER 已存在，更新密码与附加组"
  else
    log "创建用户 $KS_USER"
    useradd -m -s /bin/bash "$KS_USER"
  fi
  echo "$KS_USER:$KS_PASS" | chpasswd
  groupadd -f moonraker-admin
  for g in sudo dialout tty video render input plugdev netdev moonraker-admin; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$KS_USER" || true
  done
  ok "用户 $KS_USER 就绪（密码 ${KS_PASS}，已加入 sudo/tty/video/render/input/moonraker-admin 等组）"
}

HOME_DIR() { getent passwd "$KS_USER" | cut -d: -f6; }

# ------------------------------ 源码部署 ------------------------------------
deploy_sources() {
  local H; H="$(HOME_DIR)"
  log "部署源码到 $H/"
  mkdir -p "$H"
  for d in klipper moonraker KlipperScreen mainsail mainsail-config; do
    [[ -d "$PAYLOAD/src/$d" ]] || { warn "payload 缺少 ${d}，跳过"; continue; }
    rm -rf "${H:?}/$d.tmp"
    cp -a "$PAYLOAD/src/$d" "$H/$d.tmp"
    rm -rf "${H:?}/$d"
    mv "$H/$d.tmp" "$H/$d"
    chown -R "$KS_USER:$KS_USER" "$H/$d"
  done
  ok "源码就绪：klipper / moonraker / KlipperScreen / mainsail / mainsail-config"
}

# ------------------------------ venv ---------------------------------------
make_venv() {   # $1=venv路径  $2=requirements文件
  local VENV="$1" REQ="$2"
  # 幂等：venv 已存在就跳过（升级依赖时用 --rebuild-envs）
  if [[ $REBUILD_ENVS -eq 0 && -x "$VENV/bin/pip" ]]; then
    warn "  $VENV 已存在，跳过（要重建请加 --rebuild-envs）"
    return 0
  fi
  log "创建 venv: $VENV"
  rm -rf "$VENV"
  sudo -u "$KS_USER" python3 -m venv "$VENV" || die "venv 创建失败: $VENV"

  # 组装 pip 参数：离线优先（--no-index + 本地 find-links）
  PIP_ARGS=(-q)
  if [[ -n "${FIND_LINKS_ARG:-}" ]]; then
    for d in "${WHEEL_DIRS[@]}"; do PIP_ARGS+=(--find-links="$d"); done
    PIP_ARGS+=(--no-index)
  else
    PIP_ARGS+=(-i "$PIP_INDEX" --trusted-host "$PIP_HOST")
  fi

  run_pip() { sudo -u "$KS_USER" "$VENV/bin/pip" "$@"; }

  # 升级打包工具。注意 setuptools 必须 pin <81：
  # setuptools 81+ 移除了 pkg_resources，而 python-can 3.3.4 (Klipper 依赖) 仍在用它，
  # 装成新版会导致 klippy 启动即 ModuleNotFoundError: No module named 'pkg_resources'
  run_pip install "${PIP_ARGS[@]}" -U pip wheel "setuptools<81" >/dev/null 2>&1 \
    || warn "  pip/setuptools 升级跳过（沿用 venv 自带版本）"

  if [[ ! -f "$REQ" ]]; then
    warn "  没有 requirements 文件（${REQ}），跳过"
    return 0
  fi

  log "  安装依赖: $(basename "$REQ")"
  local rc=0
  run_pip install "${PIP_ARGS[@]}" -r "$REQ" || rc=$?

  if [[ $rc -ne 0 ]]; then
    if [[ $OFFLINE -eq 1 ]]; then
      die "离线安装依赖失败（${REQ}）—— 缺少对应 wheel/sdist，请用 tools/collect-wheels.sh 在本平台补全"
    fi
    warn "  离线依赖不完整，回退联网安装…"
    run_pip install -q -r "$REQ" -i "$PIP_INDEX" --trusted-host "$PIP_HOST" \
      || die "联网安装依赖仍失败（${REQ}）"
  fi
  ok "  $VENV 完成"
}

install_python_envs() {
  local H; H="$(HOME_DIR)"
  log "安装 Python 运行环境"

  # klippy-env
  make_venv "$H/klippy-env" "$H/klipper/scripts/klippy-requirements.txt"
  # klippy 额外需要 psutil（klipper 的 requirements 里没有它，缺了 klippy 启动即报错）
  local pa=(-q)
  if [[ -n "${FIND_LINKS_ARG:-}" ]]; then
    pa+=(--no-index "--find-links=$STAGE_DIR")
  else
    pa+=(-i "$PIP_INDEX" --trusted-host "$PIP_HOST")
  fi
  if ! sudo -u "$KS_USER" "$H/klippy-env/bin/pip" install "${pa[@]}" psutil >/dev/null 2>&1; then
    if [[ $OFFLINE -eq 1 ]]; then
      die "离线安装 psutil 失败（wheelhouse 里缺 psutil 的 wheel）"
    fi
    sudo -u "$KS_USER" "$H/klippy-env/bin/pip" install -q psutil -i "$PIP_INDEX" --trusted-host "$PIP_HOST" \
      || die "psutil 安装失败（klippy 会因缺少 psutil 起不来）"
  fi
  ok "  klippy-env + psutil"

  # moonraker-env
  make_venv "$H/moonraker-env" "$H/moonraker/scripts/moonraker-requirements.txt"

  # KlipperScreen-env（系统 python + PyGObject/pycairo 需要编译）
  make_venv "$H/.KlipperScreen-env" "$H/KlipperScreen/scripts/KlipperScreen-requirements.txt"

  # 验证导入
  sudo -u "$KS_USER" "$H/klippy-env/bin/python" -c "import cffi,serial,jinja2,greenlet,can,msgspec,psutil" \
    || die "klippy-env 依赖导入失败"
  sudo -u "$KS_USER" "$H/moonraker-env/bin/python" -c "import tornado,paho.mqtt,PIL,dbus_fast,ldap3" \
    || die "moonraker-env 依赖导入失败"
  ok "  依赖导入校验通过"
}

# ------------------------------ 配置 ---------------------------------------
deploy_config() {
  local H; H="$(HOME_DIR)"
  log "部署配置"
  mkdir -p "$H/printer_data"/{config,logs,comms,systemd,gcodes,certs,database,misc}
  chown -R "$KS_USER:$KS_USER" "$H/printer_data"

  install_cfg() {  # $1=源  $2=目标  $3=是否可覆盖
    local src="$1" dst="$2" force="${3:-0}"
    if [[ -f "$dst" && $force -eq 0 ]]; then
      warn "  已存在，保留原文件: $(basename "$dst")"
    else
      cp -f "$src" "$dst"
    fi
    chown "$KS_USER:$KS_USER" "$dst"
  }

  install_cfg "$PAYLOAD/config/printer.cfg"        "$H/printer_data/config/printer.cfg"
  install_cfg "$PAYLOAD/config/moonraker.conf"     "$H/printer_data/config/moonraker.conf" 1
  install_cfg "$PAYLOAD/config/KlipperScreen.conf" "$H/printer_data/config/KlipperScreen.conf" 1
  ln -sfn "$H/mainsail-config/mainsail.cfg" "$H/printer_data/config/mainsail.cfg"
  chown -h "$KS_USER:$KS_USER" "$H/printer_data/config/mainsail.cfg"

  cat > "$H/printer_data/systemd/klipper.env" <<EOF
KLIPPER_ARGS="$H/klipper/klippy/klippy.py $H/printer_data/config/printer.cfg -I $H/printer_data/comms/klippy.serial -l $H/printer_data/logs/klippy.log -a $H/printer_data/comms/klippy.sock"
EOF
  cat > "$H/printer_data/systemd/moonraker.env" <<EOF
MOONRAKER_ARGS="$H/moonraker/moonraker/moonraker.py -d $H/printer_data"
EOF
  chown "$KS_USER:$KS_USER" "$H/printer_data/systemd/"*.env
  ok "配置就绪（printer.cfg 已存在时不覆盖）"
}

# ------------------------------ 服务 ---------------------------------------
install_services() {
  local H; H="$(HOME_DIR)"
  log "安装 systemd 服务 / nginx / polkit"

  sed -e "s#/home/klipper#$H#g" -e "s#User=klipper#User=$KS_USER#g" \
      -e "s#Group=klipper#Group=$KS_USER#g" \
      "$PAYLOAD/system/klipper.service"       > /etc/systemd/system/klipper.service
  sed -e "s#/home/klipper#$H#g" -e "s#User=klipper#User=$KS_USER#g" \
      "$PAYLOAD/system/moonraker.service"     > /etc/systemd/system/moonraker.service
  sed -e "s#/home/klipper#$H#g" \
      "$PAYLOAD/system/klipper-mcu.service"   > /etc/systemd/system/klipper-mcu.service
  sed -e "s#/home/klipper#$H#g" -e "s#User=klipper#User=$KS_USER#g" \
      "$PAYLOAD/system/KlipperScreen.service" > /etc/systemd/system/KlipperScreen.service
  systemctl daemon-reload

  # polkit（让网页/触屏能重启服务与关机）
  mkdir -p /etc/polkit-1/rules.d
  sed "s#\"klipper\"#\"$KS_USER\"#g" "$PAYLOAD/system/99-moonraker.rules" \
      > /etc/polkit-1/rules.d/99-moonraker.rules

  # nginx + Mainsail
  if command -v nginx >/dev/null; then
    sed -e "s#/home/klipper#$H#g" "$PAYLOAD/system/mainsail.nginx" > /etc/nginx/sites-available/mainsail
    cp -f "$PAYLOAD/system/upstreams.conf" "$PAYLOAD/system/common_vars.conf" /etc/nginx/conf.d/
    rm -f /etc/nginx/sites-enabled/default
    ln -sfn /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
    nginx -t >/dev/null 2>&1 && systemctl enable nginx >/dev/null 2>&1 && systemctl restart nginx || warn "nginx 配置有问题，请检查"
    ok "nginx + Mainsail 网页已配置"
  else
    warn "未装 nginx，跳过网页（可 apt install nginx 后重跑本脚本）"
  fi

  # KlipperScreen 的 X 授权（Debian 默认只允许 console 用户起 X）
  if [[ -d /etc/X11 ]]; then
    printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
    ok "Xwrapper.config 已修正（允许服务用户起 X）"
  fi
  ok "服务单元就绪"
}

# ------------------------------ 网络看门狗 ----------------------------------
install_watchdog() {
  [[ $WITH_WATCHDOG -eq 1 ]] || { warn "按要求跳过网络看门狗"; return 0; }
  if ! command -v nmcli >/dev/null 2>&1; then
    warn "系统没有 NetworkManager(nmcli)，跳过网络看门狗"
    return 0
  fi
  log "安装网络看门狗（掉线自愈：每 2 分钟探测，断了自动重连）"
  install -m 755 "$PAYLOAD/system/net-watchdog.sh" /usr/local/bin/net-watchdog.sh
  install -m 644 "$PAYLOAD/system/net-watchdog.service" \
                "$PAYLOAD/system/net-watchdog.timer" /etc/systemd/system/
  systemctl daemon-reload
  if systemctl enable --now net-watchdog.timer >/dev/null 2>&1; then
    ok "  看门狗已启用（日志 /var/log/net-watchdog.log）"
  else
    warn "  看门狗启用失败（可手动 systemctl enable --now net-watchdog.timer）"
  fi
}

# ------------------------------ Linux host MCU ------------------------------
build_host_mcu() {
  [[ $WITH_HOST_MCU -eq 1 ]] || { warn "按要求跳过 Linux host MCU"; return 0; }
  local H; H="$(HOME_DIR)"
  log "编译 Linux host MCU（让无主板的机器也能进 ready）"
  cd "$H/klipper"
  printf 'CONFIG_LOW_LEVEL_OPTIONS=y\nCONFIG_MACH_LINUX=y\n' > .config
  chown "$KS_USER:$KS_USER" .config
  if sudo -u "$KS_USER" bash -c "cd '$H/klipper' && (make olddefconfig >/dev/null 2>&1 || true) && make -j$(nproc)" >>"$LOGFILE" 2>&1; then
    install -m 755 "$H/klipper/out/klipper.elf" /usr/local/bin/klipper_mcu
    ok "  klipper_mcu 已安装（/usr/local/bin/klipper_mcu）"
  else
    warn "  Linux MCU 编译失败（跳过；接了真实主板时不需要它）"
    warn "  常见原因：包内精简掉了 klipper/lib，或缺少 gcc。"
    warn "  补全源码：./tools/fetch-sources.sh 后重新打包，或在设备上 git clone klipper"
    WITH_HOST_MCU=0
  fi
  cd - >/dev/null
}

# ------------------------------ 启动 ---------------------------------------
start_services() {
  log "启动服务"
  if [[ $WITH_HOST_MCU -eq 1 ]]; then
    systemctl enable klipper-mcu >/dev/null 2>&1 || true
    systemctl restart klipper-mcu || warn "klipper-mcu 启动失败"
    sleep 2
  fi
  for s in klipper moonraker; do
    systemctl enable "$s" >/dev/null 2>&1 || true
    systemctl restart "$s" || warn "$s 启动失败"
  done
  sleep 10
  systemctl enable KlipperScreen >/dev/null 2>&1 || true
  systemctl restart KlipperScreen || warn "KlipperScreen 启动失败"
  sleep 5
}

# ------------------------------ 自检 ---------------------------------------
selftest() {
  local H; H="$(HOME_DIR)"
  log "自检"
  local fail=0
  echo "  ── 服务状态 ──"
  for s in klipper-mcu klipper moonraker KlipperScreen nginx net-watchdog.timer; do
    local st; st="$(systemctl is-active "$s" 2>/dev/null || true)"
    if [[ "$st" == "active" ]]; then printf "  %-16s ${c_grn}%s${c_reset}\n" "$s" "$st"
    else printf "  %-16s ${c_ylw}%s${c_reset}\n" "$s" "${st:-n/a}"; [[ "$s" != "nginx" ]] && fail=1; fi
  done

  echo "  ── Klipper API ──"
  local info="" state="?" k
  for _ in $(seq 1 12); do                     # 等最多 60 秒：moonraker 起来后还要连上 klippy
    info="$(curl -s -m 5 http://127.0.0.1:7125/printer/info 2>/dev/null || true)"
    if echo "$info" | grep -q '"state"'; then
      state="$(echo "$info" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["state"])' 2>/dev/null || echo '?')"
      [[ "$state" == "ready" ]] && break
    fi
    sleep 5
  done
  if [[ "$state" == "ready" ]]; then
    ok "Klipper state=ready"
  elif echo "$info" | grep -q '"state"'; then
    warn "Klipper state=$state （接了真实主板但未上电/未连上时属正常）"
  else
    warn "Moonraker API 无响应"; fail=1
  fi

  echo "  ── Mainsail 网页 ──"
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1/ 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && ok "http://<本机IP>/ -> 200" || { warn "网页返回 $code"; fail=1; }

  echo "  ── KlipperScreen ──"
  if pgrep -f "KlipperScreen/screen.py" >/dev/null; then ok "screen.py 运行中（HDMI 已显示界面）"
  else warn "screen.py 未运行（无显示器/无触摸屏时可忽略）"; fi

  echo
  if [[ $fail -eq 0 ]]; then
    echo -e "${c_grn}  ✅ 安装完成，全部检查通过${c_reset}"
    # 用默认路由出口的地址，避免多网卡时 hostname -I 报错网段
    local IP; IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
    [[ -z "$IP" ]] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "     网页:  http://${IP:-<本机IP>}/"
    echo "     账号:  $KS_USER / $KS_PASS"
  else
    echo -e "${c_ylw}  ⚠ 安装完成，但上面有未通过项 —— 日志: $LOGFILE${c_reset}"
  fi
}

# ------------------------------ 卸载 ---------------------------------------
do_uninstall() {
  log "卸载 Klipper 全家桶"
  for s in KlipperScreen moonraker klipper klipper-mcu net-watchdog.timer; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload
  rm -f /etc/polkit-1/rules.d/99-moonraker.rules
  rm -f /etc/nginx/sites-enabled/mainsail /etc/nginx/sites-available/mainsail
  rm -f /usr/local/bin/klipper_mcu /usr/local/bin/net-watchdog.sh
  local H; H="$(HOME_DIR 2>/dev/null || echo /home/$KS_USER)"
  warn "用户数据保留在 ${H}（源码/配置/日志），需要清空请手动 rm -rf $H"
  ok "服务与系统集成已卸载"
  exit 0
}

# ============================== 主流程 =====================================
banner
: > "$LOGFILE"
trap cleanup_stage EXIT
detect_env
[[ $DO_UNINSTALL -eq 1 ]] && do_uninstall

pick_wheel_dir
apt_install
setup_user
deploy_sources
install_python_envs
deploy_config
install_services
install_watchdog
build_host_mcu
start_services
selftest

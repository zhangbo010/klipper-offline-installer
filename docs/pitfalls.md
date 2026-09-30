# 踩过的坑

这些都是**实际部署中真踩到并解决**的问题，按现象查即可。

---

## 1. 离线装依赖报 `Could not find a version that satisfies the requirement meson-python>=0.16.0`

**现象**：把 `pip download` 下来的 wheel 目录丢给目标机装，pycairo / PyGObject 装不上。

**原因**：这两个包在 PyPI 上**没有 manylinux wheel**，`pip download` 只能拿到
源码包（`.tar.gz`）。目标机安装时要现场编译，而 pip 会为编译**另建一个隔离环境**
去装 PEP-517 构建依赖（`meson-python`、`pyproject-metadata`、`meson`、`ninja`）——
这些不会跟主依赖一起被 `pip download` 带下来，于是离线环境下直接失败。

**解法**（两层都要做）：

```bash
# 主：在目标平台预编译成 wheel，目标机就完全不需要构建链
pip wheel --no-deps -w "$OUT" "PyGObject<3.51" "pycairo>=1.27.0"

# 副：把构建依赖也下载进 wheelhouse 兜底
pip download -d "$OUT" meson-python pyproject-metadata meson ninja
```

`tools/collect-wheels.sh` 已经内置了这两步。

---

## 2. `ModuleNotFoundError: No module named 'pkg_resources'`（klippy 起不来）

**原因**：Klipper 依赖的 `python-can 3.3.4` 仍在用 `from pkg_resources import ...`，
而 **setuptools 81 起移除了 `pkg_resources`**。安装时若把 setuptools 升到最新，就会踩中。

**解法**：安装器里显式钉版本，不要盲目升到最新：

```bash
pip install -U pip wheel "setuptools<81"
```

（实测 setuptools **80.10.2 仍包含 pkg_resources**；81+ 才移除。）

---

## 3. 预编译 PyGObject 报 `Dependency 'girepository-2.0' is required but not found`

**原因**：`pip wheel pygobject` 不带版本约束时会取**最新版**，
而 PyGObject > 3.51 需要 `girepository-2.0`（Debian 12 / bookworm 只有 1.0）。

**解法**：预编译时**必须带上 requirements 里的版本约束**：

```bash
pip wheel --no-deps -w "$OUT" "PyGObject<3.51"
```

`tools/collect-wheels.sh` 会从 `KlipperScreen-requirements.txt` 里自动抽约束。

---

## 4. `pip` 报 `from versions: none` / `OSError: [Errno 2] No such file or directory`

**现象**：wheelhouse 里明明有包，pip 却说"找不到任何版本"，还报一个莫名其妙的
"文件不存在"。

**原因**：pip 是以普通用户（如 `klipper`）身份运行的，而安装包可能解压在
`/root/` 这类 **700 权限**的目录下 —— 普通用户根本读不到那个目录，
pip 于是把它当成"空目录"。

**解法**：安装前把 wheel 目录**暂存到普通用户可读的位置**并放权：

```bash
STAGE="$(mktemp -d /var/tmp/klipper-stack-wheels.XXXXXX)"
cp -a "$WHEELS_DIR"/. "$STAGE"/
find "$STAGE" -type f -exec chmod a+r {} +
```

`install.sh` 已内置（`stage_wheels()`），装完自动清理。

---

## 5. KlipperScreen 起不来：`Only console users are allowed to run the X server`

**原因**：Debian 的 `Xorg.wrap` 默认只允许**控制台登录用户**启动 X 服务，
而 KlipperScreen 是由 systemd 以普通用户身份启动的。

**解法**：改 `/etc/X11/Xwrapper.config`：

```
allowed_users=anybody
needs_root_rights=yes
```

⚠️ **注意**：某些发行版/镜像里这个文件内容有问题是**一整行**（换行被写成了字面量
`\n`），那样配置根本不生效（`wc -l` 会是 0）。用 printf 重新写两行：

```bash
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
```

---

## 6. 自定义宏导致 Klipper 停机：`gcode command XXX already registered`

**原因**：`printer.cfg` 里定义的 `[gcode_macro]` 名字**与 Klipper 内建命令重名**。

**注意**：`STATUS`、`RESTART`、`PARK`、`M115` 等都是内建/常用名，别用。
起个带前缀的名字，例如 `MACHINE_STATUS`。

---

## 7. apt 阶段失败：`Could not get lock /var/lib/dpkg/lock-frontend`

**原因**：系统后台的无人值守升级（unattended-upgrades）正占着 dpkg 锁。

**解法**：让 apt 自己等锁，而不是直接失败：

```bash
apt-get -o DPkg::Lock::Timeout=180 install -y <packages>
```

安装器已内置；并且单个包失败不会中断整个流程。

---

## 8. SSH 上跑后台任务"卡住不动"

**现象**：`ssh host 'setsid nohup ./install.sh &'` 之后命令一直不返回，
看起来像超时/卡死（但实际上任务在远端正常跑着）。

**原因**：SSH 会话会等它启动的后台进程释放 stdout/stderr，即使重定向过也可能不返回。

**解法**：把长任务交给 systemd 托管，SSH 立即返回：

```bash
systemd-run --unit=myinstall --collect --no-block \
  --property=StandardOutput=file:/tmp/install.log \
  --property=StandardError=append:/tmp/install.log \
  /root/install.sh --offline
```

⚠️ 别加 `--property=Type=oneshot` —— 那样 systemd-run 会同步等待，又变成"卡住"。

**另**：`sshpass` 在目标机高负载时可能**偶发**密码验证失败（远端 `auth.log` 里能看到
连带两次 failed password，但密码本身没问题）。自动化脚本里给 SSH 命令包一层重试
（3~5 次 + 间隔几秒）即可。

---

## 9. 重测时"修复没生效"

**现象**：改了包再重测，现象一模一样，像修复无效。

**原因**：测试脚本里只跑了 `cd /root/klipper-stack-* && ./install.sh`，
用的是**上一次解压的旧目录**（旧 wheelhouse、旧 install.sh）。

**解法**：测试脚本里固定写"先删旧目录再解压新包"，并打印包内关键文件版本做交叉校验：

```bash
rm -rf /root/klipper-stack-1.0.0
tar xzf /root/klipper-stack-1.0.0.tar.gz
ls klipper-stack-1.0.0/wheels/py311-aarch64 | grep -i '^setuptools'   # 确认版本对
```

---

## 附：想把系统库（apt）也完全离线化

包里默认不含 `.deb`（体积翻几倍，且跨发行版容易依赖冲突）。需要彻底断网时：

```bash
# 在目标发行版+架构的机器上（需一次联网）
apt-get install -y --download-only <install.sh 里那串包名>
# 收集
mkdir -p debs && cp /var/cache/apt/archives/*.deb debs/
```

然后在安装流程里改成从本地装：

```bash
dpkg -i debs/*.deb || apt-get -f install -y     # 补齐依赖关系
```

包名清单见 `install.sh` 的 `apt_install()` 函数（`PKGS` 数组）。
建议按 `debs/<发行版>-<架构>/` 分目录存放，安装器按 `ID-VERSION_ID-架构` 选目录。

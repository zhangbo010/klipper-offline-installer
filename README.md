# Klipper 全家桶离线安装包

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

把 **Klipper + Moonraker + Mainsail + KlipperScreen** 打成一个 tar 包，
在目标机器上几条命令装完 —— **不用 git clone、不用现场编译、可以完全断网安装**。

适合这些场景：

- 批量部署一批 Klipper 主机（ARM 盒子 / 工控机 / 树莓派），不想每台都联网拉代码
- 现场或内网没有外网，或 GitHub / PyPI 访问不稳定
- 想给不同架构（arm64 / x86_64）、不同发行版（Debian / Ubuntu）用同一套安装方式

> 一句话原理：**通用部分（源码/前端/配置/服务模板）跨平台共用，
> 平台相关部分（Python 依赖）按 `Python版本-架构` 分目录携带。**
> 依赖里需要编译的（pycairo / PyGObject）在收集阶段就预编译成 wheel，
> 所以目标机拿到的是"解开即用"的依赖，不需要编译器、不需要 PEP-517 构建链。

---

## 快速开始

### 方式 A：直接用发行包（推荐）

从 [Releases](../../releases) 下载 `klipper-stack-<版本>.tar.xz`：

```bash
tar xf klipper-stack-*.tar.xz
cd klipper-stack-*
sudo ./install.sh              # 离线优先，缺包时自动回落到国内镜像
```

装完打开浏览器访问 `http://<设备IP>/`，账号 `klipper / 1234`。

### 方式 B：自己构建（需要先准备源码与依赖）

```bash
./tools/fetch-sources.sh       # ① 拉源码到 payload/src/（优先 Gitee 镜像）
./tools/collect-wheels.sh      # ② 在**目标平台**上收集离线依赖到 wheels/
./build-package.sh 1.0.3       # ③ 打包 → dist/klipper-stack-1.0.3.tar.xz
```

第 ② 步必须在**与目标机相同架构 + 相同 Python 版本**的机器上执行，
它会把 pip 能拿到的 wheel 全部下下来，并把 pycairo / PyGObject 预编译成 wheel。

---

## 安装器参数

| 参数 | 说明 |
|---|---|
| `--offline` | 强制完全离线；缺任何依赖直接报错退出（用于验证包的自包含性） |
| `--skip-apt` | 跳过 apt 系统依赖安装（自己已装好系统库时） |
| `--no-host-mcu` | 不装 Linux host MCU（目标机已接真实打印主板时用） |
| `--rebuild-envs` | 强制重建 Python 环境；默认 venv 已存在就跳过（重跑很快） |
| `--user <名字>` / `--password <密码>` | 自定义账号，默认 `klipper / 1234` |
| `--uninstall` | 卸载服务与系统集成（保留用户数据） |

安装器是**幂等**的：重复运行不会破坏已有的 `printer.cfg`，
已存在的 Python 环境默认跳过，所以升级源码或改配置后重跑很快。

---

## 装出来的东西

| 组件 | 位置 / 服务 | 说明 |
|---|---|---|
| Klipper | `klipper.service` | 主力固件（host 端） |
| Moonraker | `moonraker.service` (:7125) | API 服务 |
| Mainsail | `nginx` (:80) | 网页界面 |
| KlipperScreen | `KlipperScreen.service` | HDMI 触屏界面（自动带 X 授权修复） |
| klipper-mcu | `klipper-mcu.service` | **Linux host MCU**，没接打印主板也能进 ready |
| 网络看门狗 | `net-watchdog.timer` | 掉线自动重连，适合无人值守 |

全部开机自启。装完可用 `systemctl status klipper` 等检查。

**没接打印主板也能验证整套系统**：Linux host MCU 让 Klipper 真正进入 `ready`，
网页、触屏、G-code 通道、虚拟打印全都能跑通。
后续接真实主板时，只改 `~/printer_data/config/printer.cfg` 里的 `[mcu] serial:`。

---

## 平台覆盖与扩展

已自带离线依赖的平台，见 `wheels/` 目录名（`<python>-<架构>`）：

| 目录 | 适用 |
|---|---|
| `py311-aarch64` | Debian 12 / Ubuntu 22.04+ 的 ARM64 板子（全志 H618、RK 系列、树莓派等） |
| `py311-x86_64` | 同类发行版的 x86_64 机器 |

没覆盖的组合（Python 3.9 / 3.10 / 3.12、armv7 等）**照样能装** ——
安装器会自动回落到联网 pip。要让它也完全离线：

```bash
# 在那台机器上（需要一次联网）
./tools/collect-wheels.sh
# 然后把生成的 wheels/<python>-<架构>/ 拷回来，重新 ./build-package.sh
```

---

## 常见问题 / 踩过的坑

整理在 [`docs/pitfalls.md`](docs/pitfalls.md)，包括：

- 离线装 Python 依赖时报 `meson-python not found`（PEP-517 构建依赖不会跟着 `pip download` 下来）
- `ModuleNotFoundError: No module named 'pkg_resources'`（setuptools ≥ 81 移除了它，而 python-can 还在用）
- 预编译 PyGObject 报 `girepository-2.0 is required`（版本约束没带上的后果）
- `pip` 报 `from versions: none`（wheelhouse 放在 `/root` 下，普通用户读不到）
- KlipperScreen 报 `Only console users are allowed to run the X server`
- **触摸屏完全无响应**：Xorg 日志里有 `config/udev: Adding input device <触摸设备>`，
  但 `xinput list` 里看不到它 → 缺 `xserver-xorg-input-libinput` /
  `xserver-xorg-input-evdev`，X 无法接管触摸设备。内核侧其实是好的
  （`/dev/input/event*` 存在），所以这种症状很容易误判成"开发板不兼容这块屏"。
  安装器已包含这两个驱动包

系统库（apt 那些包，含 X 服务器 + 触摸屏输入驱动 + MCU 交叉编译器）**没有**打进包里
—— 体积翻几倍且跨发行版容易冲突；
安装器会自动用 apt 装（国内源几秒）。需要彻底断网环境时按 `docs/pitfalls.md`
最后一节把 `.deb` 也离线化。

---

## MCU 固件编译（功能完整）

包内**含完整的 `klipper/lib/`**（STM32 / RP2040 / SAM 等全部厂商 SDK），
所以装完就能编译**真实打印主板**的固件，不需要再补任何东西：

```bash
cd ~/klipper
make menuconfig          # 选你的主板芯片（STM32F446 / STM32H723 / RP2040 …）
make                     # 产出 out/klipper.bin
```

安装器同时会装交叉编译器（`gcc-arm-none-eabi`、`gcc-avr` 等），
否则会报 `arm-none-eabi-gcc: No such file or directory`。

> **实机验证**（全志 H618 / arm64 Debian 12，四种架构全部一次通过）：
>
> | 目标 | 产物 | 大小 |
> |---|---|---|
> | STM32F446（Fly-D8 类） | `klipper.bin` | 44.5 KB |
> | STM32H723 | `klipper.bin` | — |
> | RP2040 | `klipper.uf2` | 87 KB |
> | AVR ATmega2560（老 Melzi 板） | `klipper.elf.hex` | — |
>
> 注意**产物后缀随架构不同**：STM32 出 `.bin`，RP2040 出 `.uf2`，AVR 出 `.elf.hex` ——
> 写自动化脚本时别一律找 `klipper.bin`。
>
> 另外 RP2040 的 kconfig 选项名在不同 Klipper 版本里有差别：这一版架构选项是
> `MACH_RPXXXX`（同时覆盖 RP2040 / RP235x），芯片再选 `MACH_RP2040`。
> 用 `make menuconfig` 点选最省事，手写 `.config` 时留意。

**为什么是 `.tar.xz` 而不是 `.tar.gz`**：带完整 SDK 的包用 gzip 压出来约 106MB，
超过 Gitee 100MB 的附件上限；换成 xz 后是 83MB，体积小、功能完整。
解压用 `tar xf klipper-stack-*.tar.xz` 即可（现代 tar 会自动识别 xz）。

## 许可

本仓库的脚本与模板：MIT，见 [LICENSE](LICENSE)。

包内会包含第三方项目（Klipper / Moonraker / KlipperScreen / Mainsail），
它们各自遵循自己的许可证，请以其上游仓库为准。

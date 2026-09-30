# 平台覆盖与扩展

## 怎么判断目标机属于哪一档

```bash
# 架构
uname -m                       # aarch64 / x86_64 / armv7l
# Python 版本
python3 -c 'import sys;print("%d%d"%sys.version_info[:2])'   # 311 / 39 / 310 / 312
# 发行版
. /etc/os-release && echo "$ID $VERSION_ID"   # debian 12 / ubuntu 22.04
```

对应到 `wheels/` 下的目录名 `<python>-<架构>`，例如 `py311-aarch64`。

## 常见组合对照

| 系统 | Python | 架构 | wheels 目录名 |
|---|---|---|---|
| Debian 12 / Ubuntu 22.04+ | 3.11 | arm64（全志 H618、RK35xx、树莓派 4/5） | `py311-aarch64` |
| Debian 12 / Ubuntu 22.04+ | 3.11 | x86_64 | `py311-x86_64` |
| Debian 11 / Ubuntu 20.04 | 3.9 | arm64 / x86_64 | `py39-aarch64` / `py39-x86_64` |
| Ubuntu 22.04 | 3.10 | 同上 | `py310-*` |
| Ubuntu 24.04 | 3.12 | 同上 | `py312-*` |
| 32 位 ARM | 3.9+ | armv7l | `py3xx-armv7l` |

**没命中也能装** —— 安装器会自动回落到联网 pip（国内镜像），只是失去了"完全离线"这一点。

## 为新平台收集离线依赖

在**与目标机同架构、同 Python 版本**的机器上（实体机、虚拟机、Docker 容器都行）：

```bash
# 把仓库拷/挂载进去，然后
./tools/collect-wheels.sh
```

它会做三件事：

1. `pip download` 三套运行时依赖（Klipper / Moonraker / KlipperScreen）+ `psutil`
2. 把 PEP-517 构建依赖（meson-python / pyproject-metadata / meson / ninja）也下下来兜底
3. 按 requirements 里的版本约束**预编译** pycairo 与 PyGObject 成 wheel

> 第 3 步是关键：这两个包在 PyPI 上没有 manylinux wheel，不预编译的话目标机
> 必须现场编译，需要额外装 `libgirepository1.0-dev libcairo2-dev pkg-config`，
> 而且在 ARM 板子上要跑好几分钟。预编译后目标机 40 秒左右就装完。

编译它们需要的系统依赖（收集机上装一次）：

```bash
sudo apt install -y gcc python3-dev pkg-config \
     libcairo2-dev libgirepository1.0-dev libmpv-dev
```

把生成的 `wheels/<python>-<架构>/` 目录拷回本仓库的 `wheels/` 下，重新 `./build-package.sh` 即可。

## 用 Docker 收集（没有对应实体机时）

```bash
# 例：为 Debian 11 / arm64 收集（在 arm64 主机上原生跑，无需 qemu）
docker run --rm -v "$PWD":/repo -w /repo debian:11 bash -c '
  apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-venv \
      gcc python3-dev pkg-config libcairo2-dev libgirepository1.0-dev
  ./tools/collect-wheels.sh'
```

换 `debian:11` / `ubuntu:24.04` 等镜像即可得到对应发行版与 Python 版本的依赖。
（跨架构需要 qemu 的 binfmt，速度会慢很多，能上真机就上真机。）

## 在包里增加平台时注意

- 目录名必须是 `<python><主次版本>-<架构>`，安装器按这个规则匹配
- 纯 Python 的包（`*-py3-none-any.whl`）所有平台通用，可以放在 `wheels/any-any/`
  让所有平台共用，减小体积
- 带 C 扩展的 wheel（文件名里带 `cp3xx` 和 `manylinux*<架构>`）只能给对应平台用

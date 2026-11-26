# HFT 系统环境一键初始化（`00_hft_system`）

本仓库是一套两层、确定性、fail-closed 的操作系统与用户空间初始化脚本集，**目标主机为 Ubuntu 24.04 LTS**（同时支持 **AWS EC2** 与 **物理机 / 裸金属**），**不以 macOS 为目标主机**。

唯一的例外是仓库根目录的 [`remote_bootstrap.sh`](#script-remote-bootstrap)：它运行在运维人员的 **macOS / Linux 控制终端**上（兼容 macOS 自带 `/bin/bash 3.2` 与 bash 5.x），通过 **一次 SSH 认证** 把第一层流式下发到远端 Ubuntu 24.04 目标机执行，再以 `hft` 账号独立复核免密登录与免密 `sudo`。

> 本公开仓仅包含通用 Ubuntu 低延迟基础设施，**不包含任何私有仓库地址、IP、凭据或业务策略**。文中 `<host>`、`<40位commit>`、`<密钥路径>` 均为占位符，请替换为你自己的值。

<a id="toc"></a>

## 目录

- [设计原则](#design)
- [目录结构](#layout)
- [标准初始化流程](#workflow)
  - [第 0 步：控制终端准备与离线自检](#step-0)
  - [第 1 步 A：物理机 —— Mac 终端单次 SSH 密码](#step-1-baremetal)
  - [第 1 步 B：AWS EC2 —— Key Pair 零密码](#step-1-ec2)
  - [第 2 步：重启](#step-2)
  - [第 3 步：重启后实态门禁（`--live` + `--require-exchange-time`）](#step-3)
  - [第 4 步：第二层（`hft`，严格零 `sudo`）](#step-4)
  - [第 5 步：衔接下游私有仓库（第三层）](#step-5)
  - [备选：登录目标机本地执行第一层](#step-manual)
- [离线测试与语法检查](#tests)
- [逐脚本详解（29 个 `.sh`）](#scripts)

### 表 1：核心流程命令速查

| # | Shell 命令 | 执行位置 | 做什么 | 详解 |
|---|---|---|---|---|
| 1 | `/bin/bash test/test_remote_bootstrap.sh` | 控制终端 | 离线自检 `remote_bootstrap.sh`（RA1–RA5，零真实 SSH / `sudo`） | [查看详解](#cmd-selftest) |
| 2 | `./remote_bootstrap.sh --dry-run --ref <40位commit> root@<host>` | 控制终端 | 只做全部本地安全校验并打印执行摘要，**零 SSH 调用** | [查看详解](#cmd-dry-run) |
| 3 | `./remote_bootstrap.sh --ref <40位commit> root@<host>` | 控制终端 | 物理机：只输一次 SSH 密码完成第一层 staged + `hft` 独立复核 | [查看详解](#cmd-baremetal) |
| 4 | `./remote_bootstrap.sh -i <EC2密钥.pem> --ref <40位commit> ubuntu@<host>` | 控制终端 | EC2：Key Pair 零密码完成第一层 staged + `hft` 独立复核 | [查看详解](#cmd-ec2) |
| 5 | `ssh -i <hft私钥> hft@<host> 'sudo -n reboot'` | 控制终端 | 以 `hft` 免密重启，使 GRUB 核隔离等开机参数生效 | [查看详解](#cmd-reboot) |
| 6 | `git clone <本仓公开地址> ~/Proj/00_hft_system && git checkout --detach <40位commit>` | 目标机（`hft`） | 以 `hft` 重新克隆**同一已批准 commit** | [查看详解](#cmd-hft-clone) |
| 7 | `./00_sudo_script/verify_all.sh --live` | 目标机（`hft`） | 重启后第一层实态验收（纯只读、零写入） | [查看详解](#cmd-verify-live) |
| 8 | `./00_sudo_script/verify_07_chrony_time_sync.sh --require-exchange-time` | 目标机（`hft`） | 真机必跑：与交易所时间偏差须在 ±100ms 内 | [查看详解](#cmd-exchange-time) |
| 9 | `./01_startup/run_all.sh` | 目标机（`hft`） | 第二层：工作目录、Git/SSH 基础、静态 TLS 库（严格零 `sudo`） | [查看详解](#cmd-layer2) |
| 10 | `./01_startup/verify_all.sh` | 目标机（`hft`） | 第二层纯只读总验收（含第一层 `--live` 门禁） | [查看详解](#cmd-layer2-verify) |
| 11 | `./00_sudo_script/run_all.sh` | 目标机（初始账号） | 备选：登录目标机本地执行第一层 01–07 | [查看详解](#cmd-manual-layer1) |
| 12 | `./00_sudo_script/03_grub_cpu_isolation.sh --dry-run` | 目标机 | 无写入预览物理核拓扑与 GRUB 配置差异 | [查看详解](#cmd-grub-dry-run) |
| 13 | `./01_startup/03_build_tls_libs.sh openssl` | 目标机（`hft`） | 单独构建某一套静态 TLS 库 | [查看详解](#cmd-tls-single) |
| 14 | `bash test/test_bootstrap_suite.sh` | Linux（bash ≥ 4.3） | 全量离线沙箱测试（公共库、第一层、第二层、回滚） | [查看详解](#cmd-offline-tests) |

### 表 2：全仓 29 个脚本文件可点击目录

| 脚本路径 | 运行位置 | 做什么 |
|---|---|---|
| [`remote_bootstrap.sh`](#script-remote-bootstrap) | 控制终端（macOS / Linux） | 单次 SSH 认证远程执行第一层 + `hft` 裸密钥独立复核 + 可选重启 |
| [`lib/common.sh`](#script-lib-common) | 目标机（被 source） | 公共基础库：平台 / EC2 识别、root/sudo 封装、全链门禁、事务回滚 |
| [`00_sudo_script/01_user_and_sudo.sh`](#script-l1-01-user-and-sudo) | 目标机（特权） | 创建 `hft`、免密 `sudo`、单一来源 SSH 公钥、linger、开机签章服务 |
| [`00_sudo_script/02_base_packages_and_tz.sh`](#script-l1-02-base-packages-and-tz) | 目标机（特权） | `Asia/Hong_Kong` 时区、编译链 / liburing / DPDK 基础包、cron |
| [`00_sudo_script/03_grub_cpu_isolation.sh`](#script-l1-03-grub-cpu-isolation) | 目标机（特权） | 物理核粒度 GRUB CPU 隔离（POSIX sh drop-in，三态回滚） |
| [`00_sudo_script/04_irq_nic_and_perf.sh`](#script-l1-04-irq-nic-and-perf) | 目标机（特权） | 屏蔽 irqbalance、网卡中断聚合、IRQ 归核 0、cpufreq performance |
| [`00_sudo_script/05_memory_net_and_limits.sh`](#script-l1-05-memory-net-and-limits) | 目标机（特权） | 静态大页、`/dev/shm` THP、低延迟 sysctl、`hft` 专属 limits |
| [`00_sudo_script/06_disable_bg_noise.sh`](#script-l1-06-disable-bg-noise) | 目标机（特权） | 屏蔽 apt 自动更新 / 重启定时任务、限制 journald 磁盘占用 |
| [`00_sudo_script/07_chrony_time_sync.sh`](#script-l1-07-chrony-time-sync) | 目标机（特权） | 候选预检式安装配置 chrony（EC2 / 物理机两种时间源模式） |
| [`00_sudo_script/run_all.sh`](#script-l1-run-all) | 目标机（特权） | 第一层编排器：按序执行 01–07 并做 staged 验收 |
| [`00_sudo_script/verify_01_user_and_sudo.sh`](#script-l1-verify-01-user-and-sudo) | 目标机（只读） | 纯只读校验第一层第 01 步 |
| [`00_sudo_script/verify_02_base_packages_and_tz.sh`](#script-l1-verify-02-base-packages-and-tz) | 目标机（只读） | 纯只读校验第一层第 02 步 |
| [`00_sudo_script/verify_03_grub_cpu_isolation.sh`](#script-l1-verify-03-grub-cpu-isolation) | 目标机（只读） | 纯只读校验第一层第 03 步（`--staged` / `--live`） |
| [`00_sudo_script/verify_04_irq_nic_and_perf.sh`](#script-l1-verify-04-irq-nic-and-perf) | 目标机（只读） | 纯只读校验第一层第 04 步 |
| [`00_sudo_script/verify_05_memory_net_and_limits.sh`](#script-l1-verify-05-memory-net-and-limits) | 目标机（只读） | 纯只读校验第一层第 05 步 |
| [`00_sudo_script/verify_06_disable_bg_noise.sh`](#script-l1-verify-06-disable-bg-noise) | 目标机（只读） | 纯只读校验第一层第 06 步 |
| [`00_sudo_script/verify_07_chrony_time_sync.sh`](#script-l1-verify-07-chrony-time-sync) | 目标机（只读） | 纯只读校验第一层第 07 步（可选交易所时间偏差门禁） |
| [`00_sudo_script/verify_all.sh`](#script-l1-verify-all) | 目标机（只读） | 第一层纯只读总验收（01–07，`--staged` / `--live`） |
| [`01_startup/01_user_workspace.sh`](#script-l2-01-user-workspace) | 目标机（`hft`，零 `sudo`） | 创建 `~/Proj`、`~/etc`、`~/log` 等工作目录骨架 |
| [`01_startup/02_git_ssh_base.sh`](#script-l2-02-git-ssh-base) | 目标机（`hft`，零 `sudo`） | 通用 Git 默认值、`~/.ssh/config.d`、GitHub 官方主机公钥 |
| [`01_startup/03_build_tls_libs.sh`](#script-l2-03-build-tls-libs) | 目标机（`hft`，零 `sudo`） | SHA-256 校验后静态编译 WolfSSL / OpenSSL / LibreSSL |
| [`01_startup/run_all.sh`](#script-l2-run-all) | 目标机（`hft`，零 `sudo`） | 第二层编排器：按序执行 01–03 |
| [`01_startup/verify_01_user_workspace.sh`](#script-l2-verify-01-user-workspace) | 目标机（只读） | 纯只读校验第二层第 01 步 |
| [`01_startup/verify_02_git_ssh_base.sh`](#script-l2-verify-02-git-ssh-base) | 目标机（只读） | 纯只读校验第二层第 02 步 |
| [`01_startup/verify_03_build_tls_libs.sh`](#script-l2-verify-03-build-tls-libs) | 目标机（只读） | 纯只读校验第二层第 03 步 |
| [`01_startup/verify_all.sh`](#script-l2-verify-all) | 目标机（只读） | 第二层纯只读总验收（含第一层 `--live` 门禁） |
| [`test/test_remote_bootstrap.sh`](#script-test-remote-bootstrap) | 控制终端（bash 3.2 / 5.x） | `remote_bootstrap.sh` 离线测试套件 RA1–RA5 |
| [`test/test_bootstrap_suite.sh`](#script-test-bootstrap-suite) | Linux（bash ≥ 4.3） | 全量离线沙箱测试（common、第一层、第二层、回滚） |
| [`test/test_grub_optimise.sh`](#script-test-grub-optimise) | Linux（bash ≥ 4.3） | GRUB 拓扑、POSIX drop-in、grubenv 与回滚离线测试 |

<a id="design"></a>

## 设计原则

- **两位数字定序 + 配对纯只读验证闭环**：每个执行脚本 `NN_*.sh` 均配对一个 **100% 纯只读** 的 `verify_NN_*.sh`；当前步骤开头先跑完 `01..(N-1)` 全部前序校验，末尾再自验本步，任何异常立即 fail-closed 退出。
- **权限分层与最少 `sudo`**：
  - **第一层（`00_sudo_script/`）**：系统特权准备（可从无 `sudo` 的 `root` 裸机或已有免密 `sudo` 的账号起步），安装开机持久化服务并配好 `hft` 免密 `sudo`；以「重启一次 + `--live` 实态验证」作为进入第二层的硬门禁。
  - **第二层（`01_startup/`）**：由 `hft` 执行，强制 **严格零 `sudo`**（`HFT_NO_SUDO=1`），绝不以 `root` 运行。
- **事务记录与逆序回滚**：第一层变更脚本在修改系统前，将原文件、时区、systemd 单元状态、sysctl / coalesce / IRQ / governor 原值及新装包清单记录到 `/var/lib/hft-bootstrap/txn_log/`，异常时自动逆序回滚。
- **来源钉死**：`remote_bootstrap.sh` 要求目标机检出的代码等于一个 **已批准的 40 位 commit**，拒绝任何漂移。

[返回目录](#toc)

<a id="layout"></a>

## 目录结构

```text
00_hft_system/
├── remote_bootstrap.sh                    # 控制终端（macOS/Linux）：单次 SSH 远程执行第一层 + hft 独立复核
├── lib/
│   └── common.sh                          # 公共基础库
├── 00_sudo_script/                        # 第一层：系统特权准备（重启一次全部生效）
│   ├── 01_user_and_sudo.sh  … 07_chrony_time_sync.sh
│   ├── verify_01_user_and_sudo.sh  … verify_07_chrony_time_sync.sh
│   ├── run_all.sh
│   └── verify_all.sh
├── 01_startup/                            # 第二层：hft 用户基础设施（严格零 sudo）
│   ├── 01_user_workspace.sh  … 03_build_tls_libs.sh
│   ├── verify_01_user_workspace.sh  … verify_03_build_tls_libs.sh
│   ├── run_all.sh
│   └── verify_all.sh
└── test/
    ├── test_remote_bootstrap.sh           # remote_bootstrap.sh 离线测试（RA1–RA5，兼容 bash 3.2）
    ├── test_bootstrap_suite.sh            # 全量离线沙箱测试
    └── test_grub_optimise.sh              # GRUB 专项离线沙箱测试
```

[返回目录](#toc)

<a id="workflow"></a>

## 标准初始化流程

总体顺序（两种主机类型完全一致，只有第 1 步的认证方式不同）：

1. **第 1 步**：控制终端执行 `remote_bootstrap.sh`，一次认证完成 **第一层 staged**，随后以 `hft` 裸密钥 **独立复核**（`sudo -n true && id -un` 必须恰好输出 `hft`）；**两者都成功才停下**。
2. **第 2 步**：重启目标机。
3. **第 3 步**：以 `hft` 登录，克隆同一 commit，执行 `verify_all.sh --live` 与 `verify_07_chrony_time_sync.sh --require-exchange-time`。
4. **第 4 步**：以 `hft` 执行第二层，**全程零 `sudo`**。

目标机要求：**Ubuntu 24.04 LTS**；至少 **2 颗物理 CPU 核**（物理核 P0 留给 OS 与中断，默认从 P1 起最多隔离 3 颗物理核及其全部 HT 兄弟核）；至少 **4 GiB 内存**（`512×2MB` = 1 GiB 静态大页池）。

<a id="step-0"></a>

### 第 0 步：控制终端准备与离线自检

<a id="cmd-selftest"></a>

在 macOS / Linux 控制终端克隆本仓，先跑离线自检（不会连接任何真实主机）：

```bash
/bin/bash -n remote_bootstrap.sh
/bin/bash test/test_remote_bootstrap.sh
```

选定一个已审阅的 **40 位 commit** 作为本次部署的批准版本（下文记为 `<40位commit>`）。也可以用分支 / 标签 `--ref`，但必须同时给出 `--expected-commit <40位commit>` 或 `--approved-commits-file <文件>`（文件内容形如 `00_hft_system=<40位commit>`）；`--allow-unpinned-ref` 仅作应急使用。

<a id="cmd-dry-run"></a>

正式执行前可先预演——完成全部本地参数、密钥、commit 校验并打印摘要，**不发起任何 SSH 连接**：

```bash
./remote_bootstrap.sh --dry-run --ref <40位commit> root@<host>
```

[返回目录](#toc)

<a id="step-1-baremetal"></a>

### 第 1 步 A：物理机 —— Mac 终端单次 SSH 密码

<a id="cmd-baremetal"></a>

适用于刚装好 Ubuntu 24.04、只能用密码登录 `root`（或已有**免密** `sudo` 的初始账号）的物理机：

```bash
./remote_bootstrap.sh --ref <40位commit> root@<host>
```

- 不传 `-i` 时，OpenSSH 会在 `/dev/tty` 上 **只提示一次** 密码；密码永不经过脚本、永不落盘，脚本也不使用 `sshpass`、不复用 ControlMaster、不转发 agent。
- 首次连接时 `StrictHostKeyChecking` 默认为 `ask`：**先**把显示的主机指纹与机房控制台 / 装机记录比对，确认后再输入 `yes`，然后输入密码。
- `hft` 的登录公钥默认取控制终端 `~/.ssh/id_ed25519.pub`（对应私钥 `~/.ssh/id_ed25519`）；也可用 `--pubkey <x>.pub`（自动以 `<x>` 作为复核私钥）或 `--hft-identity <私钥>` 显式指定。复核私钥必须 **无口令**（BatchMode）。
- 第 1 步（Step 1）：单次 `ssh … 'sh -s'` 流式下发 POSIX sh 载荷 → 校验 Ubuntu 24.04、权限（`root` 或 `sudo -n true`）→ 必要时安装 `git` / `ca-certificates` → 克隆并检出已批准 commit → 执行 `00_sudo_script/run_all.sh --ssh-key-source <下发的公钥>`（第一层 staged）。
- 第 2 步（Step 2）：**独立的** `hft` 非交互连接，强制 `IdentitiesOnly=yes`、`IdentityAgent=none`、`CertificateFile=none`、禁用密码 / 键盘交互，只允许裸公钥算法；`sudo -n true && id -un` 输出必须恰好是 `hft`。
- 任一步失败立即停止，**不会重启**；此时原初始账号仍可登录，可从容排障。

[返回目录](#toc)

<a id="step-1-ec2"></a>

### 第 1 步 B：AWS EC2 —— Key Pair 零密码

<a id="cmd-ec2"></a>

适用于用 EC2 Key Pair 启动、默认账号 `ubuntu`（自带免密 `sudo`）的实例：

```bash
./remote_bootstrap.sh -i ~/.ssh/<EC2密钥>.pem --ref <40位commit> ubuntu@<host>
```

- 传 `-i` 后 Step 1 使用 `BatchMode=yes`，**全程零密码**。
- 只传 `-i` 时，`hft` 复核私钥默认就是同一把密钥，公钥由 `ssh-keygen -y` 本地推导后下发；也可另用 `--hft-identity` / `--pubkey` 为 `hft` 指定独立密钥。
- 传 `-i` 时 `StrictHostKeyChecking` 默认为 `yes`：请先把从 EC2 控制台（系统日志 / 实例连接）核对过的主机公钥写入 known_hosts，或用 `--known-hosts-file <文件>` 指定；确有需要可显式 `--strict-host-key-checking accept-new`（需 OpenSSH ≥ 7.6）。`no` 永远被拒绝。
- 之后与物理机完全相同：第一层 staged → `hft` 独立复核 → 停下。

第一层透传参数（两种模式通用）：`--max-phys-cores <N>`、`--enable-idle-poll`（虚拟化 EC2 默认关闭）、`--no-managed-irq`；非 22 端口用 `-p <port>`。

[返回目录](#toc)

<a id="step-2"></a>

### 第 2 步：重启

<a id="cmd-reboot"></a>

Step 1、Step 2 均成功后，以 `hft` 免密重启，使 GRUB 核隔离、`/dev/hugepages` 挂载参数、`user@<uid>` 资源上限及开机服务全部生效：

```bash
ssh -i <hft私钥> hft@<host> 'sudo -n reboot'
```

也可在第 1 步命令中追加 `--reboot`，脚本只会在两步都成功后才以 `hft` 执行 `sudo -n reboot`（连接被重启中断导致的 ssh 退出码 255 视为正常）。

[返回目录](#toc)

<a id="step-3"></a>

### 第 3 步：重启后实态门禁（`--live` + `--require-exchange-time`）

<a id="cmd-hft-clone"></a>

以 **`hft`** 登录，克隆 **同一已批准 commit**（远端 Step 1 使用的是临时目录，结束后已清理）：

```bash
git clone https://github.com/ziwei-yang/00_hft_system.git ~/Proj/00_hft_system
cd ~/Proj/00_hft_system && git checkout --detach <40位commit>
```

<a id="cmd-verify-live"></a>

第一层重启后实态验收（纯只读，零写入）：

```bash
./00_sudo_script/verify_all.sh --live
```

<a id="cmd-exchange-time"></a>

真机验收必跑：核验与 Binance / OKX 交易所时间偏差在 `[-100ms, +100ms]` 内：

```bash
./00_sudo_script/verify_07_chrony_time_sync.sh --require-exchange-time
```

[返回目录](#toc)

<a id="step-4"></a>

### 第 4 步：第二层（`hft`，严格零 `sudo`）

<a id="cmd-layer2"></a>

以 **`hft`** 执行（禁止以 `root` 运行，脚本内部强制 `HFT_NO_SUDO=1`）：

```bash
./01_startup/run_all.sh
```

依次完成：工作目录骨架 → 通用 Git / SSH 基础配置 → 静态 TLS 库构建。

<a id="cmd-layer2-verify"></a>

随时可复跑纯只读总验收：

```bash
./01_startup/verify_all.sh
```

<a id="cmd-tls-single"></a>

也可单独构建并校验某一套加密库（`wolfssl` / `openssl` / `libressl`）：

```bash
./01_startup/03_build_tls_libs.sh openssl
./01_startup/verify_03_build_tls_libs.sh openssl
```

[返回目录](#toc)

<a id="step-5"></a>

### 第 5 步：衔接下游私有仓库（第三层）

`01_startup/verify_all.sh` 全部通过即表示通用基础设施就绪。随后按私有部署文档：

1. 在目标机以 `hft` 为每个下游私有仓库生成独立的只读 Deploy Key（权限 `0600`），仅把公钥登记为对应仓库的只读 Deploy Key，并在 `~/.ssh/config.d/` 配置独立 Host 别名（`IdentitiesOnly yes`）；
2. 将私有仓库克隆到 `~/Proj/`，执行私有侧第三层初始化；
3. 将来原地升配（例如 2 核升 4 核）后，重新运行 `03_grub_cpu_isolation.sh`、重启并复跑 `verify_all.sh --live` 即可刷新核隔离。

[返回目录](#toc)

<a id="step-manual"></a>

### 备选：登录目标机本地执行第一层

<a id="cmd-manual-layer1"></a>

无法使用控制终端时，可登录目标机（`root` 或具备 `sudo` 的初始账号）直接执行；最小镜像若缺 `git` 先 `apt-get install -y git ca-certificates`：

```bash
git clone https://github.com/ziwei-yang/00_hft_system.git ~/00_hft_system
cd ~/00_hft_system && git checkout --detach <40位commit>
./00_sudo_script/run_all.sh --ssh-key-source <user|公钥文件>
```

完成后务必 **另开终端** 实测 `ssh hft@<host> 'sudo -n true'`，再按第 2–4 步继续。

<a id="cmd-grub-dry-run"></a>

无写入预览本机物理核拓扑与 GRUB 配置差异：

```bash
./00_sudo_script/03_grub_cpu_isolation.sh --dry-run
```

[返回目录](#toc)

<a id="tests"></a>

## 离线测试与语法检查

<a id="cmd-offline-tests"></a>

全部测试都在隔离的 `/tmp/test_*` 沙箱内执行，绝不触碰宿主真实路径、真实主机或真实 `sudo`：

```bash
# 控制终端（macOS /bin/bash 3.2 或 bash 5.x）
/bin/bash -n remote_bootstrap.sh && /bin/bash -n test/test_remote_bootstrap.sh
/bin/bash test/test_remote_bootstrap.sh

# Linux（GNU bash >= 4.3；在 bash 3.2 下会自动 SKIP）
for f in lib/*.sh 00_sudo_script/*.sh 01_startup/*.sh test/*.sh; do bash -n "$f" || exit 1; done
bash test/test_grub_optimise.sh
bash test/test_bootstrap_suite.sh                 # 或 --only common|layer1|layer2
```

[返回目录](#toc)

<a id="scripts"></a>

## 逐脚本详解（29 个 `.sh`）

<a id="script-remote-bootstrap"></a>

### `remote_bootstrap.sh`

- **运行位置**：macOS / Linux 控制终端（bash 3.2.57 / 5.x），**不在**目标机上执行。
- **作用**：对远端 Ubuntu 24.04 目标机完成「一次认证 → 第一层 staged → `hft` 独立复核 → 可选重启」。
- **本地安全门（任何 SSH 之前）**：校验 `<user@host>`（主机名 / IPv4 / 方括号 IPv6）、端口、`--repo-url` 白名单（仅 `https://`、`ssh://`、`git@`）、ref 与已批准 commit 一致性、公钥格式与私钥匹配、拒绝 `StrictHostKeyChecking=no`。
- **SSH 隔离**：所有连接使用 `-F /dev/null`、`ControlMaster=no`、`ForwardAgent=no`、`ClearAllForwardings=yes`，从不复制本地私钥。
- **远端载荷**：参数经 base64 嵌入后在远端二次校验；在 `mktemp` 私有目录克隆、按 commit 检出、静态核对 `run_all.sh` 接口后执行；失败时保留退出码并清理临时目录。
- **常用参数**：`-i`、`--hft-identity`、`--pubkey`、`-p`、`--known-hosts-file`、`--strict-host-key-checking`、`--ref`、`--expected-commit`、`--approved-commits-file`、`--max-phys-cores`、`--enable-idle-poll`、`--no-managed-irq`、`--dry-run`、`--reboot`。

[返回目录](#toc)

<a id="script-lib-common"></a>

### `lib/common.sh`

- 被所有第一层 / 第二层脚本 `source` 的公共库，要求 GNU bash ≥ 4.3。
- 提供：可注入路径（`HFT_ROOT` 等，供离线沙箱测试）、平台与 EC2 识别、`root` / `sudo` 统一封装与 `HFT_NO_SUDO` 零 `sudo` 强制、前序 verifier 全链门禁、事务日志与逆序回滚。

[返回目录](#toc)

<a id="script-l1-01-user-and-sudo"></a>

### `00_sudo_script/01_user_and_sudo.sh`

- 在改动前先确定 **唯一** 最高优先级的 SSH 公钥来源（`--ssh-key-source <user|file>`；缺省按非 root `SUDO_USER` > `ubuntu` > `root`，过滤云镜像拒登前缀），若 `hft` 已存在则先核对指纹，不一致即 fail-closed。
- 必要时安装 `sudo`；创建 / 校准 `hft` 账号、写入 `authorized_keys`、经 `visudo` 校验后安装 `/etc/sudoers.d/90-hft-nopasswd`、开启 linger、创建 `/etc/hft`，并安装开机特权签章脚本与 systemd 服务。

[返回目录](#toc)

<a id="script-l1-02-base-packages-and-tz"></a>

### `00_sudo_script/02_base_packages_and_tz.sh`

- 先跑前序只读校验链；设置时区 `Asia/Hong_Kong`；幂等安装编译链、liburing、DPDK 等基础包；启用 cron。新装包名记入事务日志以便回滚。

[返回目录](#toc)

<a id="script-l1-03-grub-cpu-isolation"></a>

### `00_sudo_script/03_grub_cpu_isolation.sh`

- 按 **物理核** 粒度（自动识别 HT 兄弟核）生成纯 POSIX sh 的 `/etc/default/grub.d/99-hft-isolation.cfg`，兼容 EC2 云镜像；默认 `isolcpus=domain,managed_irq,<list>`，P0 保留。
- 参数：`--dry-run`、`--max-phys-cores <N>`（默认 3）、`--enable-idle-poll`、`--no-managed-irq`；支持三态回滚与下次启动项校验。

[返回目录](#toc)

<a id="script-l1-04-irq-nic-and-perf"></a>

### `00_sudo_script/04_irq_nic_and_perf.sh`

- 停用并屏蔽 irqbalance；安装网卡中断聚合（coalescing）调优服务、IRQ 归核 0 服务（严格检查 `IRQD_AFFINITY_MANAGED`）与 cpufreq `performance` 调速服务，均开机持久化。

[返回目录](#toc)

<a id="script-l1-05-memory-net-and-limits"></a>

### `00_sudo_script/05_memory_net_and_limits.sh`

- 预留 ≥ 512 × 2MB 静态大页（只增不减）、`/dev/hugepages` 挂载 drop-in 与权限服务、`/dev/shm` THP `huge=within_size`、低延迟 sysctl，以及仅作用于 `hft` 的资源上限。

[返回目录](#toc)

<a id="script-l1-06-disable-bg-noise"></a>

### `00_sudo_script/06_disable_bg_noise.sh`

- 停用 / 屏蔽 apt 自动更新与自动重启类定时任务，限制 systemd-journald 磁盘占用，降低后台抖动。

[返回目录](#toc)

<a id="script-l1-07-chrony-time-sync"></a>

### `00_sudo_script/07_chrony_time_sync.sh`

- **候选优先**：在安装 chrony 或停用 systemd-timesyncd 之前，先校验渲染后的配置与上游时间源。
- EC2 模式：独占使用 Amazon Time Sync Service；物理机模式：Cloudflare anycast + NIST stratum-1（非闰秒平滑 UTC）。
- 失败时对软件包、配置与服务完整事务回滚。

[返回目录](#toc)

<a id="script-l1-run-all"></a>

### `00_sudo_script/run_all.sh`

- 第一层编排器：按序执行 01–07，结束时做 staged 验收。
- 透传参数：`--ssh-key-source`、`--max-phys-cores`、`--enable-idle-poll`、`--no-managed-irq`。`remote_bootstrap.sh` 远端调用的就是它。

[返回目录](#toc)

<a id="script-l1-verify-01-user-and-sudo"></a>

### `00_sudo_script/verify_01_user_and_sudo.sh`

- 纯只读校验 `hft` 账号、免密 `sudo`、SSH 公钥与开机签章；支持 `--staged` / `--live`。

[返回目录](#toc)

<a id="script-l1-verify-02-base-packages-and-tz"></a>

### `00_sudo_script/verify_02_base_packages_and_tz.sh`

- 纯只读校验时区、基础包、libdpdk、liburing 与 cron。

[返回目录](#toc)

<a id="script-l1-verify-03-grub-cpu-isolation"></a>

### `00_sudo_script/verify_03_grub_cpu_isolation.sh`

- `--staged`：`grub-script-check` + 下次启动项检查；`--live`：重启门禁 + `/proc/cmdline` + sysfs `isolated` 实态核对。

[返回目录](#toc)

<a id="script-l1-verify-04-irq-nic-and-perf"></a>

### `00_sudo_script/verify_04_irq_nic_and_perf.sh`

- 纯只读校验 irqbalance 屏蔽、网卡调优、IRQ 归核与 cpufreq；支持 `--staged` / `--live`。

[返回目录](#toc)

<a id="script-l1-verify-05-memory-net-and-limits"></a>

### `00_sudo_script/verify_05_memory_net_and_limits.sh`

- 纯只读校验大页、`/dev/shm` THP、sysctl 与 `hft` limits；支持 `--staged` / `--live`。

[返回目录](#toc)

<a id="script-l1-verify-06-disable-bg-noise"></a>

### `00_sudo_script/verify_06_disable_bg_noise.sh`

- 纯只读校验 apt 后台任务已屏蔽、journald 已限额。

[返回目录](#toc)

<a id="script-l1-verify-07-chrony-time-sync"></a>

### `00_sudo_script/verify_07_chrony_time_sync.sh`

- 纯只读校验 chrony 配置与时间源法定数；`--require-exchange-time` 额外要求与交易所时间偏差在 ±100ms 内（真机验收必跑）。

[返回目录](#toc)

<a id="script-l1-verify-all"></a>

### `00_sudo_script/verify_all.sh`

- 第一层纯只读总验收（01–07），永不写文件、永不调用 `sudo`；参数 `--staged` / `--live` / `--require-exchange-time`。

[返回目录](#toc)

<a id="script-l2-01-user-workspace"></a>

### `01_startup/01_user_workspace.sh`

- 先过第一层 `--live` 门禁；创建 `~/Proj`、`~/etc`、`~/log`、`~/.config/hft`（`0700`）、`~/.config/systemd/user`、`~/.ssh`（`0700`）。严格零 `sudo`、非 root。

[返回目录](#toc)

<a id="script-l2-02-git-ssh-base"></a>

### `01_startup/02_git_ssh_base.sh`

- 配置通用 Git 默认值、`~/.ssh/config` 引入 `~/.ssh/config.d/*.conf`，写入 GitHub 官方 ED25519 / RSA 主机公钥。严格零 `sudo`。

[返回目录](#toc)

<a id="script-l2-03-build-tls-libs"></a>

### `01_startup/03_build_tls_libs.sh`

- 以 `-O3 -march=native -mtune=native -pipe` 静态编译 WolfSSL 5.8.4、OpenSSL 3.6.0、LibreSSL 4.2.1 至 `~/Proj/{wolfssl,openssl,libressl}/install`。
- 官方 SHA-256 校验、按库 flock 加锁、`mktemp` 隔离暂存、断言零 `*.so*`、C++ 静态链接探针、manifest 跟踪、原子软链切换；同版本构建指纹自动跳过。可传单个库名只构建一套。

[返回目录](#toc)

<a id="script-l2-run-all"></a>

### `01_startup/run_all.sh`

- 第二层编排器：以非 root 的 `hft` 按序执行 01–03，严格零 `sudo`。

[返回目录](#toc)

<a id="script-l2-verify-01-user-workspace"></a>

### `01_startup/verify_01_user_workspace.sh`

- 纯只读校验工作目录存在性与权限。

[返回目录](#toc)

<a id="script-l2-verify-02-git-ssh-base"></a>

### `01_startup/verify_02_git_ssh_base.sh`

- 纯只读校验 Git 默认值、`~/.ssh/config.d` 引入与 GitHub known_hosts。

[返回目录](#toc)

<a id="script-l2-verify-03-build-tls-libs"></a>

### `01_startup/verify_03_build_tls_libs.sh`

- 纯只读校验静态 TLS 库安装、版本与无动态库污染；可传单个库名。

[返回目录](#toc)

<a id="script-l2-verify-all"></a>

### `01_startup/verify_all.sh`

- 第二层纯只读总验收，并先执行第一层 `--live` 门禁。严格零 `sudo`、非 root。

[返回目录](#toc)

<a id="script-test-remote-bootstrap"></a>

### `test/test_remote_bootstrap.sh`

- `remote_bootstrap.sh` 的离线测试，兼容 macOS `/bin/bash 3.2.57` 与 bash 5.x；使用 mock `ssh`、真实 `/bin/sh -s` 与本地裸 git 仓库，永不连接真实主机、永不调用真实 `sudo` / `apt-get`。
- RA1 本地 fail-closed 安全门；RA2 `--dry-run` 零 SSH；RA3 Step 1 流式协议与 ref 解析矩阵；RA4 EC2 Key Pair 模式与 `hft` 裸密钥独立复核（含 agent / 证书绕过防护、重启门禁）；RA5 本 README 目录锚点完整性。

[返回目录](#toc)

<a id="script-test-bootstrap-suite"></a>

### `test/test_bootstrap_suite.sh`

- 全量离线沙箱测试（公共库、第一层 C1–C7、第二层 C8、事务回滚 C10），`--only common|layer1|layer2` 可分组运行；需 bash ≥ 4.3，否则 SKIP。

[返回目录](#toc)

<a id="script-test-grub-optimise"></a>

### `test/test_grub_optimise.sh`

- `03_grub_cpu_isolation.sh` 与 `verify_03_grub_cpu_isolation.sh` 的专项离线测试：GRUB 拓扑、POSIX drop-in、grubenv、三态回滚与重启门禁；需 bash ≥ 4.3，否则 SKIP。

[返回目录](#toc)

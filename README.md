# HFT 系统环境一键初始化（`00_hft_system`）

面向低延迟 HFT Linux 主机（**Ubuntu 24.04 LTS**，同时支持 AWS EC2 与物理机，不适配 macOS）的两层、确定性、fail-closed 操作系统与用户空间初始化脚本集。

## 设计原则

- **两位数字定序 + 配对纯只读验证闭环**：所有阶段目录与脚本按两位数字编号标明执行顺序；每个执行脚本 `NN_*.sh` 均配对一个 **100% 纯只读** 验证脚本 `verify_NN_*.sh`——当前步骤开头先跑完 `01..(N-1)` 全部前序校验，末尾再自验本步；任何异常立即 fail-closed 退出。
- **权限分层与最少 `sudo`**：
  - **第一层（`00_sudo_script/`）**：系统特权准备（支持从无 `sudo` 的 `root` 裸机或已有 `sudo` 的账号起步），安装开机持久化服务并配好 `hft` 账号免密 `sudo`，以「重启一次 + `--live` 实态验证」作为进入第二层的硬门禁。
  - **第二层（`01_startup/`）**：由 `hft` 用户执行，强制 **严格零 `sudo`**（`HFT_NO_SUDO=1`），绝不以 `root` 运行。
- **事务记录与逆序回滚**：第一层变更脚本在修改系统前将原文件、时区、systemd 单元状态、sysctl/coalesce/IRQ/governor 原值与新装包名清单记录在 `/var/lib/hft-bootstrap/txn_log/`，支持异常自动回滚。
- **公开与私有解耦**：本公开仓仅包含通用 Ubuntu 低延迟基础设施，**不包含任何私有仓库地址、IP、凭据或业务策略**。

## 目录结构

```text
00_hft_system/
├── lib/
│   └── common.sh                          # 公共基础库（平台/EC2 识别、root/sudo、全链门禁、事务回滚）
├── 00_sudo_script/                        # 第一层：系统特权准备（重启一次全部生效）
│   ├── 01_user_and_sudo.sh                # hft 账号、免密 sudo、单一来源 SSH 公钥、linger、开机签章服务
│   ├── verify_01_user_and_sudo.sh
│   ├── 02_base_packages_and_tz.sh         # Asia/Hong_Kong 时区、编译链/liburing/DPDK 基础包、cron
│   ├── verify_02_base_packages_and_tz.sh
│   ├── 03_grub_cpu_isolation.sh           # 物理核粒度隔离（POSIX sh grub.d drop-in，兼容 EC2 云镜像）
│   ├── verify_03_grub_cpu_isolation.sh
│   ├── 04_irq_nic_and_perf.sh             # 屏蔽 irqbalance、网卡中断聚合、IRQ 归核 0、cpufreq performance
│   ├── verify_04_irq_nic_and_perf.sh
│   ├── 05_memory_net_and_limits.sh        # 512x2MB 静态大页、/dev/shm THP、低延迟 sysctl、hft 专属 limits
│   ├── verify_05_memory_net_and_limits.sh
│   ├── 06_disable_bg_noise.sh             # 屏蔽 apt 自动更新/重启定时任务、限制 journald 磁盘占用
│   ├── verify_06_disable_bg_noise.sh
│   ├── 07_chrony_time_sync.sh             # 候选预检 chrony（EC2 169.254.169.123 / 物理机 Cloudflare+NIST）
│   ├── verify_07_chrony_time_sync.sh
│   ├── run_all.sh
│   └── verify_all.sh
├── 01_startup/                            # 第二层：hft 用户基础设施准备（严格零 sudo）
│   ├── 01_user_workspace.sh               # 创建 ~/Proj、~/etc、~/log、~/.config/hft、~/.ssh 等目录骨架
│   ├── verify_01_user_workspace.sh
│   ├── 02_git_ssh_base.sh                 # 通用 Git 默认配置、~/.ssh/config.d、GitHub 官方主机指纹
│   ├── verify_02_git_ssh_base.sh
│   ├── 03_build_tls_libs.sh               # SHA-256 校验静态编译 WolfSSL 5.8.4 / OpenSSL 3.6.0 / LibreSSL 4.2.1
│   ├── verify_03_build_tls_libs.sh
│   ├── run_all.sh
│   └── verify_all.sh
└── test/
    ├── test_grub_optimise.sh              # GRUB 拓扑、POSIX drop-in、grubenv 与回滚离线沙箱测试
    └── test_bootstrap_suite.sh            # 全量离线沙箱测试（common、第一层 C1–C7、第二层 C8、回滚 C10）
```

## 标准初始化流程

### 第 0 步：准备全新主机并免密拉取本仓

- 准备一台 **Ubuntu 24.04 LTS** 主机（AWS EC2 或物理机），满足：
  - 至少 **2 颗物理 CPU 核**（物理核 P0 留给 OS 与中断，默认从 P1 起最多隔离 3 颗物理核及其全部 HT 兄弟核）；
  - 至少 **4 GiB 内存**（用于 `512×2MB` = 1 GiB 静态大页池，默认单系统盘即可）。
- 登录主机（`ubuntu`、`root` 或具备 `sudo` 权限的初始账号）；最小裸机若未装 `git` 或 CA 证书先执行 `apt-get update && apt-get install -y git ca-certificates`（Ubuntu 24.04 AMI 已自带），然后直接从公开地址免密克隆本仓：

```bash
git clone https://github.com/ziwei-yang/00_hft_system.git ~/00_hft_system
cd ~/00_hft_system
```

### 第 1 步：执行第一层（系统特权准备）

一键按序执行 `01` 到 `07`（或逐个执行）：

```bash
./00_sudo_script/run_all.sh
```

常用参数：
- `--ssh-key-source <user|file>`：显式指定 `hft` 继承的 SSH 公钥来源（不传时按单一最高优先级择一：非 root `SUDO_USER` > `ubuntu` > `root`，自动过滤云镜像拒登前缀）。
- `--max-phys-cores <N>`：覆盖从 P1 起最多隔离的物理核数（默认 `3`）。
- `--enable-idle-poll`：显式启用 `idle=poll`（虚拟化 EC2 默认关闭）。
- `--no-managed-irq`：使用 `isolcpus=<list>` 替代默认的 `isolcpus=domain,managed_irq,<list>`。
- 无写入、`sudo` 预览本机物理核拓扑与 GRUB 配置差异：

```bash
./00_sudo_script/03_grub_cpu_isolation.sh --dry-run
```

### 第 2 步：实测 `hft` 登录并重启（硬门禁）

在关闭当前会话或重启之前，**另开一个新终端**确认 `hft` 的 SSH 登录与免密 `sudo` 正常：

```bash
ssh hft@<host> 'sudo -n true'
```

确认无误后执行重启，使 GRUB 核隔离、`/dev/hugepages` 挂载参数、`user@<uid>` 资源上限及开机服务全部生效：

```bash
sudo reboot
```

重启后改用 **`hft`** 账号登录（若第 0 步克隆在初始账号目录下，可在 `hft` 下重新克隆至 `~/Proj/00_hft_system` 或 `~/00_hft_system`），运行重启后实态验收门禁：

```bash
git clone https://github.com/ziwei-yang/00_hft_system.git ~/Proj/00_hft_system
cd ~/Proj/00_hft_system
./00_sudo_script/verify_all.sh --live
# 真机验收必跑：核验与 Binance / OKX 交易所时间偏差区间在 [-100ms, +100ms] 内
./00_sudo_script/verify_07_chrony_time_sync.sh --require-exchange-time
```

### 第 3 步：执行第二层（`hft` 账号，严格零 `sudo`）

以 **`hft`** 账号执行（禁止以 `root` 运行）：

```bash
./01_startup/run_all.sh
```

本阶段将依次完成：
1. 创建 `~/Proj`、`~/etc`、`~/log`、`~/.config/hft`（`0700`）、`~/.config/systemd/user`、`~/.ssh`（`0700`）；
2. 配置通用 Git 默认行为、`~/.ssh/config.d/*.conf` 引入结构及 GitHub 官方 ED25519 / RSA 主机公钥指纹；
3. 按 `-O3 -march=native -mtune=native -pipe` 经官方 SHA-256 校验、静态无 `.so` 污染、C++ 静态链接探针与原子软链切换，编译安装 WolfSSL `5.8.4`、OpenSSL `3.6.0`、LibreSSL `4.2.1` 至 `~/Proj/{wolfssl,openssl,libressl}/install`（同版本构建指纹自动跳过）。

也可单独构建并校验某一套加密库：

```bash
./01_startup/03_build_tls_libs.sh openssl
./01_startup/verify_03_build_tls_libs.sh openssl
```

### 第 4 步：衔接下游私有仓库（第三层）

`01_startup/verify_all.sh` 全部通过即表示通用基础设施完全就绪。随后按私有部署文档完成衔接：

1. 在目标机以 `hft` 为下游私有仓库分别生成独立的只读 Deploy Key（权限 `0600`），仅将公钥登记到 GitHub 对应仓库的只读 Deploy Keys（不勾选写权限），并在 `~/.ssh/config.d/` 配置独立 Host 别名（`IdentitiesOnly yes`）；
2. 将私有仓库克隆到 `~/Proj/`，执行私有侧第三层初始化脚本完成代码拉齐与本机配置对接；
3. 未来 2 核原地升配 4 核（如 AWS EBS-backed 实例停机换型重启后），重新运行 `./00_sudo_script/03_grub_cpu_isolation.sh`、重启并复跑 `verify_all.sh --live` 即可平滑刷新核隔离。

## 离线测试与语法检查

全部测试均在隔离的 `/tmp/test_*` 沙箱内执行，绝不触碰宿主真实路径或真实 `sudo`（需 GNU `bash >= 4.3`）：

```bash
# 逐文件语法检查
for f in lib/*.sh 00_sudo_script/*.sh 01_startup/*.sh test/*.sh; do
    bash -n "$f" || exit 1
done

# GRUB 拓扑、POSIX drop-in、grubenv、三态回滚与重启门禁测试
bash test/test_grub_optimise.sh

# 全量离线沙箱测试（公共库、第一层 C1–C7、第二层 C8、事务回滚 C10）
bash test/test_bootstrap_suite.sh
bash test/test_bootstrap_suite.sh --only common
bash test/test_bootstrap_suite.sh --only layer1
bash test/test_bootstrap_suite.sh --only layer2
```

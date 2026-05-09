# HFT System Initialization

Scripts and tools essential for initializing HFT system environment.

## Naming Convention

Scripts use a two-digit prefix (e.g., `00_`, `01_`) to indicate initialization priority. Lower numbers run first.

## Structure

```
00_hft_system/
├── 00_sudo_script/              # Privileged scripts, run after machine startup
│   ├── 00_grub_optimise.sh      # GRUB kernel parameters for low-latency
│   ├── 01_hugepage_2MBx512.sh   # Configure 512 x 2MB hugepages
│   ├── 04_install_hft-shm.sh    # Build and install hft-shm
│   └── 05_init_share_mem.sh     # Initialize all shared memory
└── hft-shm/                     # Shared memory management tool
```

## Prerequisites

Scripts require passwordless sudo. Configure with:
```bash
sudo visudo
# Add: yourusername ALL=(ALL) NOPASSWD: ALL
```

Or run `sudo -v` before executing scripts to cache credentials.

## 00_sudo_script

Essential scripts that run after machine startup. Scripts use sudo internally for privileged operations.

### Quick Start

```bash
# Run in order after machine startup:
./00_sudo_script/00_grub_optimise.sh    # Then reboot
./00_sudo_script/01_hugepage_2MBx512.sh
./00_sudo_script/04_install_hft-shm.sh
./00_sudo_script/05_chrony_time_sync.sh # Switch to chrony, sync to non-smearing UTC
./00_sudo_script/05_init_share_mem.sh
```

### 00_grub_optimise.sh

Configures GRUB kernel parameters for low-latency performance:
- `isolcpus` - Isolate cores from scheduler
- `nohz_full` - Disable timer ticks on isolated cores
- `rcu_nocbs` - Offload RCU callbacks
- `irqaffinity` - Pin IRQs to core 0

EC2-only: `intel_pstate=disable`, `processor.max_cstate=0`, `idle=poll`

```bash
./00_sudo_script/00_grub_optimise.sh
# Requires reboot
```

### 01_hugepage_2MBx512.sh

Configures 512 x 2MB = 1GB hugepages for shared memory.

```bash
./00_sudo_script/01_hugepage_2MBx512.sh
```

### 04_install_hft-shm.sh

Builds and installs `hft-shm` to `/usr/local/bin/`.

```bash
./00_sudo_script/04_install_hft-shm.sh
```

### 05_chrony_time_sync.sh

Replaces `systemd-timesyncd` with `chrony`, configured against verified
non-smearing UTC sources (Cloudflare anycast + NIST stratum-1) for
HFT-grade clock determinism. Neutralises vendor / DHCP source directives
in `/etc/chrony/chrony.conf` (idempotent, byte-deterministic round-trip).
Verifies sub-50 ms convergence and provider-diverse ≥3-source quorum
before exiting. Re-runs are no-ops once configured.

```bash
./00_sudo_script/05_chrony_time_sync.sh
```

### 05_init_share_mem.sh

Initializes all shared memory segments from `~/hft.toml` and verifies creation.

```bash
./00_sudo_script/05_init_share_mem.sh
```

## hft-shm

Policy-based C++20 CLI tool for initializing and managing shared memory across the HFT system.

**Not a daemon** - one-shot CLI invoked at startup to create shared memory. Other processes query info as needed.

### Config

Loads from `~/hft.toml` (production) or `./conf/test.toml` (testing).

Example `~/hft.toml`:
```toml
[zwy.mktdata.binance.raw.rx]
name = "zwy/mktdata/binance/raw/rx"
pair = "BTC/USDT"
type = "ringbuffer"
capacity = "32MB"
element_size = 1
codec = "string/json"
writer = ["zwy.mktdata_receiver.binance"]
reader = ["zwy.mktdata_decoder.binance"]

[zwy.mktdata.binance.raw.tx]
name = "zwy/mktdata/binance/raw/tx"
pair = "BTC/USDT"
type = "ringbuffer"
capacity = "2MB"
element_size = 1
codec = "string/json"
writer = ["zwy.mktdata_decoder.binance"]
reader = ["zwy.mktdata_receiver.binance"]
```

### Commands

| Command | Description |
|---------|-------------|
| `hft-shm init` | Create all segments from config |
| `hft-shm list` | List all configured segments |
| `hft-shm info <name>` | Show config attributes |
| `hft-shm inspect <name>` | Show runtime properties |
| `hft-shm dump <name> --filename <path>` | Dump segment to file |
| `hft-shm reset <name>` | Zero out segment memory |
| `hft-shm destroy [--all\|<name>]` | Remove segment(s) |

### Build

```bash
cd hft-shm
make        # Build CLI
make test   # Run tests
```

### Design

- C++20 with policy-based design (template structs)
- Each policy category in one `.hpp` file
- Shared memory: `/dev/shm/hft/<name>` (Linux), `/tmp/hft/<name>` (macOS)
- Hugepages: auto-configured based on capacity (<512MB: 2MB, ≥512MB: 1GB)

## Requirements

- Ubuntu Linux
- Passwordless sudo access
- C++20 compiler (g++ 10+)
- Minimum 2 CPU cores

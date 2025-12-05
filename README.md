# HFT System Management Scripts

Scripts for configuring and optimizing Linux machines for High-Frequency Trading workloads.

## Scripts

### `script/00_grub_optimise.sh`

Configures GRUB kernel parameters for low-latency performance.

**Features:**
- Auto-detects CPU cores and configures isolation (keeps core 0 for system)
- Applies different optimization levels for EC2 vs bare-metal
- Creates backup before modifying GRUB configuration

**Parameters configured:**
- `isolcpus` - Isolate cores from scheduler
- `nohz_full` - Disable timer ticks on isolated cores
- `rcu_nocbs` - Offload RCU callbacks
- `irqaffinity` - Pin IRQs to core 0

EC2-only additional params: `intel_pstate=disable`, `processor.max_cstate=0`, `idle=poll`

**Usage:**
```bash
sudo ./script/00_grub_optimise.sh
```

Requires reboot after execution.

## Requirements

- Ubuntu Linux
- Root/sudo access
- Minimum 2 CPU cores

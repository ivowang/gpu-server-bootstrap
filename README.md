# Private GPU Dev Containers on a Single Host

A pragmatic operations model for multi-user GPU servers:

- Users do **not** log into host shell.
- Each user gets a **private Docker container** with SSH access on a dedicated high port.
- User data is persisted on `/data` mounts.
- All containers can use all GPUs (default), with rendering support enabled.

This repository provides a one-shot bootstrap script and day-2 operations scripts used in production-like setups.

## Why this model

On shared GPU servers, host-level package conflicts and accidental host pollution are common.  
This model isolates users into per-user containers while keeping administration simple:

- predictable per-user SSH entrypoint
- persistent user data
- reproducible rebuild workflows
- straightforward GPU usage attribution

## Architecture

Host policy:

- Host SSH allows `root` only.
- Normal users cannot open host shell directly.

Per-user container:

- Container name: `dev-<username>`
- Host port mapping: `<high_port>:22` (starts from `20000`)
- Mounts:
  - `/data/home/<username>` -> container `/root`
  - `/data/share` -> container `/share`
- GPU:
  - `--gpus all`
  - `NVIDIA_DRIVER_CAPABILITIES=all`
- Shared memory:
  - `--shm-size 256g`
- Restart policy:
  - `unless-stopped`

## Repository contents

- `setup_private_docker_platform.sh`: one-shot bootstrap for a fresh server
- `creater_user.sh`: create user container + print SSH config snippet
- `delete_user.sh`: delete user container (optionally purge data)
- `rebuild_user_container.sh`: rebuild user container (reset non-mounted layer)
- `rebuild_user_container_keep_data.sh`: rebuild while preserving writable layer via snapshot
- `user_storage_usage.sh`: per-user storage accounting
- `blame_gpu_use.sh`: map active GPU processes to usernames
- `private-dev-image.Dockerfile`: base image used for user containers

## Quick start

### 1) Prerequisites

- Ubuntu host with root access
- Data disk mounted at `/data`
- Internet access to APT + NVIDIA container toolkit repo + container registry mirrors

### 2) Bootstrap the machine

```bash
bash /root/setup_private_docker_platform.sh
```

What it does:

- installs Docker and NVIDIA container toolkit
- configures Docker NVIDIA runtime
- enforces host SSH policy (root-only)
- prepares `/data/home`, `/data/share`, `/data/docker-private-users`
- writes all management scripts to `/root`
- builds base image `private-dev:ssh-gpu`

## Daily operations

### Create a user container

```bash
/root/creater_user.sh <username> <public_key_or_pubkey_file> <server_host>
```

Example:

```bash
/root/creater_user.sh alice /root/alice.pub 203.0.113.10
```

The script prints an SSH config block for the user.

### Delete a user container

Keep user data:

```bash
/root/delete_user.sh <username>
```

Delete container and user data:

```bash
/root/delete_user.sh <username> --purge-home
```

### Rebuild a broken container (reset mode)

Preserves `/root` and `/share`, resets other filesystem changes:

```bash
/root/rebuild_user_container.sh <username>
```

### Rebuild and preserve all container data (keep-data mode)

Uses `docker commit` snapshot, then recreates container from snapshot:

```bash
/root/rebuild_user_container_keep_data.sh <username> --shm-size 256g
```

Notes:

- Running tasks are terminated during rebuild.
- Older snapshots for that user are auto-cleaned after successful rebuild.

## Monitoring and accounting

### Storage usage per user

```bash
/root/user_storage_usage.sh
```

Fields:

- `HOME_DIR`: `/data/home/<username>`
- `CONTAINER_RW`: current container writable layer
- `SNAP_UNIQ`: unique size of keep-data snapshot image
- `ROOTFS_ALL`: full container rootfs (includes shared layers)
- `EST_TOTAL`: `HOME_DIR + CONTAINER_RW + SNAP_UNIQ`

### Who is using which GPU

```bash
/root/blame_gpu_use.sh
```

This script maps GPU compute PIDs to container users using:

- container PID mapping (`docker top`)
- cgroup-based PID -> container ID fallback

## Security and behavior notes

- Users get `root` inside their own containers, not on host.
- Host is intentionally locked down to root-only SSH.
- This setup does not enforce per-user disk quotas by default.
- All GPUs are visible to all user containers by default.

## Common troubleshooting

### `nvidia-smi` works but rendering frameworks fail

Symptom:

- runtime reports like `failed to find a rendering device` in OpenGL/Vulkan-based workloads.

Check:

```bash
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' dev-<username> | grep NVIDIA_DRIVER_CAPABILITIES
```

Expected:

- `NVIDIA_DRIVER_CAPABILITIES=all`

Fix (preserve data):

```bash
/root/rebuild_user_container_keep_data.sh <username> --shm-size 256g
```

### `insufficient shared memory (shm)`

Check:

```bash
docker inspect --format '{{.HostConfig.ShmSize}}' dev-<username>
```

Expected:

- `274877906944` (256 GiB)

Fix:

```bash
/root/rebuild_user_container_keep_data.sh <username> --shm-size 256g
```

## Design trade-offs

This model optimizes for operational simplicity and practical isolation, not strict multi-tenant hardening.  
For stronger isolation or scheduling fairness, integrate with additional controls (GPU partitioning, quotas, cgroups policies, orchestration).


# Private GPU Container Platform (Single-Script Repo)

This repository intentionally contains **one file only**:

- `setup.sh`

The script bootstraps a fresh GPU server into a multi-user, Docker-based private-container platform.

## What this platform does

After bootstrap, each user works inside an isolated private container:

- host SSH: `root` only
- per-user container: `dev-<username>`
- SSH access via host high ports (`20000+`)
- persistent mounts:
  - `/data/home/<username>` -> container `/root`
  - `/data/share` -> container `/share`
- GPU enabled:
  - `--gpus all`
  - `NVIDIA_DRIVER_CAPABILITIES=all` (compute + rendering stacks)
- shared memory: `--shm-size 256g`
- restart policy: `unless-stopped`

## Prerequisites

- Ubuntu server
- root access
- data disk already mounted at `/data`
- internet access for apt + NVIDIA toolkit repo + container image pulls

## Usage

Run on the target server as root:

```bash
bash setup.sh
```

## What the script installs/configures

1. Installs Docker and required dependencies.
2. Installs NVIDIA Container Toolkit and configures Docker runtime.
3. Enforces host SSH policy (`AllowUsers root`).
4. Creates runtime directories:
   - `/data/home`
   - `/data/share`
   - `/data/docker-private-users`
5. Writes `/root/private-dev-image.Dockerfile`.
6. Builds base image `private-dev:ssh-gpu`.
7. Generates operation scripts under `/root`:
   - `creater_user.sh`
   - `delete_user.sh`
   - `rebuild_user_container.sh`
   - `rebuild_user_container_keep_data.sh`
   - `user_storage_usage.sh`
   - `blame_gpu_use.sh`

## Post-bootstrap quick check

```bash
docker images | grep private-dev:ssh-gpu
sshd -T | egrep 'allowusers|permitrootlogin'
```

## Minimal operation examples (generated scripts)

Create user:

```bash
/root/creater_user.sh alice /root/alice.pub 203.0.113.10
```

Rebuild while preserving all existing user container data:

```bash
/root/rebuild_user_container_keep_data.sh alice --shm-size 256g
```

Storage accounting:

```bash
/root/user_storage_usage.sh
```

GPU usage attribution:

```bash
/root/blame_gpu_use.sh
```

## Notes

- This repo is intentionally minimal: **only bootstrap script is versioned**.
- Operational scripts are generated on the target host to keep deployment one-step and reproducible.
- Rebuild operations terminate running tasks in the target container.

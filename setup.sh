#!/usr/bin/env bash
set -euo pipefail

# One-shot bootstrap for a fresh GPU server.
# Target state: same Docker-based private-container ops structure as this machine.

export DEBIAN_FRONTEND=noninteractive

IMAGE_NAME="private-dev:ssh-gpu"
CUDA_IMAGE="nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || err "Please run as root."
}

ensure_data_mount() {
  [[ -d /data ]] || err "/data not found. Please mount data disk to /data first."
}

install_base_packages() {
  log "Installing base packages..."
  apt-get update
  apt-get install -y docker.io jq curl gpg ca-certificates
}

install_nvidia_toolkit() {
  log "Installing nvidia-container-toolkit..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
}

configure_docker_runtime() {
  log "Configuring Docker NVIDIA runtime..."
  nvidia-ctk runtime configure --runtime=docker >/dev/null
  (systemctl restart docker || service docker restart)
}

configure_host_ssh_policy() {
  log "Configuring host SSH policy: only root can login..."
  cat > /etc/ssh/sshd_config.d/99-root-only.conf <<'EOF'
PermitRootLogin yes
AllowUsers root
EOF

  if sshd -t 2>&1 | grep -q 'Unsupported option UsePAM'; then
    sed -ri 's/^[[:space:]]*UsePAM[[:space:]].*/# UsePAM disabled for this sshd build/' /etc/ssh/sshd_config
  fi

  if grep -q '^[[:space:]]*GSSAPIAuthentication[[:space:]]' /etc/ssh/ssh_config 2>/dev/null; then
    sed -ri 's/^[[:space:]]*GSSAPIAuthentication[[:space:]].*/# GSSAPIAuthentication disabled for this ssh client build/' /etc/ssh/ssh_config
  fi

  sshd -t
  (systemctl reload ssh || service ssh reload)
}

prepare_data_dirs() {
  log "Preparing /data directories..."
  mkdir -p /data/home /data/share /data/docker-private-users
  chmod 755 /data/home
  chmod 777 /data/share
  touch /data/docker-private-users/registry.tsv /data/docker-private-users/.lock
  chmod 600 /data/docker-private-users/registry.tsv
}

write_dockerfile() {
  log "Writing /root/private-dev-image.Dockerfile ..."
  cat > /root/private-dev-image.Dockerfile <<'EOF'
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-server \
      ca-certificates \
      tzdata \
      vim \
      less \
      curl \
      wget \
      git \
      iproute2 \
      net-tools \
      procps && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd /share && \
    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -ri 's|^#?AuthorizedKeysFile.*|AuthorizedKeysFile .ssh/authorized_keys|' /etc/ssh/sshd_config && \
    grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
}

write_creater_user() {
  cat > /root/creater_user.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

START_PORT=20000
BASE_HOME="/data/home"
SHARE_DIR="/data/share"
META_DIR="/data/docker-private-users"
REGISTRY_FILE="${META_DIR}/registry.tsv"
LOCK_FILE="${META_DIR}/.lock"
IMAGE_NAME="private-dev:ssh-gpu"
CONTAINER_PREFIX="dev"
SHM_SIZE="256g"
NVIDIA_DRIVER_CAPABILITIES_VALUE="all"

usage() {
  cat <<'USAGE'
Usage:
  creater_user.sh <username> <pubkey_or_pubkey_file> [server_host]
USAGE
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

is_port_busy() {
  local port="$1"
  if ss -ltn "( sport = :${port} )" | awk 'NR>1 {exit 0} END {exit 1}'; then
    return 0
  fi
  if [[ -f "${REGISTRY_FILE}" ]] && awk -F'\t' -v p="${port}" '$2 == p {found=1} END {exit(found ? 0 : 1)}' "${REGISTRY_FILE}"; then
    return 0
  fi
  return 1
}

next_free_port() {
  local port="${START_PORT}"
  while is_port_busy "${port}"; do
    port=$((port + 1))
  done
  echo "${port}"
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 1
fi
[[ "$(id -u)" -eq 0 ]] || die "Please run as root."

USERNAME="$1"
KEY_INPUT="$2"
SERVER_HOST="${3:-$(hostname -I | awk '{print $1}')}"
[[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: ${USERNAME}"

if [[ -f "${KEY_INPUT}" ]]; then
  PUBKEY="$(tr -d '\r' < "${KEY_INPUT}")"
else
  PUBKEY="${KEY_INPUT}"
fi
[[ "${PUBKEY}" =~ ^ssh-(rsa|ed25519|ecdsa-sha2-nistp(256|384|521))\  ]] || die "Invalid SSH public key format."

mkdir -p "${BASE_HOME}" "${SHARE_DIR}" "${META_DIR}"
chmod 755 "${BASE_HOME}"
chmod 777 "${SHARE_DIR}"
touch "${REGISTRY_FILE}"

exec 9>"${LOCK_FILE}"
flock -x 9

if awk -F'\t' -v u="${USERNAME}" '$1 == u {found=1} END {exit(found ? 0 : 1)}' "${REGISTRY_FILE}"; then
  die "User already exists in registry: ${USERNAME}"
fi

CONTAINER_NAME="${CONTAINER_PREFIX}-${USERNAME}"
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  die "Container already exists: ${CONTAINER_NAME}"
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  DOCKERFILE_PATH="${SCRIPT_DIR}/private-dev-image.Dockerfile"
  [[ -f "${DOCKERFILE_PATH}" ]] || die "Image ${IMAGE_NAME} missing and Dockerfile not found."
  docker build -t "${IMAGE_NAME}" -f "${DOCKERFILE_PATH}" "${SCRIPT_DIR}" >/dev/null
fi

PORT="$(next_free_port)"
USER_HOME="${BASE_HOME}/${USERNAME}"
mkdir -p "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
printf '%s\n' "${PUBKEY}" > "${USER_HOME}/.ssh/authorized_keys"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R root:root "${USER_HOME}"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname "${USERNAME}-dev" \
  --restart unless-stopped \
  --shm-size "${SHM_SIZE}" \
  --env "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES_VALUE}" \
  --gpus all \
  --label private.dev.managed=true \
  --label private.dev.username="${USERNAME}" \
  --label private.dev.port="${PORT}" \
  -p "${PORT}:22" \
  -v "${USER_HOME}:/root" \
  -v "${SHARE_DIR}:/share" \
  "${IMAGE_NAME}" >/dev/null

printf '%s\t%s\t%s\t%s\n' "${USERNAME}" "${PORT}" "${CONTAINER_NAME}" "$(date -Iseconds)" >> "${REGISTRY_FILE}"

cat <<OUT
[OK] User container created
username: ${USERNAME}
container: ${CONTAINER_NAME}
port: ${PORT}
home_mount: ${USER_HOME} -> /root
share_mount: ${SHARE_DIR} -> /share

SSH config:
Host ${USERNAME}
  HostName ${SERVER_HOST}
  Port ${PORT}
  User root
  IdentityFile ~/.ssh/id_rsa
  ServerAliveInterval 60
  ServerAliveCountMax 3
OUT
EOF
}

write_delete_user() {
  cat > /root/delete_user.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_HOME="/data/home"
META_DIR="/data/docker-private-users"
REGISTRY_FILE="${META_DIR}/registry.tsv"
LOCK_FILE="${META_DIR}/.lock"
CONTAINER_PREFIX="dev"

usage() {
  cat <<'USAGE'
Usage:
  delete_user.sh <username> [--purge-home]
USAGE
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi
[[ "$(id -u)" -eq 0 ]] || die "Please run as root."

USERNAME="$1"
PURGE_HOME=0
if [[ $# -eq 2 ]]; then
  [[ "$2" == "--purge-home" ]] || die "Unknown option: $2"
  PURGE_HOME=1
fi
[[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: ${USERNAME}"

mkdir -p "${META_DIR}"
touch "${REGISTRY_FILE}"

exec 9>"${LOCK_FILE}"
flock -x 9

CONTAINER_NAME="${CONTAINER_PREFIX}-${USERNAME}"
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

while IFS= read -r c; do
  [[ -n "${c}" ]] || continue
  [[ "${c}" == "${CONTAINER_NAME}" ]] && continue
  docker rm -f "${c}" >/dev/null
done < <(docker ps -a --filter "label=private.dev.managed=true" --filter "label=private.dev.username=${USERNAME}" --format '{{.Names}}')

tmp_file="$(mktemp)"
awk -F'\t' -v u="${USERNAME}" '$1 != u' "${REGISTRY_FILE}" > "${tmp_file}"
mv "${tmp_file}" "${REGISTRY_FILE}"

if [[ "${PURGE_HOME}" -eq 1 ]]; then
  rm -rf "${BASE_HOME:?}/${USERNAME}"
  echo "[OK] Deleted user ${USERNAME}, container(s), and ${BASE_HOME}/${USERNAME}"
else
  echo "[OK] Deleted user ${USERNAME} container(s)."
  echo "[INFO] Kept data directory: ${BASE_HOME}/${USERNAME}"
fi
EOF
}

write_rebuild_user() {
  cat > /root/rebuild_user_container.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_HOME="/data/home"
SHARE_DIR="/data/share"
META_DIR="/data/docker-private-users"
REGISTRY_FILE="${META_DIR}/registry.tsv"
LOCK_FILE="${META_DIR}/.lock"
IMAGE_NAME="private-dev:ssh-gpu"
CONTAINER_PREFIX="dev"
SHM_SIZE="256g"
NVIDIA_DRIVER_CAPABILITIES_VALUE="all"

usage() {
  cat <<'USAGE'
Usage:
  rebuild_user_container.sh <username>
USAGE
}

die() { echo "[ERROR] $*" >&2; exit 1; }

get_container_by_label() {
  local username="$1"
  docker ps -a --filter "label=private.dev.managed=true" --filter "label=private.dev.username=${username}" --format '{{.Names}}'
}

get_port_from_container() {
  local container_name="$1"
  local p
  p="$(docker inspect --format '{{index .Config.Labels "private.dev.port"}}' "${container_name}" 2>/dev/null || true)"
  if [[ -n "${p}" && "${p}" != "<no value>" ]]; then
    echo "${p}"; return
  fi
  docker port "${container_name}" 22/tcp 2>/dev/null | head -n1 | awk -F: '{print $NF}'
}

[[ $# -eq 1 ]] || { usage; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "Please run as root."
command -v docker >/dev/null || die "docker not found."

USERNAME="$1"
[[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: ${USERNAME}"

mkdir -p "${BASE_HOME}" "${SHARE_DIR}" "${META_DIR}"
touch "${REGISTRY_FILE}"
exec 9>"${LOCK_FILE}"
flock -x 9

REG_LINE="$(awk -F'\t' -v u="${USERNAME}" '$1 == u {print; exit}' "${REGISTRY_FILE}" || true)"
PORT=""
CONTAINER_NAME=""
if [[ -n "${REG_LINE}" ]]; then
  IFS=$'\t' read -r _u PORT CONTAINER_NAME _ts <<< "${REG_LINE}"
fi
[[ -n "${CONTAINER_NAME}" ]] || CONTAINER_NAME="${CONTAINER_PREFIX}-${USERNAME}"

MATCHED_CONTAINERS="$(get_container_by_label "${USERNAME}" || true)"
MATCHED_COUNT="$(printf '%s\n' "${MATCHED_CONTAINERS}" | sed '/^$/d' | wc -l)"
[[ "${MATCHED_COUNT}" -le 1 ]] || die "Found multiple managed containers for ${USERNAME}."
if [[ "${MATCHED_COUNT}" -eq 1 ]]; then
  CONTAINER_NAME="$(printf '%s\n' "${MATCHED_CONTAINERS}" | sed '/^$/d' | head -n1)"
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  [[ -n "${PORT}" ]] || PORT="$(get_port_from_container "${CONTAINER_NAME}")"
else
  [[ -n "${REG_LINE}" ]] || die "User not found in registry and no managed container found: ${USERNAME}"
fi

[[ -n "${PORT}" && "${PORT}" =~ ^[0-9]+$ ]] || die "Invalid port value for ${USERNAME}: ${PORT:-<empty>}"
USER_HOME="${BASE_HOME}/${USERNAME}"
[[ -d "${USER_HOME}" ]] || die "User home directory not found: ${USER_HOME}"
[[ -d "${SHARE_DIR}" ]] || die "Share directory not found: ${SHARE_DIR}"

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  DOCKERFILE_PATH="${SCRIPT_DIR}/private-dev-image.Dockerfile"
  [[ -f "${DOCKERFILE_PATH}" ]] || die "Image ${IMAGE_NAME} missing and Dockerfile not found."
  docker build -t "${IMAGE_NAME}" -f "${DOCKERFILE_PATH}" "${SCRIPT_DIR}" >/dev/null
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname "${USERNAME}-dev" \
  --restart unless-stopped \
  --shm-size "${SHM_SIZE}" \
  --env "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES_VALUE}" \
  --gpus all \
  --label private.dev.managed=true \
  --label private.dev.username="${USERNAME}" \
  --label private.dev.port="${PORT}" \
  --label private.dev.rebuilt_at="$(date -Iseconds)" \
  -p "${PORT}:22" \
  -v "${USER_HOME}:/root" \
  -v "${SHARE_DIR}:/share" \
  "${IMAGE_NAME}" >/dev/null

tmp_file="$(mktemp)"
awk -F'\t' -v u="${USERNAME}" '$1 != u' "${REGISTRY_FILE}" > "${tmp_file}"
printf '%s\t%s\t%s\t%s\n' "${USERNAME}" "${PORT}" "${CONTAINER_NAME}" "$(date -Iseconds)" >> "${tmp_file}"
mv "${tmp_file}" "${REGISTRY_FILE}"

echo "[OK] Rebuilt private container for user: ${USERNAME}"
echo "container: ${CONTAINER_NAME}"
echo "port: ${PORT}"
EOF
}

write_rebuild_keep_data() {
  cat > /root/rebuild_user_container_keep_data.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_HOME="/data/home"
SHARE_DIR="/data/share"
META_DIR="/data/docker-private-users"
REGISTRY_FILE="${META_DIR}/registry.tsv"
LOCK_FILE="${META_DIR}/.lock"
CONTAINER_PREFIX="dev"
DEFAULT_SHM_SIZE="256g"
SNAPSHOT_REPO="private-dev-snapshots"
NVIDIA_DRIVER_CAPABILITIES_VALUE="all"

usage() {
  cat <<'USAGE'
Usage:
  rebuild_user_container_keep_data.sh <username> [--shm-size <size>]
USAGE
}

die() { echo "[ERROR] $*" >&2; exit 1; }

get_container_by_label() {
  local username="$1"
  docker ps -a --filter "label=private.dev.managed=true" --filter "label=private.dev.username=${username}" --format '{{.Names}}'
}

get_port_from_container() {
  local container_name="$1"
  local p
  p="$(docker inspect --format '{{index .Config.Labels "private.dev.port"}}' "${container_name}" 2>/dev/null || true)"
  if [[ -n "${p}" && "${p}" != "<no value>" ]]; then
    echo "${p}"; return
  fi
  docker port "${container_name}" 22/tcp 2>/dev/null | head -n1 | awk -F: '{print $NF}'
}

if [[ $# -ne 1 && $# -ne 3 ]]; then usage; exit 1; fi
[[ "$(id -u)" -eq 0 ]] || die "Please run as root."
command -v docker >/dev/null || die "docker not found."

USERNAME="$1"
[[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: ${USERNAME}"

TARGET_SHM_SIZE="${DEFAULT_SHM_SIZE}"
if [[ $# -eq 3 ]]; then
  [[ "$2" == "--shm-size" ]] || die "Unknown option: $2"
  [[ -n "$3" ]] || die "Missing shm size value."
  TARGET_SHM_SIZE="$3"
fi

mkdir -p "${BASE_HOME}" "${SHARE_DIR}" "${META_DIR}"
touch "${REGISTRY_FILE}"
exec 9>"${LOCK_FILE}"
flock -x 9

REG_LINE="$(awk -F'\t' -v u="${USERNAME}" '$1 == u {print; exit}' "${REGISTRY_FILE}" || true)"
PORT=""
CONTAINER_NAME=""
if [[ -n "${REG_LINE}" ]]; then
  IFS=$'\t' read -r _u PORT CONTAINER_NAME _ts <<< "${REG_LINE}"
fi
[[ -n "${CONTAINER_NAME}" ]] || CONTAINER_NAME="${CONTAINER_PREFIX}-${USERNAME}"

MATCHED_CONTAINERS="$(get_container_by_label "${USERNAME}" || true)"
MATCHED_COUNT="$(printf '%s\n' "${MATCHED_CONTAINERS}" | sed '/^$/d' | wc -l)"
[[ "${MATCHED_COUNT}" -le 1 ]] || die "Found multiple managed containers for ${USERNAME}."
if [[ "${MATCHED_COUNT}" -eq 1 ]]; then
  CONTAINER_NAME="$(printf '%s\n' "${MATCHED_CONTAINERS}" | sed '/^$/d' | head -n1)"
fi

docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" || die "Container not found for ${USERNAME}: ${CONTAINER_NAME}"
[[ -n "${PORT}" ]] || PORT="$(get_port_from_container "${CONTAINER_NAME}")"
[[ -n "${PORT}" && "${PORT}" =~ ^[0-9]+$ ]] || die "Invalid port value for ${USERNAME}: ${PORT:-<empty>}"

USER_HOME="${BASE_HOME}/${USERNAME}"
[[ -d "${USER_HOME}" ]] || die "User home directory not found: ${USER_HOME}"
[[ -d "${SHARE_DIR}" ]] || die "Share directory not found: ${SHARE_DIR}"

WAS_RUNNING="0"
if docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" | grep -q '^true$'; then
  WAS_RUNNING="1"
fi

TS="$(date +%Y%m%d%H%M%S)"
SNAP_TAG_USER="$(printf '%s' "${USERNAME}" | tr -c 'a-zA-Z0-9_.-' '-')"
SNAPSHOT_IMAGE="${SNAPSHOT_REPO}:${SNAP_TAG_USER}-${TS}"
OLD_CONTAINER_NAME="${CONTAINER_NAME}-old-${TS}"

docker stop -t 10 "${CONTAINER_NAME}" >/dev/null || true
docker commit "${CONTAINER_NAME}" "${SNAPSHOT_IMAGE}" >/dev/null
docker rename "${CONTAINER_NAME}" "${OLD_CONTAINER_NAME}"

cleanup_and_rollback() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rename "${OLD_CONTAINER_NAME}" "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  if [[ "${WAS_RUNNING}" == "1" ]]; then
    docker start "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

if ! docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname "${USERNAME}-dev" \
  --restart unless-stopped \
  --shm-size "${TARGET_SHM_SIZE}" \
  --env "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES_VALUE}" \
  --gpus all \
  --label private.dev.managed=true \
  --label private.dev.username="${USERNAME}" \
  --label private.dev.port="${PORT}" \
  --label private.dev.rebuild_mode=keep_data \
  --label private.dev.rebuilt_at="$(date -Iseconds)" \
  --label private.dev.snapshot_image="${SNAPSHOT_IMAGE}" \
  -p "${PORT}:22" \
  -v "${USER_HOME}:/root" \
  -v "${SHARE_DIR}:/share" \
  "${SNAPSHOT_IMAGE}" >/dev/null; then
  cleanup_and_rollback
  die "Rebuild failed. Rolled back to old container."
fi

docker rm "${OLD_CONTAINER_NAME}" >/dev/null

OLD_SNAPSHOT_REMOVED=0
while IFS= read -r img; do
  [[ -n "${img}" ]] || continue
  case "${img}" in
    "${SNAPSHOT_REPO}:${SNAP_TAG_USER}-"*)
      [[ "${img}" == "${SNAPSHOT_IMAGE}" ]] && continue
      if docker image rm "${img}" >/dev/null 2>&1; then
        OLD_SNAPSHOT_REMOVED=$((OLD_SNAPSHOT_REMOVED + 1))
      fi
      ;;
  esac
done < <(docker images --format '{{.Repository}}:{{.Tag}}' "${SNAPSHOT_REPO}")

tmp_file="$(mktemp)"
awk -F'\t' -v u="${USERNAME}" '$1 != u' "${REGISTRY_FILE}" > "${tmp_file}"
printf '%s\t%s\t%s\t%s\n' "${USERNAME}" "${PORT}" "${CONTAINER_NAME}" "$(date -Iseconds)" >> "${tmp_file}"
mv "${tmp_file}" "${REGISTRY_FILE}"

cat <<OUT
[OK] Rebuilt private container (keep data) for user: ${USERNAME}
container: ${CONTAINER_NAME}
port: ${PORT}
shm_size: ${TARGET_SHM_SIZE}
snapshot_image: ${SNAPSHOT_IMAGE}
old_snapshots_removed: ${OLD_SNAPSHOT_REMOVED}
OUT
EOF
}

write_user_storage_usage() {
  cat > /root/user_storage_usage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_HOME="/data/home"
META_DIR="/data/docker-private-users"
REGISTRY_FILE="${META_DIR}/registry.tsv"

command -v docker >/dev/null || { echo "[ERROR] docker not found." >&2; exit 1; }
command -v du >/dev/null || { echo "[ERROR] du not found." >&2; exit 1; }
command -v numfmt >/dev/null || { echo "[ERROR] numfmt not found." >&2; exit 1; }
command -v jq >/dev/null || { echo "[ERROR] jq not found." >&2; exit 1; }

human_bytes() { numfmt --to=iec-i --suffix=B "$1"; }

path_bytes() {
  local p="$1"
  if [[ -d "${p}" ]]; then du -sB1 "${p}" | awk '{print $1}'; else echo 0; fi
}

size_text_to_bytes() {
  local s="$1"
  [[ -n "${s}" ]] || { echo 0; return; }
  [[ "${s}" == "0B" || "${s}" == "<none>" ]] && { echo 0; return; }
  local normalized
  normalized="$(echo "${s}" | sed -E 's/kB/K/; s/MB/M/; s/GB/G/; s/TB/T/; s/B$//')"
  numfmt --from=si "${normalized}" 2>/dev/null || echo 0
}

declare -A USERS=()
if [[ -f "${REGISTRY_FILE}" ]]; then
  while IFS=$'\t' read -r u _rest; do [[ -n "${u}" ]] && USERS["${u}"]=1; done < "${REGISTRY_FILE}"
fi
if [[ -d "${BASE_HOME}" ]]; then
  while IFS= read -r d; do [[ -n "${d}" ]] && USERS["$(basename "${d}")"]=1; done < <(find "${BASE_HOME}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi
while IFS= read -r u; do [[ -n "${u}" ]] && USERS["${u}"]=1; done < <(docker ps -a --filter label=private.dev.managed=true --format '{{.Label "private.dev.username"}}')
[[ "${#USERS[@]}" -gt 0 ]] || { echo "[INFO] No users found."; exit 0; }

TOTAL_HOME=0
TOTAL_RW=0
TOTAL_SNAP_UNIQ=0
TOTAL_ROOTFS=0

declare -A SNAP_UNIQ_BYTES=()
DF_JSON="$(docker system df -v --format json 2>/dev/null || true)"
if [[ -n "${DF_JSON}" ]]; then
  while IFS=$'\t' read -r REPO TAG UNIQUE_TXT; do
    [[ -n "${REPO}" && -n "${TAG}" ]] || continue
    REF="${REPO}:${TAG}"
    SNAP_UNIQ_BYTES["${REF}"]="$(size_text_to_bytes "${UNIQUE_TXT}")"
  done < <(echo "${DF_JSON}" | jq -r '.Images[] | [.Repository, .Tag, .UniqueSize] | @tsv' 2>/dev/null || true)
fi

printf '%-16s | %-12s | %-12s | %-12s | %-12s | %-12s | %-9s\n' "USER" "HOME_DIR" "CONTAINER_RW" "SNAP_UNIQ" "ROOTFS_ALL" "EST_TOTAL" "CTN_COUNT"
printf '%.0s-' {1..111}; printf '\n'

while IFS= read -r USERNAME; do
  HOME_BYTES="$(path_bytes "${BASE_HOME}/${USERNAME}")"
  RW_SUM=0
  SNAP_UNIQ_SUM=0
  ROOTFS_SUM=0
  CTN_COUNT=0

  while IFS=' ' read -r CID CNAME; do
    [[ -n "${CID}" ]] || continue
    CTN_COUNT=$((CTN_COUNT + 1))

    SIZE_LINE="$(docker inspect --size --format '{{.SizeRw}} {{.SizeRootFs}} {{index .Config.Labels "private.dev.snapshot_image"}} {{.Config.Image}}' "${CID}" 2>/dev/null || echo '0 0 <no> <no>')"
    RW_BYTES="$(echo "${SIZE_LINE}" | awk '{print $1}')"
    ROOTFS_BYTES="$(echo "${SIZE_LINE}" | awk '{print $2}')"
    SNAP_LABEL="$(echo "${SIZE_LINE}" | awk '{print $3}')"
    IMG_REF="$(echo "${SIZE_LINE}" | awk '{print $4}')"
    [[ "${RW_BYTES}" =~ ^[0-9]+$ ]] || RW_BYTES=0
    [[ "${ROOTFS_BYTES}" =~ ^[0-9]+$ ]] || ROOTFS_BYTES=0

    SNAP_REF=""
    if [[ -n "${SNAP_LABEL}" && "${SNAP_LABEL}" != "<no" && "${SNAP_LABEL}" != "<no>" ]]; then
      SNAP_REF="${SNAP_LABEL}"
    elif [[ -n "${IMG_REF}" && "${IMG_REF}" == private-dev-snapshots:* ]]; then
      SNAP_REF="${IMG_REF}"
    fi
    SNAP_UNIQ_BYTES_ONE=0
    if [[ -n "${SNAP_REF}" ]]; then
      SNAP_UNIQ_BYTES_ONE="${SNAP_UNIQ_BYTES[${SNAP_REF}]:-0}"
      [[ "${SNAP_UNIQ_BYTES_ONE}" =~ ^[0-9]+$ ]] || SNAP_UNIQ_BYTES_ONE=0
    fi

    RW_SUM=$((RW_SUM + RW_BYTES))
    SNAP_UNIQ_SUM=$((SNAP_UNIQ_SUM + SNAP_UNIQ_BYTES_ONE))
    ROOTFS_SUM=$((ROOTFS_SUM + ROOTFS_BYTES))
  done < <(docker ps -a --filter "label=private.dev.managed=true" --filter "label=private.dev.username=${USERNAME}" --format '{{.ID}} {{.Names}}')

  EST_TOTAL=$((HOME_BYTES + RW_SUM + SNAP_UNIQ_SUM))
  TOTAL_HOME=$((TOTAL_HOME + HOME_BYTES))
  TOTAL_RW=$((TOTAL_RW + RW_SUM))
  TOTAL_SNAP_UNIQ=$((TOTAL_SNAP_UNIQ + SNAP_UNIQ_SUM))
  TOTAL_ROOTFS=$((TOTAL_ROOTFS + ROOTFS_SUM))

  printf '%-16s | %-12s | %-12s | %-12s | %-12s | %-12s | %-9s\n' \
    "${USERNAME}" \
    "$(human_bytes "${HOME_BYTES}")" \
    "$(human_bytes "${RW_SUM}")" \
    "$(human_bytes "${SNAP_UNIQ_SUM}")" \
    "$(human_bytes "${ROOTFS_SUM}")" \
    "$(human_bytes "${EST_TOTAL}")" \
    "${CTN_COUNT}"
done < <(printf '%s\n' "${!USERS[@]}" | sort)

printf '%.0s-' {1..111}; printf '\n'
printf '%-16s | %-12s | %-12s | %-12s | %-12s | %-12s | %-9s\n' \
  "TOTAL" \
  "$(human_bytes "${TOTAL_HOME}")" \
  "$(human_bytes "${TOTAL_RW}")" \
  "$(human_bytes "${TOTAL_SNAP_UNIQ}")" \
  "$(human_bytes "${TOTAL_ROOTFS}")" \
  "$(human_bytes "$((TOTAL_HOME + TOTAL_RW + TOTAL_SNAP_UNIQ))")" \
  "-"

cat <<'OUT'

Note:
1) HOME_DIR is /data/home/<username> usage on host disk.
2) CONTAINER_RW is current container writable layer size.
3) SNAP_UNIQ is unique size of user's snapshot image (created by keep-data rebuild).
4) ROOTFS_ALL includes image layers and may be shared across users; do not sum it as real billable usage.
5) EST_TOTAL = HOME_DIR + CONTAINER_RW + SNAP_UNIQ.
OUT
EOF
}

write_blame_gpu_use() {
  cat > /root/blame_gpu_use.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command -v nvidia-smi >/dev/null 2>&1 || { echo "[ERROR] nvidia-smi not found." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "[ERROR] docker not found." >&2; exit 1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

add_unique_csv() {
  local current="$1"
  local value="$2"
  if [[ -z "${current}" ]]; then printf '%s' "${value}"; return; fi
  if [[ ",${current}," == *",${value},"* ]]; then printf '%s' "${current}"; else printf '%s,%s' "${current}" "${value}"; fi
}

declare -A GPU_UUID_TO_INDEX=()
while IFS=',' read -r idx uuid; do
  idx="$(trim "${idx}")"; uuid="$(trim "${uuid}")"
  [[ -n "${idx}" && -n "${uuid}" ]] || continue
  GPU_UUID_TO_INDEX["${uuid}"]="${idx}"
done < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)

declare -A PID_TO_USER=()
declare -A PID_TO_CONTAINER=()
declare -A CID_TO_USER=()
declare -A CID_TO_CONTAINER=()

lookup_pid_owner() {
  local pid="$1"
  local user="" container="" host_user=""

  user="${PID_TO_USER[${pid}]:-}"
  container="${PID_TO_CONTAINER[${pid}]:-}"
  if [[ -n "${user}" ]]; then printf '%s\t%s' "${user}" "${container}"; return 0; fi

  if [[ -r "/proc/${pid}/cgroup" ]]; then
    while IFS= read -r maybe_cid; do
      [[ -n "${maybe_cid}" ]] || continue
      user="${CID_TO_USER[${maybe_cid}]:-}"
      container="${CID_TO_CONTAINER[${maybe_cid}]:-}"
      if [[ -n "${user}" ]]; then printf '%s\t%s' "${user}" "${container}"; return 0; fi
    done < <(grep -Eo '[0-9a-f]{64}' "/proc/${pid}/cgroup" | sort -u || true)
  fi

  host_user="$(ps -o user= -p "${pid}" 2>/dev/null | xargs || true)"
  [[ -n "${host_user}" ]] || host_user="unknown"
  printf 'HOST:%s\t-' "${host_user}"
}

while read -r cid cname username; do
  [[ -n "${cid}" ]] || continue
  [[ -n "${username}" ]] || username="${cname}"
  CID_TO_USER["${cid}"]="${username}"
  CID_TO_CONTAINER["${cid}"]="${cname}"
  CID_TO_USER["${cid:0:12}"]="${username}"
  CID_TO_CONTAINER["${cid:0:12}"]="${cname}"
  while read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    PID_TO_USER["${pid}"]="${username}"
    PID_TO_CONTAINER["${pid}"]="${cname}"
  done < <(docker top "${cid}" -eo pid= 2>/dev/null || true)
done < <(docker ps --no-trunc --filter label=private.dev.managed=true --format '{{.ID}} {{.Names}} {{.Label "private.dev.username"}}')

declare -A GPU_USERS=()
declare -A GPU_DETAILS=()

while IFS=',' read -r gpu_uuid pid process_name used_memory; do
  gpu_uuid="$(trim "${gpu_uuid}")"
  pid="$(trim "${pid}")"
  process_name="$(trim "${process_name}")"
  used_memory="$(trim "${used_memory}")"
  [[ -n "${gpu_uuid}" && -n "${pid}" ]] || continue

  gpu_index="${GPU_UUID_TO_INDEX[${gpu_uuid}]:-}"
  [[ -n "${gpu_index}" ]] || continue

  IFS=$'\t' read -r user container <<< "$(lookup_pid_owner "${pid}")"
  GPU_USERS["${gpu_index}"]="$(add_unique_csv "${GPU_USERS[${gpu_index}]:-}" "${user}")"

  detail="${user}(pid=${pid},proc=${process_name},mem=${used_memory}MiB,ctr=${container})"
  if [[ -z "${GPU_DETAILS[${gpu_index}]:-}" ]]; then
    GPU_DETAILS["${gpu_index}"]="${detail}"
  else
    GPU_DETAILS["${gpu_index}"]="${GPU_DETAILS[${gpu_index}]}; ${detail}"
  fi
done < <(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)

printf '%-6s | %-24s | %s\n' "GPU" "USER" "DETAILS"
printf '%.0s-' {1..120}; printf '\n'
for i in 0 1 2 3 4 5 6 7; do
  user="${GPU_USERS[${i}]:-(idle)}"
  detail="${GPU_DETAILS[${i}]:--}"
  printf '%-6s | %-24s | %s\n' "${i}" "${user}" "${detail}"
done
EOF
}

ensure_cuda_base_image() {
  log "Ensuring CUDA base image exists..."
  if docker image inspect "${CUDA_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi

  if docker pull "${CUDA_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi
  if docker pull "docker.m.daocloud.io/${CUDA_IMAGE}" >/dev/null 2>&1; then
    docker tag "docker.m.daocloud.io/${CUDA_IMAGE}" "${CUDA_IMAGE}"
    return 0
  fi
  if docker pull "swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/${CUDA_IMAGE}" >/dev/null 2>&1; then
    docker tag "swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/${CUDA_IMAGE}" "${CUDA_IMAGE}"
    return 0
  fi

  err "Failed to pull CUDA base image from all configured sources."
}

write_all_scripts() {
  log "Writing management scripts to /root ..."
  write_creater_user
  write_delete_user
  write_rebuild_user
  write_rebuild_keep_data
  write_user_storage_usage
  write_blame_gpu_use
  chmod +x /root/creater_user.sh /root/delete_user.sh /root/rebuild_user_container.sh \
    /root/rebuild_user_container_keep_data.sh /root/user_storage_usage.sh /root/blame_gpu_use.sh
}

build_base_image() {
  log "Building ${IMAGE_NAME} ..."
  docker build -t "${IMAGE_NAME}" -f /root/private-dev-image.Dockerfile /root
}

final_verify() {
  log "Verification..."
  docker image inspect "${IMAGE_NAME}" >/dev/null
  docker info >/dev/null
  sshd -t
  echo
  echo "[OK] Bootstrap completed."
  echo "[INFO] Key scripts:"
  echo "  /root/creater_user.sh"
  echo "  /root/rebuild_user_container_keep_data.sh"
  echo "  /root/user_storage_usage.sh"
  echo "  /root/blame_gpu_use.sh"
}

main() {
  require_root
  ensure_data_mount
  install_base_packages
  install_nvidia_toolkit
  configure_docker_runtime
  configure_host_ssh_policy
  prepare_data_dirs
  write_dockerfile
  write_all_scripts
  ensure_cuda_base_image
  build_base_image
  final_verify
}

main "$@"

#!/usr/bin/env bash
# One-time prep of hermes, run FROM talos:  bash scripts/hermes-prep.sh
#   HERMES_HOST=192.168.x.x bash scripts/hermes-prep.sh     (default host: 192.168.50.65)
#
# Does: passwordless SSH → specs → (remote, via sudo) Docker + docker group +
# swap sized to RAM + lid-close ignore → creates the local `hermes` Docker context.
# You will be prompted for the ssh password once (ssh-copy-id) and for sudo on hermes.
set -euo pipefail

HOST="${HERMES_HOST:-192.168.50.65}"
USER_="${HERMES_USER:-twelvetwo}"
TARGET="${USER_}@${HOST}"

# 1) passwordless SSH
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh -o BatchMode=yes -o ConnectTimeout=5 "${TARGET}" true 2>/dev/null || ssh-copy-id "${TARGET}"

# 2) confirm specs
echo "--- ${TARGET} specs ---"
ssh "${TARGET}" 'free -h; echo "cores: $(nproc)"; df -h /'

# 3) remote prep (needs sudo → allocate a tty)
ssh "${TARGET}" 'cat > /tmp/hermes-remote.sh' <<'REMOTE'
set -euo pipefail

# Docker
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker twelvetwo
systemctl enable --now docker

# Swap: RAM<=8G → swap = RAM (min 2G); else 4G. Skip if swap already exists.
if [[ "$(swapon --show --noheadings | wc -l)" -eq 0 ]]; then
  ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  if   (( ram_mb <= 2048 )); then swap_mb=2048
  elif (( ram_mb <= 8192 )); then swap_mb=$ram_mb
  else swap_mb=4096; fi
  fallocate -l "${swap_mb}M" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "swap: ${swap_mb}M"
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -p /etc/sysctl.d/99-swappiness.conf

# Ignore lid close (laptop stays awake with lid shut)
for key in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
  if grep -qE "^#?${key}=" /etc/systemd/logind.conf; then
    sed -i -E "s/^#?${key}=.*/${key}=ignore/" /etc/systemd/logind.conf
  else
    echo "${key}=ignore" >> /etc/systemd/logind.conf
  fi
done
systemctl restart systemd-logind

free -h; swapon --show
REMOTE
ssh -t "${TARGET}" 'sudo bash /tmp/hermes-remote.sh; rm -f /tmp/hermes-remote.sh'

# 4) local docker context (group change applies to new ssh sessions)
if ! docker context inspect hermes >/dev/null 2>&1; then
  docker context create hermes --docker "host=ssh://${TARGET}"
fi
docker --context hermes info --format 'hermes docker: {{.ServerVersion}}, {{.NCPU}} cpu, {{.MemTotal}} bytes RAM'
echo "Done. Deploy everywhere with: bash up.sh"

#!/usr/bin/env bash
# Prepares an Ubuntu 22.04 / 24.04 machine (x86_64 or arm64) to run the E2E
# backend and API jobs as a self-hosted GitHub Actions runner.
#
#   sudo e2e/ci/setup-runner-ubuntu.sh [runner-user]     (default: ubuntu)
#
# Installs Docker Engine + Compose, JDK 21, Maven and Node 22, and lets the
# runner user use Docker. Idempotent. It does NOT register the runner: that
# needs a short-lived token from GitHub, and the steps are printed at the end.
#
# Not installed: the Android SDK. An emulator needs /dev/kvm, which Oracle's
# Ampere A1 shapes do not expose, so the mobile job cannot run on them.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
RUNNER_USER="${1:-ubuntu}"
id "$RUNNER_USER" >/dev/null 2>&1 || { echo "user '$RUNNER_USER' does not exist" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git unzip jq

# Docker Engine from Docker's repository (the distro package lags, and the
# Compose plugin is needed).
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$RUNNER_USER"
systemctl enable --now docker

# JDK 21 and Maven for the plutus-java build. (The workflow also runs
# actions/setup-java, so this mainly makes `e2e/run.sh` usable by hand.)
apt-get install -y -qq openjdk-21-jdk-headless maven

# Node 22 for the Bruno CLI and the seed script.
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi

# Old stacks and images must not fill the disk on a long-lived runner.
cat > /etc/cron.daily/e2e-docker-prune <<'CRON'
#!/bin/sh
docker container prune -f --filter "until=6h" >/dev/null 2>&1
docker network prune -f --filter "until=6h" >/dev/null 2>&1
docker image prune -af --filter "until=336h" >/dev/null 2>&1
CRON
chmod +x /etc/cron.daily/e2e-docker-prune

echo
echo "Installed: $(docker --version), $(docker compose version | head -n 1)"
echo "           $(java -version 2>&1 | head -n 1), $(mvn -v | head -n 1), node $(node --version)"
echo "KVM:       $([ -e /dev/kvm ] && echo available || echo 'not available (no Android emulator on this machine)')"
cat <<NEXT

Next, as $RUNNER_USER (log out and in again first, so the docker group applies):

  1. GitHub -> organisation (or themis repo) -> Settings -> Actions -> Runners
     -> New self-hosted runner -> Linux / $(dpkg --print-architecture | sed 's/amd64/x64/'). Run the download commands shown.
  2. ./config.sh --url <shown> --token <shown> --labels e2e --unattended
  3. sudo ./svc.sh install $RUNNER_USER && sudo ./svc.sh start
  4. Check the machine:   git clone <themis> && themis/e2e/run.sh doctor
  5. Point the jobs here: set the variable
       E2E_RUNNER_BACKEND = ["self-hosted","linux","$(dpkg --print-architecture | sed 's/amd64/x64/')","e2e"]
NEXT

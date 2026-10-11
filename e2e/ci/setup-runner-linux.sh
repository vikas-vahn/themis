#!/usr/bin/env bash
# Prepares a Linux machine (x86_64 or arm64) to run the E2E backend, API and
# web jobs as a self-hosted GitHub Actions runner. Supports Ubuntu 22.04 /
# 24.04 and Oracle Linux 9 (and other RHEL 9 rebuilds).
#
#   sudo e2e/ci/setup-runner-linux.sh [runner-user]
#       default user: whoever ran sudo (ubuntu on Ubuntu images, opc on Oracle Linux)
#
# Installs Docker Engine + Compose, JDK 21, Maven and Node 22, and lets the
# runner user use Docker. Idempotent. It does NOT register the runner: that
# needs a short-lived token from GitHub, and the steps are printed at the end.
#
# Not installed: the Android SDK. An emulator needs /dev/kvm, which Oracle's
# Ampere A1 shapes do not expose, so the mobile job cannot run on them.
set -euo pipefail
# sudo on RHEL-family systems drops /usr/local/bin, where Maven is linked.
export PATH="/usr/local/bin:$PATH"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
RUNNER_USER="${1:-${SUDO_USER:-}}"
[ -n "$RUNNER_USER" ] || { echo "usage: sudo $0 <runner-user>" >&2; exit 1; }
id "$RUNNER_USER" >/dev/null 2>&1 || { echo "user '$RUNNER_USER' does not exist" >&2; exit 1; }

. /etc/os-release
case "$(uname -m)" in
  x86_64) GH_ARCH=x64 ;;
  aarch64 | arm64) GH_ARCH=arm64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

node_is_current() {
  command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]
}

setup_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg git unzip jq rsync

  # Docker Engine from Docker's repository (the distro package lags, and the
  # Compose plugin is needed).
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # JDK 21 and Maven for the plutus-java build. (The workflow also runs
  # actions/setup-java, so this mainly makes `e2e/run.sh` usable by hand.)
  apt-get install -y -qq openjdk-21-jdk-headless maven

  # Node 22 for the Bruno CLI and the seed script.
  if ! node_is_current; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
  fi
}

setup_dnf() {
  dnf install -y -q ca-certificates curl git unzip jq rsync tar cronie dnf-plugins-core

  # Docker's CentOS repository serves every RHEL 9 rebuild, Oracle Linux included.
  if ! command -v docker >/dev/null 2>&1; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # The distro's Maven is 3.6 and drags in an older JDK as the default `java`,
  # so take the JDK from the distro and Maven from Apache.
  dnf install -y -q java-21-openjdk-devel
  alternatives --set java "$(alternatives --display java | awk '/java-21-openjdk.*priority/ {print $1; exit}')" 2>/dev/null || true
  if ! command -v mvn >/dev/null 2>&1; then
    local v=3.9.9
    curl -fsSL "https://archive.apache.org/dist/maven/maven-3/$v/binaries/apache-maven-$v-bin.tar.gz" | tar -xz -C /opt
    ln -sfn "/opt/apache-maven-$v/bin/mvn" /usr/local/bin/mvn
  fi

  if ! node_is_current; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    dnf install -y -q nodejs
  fi
  systemctl enable --now crond
}

if command -v apt-get >/dev/null 2>&1; then
  setup_apt
elif command -v dnf >/dev/null 2>&1; then
  setup_dnf
else
  echo "unsupported distribution: ${PRETTY_NAME:-unknown} (need apt or dnf)" >&2
  exit 1
fi

usermod -aG docker "$RUNNER_USER"
systemctl enable --now docker

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
echo "Disk:      $(df -h --output=avail / | tail -n 1 | tr -d ' ') free on /"
cat <<NEXT

Next, as $RUNNER_USER (log out and in again first, so the docker group applies):

  1. GitHub -> organisation (or themis repo) -> Settings -> Actions -> Runners
     -> New self-hosted runner -> Linux / $GH_ARCH. Run the download commands shown.
  2. ./config.sh --url <shown> --token <shown> --labels e2e --unattended
  3. sudo ./svc.sh install $RUNNER_USER && sudo ./svc.sh start
  4. Check the machine:   git clone <themis> && themis/e2e/run.sh doctor
  5. Point the jobs here: set the variables
       E2E_RUNNER_BACKEND = ["self-hosted","linux","$GH_ARCH","e2e"]
       E2E_RUNNER_WEB     = ["self-hosted","linux","$GH_ARCH","e2e"]
NEXT

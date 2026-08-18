#!/usr/bin/env bash
# Installs the Linux tools startup.sh needs that _scripts/check.sh checks
# for: docker, kubectl, helm, minikube, python3 (3.9.6+) + pip3/venv.
# Idempotent - each tool is skipped if already on $PATH, so it's safe to
# re-run any time (e.g. after only some tools were missing).
#
# Installs system-wide (/usr/local/bin, apt/dnf/pacman), so it needs root -
# runs itself via sudo (or directly, if already root). Adds the current
# user to the 'docker' group so docker can be used without sudo afterwards
# (needs a fresh login / `newgrp docker` to take effect).
#
# Not meant for CI or machines with an existing, differently-managed
# install of these tools - it always installs to the standard system
# locations. Run ./_scripts/check.sh afterwards to verify.
set -eo pipefail
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

SKIP_CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) SKIP_CONFIRM=true ;;
    -h|--help)
      echo "usage: $0 [-y|--yes]"
      echo "  installs docker, kubectl, helm, minikube, python3 (Linux only)"
      echo "  -y   skip the confirmation prompt"
      exit 0
      ;;
    *) die "Unknown argument: $arg (use -h for usage)" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || die "This script only supports Linux (see https://docs.docker.com/get-docker/, https://minikube.sigs.k8s.io/docs/start/ for other OSes)."

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

PKG_MGR=""
for m in apt-get dnf yum pacman; do
  command -v "$m" >/dev/null 2>&1 && { PKG_MGR=$m; break; }
done

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Not running as root and 'sudo' isn't on \$PATH - install as root instead."
  SUDO="sudo"
fi

NEEDED=()
command -v docker   >/dev/null 2>&1 || NEEDED+=("docker")
command -v kubectl  >/dev/null 2>&1 || NEEDED+=("kubectl")
command -v helm     >/dev/null 2>&1 || NEEDED+=("helm")
command -v minikube >/dev/null 2>&1 || NEEDED+=("minikube")
command -v python3  >/dev/null 2>&1 || NEEDED+=("python3")

if [[ ${#NEEDED[@]} -eq 0 ]]; then
  ok "docker, kubectl, helm, minikube, python3 are all already installed."
  exit 0
fi

info "Missing: ${NEEDED[*]} - will install (arch=$ARCH, pkg manager=${PKG_MGR:-none detected})."
confirm "Install these system-wide (needs sudo)?" || die "Aborted."

install_docker() {
  command -v docker >/dev/null 2>&1 && { ok "docker already installed"; return; }
  info "Installing docker (official convenience script)"
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO usermod -aG docker "$USER"
  ok "docker installed. Log out/in (or run 'newgrp docker') to use it without sudo."
}

install_kubectl() {
  command -v kubectl >/dev/null 2>&1 && { ok "kubectl already installed"; return; }
  info "Installing kubectl"
  local ver tmp
  ver=$(curl -Ls https://dl.k8s.io/release/stable.txt)
  tmp=$(mktemp)
  curl -Lo "$tmp" "https://dl.k8s.io/release/${ver}/bin/linux/${ARCH}/kubectl"
  chmod +x "$tmp"
  $SUDO install -o root -g root -m 0755 "$tmp" /usr/local/bin/kubectl
  rm -f "$tmp"
  ok "kubectl $ver installed"
}

install_helm() {
  command -v helm >/dev/null 2>&1 && { ok "helm already installed"; return; }
  info "Installing helm (official install script)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "helm installed"
}

install_minikube() {
  command -v minikube >/dev/null 2>&1 && { ok "minikube already installed"; return; }
  info "Installing minikube"
  local tmp
  tmp=$(mktemp)
  curl -Lo "$tmp" "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
  chmod +x "$tmp"
  $SUDO install "$tmp" /usr/local/bin/minikube
  rm -f "$tmp"
  ok "minikube installed"
}

install_python3() {
  command -v python3 >/dev/null 2>&1 && { ok "python3 already installed"; return; }
  [[ -n "$PKG_MGR" ]] || die "python3 is missing and no supported package manager (apt-get/dnf/yum/pacman) was found - install it manually."
  info "Installing python3 via $PKG_MGR"
  case "$PKG_MGR" in
    apt-get) $SUDO apt-get update && $SUDO apt-get install -y python3 python3-venv python3-pip ;;
    dnf)     $SUDO dnf install -y python3 python3-pip ;;
    yum)     $SUDO yum install -y python3 python3-pip ;;
    pacman)  $SUDO pacman -Sy --noconfirm python python-pip ;;
  esac
  ok "python3 installed"
}

for tool in "${NEEDED[@]}"; do
  "install_${tool}"
done

echo
ok "Done. Run ./_scripts/check.sh to verify everything's ready for 'make start'."

#!/usr/bin/env bash
set -euo pipefail

# Quick installer for Snap and Flathub on Debian and Debian-based distros.
# It does:
# - install snapd + enable service/socket (if systemd is available)
# - (optional) /snap symlink for "classic" support
# - install flatpak
# - add the Flathub remote
# - (optional) install a GUI store: GNOME Software or KDE Discover
#   (if you don't pass options, it tries to detect an already-installed store)
#
# Usage:
#   sudo bash install_snapandflathub.sh
#   sudo bash install_snapandflathub.sh --gnome-software
#   sudo bash install_snapandflathub.sh --kde-discover
# Options:
#   --gnome-software Install GNOME Software (+ Flatpak plugin) as a GUI store
#   --kde-discover   Install KDE Discover (+ Flatpak backend) as a GUI store
#   --skip-update    Optionally skip the initial: apt update && apt upgrade -y

INSTALL_GNOME_SOFTWARE=0
INSTALL_KDE_DISCOVER=0
SKIP_UPDATE=0

for arg in "$@"; do
  case "$arg" in
    --gnome-software) INSTALL_GNOME_SOFTWARE=1 ;;
    --kde-discover) INSTALL_KDE_DISCOVER=1 ;;
    --skip-update) SKIP_UPDATE=1 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  sudo bash install_snapandflathub.sh [--skip-update]
  sudo bash install_snapandflathub.sh --gnome-software [--skip-update]
  sudo bash install_snapandflathub.sh --kde-discover [--skip-update]

Note:
  --gnome-software and --kde-discover are optional.
  If you don't specify a GUI store, the script will try to detect one already installed.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: installing Snap/Flatpak requires admin privileges, but 'sudo' is not available." >&2
    echo "Run as root or install/configure sudo, then re-run the script." >&2
    exit 1
  fi

  echo "==> Checking sudo permissions (required to install)..."
  if ! sudo -v; then
    echo "Error: you don't have sudo permissions (or authentication failed)." >&2
    echo "Installing packages requires sudo privileges. Add the user to sudoers and try again." >&2
    exit 1
  fi

  exec sudo bash "$0" "$@"
fi

pkg_installed() {
  # Returns 0 if the given Debian package is installed
  dpkg -s "$1" >/dev/null 2>&1
}

if [[ "$INSTALL_GNOME_SOFTWARE" -eq 1 && "$INSTALL_KDE_DISCOVER" -eq 1 ]]; then
  echo "Error: you cannot use --gnome-software and --kde-discover together." >&2
  echo "Choose only one GUI store." >&2
  exit 2
fi

if [[ "$INSTALL_GNOME_SOFTWARE" -eq 0 && "$INSTALL_KDE_DISCOVER" -eq 0 ]]; then
  # No GUI store requested: try to detect one already installed
  if pkg_installed gnome-software; then
    INSTALL_GNOME_SOFTWARE=1
    echo "==> Detected GNOME Software already installed: I will install the required plugins."
  elif pkg_installed plasma-discover || pkg_installed discover; then
    INSTALL_KDE_DISCOVER=1
    echo "==> Detected KDE Discover already installed: I will install the required backends."
  else
    echo "Note: you didn't choose a GUI store (--gnome-software/--kde-discover) and none was detected as installed." >&2
    echo "I will still proceed with Snap/Flatpak/Flathub; if you want a store, re-run with one of the two options." >&2
  fi
fi

is_debian_like() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] && return 0
  [[ "${ID_LIKE:-}" =~ debian ]] && return 0
  return 1
}

has_systemctl() {
  command -v systemctl >/dev/null 2>&1 || return 1
  # systemd present and "running" (avoid container/WSL cases without systemd)
  systemctl is-system-running >/dev/null 2>&1 && return 0
  return 1
}

is_wsl() {
  # WSL detection (v1/v2)
  if [[ -n "${WSL_INTEROP:-}" || -n "${WSL_DISTRO_NAME:-}" ]]; then
    return 0
  fi
  if [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease; then
    return 0
  fi
  if [[ -r /proc/version ]] && grep -qi microsoft /proc/version; then
    return 0
  fi
  return 1
}

is_container() {
  # First choice: systemd-detect-virt (if available)
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    # container? (docker, lxc, podman, containerd, ...)
    if systemd-detect-virt --container >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  # Fallback: common container indicators
  [[ -f /.dockerenv ]] && return 0
  [[ -f /run/.containerenv ]] && return 0
  if [[ -r /proc/1/cgroup ]] && grep -Eqi '(docker|kubepods|containerd|podman|lxc)' /proc/1/cgroup; then
    return 0
  fi
  return 1
}

refuse_unsupported_env() {
  # Block WSL and containers; allow VMs and normal hosts.
  if is_wsl; then
    echo "Error: this script must NOT be run on WSL." >&2
    echo "Run it on a Debian (or Debian-based) host/VM with a real Linux environment." >&2
    exit 1
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    # systemd-detect-virt prints the type (or 'none'); if it's wsl/container we block it.
    vt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$vt" in
      wsl)
        echo "Error: this script must NOT be run on WSL." >&2
        exit 1
        ;;
      docker|lxc|podman|container|containerd)
        echo "Error: this script must NOT be run inside a container ($vt)." >&2
        echo "Run it on a host or on a Debian/Debian-based VM." >&2
        exit 1
        ;;
      *)
        : # vm or none -> ok
        ;;
    esac
  else
    if is_container; then
      echo "Error: this script must NOT be run inside a container (Docker/LXC/Podman/...)." >&2
      echo "Run it on a host or on a Debian/Debian-based VM." >&2
      exit 1
    fi
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends "$@"
}

apt_update_upgrade() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
}

ensure_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1
}

if ! is_debian_like; then
  echo "Note: this doesn't look like a Debian/Debian-based distro (/etc/os-release check). I will try anyway with apt..." >&2
fi

refuse_unsupported_env

if [[ "$SKIP_UPDATE" -eq 1 ]]; then
  echo "==> Skip requested: skipping 'apt update && apt upgrade -y' (you may need to run it manually if you get errors)."
else
  echo "==> Updating package lists and installing upgrades (apt update && apt upgrade -y)..."
  apt_update_upgrade
fi

echo "==> Installing base dependencies..."
apt_install ca-certificates curl gnupg

echo "==> Installing Snap (snapd)..."
apt_install snapd

if has_systemctl; then
  echo "==> Enabling Snap via systemd (snapd.socket)..."
  systemctl enable --now snapd.socket >/dev/null
  # Some distros also use the snapd service (safe to enable if present)
  systemctl enable --now snapd.service >/dev/null 2>&1 || true
else
  echo "Warning: systemd/systemctl doesn't seem to be running here." >&2
  echo "If Snap doesn't work, enable snapd manually (on a system with systemd) or reboot." >&2
fi

if [[ ! -e /snap ]]; then
  # For "classic" snaps (e.g. code, etc.)
  echo "==> Creating /snap symlink (classic support), if possible..."
  if [[ -d /var/lib/snapd/snap ]]; then
    ln -s /var/lib/snapd/snap /snap || true
  fi
fi

if ensure_cmd snap; then
  echo "==> Initializing Snap (installing core)..."
  # On some systems this may fail the first time if snapd isn't ready yet: retry.
  set +e
  snap install core >/dev/null 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    sleep 2
    snap install core
  fi
  set -e
else
  echo "Warning: 'snap' command not available after installation. Check that snapd is running." >&2
fi

echo "==> Installing Flatpak..."
apt_install flatpak

echo "==> Adding and enabling Flathub (system-wide Flatpak)..."
flatpak --system remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak --system remote-modify --enable flathub >/dev/null 2>&1 || true
# Refresh metadata (and update runtimes/apps if present)
flatpak --system update -y >/dev/null 2>&1 || true

if [[ "$INSTALL_GNOME_SOFTWARE" -eq 1 ]]; then
  echo "==> Installing GNOME Software (+ Flatpak plugin) as GUI store..."
  apt-get install -y gnome-software gnome-software-plugin-flatpak gnome-software-plugin-snap || \
    apt-get install -y gnome-software gnome-software-plugin-flatpak || \
    apt-get install -y gnome-software
fi

if [[ "$INSTALL_KDE_DISCOVER" -eq 1 ]]; then
  echo "==> Installing KDE Discover (+ Flatpak backend) as GUI store..."
  # On Debian typically: plasma-discover + plasma-discover-backend-flatpak
  apt-get install -y plasma-discover plasma-discover-backend-flatpak plasma-discover-backend-snap || \
    apt-get install -y discover plasma-discover-backend-flatpak plasma-discover-backend-snap || \
    apt-get install -y plasma-discover plasma-discover-backend-flatpak || \
    apt-get install -y discover plasma-discover-backend-flatpak || \
    apt-get install -y plasma-discover || \
    apt-get install -y discover
fi

echo
echo "Done."
echo "- Snap: try 'snap list' (or install a package with 'snap install <name>')."
echo "- Flatpak/Flathub: try 'flatpak remotes' and 'flatpak install flathub <app>'."
echo "- If the store doesn't show Flatpak apps right away, reboot your PC."
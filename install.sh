#!/usr/bin/env bash
# VocaPulse installer — detects distro, fetches latest release, installs.
#
# One-liner usage:
#   curl -sSL https://vocapulse.app/install | bash
#
# Canonically lives at scripts/install.sh in xsdenite/vocapulse and is
# mirrored to /install.sh in xsdenite/vocapulse-releases (manual copy
# post-0.2.8; CI automation comes later).
#
# v1 scope:
#   - x86_64 only
#   - deb / rpm / pacman families
#   - trusts GitHub HTTPS TLS for integrity (no SHA256SUMS yet)
#
# v1.1 TODO: publish + verify SHA256SUMS (ed25519-signed) before install.

set -euo pipefail

# --------------------------------------------------------------------------
# Library mode: allow sourcing without running the installer (for tests).
#   bash -c 'source scripts/install.sh --source-only; detect_distro'
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--source-only" ]]; then
  SOURCE_ONLY=1
else
  SOURCE_ONLY=0
fi

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
REPO="xsdenite/vocapulse-releases"
RELEASES_BASE="https://github.com/${REPO}/releases"
TMPDIR="/tmp/vocapulse-install-$$"

# Colors (only if stdout is a TTY)
if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YLW=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_BOLD=''; C_RED=''; C_GRN=''; C_YLW=''; C_DIM=''; C_RST=''
fi

info()  { printf '%s==>%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s==>%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
fail()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# cleanup: wiped tmp dir on any exit (normal, error, or signal)
# --------------------------------------------------------------------------
cleanup() {
  [[ -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# detect_distro — echoes one of: deb | rpm | pacman
#
# Uses /etc/os-release ID and falls back to ID_LIKE for derivatives.
# Exits 1 on unrecognised distros.
# --------------------------------------------------------------------------
detect_distro() {
  [[ -r /etc/os-release ]] || fail "cannot read /etc/os-release — unsupported system"
  # shellcheck disable=SC1091
  . /etc/os-release
  local id="${ID:-}" id_like="${ID_LIKE:-}"

  case "$id" in
    debian|ubuntu|linuxmint|mint|pop|elementary|kali|raspbian) echo deb; return ;;
    fedora|rhel|centos|rocky|almalinux|ol)                     echo rpm; return ;;
    arch|cachyos|endeavouros|manjaro|garuda|artix)             echo pacman; return ;;
  esac

  # ID_LIKE fallback (space-separated list per os-release(5))
  case " $id_like " in
    *" debian "*|*" ubuntu "*) echo deb; return ;;
    *" fedora "*|*" rhel "*)   echo rpm; return ;;
    *" arch "*)                echo pacman; return ;;
  esac

  fail "unsupported distro (ID=$id, ID_LIKE=$id_like).
See manual install instructions: https://github.com/xsdenite/vocapulse#installation"
}

# --------------------------------------------------------------------------
# detect_arch — only x86_64 is supported in v1
# --------------------------------------------------------------------------
detect_arch() {
  local arch; arch="$(uname -m)"
  if [[ "$arch" != "x86_64" ]]; then
    fail "unsupported architecture: $arch (only x86_64 is supported in v1)"
  fi
  echo "$arch"
}

# --------------------------------------------------------------------------
# fetch_latest_version — echoes bare version number, e.g. "0.2.8"
#
# Uses GitHub's /releases/latest redirect (unauthenticated, no API quota).
# The redirect target is .../releases/tag/vX.Y.Z — sed plucks the version.
# --------------------------------------------------------------------------
fetch_latest_version() {
  local location ver
  location="$(curl -sLI "${RELEASES_BASE}/latest" \
    | grep -i '^location:' \
    | tail -n1 \
    | tr -d '\r\n')" || fail "could not reach GitHub to check latest version"

  ver="$(printf '%s' "$location" | sed -E 's|.*/tag/v([0-9][0-9.]*).*|\1|')"
  [[ -n "$ver" && "$ver" != "$location" ]] \
    || fail "could not parse latest version from redirect: $location"
  echo "$ver"
}

# --------------------------------------------------------------------------
# detect_installed_version — echoes installed version or empty string
#
# Tries the binary's own --version first (authoritative), then falls back
# to the system package manager's record.
# --------------------------------------------------------------------------
detect_installed_version() {
  # 1) Binary on PATH — most reliable
  if command -v vocapulse >/dev/null 2>&1; then
    local out
    out="$(vocapulse --version 2>/dev/null || true)"
    # expected format: "vocapulse X.Y.Z" or similar — grab first X.Y.Z token
    local ver
    ver="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [[ -n "$ver" ]]; then echo "$ver"; return; fi
  fi

  # 2) Pacman
  if command -v pacman >/dev/null 2>&1 && pacman -Qi vocapulse >/dev/null 2>&1; then
    pacman -Qi vocapulse | awk -F': ' '/^Version/ { sub(/-[0-9]+$/, "", $2); print $2; exit }'
    return
  fi

  # 3) dpkg
  if command -v dpkg >/dev/null 2>&1 && dpkg -s vocapulse >/dev/null 2>&1; then
    dpkg -s vocapulse | awk -F': ' '/^Version:/ { print $2; exit }'
    return
  fi

  # 4) rpm
  if command -v rpm >/dev/null 2>&1 && rpm -q vocapulse >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}\n' vocapulse
    return
  fi

  echo ""
}

# --------------------------------------------------------------------------
# version_cmp a b — echoes "lt", "eq", or "gt" for a vs b (SemVer-ish).
# --------------------------------------------------------------------------
version_cmp() {
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then echo eq; return; fi
  # sort -V: version-sort; smaller comes first
  local smaller; smaller="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  if [[ "$smaller" == "$a" ]]; then echo lt; else echo gt; fi
}

# --------------------------------------------------------------------------
# artifact_filename <fmt> <ver> — echoes the release asset filename.
# Matches the naming contract from .github/workflows/release.yml.
# --------------------------------------------------------------------------
artifact_filename() {
  local fmt="$1" ver="$2"
  case "$fmt" in
    deb)    echo "vocapulse_${ver}_amd64.deb" ;;
    rpm)    echo "vocapulse-${ver}.x86_64.rpm" ;;
    pacman) echo "vocapulse-${ver}-1-x86_64.pkg.tar.zst" ;;
    *)      fail "unknown format: $fmt" ;;
  esac
}

# --------------------------------------------------------------------------
# download_artifact <fmt> <ver> — downloads to $TMPDIR and echoes path.
#
# Uses GitHub's /releases/latest/download/<filename> redirect convention,
# which resolves to the right asset on the latest release.
# --------------------------------------------------------------------------
download_artifact() {
  local fmt="$1" ver="$2"
  local filename; filename="$(artifact_filename "$fmt" "$ver")"
  local url="${RELEASES_BASE}/latest/download/${filename}"
  local dest="${TMPDIR}/${filename}"

  mkdir -p "$TMPDIR"
  info "Downloading ${filename}"
  # --fail: non-zero on HTTP errors; -L: follow redirects; -o: output file
  curl -fL --progress-bar -o "$dest" "$url" \
    || fail "download failed: $url"
  echo "$dest"
}

# --------------------------------------------------------------------------
# install_artifact <fmt> <path> — runs the system package manager.
# We intentionally surface the pkg manager's own output (progress, dep
# resolution, etc.) — do NOT redirect stdout/stderr.
# --------------------------------------------------------------------------
install_artifact() {
  local fmt="$1" path="$2"
  info "Installing via system package manager (sudo will prompt)"
  case "$fmt" in
    deb)
      # ./ prefix is required for apt-get to treat it as a local file
      sudo apt-get install -y "./$path"
      ;;
    rpm)
      sudo dnf install -y "./$path"
      ;;
    pacman)
      # --noconfirm is safe: user explicitly invoked an install script
      sudo pacman -U --noconfirm "$path"
      ;;
    *) fail "unknown format: $fmt" ;;
  esac
}

# --------------------------------------------------------------------------
# print_post_install <ver>
# --------------------------------------------------------------------------
print_post_install() {
  local ver="$1"
  printf '\n'
  printf '%sVocaPulse v%s installed successfully!%s\n\n' "$C_BOLD" "$ver" "$C_RST"
  printf 'To get started:\n'
  printf '  1. Launch VocaPulse from your application menu (or run: vocapulse).\n'
  printf '  2. Sign in when prompted.\n'
  printf '  3. Press Ctrl+Shift+Space anywhere to start recording.\n\n'
  printf 'One-time setup for auto-paste (Ctrl+V simulation):\n'
  printf '  %ssudo usermod -aG input $USER%s\n' "$C_DIM" "$C_RST"
  printf '  # Then log out and back in.\n\n'
  printf 'Need help? https://vocapulse.app\n'
}

# --------------------------------------------------------------------------
# main — glue
# --------------------------------------------------------------------------
main() {
  info "VocaPulse installer"

  # Sanity deps
  command -v curl >/dev/null 2>&1 || fail "curl is required but not found"
  command -v sudo >/dev/null 2>&1 || fail "sudo is required but not found"

  detect_arch >/dev/null
  local fmt; fmt="$(detect_distro)"
  info "Detected package format: $fmt"

  local latest; latest="$(fetch_latest_version)"
  info "Latest release: v${latest}"

  local installed; installed="$(detect_installed_version)"
  if [[ -n "$installed" ]]; then
    local cmp; cmp="$(version_cmp "$installed" "$latest")"
    case "$cmp" in
      eq) info "You have the latest version (v${installed})"; exit 0 ;;
      gt) info "Installed version v${installed} is newer than latest release v${latest}; skipping"; exit 0 ;;
      lt) info "Upgrading VocaPulse ${installed} → ${latest}" ;;
    esac
  else
    info "Installing VocaPulse v${latest}"
  fi

  local path; path="$(download_artifact "$fmt" "$latest")"
  install_artifact "$fmt" "$path"
  print_post_install "$latest"
}

# --------------------------------------------------------------------------
# Entry point (skipped in --source-only mode)
# --------------------------------------------------------------------------
if [[ "$SOURCE_ONLY" -eq 0 ]]; then
  main "$@"
fi

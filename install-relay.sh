#!/usr/bin/env bash
#
# Surgical Reality Relay + API installer for RHEL 10 (stage 1: bootstrap).
#
#   1. Checks the host (RHEL 10.x, root, systemd, disk, network, repositories).
#   2. Installs the prerequisites (Node.js 24 from the RHEL AppStream, ...).
#   3. Downloads the release payload (GitHub Release asset), verifies its
#      SHA-256 and runs stage 2 (install/install.sh from the payload), which
#      asks for the configuration, writes the .env and sets up the services.
#
# Run it as root, from a terminal (stage 2 asks questions):
#
#   sudo ./install-relay.sh
#
# Environment variables (all optional):
#   RELAY_VERSION          Release tag to install, e.g. v0.1.4 (default: latest)
#   GITHUB_TOKEN           Token with read access to the repo; required while the
#                          repository / its releases are private
#   RELAY_REPO             GitHub repository (default: SurgicalReality/relay)
#   RELAY_PAYLOAD_URL      Download the payload from this URL instead of GitHub
#                          (the SHA-256 is expected at "<url>.sha256")
#   RELAY_PAYLOAD_FILE     Use this local payload tarball (offline installs);
#                          "<file>.sha256" is verified when present
#   RELAY_SKIP_OS_CHECK=1  Don't insist on RHEL 10 (e.g. for Rocky/Alma 10)
#   RELAY_NONINTERACTIVE=1 Don't ask questions: use INSTALL_<KEY> variables / defaults
#                          (see install/install.sh for the variable names)
#
# Anything else on the command line is passed on to stage 2.

set -Eeuo pipefail

RELAY_REPO="${RELAY_REPO:-SurgicalReality/relay}"
RELAY_VERSION="${RELAY_VERSION:-latest}"
PAYLOAD_ASSET="relay-rhel-linux-x64.tar.gz"
MIN_NODE_MAJOR=22
MIN_FREE_MB=2048

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_BLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_BLD=""; C_OFF=""
fi
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '\n%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

WORKDIR=""
cleanup() {
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

# --------------------------------------------------------------------------
# Stage 1a: checks
# --------------------------------------------------------------------------
check_host() {
  step "Checking the host"

  [[ $EUID -eq 0 ]] || die "Run this script as root (sudo $0)."

  [[ -r /etc/os-release ]] || die "/etc/os-release not found; is this RHEL?"
  # shellcheck disable=SC1091
  . /etc/os-release
  local major="${VERSION_ID%%.*}"
  if [[ "${ID:-}" == "rhel" && "$major" == "10" ]]; then
    ok "Red Hat Enterprise Linux ${VERSION_ID}"
  elif [[ "${RELAY_SKIP_OS_CHECK:-0}" == "1" ]]; then
    warn "Not RHEL 10 (${PRETTY_NAME:-unknown}); continuing because RELAY_SKIP_OS_CHECK=1."
  else
    die "This installer targets RHEL 10.x, found '${PRETTY_NAME:-unknown}'. Set RELAY_SKIP_OS_CHECK=1 to override (e.g. Rocky/Alma 10)."
  fi

  local arch; arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || die "Unsupported CPU architecture '$arch'; only x86_64 payloads are published."
  ok "Architecture x86_64"

  [[ -d /run/systemd/system ]] || die "systemd is not running as init; the services are installed as systemd units."
  ok "systemd is running"

  command -v dnf >/dev/null || die "dnf not found."

  # An unregistered RHEL has no AppStream, so nodejs can't be installed.
  local repos; repos="$(dnf -q repolist --enabled 2>/dev/null || true)"
  if ! grep -qi 'appstream' <<<"$repos"; then
    die "No enabled AppStream repository. Register the system (subscription-manager register) or configure a mirror, then re-run."
  fi
  ok "AppStream repository is enabled"

  local path free_mb
  for path in /opt /var /var/tmp; do
    free_mb="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
    (( free_mb >= MIN_FREE_MB )) || die "Less than ${MIN_FREE_MB} MB free on $path (${free_mb} MB)."
  done
  ok "Enough free disk space"

  local mem_mb; mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  if (( mem_mb < 3500 )); then
    warn "Only ${mem_mb} MB RAM; 4 GB or more is recommended (two Node.js services)."
  else
    ok "${mem_mb} MB RAM"
  fi

  if [[ -z "${RELAY_PAYLOAD_FILE:-}" ]]; then
    local probe="https://github.com"
    if [[ -n "${RELAY_PAYLOAD_URL:-}" ]]; then
      probe="${RELAY_PAYLOAD_URL}"
    fi
    # Any HTTP answer will do here; curl honours the proxy environment variables.
    if ! curl -sS -o /dev/null -I --connect-timeout 10 "$probe" 2>/dev/null; then
      die "Cannot reach $probe. Check DNS, the firewall and proxy settings (https_proxy), or use RELAY_PAYLOAD_FILE for an offline install."
    fi
    ok "Can reach $probe"
  fi

  if [[ "${RELAY_NONINTERACTIVE:-0}" != "1" ]] && ! { : </dev/tty; } 2>/dev/null; then
    die "No terminal available for the questions in stage 2. Run this script from a shell session (not from a non-interactive pipe), or set RELAY_NONINTERACTIVE=1."
  fi
}

# --------------------------------------------------------------------------
# Stage 1b: prerequisites
# --------------------------------------------------------------------------
install_prerequisites() {
  step "Installing prerequisites"

  # RHEL 10 has no module streams. Newer Node.js streams are separate AppStream
  # packages (nodejs24, ...); plain 'nodejs' is the older default (22).
  local node_pkg=nodejs
  if dnf -q list --available nodejs24 >/dev/null 2>&1 || rpm -q nodejs24 >/dev/null 2>&1; then
    node_pkg=nodejs24
  fi
  info "Using the AppStream package $node_pkg"
  local packages=(
    "$node_pkg"     # runtime for the relay and api services
    curl ca-certificates tar gzip
    jq              # reads the GitHub release API
    openssl         # secrets and the self-signed TLS certificate
    util-linux      # findmnt, runuser
    policycoreutils # restorecon, getenforce
  )
  dnf -y install "${packages[@]}" >/dev/null
  ok "Packages installed"

  if systemctl is-active --quiet firewalld 2>/dev/null && ! command -v firewall-cmd >/dev/null; then
    dnf -y install firewalld >/dev/null
  fi

  # nodejs24 only ships /usr/bin/node-24; the services and pm2 run plain 'node'.
  if [[ "$node_pkg" == nodejs24 && -x /usr/bin/node-24 ]]; then
    ln -sf /usr/bin/node-24 /usr/local/bin/node
    hash -r
  fi

  command -v node >/dev/null || die "node is not available after installing $node_pkg."
  local node_major; node_major="$(node -p 'process.versions.node.split(".")[0]')"
  (( node_major >= MIN_NODE_MAJOR )) \
    || die "Node.js $(node -v) is too old; version ${MIN_NODE_MAJOR} or newer is required."
  ok "Node.js $(node -v)"
  if (( node_major < 24 )); then
    info "Releases are built with Node.js 24; this host runs Node.js ${node_major} (RHEL AppStream)."
  fi
}

# --------------------------------------------------------------------------
# Stage 1c: payload
# --------------------------------------------------------------------------
gh_api() {
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${RELAY_REPO}/$1"
}

# Downloads release asset $1 to file $2.
gh_download_asset() {
  local name="$1" out="$2"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    # Private repositories only serve assets through the API, by asset id.
    local endpoint="releases/latest"
    if [[ "$RELAY_VERSION" != "latest" ]]; then
      endpoint="releases/tags/${RELAY_VERSION}"
    fi
    local id
    id="$(gh_api "$endpoint" | jq -r --arg n "$name" '.assets[] | select(.name == $n) | .id')"
    [[ -n "$id" ]] || die "Release asset '$name' not found for ${RELAY_REPO} (${RELAY_VERSION})."
    curl -fSL --progress-bar -o "$out" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/${RELAY_REPO}/releases/assets/${id}"
  else
    local base="https://github.com/${RELAY_REPO}/releases"
    if [[ "$RELAY_VERSION" == "latest" ]]; then
      base="${base}/latest/download"
    else
      base="${base}/download/${RELAY_VERSION}"
    fi
    curl -fSL --progress-bar -o "$out" "${base}/${name}" \
      || die "Could not download ${base}/${name}. For a private repository, set GITHUB_TOKEN."
  fi
}

fetch_payload() {
  step "Fetching the payload"
  WORKDIR="$(mktemp -d /var/tmp/relay-install.XXXXXX)"
  local tarball="$WORKDIR/payload.tar.gz" sumfile="$WORKDIR/payload.tar.gz.sha256"

  if [[ -n "${RELAY_PAYLOAD_FILE:-}" ]]; then
    [[ -r "$RELAY_PAYLOAD_FILE" ]] || die "Cannot read RELAY_PAYLOAD_FILE=$RELAY_PAYLOAD_FILE"
    cp "$RELAY_PAYLOAD_FILE" "$tarball"
    if [[ -r "${RELAY_PAYLOAD_FILE}.sha256" ]]; then
      cp "${RELAY_PAYLOAD_FILE}.sha256" "$sumfile"
    fi
  elif [[ -n "${RELAY_PAYLOAD_URL:-}" ]]; then
    info "Downloading $RELAY_PAYLOAD_URL"
    curl -fSL --progress-bar -o "$tarball" "$RELAY_PAYLOAD_URL"
    curl -fsSL -o "$sumfile" "${RELAY_PAYLOAD_URL}.sha256" 2>/dev/null || rm -f "$sumfile"
  else
    info "Downloading $PAYLOAD_ASSET from ${RELAY_REPO} (${RELAY_VERSION})"
    gh_download_asset "$PAYLOAD_ASSET" "$tarball"
    gh_download_asset "${PAYLOAD_ASSET}.sha256" "$sumfile"
  fi

  if [[ -s "$sumfile" ]]; then
    local expected actual
    expected="$(awk '{print $1; exit}' "$sumfile")"
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "SHA-256 mismatch for the payload (expected $expected, got $actual)."
    ok "SHA-256 verified"
  else
    warn "No SHA-256 available to verify the payload."
  fi

  mkdir -p "$WORKDIR/payload"
  tar -xzf "$tarball" -C "$WORKDIR/payload" --strip-components=1
  [[ -f "$WORKDIR/payload/install/install.sh" ]] || die "The payload doesn't contain install/install.sh."
  ok "Payload $(cat "$WORKDIR/payload/VERSION" 2>/dev/null || echo '(unknown version)') extracted"
}

main() {
  printf '%sSurgical Reality Relay installer for RHEL 10%s\n' "$C_BLD" "$C_OFF"
  check_host
  install_prerequisites
  fetch_payload

  step "Starting the installation"
  # Not exec'd: the temporary directory is removed once stage 2 is done.
  bash "$WORKDIR/payload/install/install.sh" --payload-dir "$WORKDIR/payload" "$@" || exit $?
}

main "$@"

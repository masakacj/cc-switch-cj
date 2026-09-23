#!/usr/bin/env bash
set -Eeuo pipefail

# One-click DevSpace installer.
# Cloudflare Tunnel is NOT installed or modified by this script.
# Supported: Debian/Ubuntu and Rocky/RHEL-like distributions using systemd.
#
# Interactive:
#   curl -fsSL https://raw.githubusercontent.com/masakacj/cc-switch-cj/main/scripts/install-devspace.sh | bash
#
# Non-interactive:
#   PUBLIC_URL=https://mcp.example.com \
#   ALLOWED_ROOTS='/home/devspace,/srv/projects' \
#   bash install-devspace.sh

DEVSPACE_USER="${DEVSPACE_USER:-devspace}"
DEVSPACE_VERSION="${DEVSPACE_VERSION:-1.0.8}"
DEVSPACE_PORT="${DEVSPACE_PORT:-7676}"
NODE_MAJOR="${NODE_MAJOR:-24}"
PUBLIC_URL="${PUBLIC_URL:-}"
ALLOWED_ROOTS="${ALLOWED_ROOTS:-}"

log() { printf '\033[1;34m[devspace-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warning]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root."
command -v systemctl >/dev/null 2>&1 || die "systemd is required."

if [[ -z "${PUBLIC_URL}" ]]; then
  [[ -r /dev/tty ]] || die "No TTY. Set PUBLIC_URL=https://your-mcp-host.example.com"
  read -r -p "Existing public HTTPS URL for DevSpace (without /mcp): " PUBLIC_URL </dev/tty
fi

PUBLIC_URL="${PUBLIC_URL%/}"
PUBLIC_URL="${PUBLIC_URL%/mcp}"
[[ "${PUBLIC_URL}" == https://* ]] || die "PUBLIC_URL must start with https://"

DEVSPACE_HOME="/home/${DEVSPACE_USER}"
DEFAULT_ROOT="${DEVSPACE_HOME}"

if [[ -z "${ALLOWED_ROOTS}" ]]; then
  if [[ -r /dev/tty ]]; then
    read -r -p "DevSpace allowed project roots, comma-separated [${DEFAULT_ROOT}]: " ALLOWED_ROOTS </dev/tty
  fi
  ALLOWED_ROOTS="${ALLOWED_ROOTS:-${DEFAULT_ROOT}}"
fi

install_base_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing base packages with apt..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git openssl tar xz-utils
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing base packages with dnf..."
    dnf install -y ca-certificates curl git openssl tar xz
  else
    die "Unsupported distribution: apt-get or dnf is required."
  fi
}

node_is_compatible() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1
  node -e '
    const [major, minor] = process.versions.node.split(".").map(Number);
    process.exit(major > 22 && major < 27 || (major === 22 && minor >= 19) ? 0 : 1);
  ' >/dev/null 2>&1
}

install_node() {
  if node_is_compatible; then
    log "Using existing Node.js $(node -v)."
    return
  fi

  local machine node_arch sums archive checksum version_dir tmpdir
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *) die "Unsupported CPU architecture for Node.js: ${machine}" ;;
  esac

  log "Installing Node.js ${NODE_MAJOR}.x from nodejs.org..."
  sums="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt")"
  archive="$(printf '%s\n' "${sums}" | awk -v s="linux-${node_arch}.tar.xz" 'index($2,s) && length($2)>=length(s) && substr($2,length($2)-length(s)+1)==s {print $2; exit}')"
  [[ -n "${archive}" ]] || die "Unable to resolve Node.js archive."
  checksum="$(printf '%s\n' "${sums}" | awk -v f="${archive}" '$2==f {print $1; exit}')"
  [[ -n "${checksum}" ]] || die "Unable to resolve Node.js checksum."

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' RETURN
  curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${archive}" -o "${tmpdir}/${archive}"
  printf '%s  %s\n' "${checksum}" "${tmpdir}/${archive}" | sha256sum -c - >/dev/null

  version_dir="${archive%.tar.xz}"
  mkdir -p /opt/nodejs
  rm -rf "/opt/nodejs/${version_dir}"
  tar -xJf "${tmpdir}/${archive}" -C /opt/nodejs

  ln -sfn "/opt/nodejs/${version_dir}/bin/node" /usr/local/bin/node
  ln -sfn "/opt/nodejs/${version_dir}/bin/npm" /usr/local/bin/npm
  ln -sfn "/opt/nodejs/${version_dir}/bin/npx" /usr/local/bin/npx
  if [[ -e "/opt/nodejs/${version_dir}/bin/corepack" ]]; then
    ln -sfn "/opt/nodejs/${version_dir}/bin/corepack" /usr/local/bin/corepack
  fi

  node_is_compatible || die "Node.js installation failed or installed version is incompatible."
  log "Installed Node.js $(node -v)."
}

install_devspace() {
  log "Installing DevSpace @waishnav/devspace@${DEVSPACE_VERSION}..."
  /usr/local/bin/npm install -g --prefix /usr/local "@waishnav/devspace@${DEVSPACE_VERSION}"
  /usr/local/bin/devspace --version
}

create_service_user() {
  if ! id "${DEVSPACE_USER}" >/dev/null 2>&1; then
    log "Creating service user ${DEVSPACE_USER}..."
    useradd --create-home --home-dir "${DEVSPACE_HOME}" --shell /bin/bash "${DEVSPACE_USER}"
  fi
  mkdir -p "${DEVSPACE_HOME}"
  chown "${DEVSPACE_USER}:${DEVSPACE_USER}" "${DEVSPACE_HOME}"
}

write_devspace_config() {
  log "Writing DevSpace configuration..."
  mkdir -p "${DEVSPACE_HOME}/.devspace"
  chown "${DEVSPACE_USER}:${DEVSPACE_USER}" "${DEVSPACE_HOME}/.devspace"
  chmod 700 "${DEVSPACE_HOME}/.devspace"

  PUBLIC_URL="${PUBLIC_URL}" \
  ALLOWED_ROOTS="${ALLOWED_ROOTS}" \
  DEVSPACE_HOME="${DEVSPACE_HOME}" \
  DEVSPACE_PORT="${DEVSPACE_PORT}" \
  DEVSPACE_CONFIG_DIR="${DEVSPACE_HOME}/.devspace" \
  /usr/local/bin/node <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const dir = process.env.DEVSPACE_CONFIG_DIR;
const configPath = path.join(dir, "config.json");
const authPath = path.join(dir, "auth.json");
const home = process.env.DEVSPACE_HOME;
const publicBaseUrl = process.env.PUBLIC_URL.replace(/\/$/, "");
const port = Number(process.env.DEVSPACE_PORT || "7676");

const parseJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { return {}; }
};

const roots = (process.env.ALLOWED_ROOTS || home)
  .split(",")
  .map((v) => v.trim())
  .filter(Boolean)
  .map((v) => v === "~" ? home : v.startsWith("~/") ? path.join(home, v.slice(2)) : path.resolve(v));

const oldConfig = parseJson(configPath);
const oldAuth = parseJson(authPath);
const config = {
  ...oldConfig,
  host: "127.0.0.1",
  port,
  publicBaseUrl,
  allowedRoots: [...new Set(roots)],
};
const auth = {
  ...oldAuth,
  ownerToken: oldAuth.ownerToken || crypto.randomBytes(32).toString("base64url"),
};

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
fs.writeFileSync(authPath, JSON.stringify(auth, null, 2) + "\n", { mode: 0o600 });
NODE

  chown -R "${DEVSPACE_USER}:${DEVSPACE_USER}" "${DEVSPACE_HOME}/.devspace"
  chmod 600 "${DEVSPACE_HOME}/.devspace/config.json" "${DEVSPACE_HOME}/.devspace/auth.json"
}

write_systemd_unit() {
  log "Installing devspace.service..."
  cat >/etc/systemd/system/devspace.service <<EOF
[Unit]
Description=DevSpace MCP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DEVSPACE_USER}
Group=${DEVSPACE_USER}
WorkingDirectory=${DEVSPACE_HOME}
Environment=HOME=${DEVSPACE_HOME}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DEVSPACE_TRUST_PROXY=1
ExecStart=/usr/local/bin/devspace serve
Restart=always
RestartSec=3
TimeoutStopSec=15
KillSignal=SIGTERM
PrivateTmp=true
UMask=0022
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable devspace.service >/dev/null
  systemctl restart devspace.service
}

verify_service() {
  log "Checking DevSpace..."
  sleep 2
  systemctl is-active --quiet devspace.service || {
    systemctl --no-pager -l status devspace.service || true
    die "DevSpace failed to start."
  }
}

show_result() {
  local owner_token
  owner_token="$(/usr/local/bin/node -e '
    const fs=require("node:fs");
    const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    process.stdout.write(a.ownerToken || "");
  ' "${DEVSPACE_HOME}/.devspace/auth.json")"

  printf '\n'
  printf '============================================================\n'
  printf ' DevSpace installed successfully\n'
  printf '============================================================\n'
  printf 'MCP URL:        %s/mcp\n' "${PUBLIC_URL}"
  printf 'Local endpoint: http://127.0.0.1:%s/mcp\n' "${DEVSPACE_PORT}"
  printf 'Service user:   %s\n' "${DEVSPACE_USER}"
  printf 'Allowed roots:  %s\n' "${ALLOWED_ROOTS}"
  printf 'Owner password: %s\n' "${owner_token}"
  printf '\n'
  printf 'Existing tunnel/reverse proxy should point to http://127.0.0.1:%s\n' "${DEVSPACE_PORT}"
  printf 'This installer did NOT install or modify cloudflared.\n'
  printf '\nUseful commands:\n'
  printf '  systemctl status devspace\n'
  printf '  journalctl -u devspace -f\n'
  printf '  /usr/local/bin/devspace --version\n'
  printf '\n'
}

install_base_packages
install_node
install_devspace
create_service_user
write_devspace_config
write_systemd_unit
verify_service
show_result

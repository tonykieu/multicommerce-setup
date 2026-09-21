#!/usr/bin/env bash
# MultiCommerce server bootstrap — prepares SQLite data dirs, env, deps, and build.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tonykieu/multicommerce-setup/main/setup-server.sh | bash -s -- --dir /opt/multicommerce --start
#   ./scripts/setup-server.sh --dir /opt/multicommerce --start
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/tonykieu/multicommerce.git}"
BRANCH="${BRANCH:-feat/catalog-database-settings}"
INSTALL_DIR="${INSTALL_DIR:-/opt/multicommerce}"
WITH_SYSTEMD=0
WITH_START=0
SKIP_CLONE=0

usage() {
  cat <<'EOF'
MultiCommerce server setup

Options:
  --dir PATH       Install directory (default: /opt/multicommerce)
  --branch NAME    Git branch to clone (default: feat/catalog-database-settings)
  --repo URL       Git repository URL
  --skip-clone     Use current directory; do not clone or pull
  --systemd        Write a systemd user unit (requires systemd)
  --start          Run npm start after setup
  -h, --help       Show this help

Environment:
  REPO_URL, BRANCH, INSTALL_DIR, CATALOG_ADMIN_TOKEN

After setup:
  1. Edit packages/ebay-client/.env and packages/woocommerce-client/.env
  2. Open http://SERVER:5174/database
  3. Import catalog.sqlite from your PC (Database → Import)
  4. Copy data/photos/ to INSTALL_DIR/data/photos/
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --skip-clone) SKIP_CLONE=1; shift ;;
    --systemd) WITH_SYSTEMD=1; shift ;;
    --start) WITH_START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

install_os_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "==> Installing OS packages (apt)..."
    sudo apt-get update -qq
    sudo apt-get install -y curl ca-certificates git python3 make g++ build-essential
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
      echo "==> Installing Node.js 22 (NodeSource)..."
      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
      sudo apt-get install -y nodejs
    fi
  elif command -v dnf >/dev/null 2>&1; then
    echo "==> Installing OS packages (dnf)..."
    sudo dnf install -y curl ca-certificates git python3 make gcc-c++
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
      curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
      sudo dnf install -y nodejs
    fi
  else
    echo "==> Could not detect apt or dnf. Install Node.js 22+, git, and build tools manually." >&2
  fi
}

ensure_node() {
  require_cmd node
  require_cmd npm
  local major
  major="$(node -p 'Number(process.versions.node.split(".")[0])')"
  if [[ "$major" -lt 22 ]]; then
    echo "Node.js 22+ required (found $(node -v))." >&2
    exit 1
  fi
  echo "==> Node $(node -v), npm $(npm -v)"
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    node -p 'require("crypto").randomBytes(24).toString("hex")'
  fi
}

prepare_repo() {
  if [[ "$SKIP_CLONE" -eq 1 ]]; then
    INSTALL_DIR="$(pwd)"
    echo "==> Using current directory: $INSTALL_DIR"
    return
  fi

  if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    echo "==> Cloning $REPO_URL ($BRANCH) into $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown "$USER:$USER" "$INSTALL_DIR"
    git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
  else
    echo "==> Updating existing repo in $INSTALL_DIR..."
    git -C "$INSTALL_DIR" fetch origin "$BRANCH"
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH" || true
  fi
}

write_env_file() {
  local env_file="$INSTALL_DIR/.env.server"
  local admin_token="${CATALOG_ADMIN_TOKEN:-$(random_token)}"

  if [[ -f "$env_file" ]]; then
    echo "==> Keeping existing $env_file"
    return
  fi

  cat >"$env_file" <<EOF
# MultiCommerce server environment — source before npm start
export CATALOG_DATA_DIR=$INSTALL_DIR/data
export CATALOG_HOST=0.0.0.0
export CATALOG_PORT=8787
export CATALOG_ADMIN_TOKEN=$admin_token
export EBAY_ENV_FILE=$INSTALL_DIR/packages/ebay-client/.env
export WC_ENV_FILE=$INSTALL_DIR/packages/woocommerce-client/.env
EOF
  chmod 600 "$env_file"
  echo "==> Wrote $env_file"
  echo "    CATALOG_ADMIN_TOKEN=$admin_token"
}

prepare_data_dirs() {
  echo "==> Creating data directories..."
  mkdir -p "$INSTALL_DIR/data/photos" "$INSTALL_DIR/data/incoming" "$INSTALL_DIR/logs" "$INSTALL_DIR/.runtime" "$INSTALL_DIR/cache/details"
  chmod 700 "$INSTALL_DIR/data"
}

prepare_credentials() {
  local ebay_env="$INSTALL_DIR/packages/ebay-client/.env"
  local woo_env="$INSTALL_DIR/packages/woocommerce-client/.env"

  if [[ ! -f "$ebay_env" && -f "$INSTALL_DIR/packages/ebay-client/.env.example" ]]; then
    cp "$INSTALL_DIR/packages/ebay-client/.env.example" "$ebay_env"
    chmod 600 "$ebay_env"
    echo "==> Created $ebay_env (fill in eBay credentials)"
  fi

  if [[ ! -f "$woo_env" && -f "$INSTALL_DIR/packages/woocommerce-client/.env.example" ]]; then
    cp "$INSTALL_DIR/packages/woocommerce-client/.env.example" "$woo_env"
    chmod 600 "$woo_env"
    echo "==> Created $woo_env (fill in WooCommerce credentials)"
  fi
}

install_and_build() {
  echo "==> npm ci..."
  (cd "$INSTALL_DIR" && npm ci)
  echo "==> Building workspace packages..."
  (cd "$INSTALL_DIR" && npm run build -w @multicommerce/ebay-client)
  (cd "$INSTALL_DIR" && npm run build -w @multicommerce/catalog)
}

write_systemd_unit() {
  local unit_path="$HOME/.config/systemd/user/multicommerce.service"
  mkdir -p "$(dirname "$unit_path")"
  cat >"$unit_path" <<EOF
[Unit]
Description=MultiCommerce catalog
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env.server
ExecStart=$(command -v npm) start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  echo "==> Wrote $unit_path"
  echo "    Enable with: systemctl --user enable --now multicommerce"
}

start_app() {
  echo "==> Starting MultiCommerce..."
  # shellcheck disable=SC1090
  source "$INSTALL_DIR/.env.server"
  (cd "$INSTALL_DIR" && npm start)
}

print_summary() {
  local ip="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  cat <<EOF

MultiCommerce server is ready to accept a database import.

  Install dir:  $INSTALL_DIR
  Data dir:     $INSTALL_DIR/data
  Env file:     $INSTALL_DIR/.env.server
  UI:           http://${ip:-localhost}:5174
  API:          http://${ip:-localhost}:8787
  Database UI:  http://${ip:-localhost}:5174/database

Next steps:
  1. source $INSTALL_DIR/.env.server && cd $INSTALL_DIR && npm start
  2. On your PC: Database → Download catalog.sqlite
  3. scp catalog.sqlite $USER@${ip:-SERVER}:$INSTALL_DIR/data/incoming/
  4. scp -r data/photos $USER@${ip:-SERVER}:$INSTALL_DIR/data/
  5. Open Database → Import (or Attach path: $INSTALL_DIR/data/incoming/catalog.sqlite)

Firewall (if ufw is enabled):
  sudo ufw allow 5174/tcp
  sudo ufw allow 8787/tcp

EOF
}

main() {
  install_os_packages
  ensure_node
  prepare_repo
  cd "$INSTALL_DIR"
  prepare_data_dirs
  write_env_file
  prepare_credentials
  install_and_build

  if [[ "$WITH_SYSTEMD" -eq 1 ]]; then
    write_systemd_unit
  fi

  print_summary

  if [[ "$WITH_START" -eq 1 ]]; then
    start_app
  fi
}

main "$@"

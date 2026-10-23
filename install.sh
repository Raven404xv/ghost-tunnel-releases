#!/usr/bin/env bash
#
#  Ghost Tunnel 8 - installer, updater and management menu
#
#  Run it once:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Raven404xv/ghost-tunnel-releases/main/install.sh)
#  Then, at any time:
#    sudo ghost-tunnel
#
set -Eeuo pipefail

# ============================================================================
#  Project settings
#  GT_REPO is the public repository that publishes the panel releases.
#  Every value can also be overridden with an environment variable.
# ============================================================================
readonly GT_REPO="${GT_REPO:-Raven404xv/ghost-tunnel-releases}"
readonly GT_BRANCH="${GT_BRANCH:-main}"

readonly PANEL_BIN="/usr/local/bin/ghost-panel"
readonly MENU_BIN="/usr/local/bin/ghost-tunnel"
readonly CONF_DIR="/etc/ghost-tunnel"
readonly CONF_FILE="${CONF_DIR}/config.json"
readonly ADMIN_NOTE_FILE="/root/ghost-tunnel-admin.txt"
readonly VERSION_FILE="${CONF_DIR}/version"
readonly TLS_DIR="${CONF_DIR}/tls"
readonly SERVICE="ghost-tunnel-panel"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
readonly PROFILES_DIR="${CONF_DIR}/profiles"
# Old installs kept a separate Python core here; it is removed on uninstall.
readonly LEGACY_CORE_DIR="/opt/ghost-tunnel"
readonly SYSCTL_FILE="/etc/sysctl.d/99-ghost-tunnel.conf"
readonly RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/ghost-tunnel.sh"
readonly RUN_DIR="/run/ghost-tunnel"
readonly MENU_RELOAD_FLAG="${RUN_DIR}/menu-reload"
readonly DEFAULT_PORT=8443

# ----------------------------------------------------------------------------
#  Terminal output
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

info(){ printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok(){ printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail(){ printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; return 1; }
step(){ printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

print_box(){
  local title="$1"; shift
  local line="============================================================"
  printf '\n%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
  printf '  %s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
  printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
  local l
  for l in "$@"; do printf '  %s\n' "$l"; done
  printf '%s%s%s\n\n' "$C_GREEN" "$line" "$C_RESET"
}

# ----------------------------------------------------------------------------
#  Input
# ----------------------------------------------------------------------------
ask(){ # ask PROMPT [DEFAULT]  -> prints the answer
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " reply < /dev/tty || return 1
    printf '%s\n' "${reply:-$default}"
  else
    read -r -p "${prompt}: " reply < /dev/tty || return 1
    printf '%s\n' "$reply"
  fi
}

ask_secret(){ # ask_secret PROMPT -> prints the answer, input is hidden
  local prompt="$1" reply
  read -r -s -p "${prompt}: " reply < /dev/tty || return 1
  printf '\n' > /dev/tty
  printf '%s\n' "$reply"
}

confirm(){ # confirm QUESTION -> returns 0 for yes, 1 for no
  local q="$1" answer
  while true; do
    read -r -p "${q} [y/n]: " answer < /dev/tty || return 1
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

pause(){ read -r -p "Press Enter to return to the menu..." _ < /dev/tty || true; }

# ----------------------------------------------------------------------------
#  Checks and small helpers
# ----------------------------------------------------------------------------
have(){ command -v "$1" >/dev/null 2>&1; }

require_root(){
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Run this as root:  sudo ghost-tunnel"
    exit 1
  fi
}

require_tty(){
  if [[ ! -r /dev/tty ]]; then
    fail "An interactive terminal is required."
    exit 1
  fi
}

apt_install(){
  have apt-get || { fail "This installer supports Debian and Ubuntu (apt-get)."; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update -y >/dev/null 2>&1; then
    warn "apt-get update reported errors; continuing."
  fi
  if ! apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1; then
    fail "Could not install packages: $*"
    return 1
  fi
}

download(){ # download URL DEST
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$2" "$1"
}

detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) fail "Unsupported CPU architecture: $(uname -m)"; return 1 ;;
  esac
}

is_ipv4(){
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

is_domain(){ [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

port_in_use(){ ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":$1\$" >/dev/null; }

public_ip(){
  local url ip
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

is_installed(){ [[ -x "$PANEL_BIN" && -f "$CONF_FILE" ]]; }

installed_version(){
  # Always prints exactly one leading "v", whatever the file contains.
  local v=""
  if [[ -f "$VERSION_FILE" ]]; then v="$(head -n 1 "$VERSION_FILE" | tr -d '[:space:]')"; fi
  v="${v#v}"
  if [[ -n "$v" ]]; then printf 'v%s\n' "$v"; else printf 'unknown\n'; fi
}

conf_get(){ # conf_get KEY -> prints value from the panel config
  [[ -f "$CONF_FILE" ]] || return 1
  sed -n "s/^ *\"$1\": *\"\?\([^\",]*\)\"\?,\?$/\1/p" "$CONF_FILE" | head -n 1
}

# ----------------------------------------------------------------------------
#  Releases
# ----------------------------------------------------------------------------
latest_release_tag(){
  if [[ -n "${GT_PANEL_VERSION:-}" ]]; then
    echo "$GT_PANEL_VERSION"
    return 0
  fi
  local json
  json="$(curl -fsSL --retry 2 --connect-timeout 10 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${GT_REPO}/releases/latest" 2>/dev/null)" || return 1
  sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<<"$json" | head -n 1
}

asset_base(){ # asset_base TAG
  echo "${GT_ASSET_BASE:-https://github.com/${GT_REPO}/releases/download/$1}"
}

_fetch_panel_into(){ # _fetch_panel_into TAG DEST TMPDIR ASSET BASE
  local tag="$1" dest="$2" tmp="$3" asset="$4" base="$5"

  info "Downloading panel ${tag} (${asset#ghost-panel-linux-})..."
  download "${base}/${asset}" "${tmp}/${asset}" || { fail "Could not download ${asset} from ${base}"; return 1; }
  download "${base}/checksums.txt" "${tmp}/checksums.txt" || { fail "Could not download checksums.txt"; return 1; }

  awk -v f="$asset" '{ n = $2; sub(/^\*/, "", n); if (n == f) print }' "${tmp}/checksums.txt" > "${tmp}/one.sha"
  if [[ ! -s "${tmp}/one.sha" ]]; then
    fail "No checksum entry for ${asset}."
    return 1
  fi
  if ! (cd "$tmp" && sha256sum -c one.sha >/dev/null 2>&1); then
    fail "Checksum mismatch. The download was discarded."
    return 1
  fi
  install -m 0755 "${tmp}/${asset}" "$dest"
}

fetch_panel_binary(){ # fetch_panel_binary TAG DEST
  local tag="$1" dest="$2" arch asset tmp rc=0
  arch="$(detect_arch)" || return 1
  asset="ghost-panel-linux-${arch}"
  tmp="$(mktemp -d)"
  _fetch_panel_into "$tag" "$dest" "$tmp" "$asset" "$(asset_base "$tag")" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

update_menu_script(){
  local tmp
  tmp="$(mktemp)"
  if download "https://raw.githubusercontent.com/${GT_REPO}/${GT_BRANCH}/install.sh" "$tmp" \
     && [[ "$(head -n1 "$tmp")" == '#!'*bash* ]] && bash -n "$tmp" 2>/dev/null; then
    if cmp -s "$tmp" "$MENU_BIN" 2>/dev/null; then
      ok "Management menu is already the latest version from ${GT_REPO} (${GT_BRANCH})."
    else
      # Write beside the command and rename, so the running menu is never overwritten in place.
      install -m 0755 "$tmp" "${MENU_BIN}.new" && mv -f "${MENU_BIN}.new" "$MENU_BIN"
      mkdir -p "$RUN_DIR" && : > "$MENU_RELOAD_FLAG"
      ok "Management menu updated. It reloads now."
    fi
  else
    warn "The management menu could not be refreshed. The current version was kept."
  fi
  rm -f "$tmp"
}

install_menu_command(){
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    if [[ "$(readlink -f "$src")" != "$(readlink -f "$MENU_BIN" 2>/dev/null || echo "$MENU_BIN")" ]]; then
      install -m 0755 "$src" "$MENU_BIN"
    fi
  else
    update_menu_script
    return 0
  fi
  ok "Command installed: ghost-tunnel"
}

wait_for_panel(){
  local port i
  port="$(conf_get port)" || return 1
  for i in $(seq 1 30); do
    if curl -ksf --max-time 3 "https://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ----------------------------------------------------------------------------
#  Certificates and service
# ----------------------------------------------------------------------------
make_self_signed(){ # make_self_signed IP
  local ip="$1"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/cert.pem" \
    -subj "/CN=${ip}" -addext "subjectAltName=IP:${ip}" >/dev/null 2>&1 \
    || { fail "Could not create the self-signed certificate."; return 1; }
  chmod 600 "${TLS_DIR}/key.pem"
}

issue_letsencrypt(){ # issue_letsencrypt DOMAIN EMAIL
  local domain="$1" email="$2"
  local -a args=()
  if [[ -n "$email" ]]; then
    args+=(-m "$email")
  else
    args+=(--register-unsafely-without-email)
  fi
  apt_install certbot || return 1
  if port_in_use 80; then
    fail "Port 80 is in use. Certbot needs it briefly to verify the domain. Free it and try again."
    return 1
  fi
  if ! certbot certonly --standalone --non-interactive --agree-tos \
       "${args[@]}" -d "$domain" --keep-until-expiring; then
    fail "The certificate request failed. Check that the domain points to this server and port 80 is reachable."
    return 1
  fi
}

install_renew_hook(){
  mkdir -p "$(dirname "$RENEW_HOOK")"
  cat >"$RENEW_HOOK" <<'EOF'
#!/usr/bin/env bash
# Restart the panel after certbot renews its certificate.
systemctl try-restart ghost-tunnel-panel.service
EOF
  chmod 755 "$RENEW_HOOK"
}

write_unit(){
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Ghost Tunnel 8 control panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PANEL_BIN} serve --config ${CONF_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
# Only the panel process is stopped on restart. Tunnels run in their own
# screen sessions and keep running while the panel restarts or updates.
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ----------------------------------------------------------------------------
#  Tunnel status helpers
# ----------------------------------------------------------------------------
tunnel_running(){ # tunnel_running ID
  screen -ls 2>/dev/null | awk -v id="$1" \
    '$1 ~ ("[.]gtunnel_" id "$") && index($0, "Dead") == 0 { found = 1 } END { exit found ? 0 : 1 }'
}

count_tunnels(){ # prints "TOTAL RUNNING"
  local total=0 running=0 f id
  if [[ -d "$PROFILES_DIR" ]]; then
    for f in "$PROFILES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      total=$((total + 1))
      id="$(basename "$f" .env)"
      if tunnel_running "$id"; then running=$((running + 1)); fi
    done
  fi
  echo "$total $running"
}

# ============================================================================
#  Actions
# ============================================================================
do_install(){
  if is_installed; then
    warn "Ghost Tunnel is already installed (version $(installed_version))."
    info "Use [2] Update to upgrade, or [3] Uninstall for a clean reinstall."
    return 0
  fi
  have systemctl || { fail "systemd is required."; return 1; }
  detect_arch >/dev/null || return 1

  step "1/6  Installing required packages"
  apt_install screen curl openssl ca-certificates iproute2 || return 1
  mkdir -p "$CONF_DIR" "$TLS_DIR" "$PROFILES_DIR"

  step "2/6  Panel address and certificate"
  local address cert_file key_file email
  if confirm "Do you have a domain name that points to this server?"; then
    address="$(ask "Domain (for example panel.example.com)")" || return 1
    address="${address,,}"
    is_domain "$address" || { fail "Invalid domain: ${address}"; return 1; }
    email="$(ask "E-mail for certificate notices (optional, press Enter to skip)" "")" || return 1
    issue_letsencrypt "$address" "$email" || return 1
    cert_file="/etc/letsencrypt/live/${address}/fullchain.pem"
    key_file="/etc/letsencrypt/live/${address}/privkey.pem"
    install_renew_hook
    ok "Trusted certificate issued for ${address}."
  else
    address="$(public_ip || true)"
    if [[ -z "$address" ]]; then
      address="$(ask "Could not detect the public IP. Enter this server's IPv4 address")" || return 1
    fi
    is_ipv4 "$address" || { fail "Invalid IPv4 address: ${address}"; return 1; }
    make_self_signed "$address" || return 1
    cert_file="${TLS_DIR}/cert.pem"
    key_file="${TLS_DIR}/key.pem"
    ok "Panel address set to IP: ${address}"
    warn "An IP address cannot get a trusted certificate. Your browser will show a warning; you can continue past it."
  fi

  local port
  while true; do
    port="$(ask "Panel HTTPS port" "$DEFAULT_PORT")" || return 1
    if [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); then
      port=$((10#$port))
      if port_in_use "$port"; then
        warn "Port ${port} is already in use. Choose another port."
      else
        break
      fi
    else
      warn "Enter a number from 1 to 65535."
    fi
  done

  step "3/6  Panel program"
  local tag
  tag="$(latest_release_tag)" || {
    fail "Could not read the latest release from GitHub (${GT_REPO}). For a mirror, set GT_PANEL_VERSION and GT_ASSET_BASE."
    return 1
  }
  fetch_panel_binary "$tag" "$PANEL_BIN" || return 1
  echo "$tag" > "$VERSION_FILE"
  ok "Panel ${tag} installed."

  step "4/6  Administrator account"
  account_setup "$address" "$port" "$cert_file" "$key_file" || return 1

  step "5/6  License"
  license_setup || return 1
  step "6/6  Starting the panel service"
  write_unit
  if ! systemctl enable --now "$SERVICE" >/dev/null 2>&1; then
    fail "The panel service could not be started. Recent log lines:"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    return 1
  fi
  install_menu_command || return 1
  if ! wait_for_panel; then
    fail "The panel did not answer. Open [4] Logs for details."
    return 1
  fi
  ok "Panel is running."

  print_box "Installation complete" \
    "Panel address : https://${address}:${port}" \
    "Username      : ${username}" \
    "Password      : the one you just set" \
    "Menu command  : sudo ghost-tunnel"
  info "Open the panel address in your browser and sign in."
}

do_update(){
  is_installed || { fail "Ghost Tunnel is not installed. Choose [1] Install first."; return 1; }
  local current latest
  current="$(installed_version)"
  info "Installed version : ${current}"
  info "Checking GitHub for a newer release..."
  latest="$(latest_release_tag)" || { fail "Could not reach GitHub (${GT_REPO}). Check the server's internet access."; return 1; }

  if [[ "$latest" == "$current" ]]; then
    ok "Already up to date (${latest})."
    update_menu_script
    return 0
  fi

  warn "A new version is available: ${latest} (installed: ${current}). Updating now..."

  fetch_panel_binary "$latest" "${PANEL_BIN}.new" || return 1
  cp -f "$PANEL_BIN" "${PANEL_BIN}.bak" 2>/dev/null || true
  mv -f "${PANEL_BIN}.new" "$PANEL_BIN"
  echo "$latest" > "$VERSION_FILE"
  update_menu_script
  systemctl restart "$SERVICE"
  if wait_for_panel; then
    rm -f "${PANEL_BIN}.bak"
    ok "Panel updated to ${latest} and is running. Tunnels were not affected."
    return 0
  fi

  warn "The new panel did not start. Restoring the previous version..."
  if [[ -f "${PANEL_BIN}.bak" ]]; then
    mv -f "${PANEL_BIN}.bak" "$PANEL_BIN"
    echo "$current" > "$VERSION_FILE"
    systemctl restart "$SERVICE" || true
  fi
  fail "The update was rolled back to ${current}. Open [4] Logs for details."
  return 1
}

do_uninstall(){
  warn "This removes the panel, the ghost-tunnel command, every tunnel profile and all running tunnels."
  if ! confirm "Delete Ghost Tunnel completely from this server?"; then
    info "Uninstall cancelled. Returning to the main menu."
    return 0
  fi

  step "Stopping tunnels"
  local f id
  if [[ -d "$PROFILES_DIR" ]]; then
    for f in "$PROFILES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      id="$(basename "$f" .env)"
      screen -S "gtunnel_${id}" -X quit >/dev/null 2>&1 || true
    done
  fi
  ok "Tunnel sessions stopped."

  step "Removing the scheduled task and leftovers of the original script"
  rm -f /usr/local/bin/Ghost-Tunnel.8

  step "Removing the panel"
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$PANEL_BIN" "${PANEL_BIN}.new" "${PANEL_BIN}.bak" "$SYSCTL_FILE" "$RENEW_HOOK"
  rm -rf "$CONF_DIR" "$LEGACY_CORE_DIR" "$RUN_DIR"
  rm -f "$ADMIN_NOTE_FILE"
  ok "Panel, configuration and tunnel profiles removed."

  info "Let's Encrypt certificates were kept (managed by certbot)."
  info "BBR stays active until the next reboot."
  rm -f "$MENU_BIN"
  ok "Ghost Tunnel has been uninstalled."
}

tunnel_status(){
  if [[ ! -d "$PROFILES_DIR" ]] || ! compgen -G "${PROFILES_DIR}/*.env" >/dev/null; then
    info "No tunnels are configured."
    return 0
  fi
  local f id role label state
  printf '  %-10s %-8s %s\n' "TUNNEL" "ROLE" "STATUS"
  for f in "$PROFILES_DIR"/*.env; do
    id="$(basename "$f" .env)"
    role="$(grep -E '^ROLE=' "$f" | head -n1 | cut -d= -f2 || true)"
    label="EU"
    [[ "$role" == "iran" ]] && label="Iran"
    if tunnel_running "$id"; then
      state="${C_GREEN}running${C_RESET}"
    else
      state="${C_RED}stopped${C_RESET}"
    fi
    printf '  %-10s %-8s %s\n' "$id" "$label" "$state"
  done
}

do_logs(){
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '%s========================================================%s\n' "$C_CYAN" "$C_RESET"
    printf '  %sLogs%s\n' "$C_BOLD" "$C_RESET"
    printf '%s========================================================%s\n' "$C_CYAN" "$C_RESET"
    printf '  [1] Panel log (last 200 lines)\n'
    printf '  [2] Live panel log (Ctrl+C to stop)\n'
    printf '  [3] Tunnel status\n'
    printf '  [0] Back\n\n'
    choice="$(ask "Select")" || return 0
    case "$choice" in
      1)
        journalctl -u "$SERVICE" -n 200 --no-pager || true
        pause
        ;;
      2)
        trap ':' INT
        journalctl -u "$SERVICE" -f || true
        trap - INT
        ;;
      3)
        echo
        tunnel_status
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid choice." ; sleep 1 ;;
    esac
  done
}

# ============================================================================
#  Main menu
# ============================================================================
show_header(){
  local status="Not installed" svc="-" addr="-" total running
  if is_installed; then
    status="${C_GREEN}✔${C_RESET} Installed ($(installed_version))"
    svc="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    if [[ "$svc" == "active" ]]; then
      svc="${C_GREEN}✔${C_RESET} active"
    else
      svc="${C_RED}✘${C_RESET} ${svc:-unknown}"
    fi
    addr="https://$(conf_get address 2>/dev/null || echo '?'):$(conf_get port 2>/dev/null || echo '?')"
  else
    status="${C_RED}✘${C_RESET} Not installed"
  fi
  read -r total running <<<"$(count_tunnels)"

  clear 2>/dev/null || true
  printf '%s========================================================%s\n' "$C_CYAN" "$C_RESET"
  printf '  %s%sGhost Tunnel 8%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '%s========================================================%s\n' "$C_CYAN" "$C_RESET"
  printf '  %-10s : %s\n' "Panel" "$status"
  printf '  %-10s : %s\n' "Service" "$svc"
  printf '  %-10s : %s\n' "Address" "$addr"
  printf '  %-10s : %s configured, %s running\n' "Tunnels" "$total" "$running"
  printf '%s--------------------------------------------------------%s\n' "$C_DIM" "$C_RESET"
  printf '  [1] Install\n'
  printf '  [2] Update\n'
  printf '  [3] Change admin username and password\n'
  printf '  [4] Uninstall\n'
  printf '  [5] Logs\n'
  printf '  [6] Exit\n'
  printf '%s--------------------------------------------------------%s\n' "$C_DIM" "$C_RESET"
}

license_setup(){
  local key out
  while true; do
    key="$(ask_secret "Paste the license key you received")" || return 1
    if [[ -z "$key" ]]; then
      warn "A license key is required."
      continue
    fi
    if out="$(printf '%s\n' "$key" | "$PANEL_BIN" license import --config "$CONF_FILE" 2>&1)"; then
      ok "License accepted: ${out#license installed for }"
      unset key out
      return 0
    fi
    warn "${out:-The license key was rejected.}"
  done
}

account_setup(){ # account_setup ADDRESS PORT CERT_FILE KEY_FILE
  local address="$1" port="$2" cert_file="$3" key_file="$4"
  local username pass1 pass2 existing
  existing="$(conf_get username 2>/dev/null || true)"
  if [[ -n "$existing" ]] && ! confirm "Do you want to change the username and password?"; then
    "$PANEL_BIN" setup --keep-credentials --config "$CONF_FILE" --address "$address" --port "$port" \
      --cert "$cert_file" --key "$key_file" </dev/null >/dev/null \
      || { fail "Saving the panel settings failed."; return 1; }
    ok "The current administrator account is kept."
  else
    while true; do
      username="$(ask "Username" "${existing:-admin}")" || return 1
      if [[ "$username" =~ ^[A-Za-z0-9_.-]{3,32}$ ]]; then break; fi
      warn "Use 3 to 32 letters, digits, dot, dash or underscore."
    done
    while true; do
      pass1="$(ask_secret "Password (at least 12 characters)")" || return 1
      if (( ${#pass1} < 12 )); then
        warn "The password is too short."
        continue
      fi
      pass2="$(ask_secret "Repeat the password")" || return 1
      if [[ "$pass1" != "$pass2" ]]; then
        warn "The passwords do not match."
        continue
      fi
      break
    done
    printf '%s\n' "$pass1" | "$PANEL_BIN" setup \
      --config "$CONF_FILE" --address "$address" --port "$port" --username "$username" \
      --cert "$cert_file" --key "$key_file" >/dev/null \
      || { fail "Saving the panel settings failed."; return 1; }

    if confirm "Save the username and password to ${ADMIN_NOTE_FILE} (readable by root only)?"; then
      (
        umask 077
        printf 'Panel URL : https://%s:%s/\nUsername  : %s\nPassword  : %s\n' \
          "$address" "$port" "$username" "$pass1" > "$ADMIN_NOTE_FILE"
      ) || { fail "The credentials file could not be written."; return 1; }
      chmod 600 "$ADMIN_NOTE_FILE"
      ok "Credentials saved to ${ADMIN_NOTE_FILE} (root only)."
    else
      warn "The password was not saved. Write it down now, it cannot be shown again."
    fi
    unset pass1 pass2
    ok "Administrator account saved."
  fi
}

do_account(){
  if ! is_installed; then
    fail "The panel is not installed. Install it first."
    return 1
  fi
  local address port cert_file key_file
  address="$(conf_get address)" || { fail "The panel settings cannot be read."; return 1; }
  port="$(conf_get port)" || { fail "The panel settings cannot be read."; return 1; }
  cert_file="$(conf_get cert_file)" || { fail "The panel settings cannot be read."; return 1; }
  key_file="$(conf_get key_file)" || { fail "The panel settings cannot be read."; return 1; }
  account_setup "$address" "$port" "$cert_file" "$key_file" || return 1
  systemctl restart "$SERVICE" >/dev/null 2>&1 || { fail "The panel could not be restarted."; return 1; }
  ok "The panel restarted with the administrator account."
}

main(){
  require_root
  require_tty

  if [[ "$GT_REPO" == *USERNAME* ]]; then
    fail "GT_REPO is not configured. Set it to your GitHub repository (owner/name) at the top of install.sh."
    exit 1
  fi

  while true; do
    show_header
    local choice
    choice="$(ask "Select an option")" || exit 0
    case "$choice" in
      1) ( do_install ) || true; pause ;;
      2) ( do_update ) || true; pause ;;
      3) ( do_account ) || true; pause ;;
      4) ( do_uninstall ) || true; pause ;;
      5) ( do_logs ) || true ;;
      6) ok "Goodbye."; exit 0 ;;
      *) warn "Invalid choice: ${choice}"; sleep 1 ;;
    esac
    if [[ -f "$MENU_RELOAD_FLAG" ]]; then
      rm -f "$MENU_RELOAD_FLAG"
      exec "$MENU_BIN"
    fi
  done
}

main "$@"

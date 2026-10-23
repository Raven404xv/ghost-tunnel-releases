# Ghost Tunnel 8

A reverse-tunnel manager for an EU server and an Iran server, with a web control
panel. The management menu is a Bash script; the panel is a single Go binary
with no external dependencies.

## Install

On the server (Debian or Ubuntu, as root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Raven404xv/ghost-tunnel/main/install.sh)
```

The management menu opens:

| Option | What it does |
|--------|--------------|
| 1 Install   | Installs packages, asks for a domain or IP, a port and the admin account, then starts the panel |
| 2 Update    | Checks GitHub for a newer release and updates the panel. Tunnels keep running |
| 3 Uninstall | Asks for confirmation (`y` deletes everything, `n` returns to the menu) |
| 4 Logs      | Panel log, live panel log, and tunnel status |
| 5 Exit      | Closes the menu |

After installation, open the panel address in a browser and sign in. Later, run
the menu with:

```bash
sudo ghost-tunnel
```

### Domain or IP

- **Domain:** the installer requests a trusted certificate from Let's Encrypt.
  The domain must already point to this server, and port 80 must be reachable
  during the request. The certificate renews automatically.
- **IP address:** the installer creates a self-signed certificate. The browser
  will show a warning, which you can accept.

## Panel

- Dashboard: server status (online/offline and latency), CPU, memory and disk,
  and the tunnel list with start and stop.
- Tunnel setup: create, edit and delete tunnels, with an optional scheduled restart
  interval per tunnel. Running tunnels restart automatically after a change.
- Settings: panel address, administrator username and password, auto-reconnect,
  and TCP tuning (BBR).
- Language: English and Persian (فارسی), switchable on the sign-in page and in the panel.

**Auto-reconnect** (Settings): when enabled, the panel checks every 20 seconds and
starts any configured tunnel that has stopped or failed. A tunnel you stopped by
hand is not started again while this is on, so turn it off if you stop tunnels on purpose.

**Scheduled restart** (Tunnel setup, per tunnel): restarts that tunnel every N minutes
(0 = off). The restart stops and starts the tunnel again, which causes a brief
interruption of a second or two. Connections that are already open are dropped.
It cannot be fully seamless because the same bridge port is reused.

**Updates** (menu option 2): when GitHub has a newer release, the panel is updated
automatically. The previous binary is kept until the new one starts; if the new one
does not start, it is restored. Tunnels keep running during the update.

Tunnel profiles are stored in `/etc/ghost-tunnel/profiles/*.env`, and each tunnel runs in a
`screen` session named `gtunnel_<id>`.

## Requirements

- Debian or Ubuntu with systemd, root access
- Internet access to GitHub (see the note below for mirrors)
- Installed by the installer: `screen`, `curl`, `openssl`, `iproute2`,
  and `certbot` (only when a domain is used)

## Configuration

Set these at the top of `install.sh`, or as environment variables when running it:

| Variable | Default | Purpose |
|----------|---------|---------|
| `GT_REPO` | `Raven404xv/ghost-tunnel` | GitHub repository that hosts the releases. **Must be set.** |
| `GT_BRANCH` | `main` | Branch used to refresh the menu script |
| `GT_PANEL_VERSION` | latest release | Pin a panel version, skipping the GitHub API call |
| `GT_ASSET_BASE` | GitHub release URL | Mirror for the panel binary and `checksums.txt` |

### Servers in Iran

If GitHub is blocked or slow from the Iran server, host the release assets
(`ghost-panel-linux-*` and `checksums.txt`) on a mirror
you can reach, then run:

```bash
GT_ASSET_BASE=https://mirror.example.com/ghost-tunnel \
GT_PANEL_VERSION=v1.0.0 \
bash <(curl -fsSL https://mirror.example.com/install.sh)
```

## Publishing a release

1. Replace `Raven404xv/ghost-tunnel` in `install.sh` with your repository.
2. Commit and push to GitHub.
3. Create a tag, for example `git tag v1.0.0 && git push origin v1.0.0`.

The workflow in `.github/workflows/release.yml` builds `ghost-panel` for
linux/amd64 and linux/arm64, writes `checksums.txt`, and publishes them as a
release. The installer downloads the binary for the server's architecture and
checks it against `checksums.txt` before installing.

## Project layout

```
install.sh                  installer, updater and management menu
panel/
  main.go                   subcommands: serve, setup, version
  config.go                 config file, PBKDF2-SHA256 password hashing
  tunnels.go                tunnel profiles, validation, screen sessions, logs
  status.go                 CPU, memory, disk and peer reachability
  server.go                 HTTPS server, sessions, rate limiting, API, watchdog
  web/index.html            web UI (embedded in the binary)
.github/workflows/release.yml
```

## Security notes

- The panel is served only over HTTPS.
- Passwords are stored as PBKDF2-SHA256 hashes (200,000 iterations).
- Sessions use HttpOnly, Secure and SameSite=Strict cookies, expire after 30
  minutes of inactivity, and are cleared when the account changes.
- Sign-in is limited to 5 failed attempts per IP, followed by a 60-second lock.
- The config file is written with mode 0600.
- The panel runs as root because it manages screen sessions and kernel TCP
  settings, as the original script did.

## Uninstall

Choose `[3] Uninstall` in the menu. It stops tunnels, removes the panel and its
configuration, and removes the `ghost-tunnel` command. Let's Encrypt certificates
are kept, and the BBR setting stays active until the next reboot.

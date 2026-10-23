# Ghost Tunnel 8

Reverse-tunnel manager for an **EU server** and an **Iran server**, with a web control panel.

- The management menu is a Bash script (`install.sh`).
- The panel is a single Go program with no external dependencies.
- A valid license key is required to use the panel.

## Requirements

- A server running **Debian or Ubuntu** (x86_64 or arm64), with root access.
- A domain name pointing to the server, or the server's public IP address.
- Port 80 (for the domain certificate) and the panel port (default `8443`) open in the firewall.

## Install

Log in to the server as `root` and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Raven404xv/ghost-tunnel-releases/main/install.sh)
```

Then choose **1 Install** and answer the questions:

1. **Server address**: a domain name, or the server's IPv4 address.
2. **Panel port**: press Enter to keep `8443`.
3. **Administrator account**: choose a username and a password of at least 12 characters.
4. **License key**: paste the key you received.
5. The panel service starts automatically.

Open the panel in a browser:

```
https://YOUR-SERVER-ADDRESS:8443
```

If you used an IP address, the browser shows a warning because the certificate is self-signed. This is expected; continue to the panel.

## Management menu

Run this command on the server at any time:

```bash
ghost-tunnel
```

| Option | What it does |
|---|---|
| 1 Install | Installs the panel (only when it is not installed yet) |
| 2 Update | Updates the panel and the menu |
| 3 Change admin username and password | Changes the panel login |
| 4 Uninstall | Removes the panel and its settings |
| 5 Logs | Shows the panel logs |
| 6 Exit | Closes the menu |

## Licensing

The panel works only with a valid license. A license is bound to a customer, may have an expiry date, and may be bound to one server address. To activate a new license later, open the panel; if no valid license is installed, the activation screen appears automatically.

## Help

If the installation stops with an error, copy the error message and contact the vendor. Do not share your administrator password or your license key publicly.

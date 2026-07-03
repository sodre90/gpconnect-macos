# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo contains two related but independently-built tools for authenticating to GlobalProtect VPNs that require SAML SSO login, then connecting via OpenConnect:

1. **`gp_saml_gui.py`** (Python, macOS/Windows) — the original interactive SAML login helper, now pywebview-only (Linux/GTK support was removed). Opens a webview, drives the SAML login flow, extracts the resulting auth cookie, and either prints shell variables, execs `openconnect` directly, or hands off to the privileged helper daemon.
2. **`helper/`** (Python daemon, macOS) — a small root-owned `launchd` daemon that lets the above (and GPConnect) spawn `openconnect` without repeated `sudo` prompts.
3. **`GPConnect/`** (Swift, macOS) — a native menu bar app + CLI that reimplements the SAML login flow with `WKWebView` and talks to the same helper daemon. See `GPConnect/CLAUDE.md` for its architecture and build quirks — this file only covers the Python side.

## Commands (Python side)

Install dependencies:
```sh
pip install -r requirements.txt
```
`requirements.txt` lists `requests` and `pywebview` — pywebview is the only webview backend; there is no GTK/WebKit2 code path anymore.

Run interactively:
```sh
./gp_saml_gui.py -g <gateway-hostname> -- -s 'vpn-slice 10.0.0.0/8'
```

Lint (matches CI in `.github/workflows/test.yml`):
```sh
flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics
flake8 . --count --exit-zero --max-complexity=10 --max-line-length=127 --statistics
```

Compile check (also run in CI, there is no automated test suite):
```sh
python -m py_compile gp_saml_gui.py test-globalprotect-login.py
```
`test-globalprotect-login.py` is a standalone manual script for replaying a non-interactive login against a known cookie/endpoint — it is not a pytest suite and isn't invoked by CI beyond the compile check.

Privileged helper daemon (macOS, install/uninstall require sudo):
```sh
sudo helper/install.sh      # installs to /Library/PrivilegedHelperTools, registers launchd daemon
sudo helper/uninstall.sh
tail /var/log/openconnect-helper.log   # daemon stdout/stderr
```

## Architecture (Python side)

`gp_saml_gui.py` flow: `parse_args` → POST to `.../prelogin.esp` and parse the `<saml-auth-method>`/`<saml-request>` tags out of the XML response → open a pywebview window pointed at the SAML entry point → watch page loads for the SAML result (`saml-username` plus `prelogin-cookie` or `portal-userauthcookie`) → once both are present, build the equivalent `openconnect` command line and either print `HOST`/`USER`/`COOKIE`/`OS` env vars, `execvp` openconnect directly (`-S`), or JSON-encode `{args, cookie}` and send it over the helper daemon's Unix socket (`-D`).

`SAMLLoginView` can't inspect real HTTP response headers (pywebview has no API for that), so it always scrapes the final page's `outerHTML` via injected JS (`get_saml_headers`) looking for `<saml-*>`/cookie tags directly in the DOM.

`helper/openconnect_helper` is a tiny root-owned daemon listening on `/var/run/openconnect-helper.sock`. It accepts one JSON message per connection (`{"args": [...], "cookie": "..."}`), spawns `openconnect` with those args, writes the cookie to its stdin, and streams stdout/stderr back over the same socket line-by-line until the process exits or the caller disconnects. This is the same protocol `GPConnect` (Swift) speaks — the daemon has no knowledge of which client (Python script or Swift app) is talking to it.

`TLSAdapter`/`SSLContextAdapter` in `gp_saml_gui.py` exist to work around GlobalProtect gateways running outdated TLS stacks (weak ciphers, legacy renegotiation). Note: `TLSAdapter` is currently dead code (never mounted on the `requests.Session` — `SSLContextAdapter` is what's actually used), and `--allow-insecure-crypto` only forwards a flag to the `openconnect` command line rather than configuring either adapter. Worth a closer look if you're touching TLS handling here.

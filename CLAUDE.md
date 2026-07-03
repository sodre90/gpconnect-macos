# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo contains two related but independently-built tools for authenticating to GlobalProtect VPNs that require SAML SSO login, then connecting via OpenConnect:

1. **`gp_saml_gui.py`** (Python, cross-platform) — the original interactive SAML login helper. Opens a webview, drives the SAML login flow, extracts the resulting auth cookie, and either prints shell variables, execs `openconnect` directly, or hands off to the privileged helper daemon.
2. **`helper/`** (Python daemon, macOS) — a small root-owned `launchd` daemon that lets the above (and GPConnect) spawn `openconnect` without repeated `sudo` prompts.
3. **`GPConnect/`** (Swift, macOS) — a native menu bar app + CLI that reimplements the SAML login flow with `WKWebView` and talks to the same helper daemon. See `GPConnect/CLAUDE.md` for its architecture and build quirks — this file only covers the Python side.

## Commands (Python side)

Install dependencies:
```sh
pip install -r requirements.txt
```
`requirements.txt` lists `requests`, `pygobject`, `pywebview`. GTK/WebKit2 (`pygobject`) is optional on the code path — if `import gi` fails, `gp_saml_gui.py` falls back to `pywebview` automatically (this is the normal/only path on macOS).

Run interactively:
```sh
./gp_saml_gui.py --pywebview -g <gateway-hostname> -- -s 'vpn-slice 10.0.0.0/8'
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

`gp_saml_gui.py` flow: `parse_args` → POST to `.../prelogin.esp` and parse the `<saml-auth-method>`/`<saml-request>` tags out of the XML response → open a webview pointed at the SAML entry point → watch page loads for the SAML result (`saml-username` plus `prelogin-cookie` or `portal-userauthcookie`) → once both are present, build the equivalent `openconnect` command line and either print `HOST`/`USER`/`COOKIE`/`OS` env vars, `execvp` openconnect directly (`-P`/`-S`), or JSON-encode `{args, cookie}` and send it over the helper daemon's Unix socket (`-D`).

Two webview backends exist side by side and both implement the same SAML-detection contract — **changes to that detection logic must be kept in sync across both**:
- `SAMLLoginView` (GTK + WebKit2, Linux) reads the real HTTP response headers via WebKit2's resource-inspection API, and falls back to scanning the response body for HTML comments containing `<saml-*>`/cookie tags (`response_callback`/`CommentHtmlParser`) if headers aren't present.
- `SAMLLoginViewWebview` (pywebview, used on macOS/Windows and whenever `--pywebview` is passed) can't inspect HTTP headers at all, so it always scrapes the final page's `outerHTML` via injected JS (`get_saml_headers`) looking for the same `<saml-*>`/cookie tags directly in the DOM (not just comments).

`helper/openconnect_helper` is a tiny root-owned daemon listening on `/var/run/openconnect-helper.sock`. It accepts one JSON message per connection (`{"args": [...], "cookie": "..."}`), spawns `openconnect` with those args, writes the cookie to its stdin, and streams stdout/stderr back over the same socket line-by-line until the process exits or the caller disconnects. This is the same protocol `GPConnect` (Swift) speaks — the daemon has no knowledge of which client (Python script or Swift app) is talking to it.

`TLSAdapter`/`SSLContextAdapter` in `gp_saml_gui.py` exist to work around GlobalProtect gateways running outdated TLS stacks (weak ciphers, legacy renegotiation) — don't remove them without checking `--allow-insecure-crypto`/`--no-verify` still behave as documented.

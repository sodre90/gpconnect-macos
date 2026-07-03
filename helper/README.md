Privileged Helper Daemon
========================

> **This is the recommended approach for macOS users of `gp-saml-gui`.** If you use
> [GPConnect](../GPConnect/) instead, you don't need any of this — the app offers to install the helper for
> you automatically on first launch.

On macOS, OpenConnect requires root to create a `utun` network interface. The `-P` (pkexec) option is
Linux-only, and `-S` (sudo) prompts for a password every time. This directory contains a small **privileged
helper daemon** that runs as root in the background via `launchd`, so subsequent VPN connections need no
password at all.

Table of Contents
=================

  * [How it works](#how-it-works)
  * [Requirements](#requirements)
  * [Install the helper (once, requires sudo)](#install-the-helper-once-requires-sudo)
  * [Connect to the VPN](#connect-to-the-vpn)
  * [Uninstall the helper](#uninstall-the-helper)

How it works
============

The helper listens on a Unix socket (`/var/run/openconnect-helper.sock`). When you use `gp-saml-gui`'s `-D`
flag (or GPConnect, which speaks the same protocol), the client connects to that socket, sends the
OpenConnect arguments and SAML cookie, and the daemon spawns OpenConnect as root and streams its output
back. Pressing Ctrl+C closes the socket, which terminates OpenConnect cleanly.

Requirements
============

- macOS (Apple Silicon or Intel)
- OpenConnect installed via Homebrew: `brew install openconnect`
- Python 3 (already required by gp-saml-gui)

Install the helper (once, requires sudo)
=========================================

From the repo root:

```sh
sudo helper/install.sh
```

This copies the helper to `/Library/PrivilegedHelperTools/openconnect-helper` and registers it as a
`launchd` system daemon. It starts immediately and restarts automatically on every boot — no further sudo
needed.

To check it is running:

```sh
tail /var/log/openconnect-helper.log
```

Connect to the VPN
===================

Use the `-D` / `--daemon-openconnect` flag instead of `-S` or `-P`:

```sh
gp-saml-gui --pywebview -D --gateway vpn.company.com
```

With `vpn-slice` for split tunnelling (only route specific subnets over the VPN):

```sh
gp-saml-gui --pywebview -D --gateway vpn.company.com -- -s 'vpn-slice 10.0.0.0/8 192.168.0.0/16'
```

As a shell alias in `~/.zshrc` or `~/.bash_profile`:

```sh
alias start-vpn="source /path/to/gp-saml-gui/venv/bin/activate && \
  gp-saml-gui --pywebview -D --gateway vpn.company.com -- \
  -s 'vpn-slice 10.0.0.0/8 192.168.0.0/16'"
```

Uninstall the helper
=====================

```sh
sudo helper/uninstall.sh
```

GPConnect
=========

A native macOS menu bar app (and companion CLI) for logging into GlobalProtect VPNs that require SAML SSO,
in the spirit of the original GlobalProtect client's menu bar icon — built on top of this repo's
[privileged helper daemon](../README.md#macos-privileged-helper-no-sudo-prompts), so connecting never prompts
for `sudo`.

Table of Contents
=================

  * [Features](#features)
  * [Requirements](#requirements)
  * [Build](#build)
  * [Install](#install)
  * [Usage](#usage)
    * [Menu bar app](#menu-bar-app)
    * [CLI](#cli)
  * [Configuration](#configuration)
  * [Known limitations](#known-limitations)

Features
========

- Menu bar icon showing connection state (disconnected / connecting / connected / error), with an animated
  icon while a connection is in progress
- Connect/disconnect from the menu bar dropdown
- Built-in SAML login window (`WKWebView`) — no separate browser needed
- Editable list of split-tunnel IP ranges (add/remove/enable/disable/import), stored in a JSON config file
  shared with the CLI
- A `gpconnect` CLI for scripting: status, listing/editing IP ranges, reading config

Requirements
============

- macOS 14.0 or newer
- [OpenConnect](https://www.infradead.org/openconnect/) installed via Homebrew: `brew install openconnect`
- The [privileged helper daemon](../README.md#macos-privileged-helper-no-sudo-prompts) from this repo,
  installed once with `sudo ../helper/install.sh`
- Xcode Command Line Tools (`xcode-select --install`) — a full Xcode install is **not** required to build

Build
=====

```sh
cd GPConnect
./build.sh
```

This builds both the app (`.build/app/GPConnect.app`) and the CLI (`.build/release/gpconnect`). It uses
`swiftc`/`swift build` directly rather than `xcodebuild`, so it works with just the Command Line Tools —
see [CLAUDE.md](CLAUDE.md) for why.

`GPConnect.xcodeproj` is included (generated via `xcodegen generate` from `project.yml`) purely so editors
get proper Swift diagnostics and autocomplete; it isn't used to produce the shipped build.

Install
=======

```sh
cp -R .build/app/GPConnect.app /Applications/
cp .build/release/gpconnect /usr/local/bin/
open /Applications/GPConnect.app
```

If `/Applications/GPConnect.app` already exists and was installed with `sudo`, remove it first
(`sudo rm -rf /Applications/GPConnect.app`) before copying a plain (non-sudo) rebuild over it, or the copy
will fail with a permissions error on the app bundle's extended attributes.

Usage
=====

Menu bar app
------------

Click the shield icon to open the dropdown: **Connect** starts the SAML login flow in its own window; once
you finish authenticating, GPConnect starts `openconnect` via the privileged helper daemon and the icon
turns into a checkmark shield once the tunnel is up. **Disconnect** tears it down. **Edit Ranges...** opens
a window to manage the split-tunnel IP ranges. **Settings...** lets you change the gateway address and
User-Agent string.

CLI
---

```sh
gpconnect status                                     # connection + helper daemon status
gpconnect ranges                                      # list all IP ranges
gpconnect ranges add --cidr 10.5.0.0/16 --label "New"
gpconnect ranges remove --cidr 10.5.0.0/16
gpconnect ranges enable --cidr 10.5.0.0/16
gpconnect ranges disable --cidr 10.5.0.0/16
gpconnect vpn-slice-args                              # print enabled ranges as a vpn-slice argument string
gpconnect config                                      # show gateway / user-agent
gpconnect config set --gateway vpn.company.com
```

Configuration
=============

Both the app and the CLI read/write the same file:

```
~/Library/Application Support/GPConnect/config.json
```

It's plain JSON (gateway address, User-Agent, and a list of `{cidr, label, enabled}` IP ranges) — safe to
edit by hand, via the app's "Edit Ranges..." window, or via `gpconnect ranges`/`gpconnect config set`.

Known limitations
=================

- **FIDO2/WebAuthn (Touch ID) 2FA does not work** in the in-app SAML login window. It requires the
  `com.apple.developer.web-browser` entitlement, which in turn requires signing with a real Apple Developer
  identity — the ad-hoc signing this project currently uses can't carry that entitlement. Password/TOTP-based
  2FA is unaffected. See [CLAUDE.md](CLAUDE.md) for details if you have a Developer ID and want to fix this.

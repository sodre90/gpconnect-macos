gp-saml-gui
===========

Table of Contents
=================

  * [Introduction](#introduction)
  * [GPConnect: native macOS menu bar app](#gpconnect-native-macos-menu-bar-app)
    * [Screenshots](#screenshots)
    * [Features](#features)
    * [GPConnect requirements](#gpconnect-requirements)
    * [Download a release](#download-a-release)
    * [Build from source](#build-from-source)
    * [Install GPConnect](#install-gpconnect)
    * [Usage](#usage)
    * [Configuration](#configuration)
    * [Known limitations](#known-limitations)
  * [Installation](#installation)
  * [How to use](#how-to-use)
    * [Extra arguments to OpenConnect](#extra-arguments-to-openconnect)
  * [macOS: Privileged Helper (no sudo prompts)](#macos-privileged-helper-no-sudo-prompts)
  * [License](#license)

Introduction
============

The main goal of this repo is to make **split tunneling** easy on GlobalProtect VPNs that require
[SAML](https://en.wikipedia.org/wiki/Security_Assertion_Markup_Language) single-sign-on (SSO) — routing only
specific subnets over the VPN via OpenConnect's `vpn-slice`, instead of sending all your traffic through it.
SAML logins can't be scripted the way username/password logins can, so this repo handles that step for you,
then connects with [OpenConnect](https://www.infradead.org/openconnect). (The GlobalProtect protocol is
supported in OpenConnect v8.0 or newer; v8.06+ is recommended.) It provides three pieces that work together:

- **`gp-saml-gui`** — a Python script (macOS/Windows) that drives the SAML login in a webview and hands the
  resulting session to `openconnect`
- **GPConnect** — a native macOS menu bar app and **`gpconnect`** CLI wrapping the same flow, with
  connect/disconnect status and an editable list of split-tunnel IP ranges (see below)
- **A privileged helper daemon** (macOS) so either of the above can start `openconnect` as root without
  repeated `sudo` prompts

This is known to work with many GlobalProtect VPNs using the major single-sign-on (SSO) providers:

- Okta (sign-in URLs typically `https://<company>.okta.com/login/*`)
- Microsoft (sign-in URLs typically `https://login.microsoftonline.com/*`)

Please search and file [issues](https://github.com/sodre90/gpconnect-macos/issues) if you can report success
or failure with other SSO SAML providers.

GPConnect: native macOS menu bar app
=====================================

**macOS users:** in addition to the Python script below, this repo includes **GPConnect** ([`GPConnect/`](GPConnect/)),
a native Swift menu bar (status bar) app plus a companion CLI, in the spirit of the original GlobalProtect
client's menu bar icon. It gives you a GlobalProtect-style icon in the menu bar with connect/disconnect,
live status, and an editable list of split-tunnel IP ranges — all backed by the same privileged helper
daemon described below, so connecting never prompts for `sudo`.

Screenshots
-----------

| Menu bar dropdown | IP Ranges editor | Settings |
| --- | --- | --- |
| ![Menu bar dropdown](GPConnect/screenshots/menu-bar-dropdown.png) | ![IP Ranges editor](GPConnect/screenshots/ip-ranges-editor.png) | ![Settings](GPConnect/screenshots/settings.png) |

Features
--------

- Menu bar icon showing connection state (disconnected / connecting / connected / error), with an animated
  icon while a connection is in progress
- Connect/disconnect from the menu bar dropdown
- Built-in SAML login window (`WKWebView`) — no separate browser needed
- Optional credential autofill: stores a username/password in the macOS Keychain and auto-submits them on
  the login page, so only MFA (e.g. Okta Verify) needs manual interaction each time
- Connection log viewer (`Logs...`) for troubleshooting without digging through files on disk
- Editable list of split-tunnel IP ranges (add/remove/enable/disable/import), stored in a JSON config file
  shared with the CLI
- A `gpconnect` CLI for scripting: status, listing/editing IP ranges, reading config

GPConnect requirements
----------------------

- macOS 14.0 or newer
- [OpenConnect](https://www.infradead.org/openconnect/) installed via Homebrew: `brew install openconnect`
- The [privileged helper daemon](#macos-privileged-helper-no-sudo-prompts) — GPConnect will offer to install
  this itself (one admin password prompt) the first time you launch it if it isn't already running, so you
  don't need to run `sudo helper/install.sh` manually
- Xcode Command Line Tools (`xcode-select --install`) — only needed if building from source; not required
  if you download a release

Download a release
-------------------

The easiest way to get GPConnect is to grab the latest prebuilt release instead of building it yourself:

1. Download `GPConnect-*-macos.zip` and `gpconnect-*-macos` from the
   [Releases page](https://github.com/sodre90/gpconnect-macos/releases/latest).
2. Unzip `GPConnect-*-macos.zip` — this gives you `GPConnect.app`.
3. Continue with [Install GPConnect](#install-gpconnect) below.

Releases are ad-hoc signed (not notarized), so Gatekeeper will block the first launch — see the note about
`xattr -cr` in that section.

Build from source
------------------

```sh
cd GPConnect
./build.sh
```

This builds both the app (`.build/app/GPConnect.app`) and the CLI (`.build/release/gpconnect`). It uses
`swiftc`/`swift build` directly rather than `xcodebuild`, so it works with just the Command Line Tools —
see [GPConnect/CLAUDE.md](GPConnect/CLAUDE.md) for why.

`GPConnect.xcodeproj` is included (generated via `xcodegen generate` from `project.yml`) purely so editors
get proper Swift diagnostics and autocomplete; it isn't used to produce the shipped build.

Install GPConnect
-----------------

```sh
cp -R .build/app/GPConnect.app /Applications/    # or wherever you unzipped the downloaded release
cp .build/release/gpconnect /usr/local/bin/      # or wherever you downloaded the CLI binary
chmod +x /usr/local/bin/gpconnect                # if downloaded, it won't have the executable bit set
open /Applications/GPConnect.app
```

Since GPConnect is ad-hoc signed rather than notarized, Gatekeeper will block that first launch. Run
`xattr -cr /Applications/GPConnect.app` (or right-click the app → Open) to get past it.

If `/Applications/GPConnect.app` already exists and was installed with `sudo`, remove it first
(`sudo rm -rf /Applications/GPConnect.app`) before copying a plain (non-sudo) rebuild over it, or the copy
will fail with a permissions error on the app bundle's extended attributes.

Usage
-----

### Menu bar app

Click the shield icon to open the dropdown: **Connect** starts the SAML login flow in its own window; once
you finish authenticating, GPConnect starts `openconnect` via the privileged helper daemon and the icon
turns into a checkmark shield once the tunnel is up. **Disconnect** tears it down. **Edit Ranges...** opens
a window to manage the split-tunnel IP ranges. **Logs...** opens a window with the connection log (copy or
clear it from there). **Settings...** lets you change the gateway address and User-Agent string, enable
credential autofill (username/password, stored in the macOS Keychain — MFA is still required every time),
and also has an **Install Helper** button if the privileged helper daemon isn't running (you'll usually be
prompted for this automatically on first launch instead).

### CLI

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
-------------

Both the app and the CLI read/write the same file:

```
~/Library/Application Support/GPConnect/config.json
```

It's plain JSON (gateway address, User-Agent, autofill toggle/username, and a list of `{cidr, label, enabled}`
IP ranges) — safe to edit by hand, via the app's "Edit Ranges..." window, or via
`gpconnect ranges`/`gpconnect config set`. The autofill password is not in this file — it's stored
separately in the macOS Keychain.

Known limitations
-----------------

- **FIDO2/WebAuthn (Touch ID) 2FA does not work** in the in-app SAML login window. It requires the
  `com.apple.developer.web-browser` entitlement, which in turn requires signing with a real Apple Developer
  identity — the ad-hoc signing this project currently uses can't carry that entitlement. Password/TOTP-based
  2FA is unaffected. See [GPConnect/CLAUDE.md](GPConnect/CLAUDE.md) for details if you have a Developer ID
  and want to fix this.

Installation
============

Install gp-saml-gui using `pip`, optionally inside a virtualenv (this pulls in
[pywebview](https://pywebview.flowrl.com/), which drives the login window on both macOS and Windows):

```
$ python3 -m venv venv && source venv/bin/activate
$ pip3 install https://github.com/sodre90/gpconnect-macos/archive/master.zip
...
$ gp-saml-gui
usage: gp-saml-gui [-h] [-g | -p] [-c CERT] [--key KEY] [-v | -q] [-x | -S | -D]
                    [-u] [--clientos {Linux,Mac,Windows}] [-f EXTRA]
                    [--allow-insecure-crypto] [--user-agent USER_AGENT]
                    server [openconnect_extra ...]
gp-saml-gui: error: the following arguments are required: server, openconnect_extra
```

How to use
==========

Specify the GlobalProtect server URL (portal or gateway) and optional
arguments, such as `--clientos=Windows` (because many GlobalProtect
servers don't require SAML login, but apparently omit it in their configuration
for OSes other than Windows).

This script will pop up a webview window alongside your terminal window.
After you successfully complete the SAML login via web forms, the script will output
`HOST`, `USER`, `COOKIE`, and `OS` variables in a form that can be used by
[OpenConnect](http://www.infradead.org/openconnect/juniper.html)
(similar to the output of `openconnect --authenticate`):

```sh
$ eval $( gp-saml-gui --gateway --clientos=Windows vpn.company.com )
Got SAML POST content, opening browser...
Finished loading about:blank...
Finished loading https://company.okta.com/app/panw_globalprotect/deadbeefFOOBARba1234/sso/saml...
Finished loading https://company.okta.com/login/sessionCookieRedirect...
Finished loading https://vpn.qorvo.com/SAML20/SP/ACS...
Got SAML relevant headers, done: {'prelogin-cookie': 'blahblahblah', 'saml-username': 'foo12345@corp.company.com', 'saml-slo': 'no', 'saml-auth-status': '1'}

SAML response converted to OpenConnect command line invocation:

    echo 'blahblahblah' |
        openconnect --protocol=gp --user='foo12345@corp.company.com' --os=win --usergroup=gateway:prelogin-cookie --passwd-on-stdin vpn.company.com

$ echo $HOST; echo $USER; echo $COOKIE; echo $OS
https://vpn.company.com/gateway:prelogin-cookie
foo12345@corp.company.com
blahblahblah
win

$ echo "$COOKIE" | openconnect --protocol=gp -u "$USER" --os="$OS" --passwd-on-stdin "$HOST"
```

If you specify either the `-S`/`--sudo-openconnect` or `-D`/`--daemon-openconnect` options, the script will
automatically invoke OpenConnect as described, using either [`sudo`](https://www.sudo.ws/) or the
[privileged helper daemon](#macos-privileged-helper-no-sudo-prompts) (recommended), as specified.

Extra arguments to OpenConnect
-------------------------------

Extra arguments needed for OpenConnect can be specified by adding ` -- ` to the command line, and then
appending these. For example:

```sh
$ gp-saml-gui -S --gateway --clientos=Windows vpn.company.com -- --csd-wrapper=hip-report.sh
…
Launching OpenConnect with sudo, equivalent to:
    echo blahblahblahlongrandomcookievalue |
        sudo openconnect --protocol=gp --user=foo12345@corp.company.com --os=win --usergroup=gateway:prelogin-cookie --passwd-on-stdin vpn.company.com
<sudo password prompt>
<openconnect runs>
```

macOS: Privileged Helper (no sudo prompts)
==========================================

> **This is the recommended approach.** This repo includes a small **privileged helper daemon** that runs
> `openconnect` as root via `launchd`, so subsequent VPN connections need no password at all — instead of
> `-S`/sudo (prompts every time). GPConnect installs this for you automatically; if you're using the
> `gp-saml-gui` script directly, see [helper/README.md](helper/README.md) for how to install it and use it
> with the `-D` flag.

License
=======

GPLv3 or newer

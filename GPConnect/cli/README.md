gpconnect CLI
=============

A small command-line companion to the [GPConnect](../) menu bar app. It reports connection status and
reads/edits the app's configuration — it does **not** connect or disconnect the VPN; use the menu bar app
for that.

The app works fine without this CLI installed. It's here for scripting.

Build
-----

```sh
swift build -c release          # from this directory
```

The binary lands at `.build/release/gpconnect`. The app's `../build.sh` does not build it — this is a
separate SwiftPM package.

Install
-------

```sh
cp .build/release/gpconnect /usr/local/bin/
```

On a machine where `/usr/local/bin` is root-owned, that needs `sudo`.

Usage
-----

```sh
gpconnect status                                      # connection + helper daemon status
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

The CLI and the app read and write the same file:

```
~/Library/Application Support/GPConnect/config.json
```

`CLIConfig` in `Sources/gpconnect-cli/main.swift` and `VPNConfig` in `../GPConnect/Models/VPNConfig.swift`
are independent `Codable` structs describing that one file, so **they must be kept in sync**. `saveConfig`
re-encodes the whole file, which means a `gpconnect` binary built before a new key was added to the app will
silently drop that key from the user's config on any `config set` or `ranges` edit. If you add a field to
`VPNConfig`, add it to `CLIConfig` too, and rebuild/reinstall the CLI alongside the app.

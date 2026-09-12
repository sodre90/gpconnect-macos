gpconnect CLI
=============

A small command-line companion to the [GPConnect](../) menu bar app. It reads/edits the app's
configuration, reports connection status, and starts the tunnel with `connect` — **without the app
running at all**. The default login opens a WKWebView positioned off-screen on the console session:
it satisfies Okta's device-proximity policy, autofills the credentials you enter in the terminal, and
waits for your phone approval (any number-match is scraped from the page and printed), so nothing
needs to be visible — it works over SSH. Alternatives: `--app` delegates the login to the running
GPConnect app (better cookies/proximity history, no password prompt), and `--http` is a pure-HTTP
Okta path with no window at all — it completes authn+push but fails at session creation (`E0000004`)
on tenants whose policy requires a real browser session, like cloudera.okta.com.

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
gpconnect connect                                     # hidden background-browser login (no app needed); attaches; Ctrl+C disconnects
gpconnect connect --app                               # let the running GPConnect app do the login instead (no password prompt)
gpconnect connect --http --mfa totp                   # pure-HTTP path: type an authenticator code
gpconnect connect --dry-run                           # show the planned openconnect invocation without logging in
gpconnect connect --user jdoe -v                      # explicit username + per-step progress on stderr
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

`connect` specifics
-------------------

- **Background browser (default)**: prelogin → the SAML form is auto-submitted inside an off-screen
  WKWebView (never focused, never visible), the Okta widget is autofilled from the credentials typed
  in the terminal, proximity/device checks run in-page, you approve the push on your phone; the final
  GP page's DOM is scraped for `saml-username` + cookie. Any number-match challenge is extracted from
  the page text and printed (best-effort). Uses `WKWebsiteDataStore.default()` under the CLI's own
  identity, so the first run starts a fresh device context — expect it to look "unusual" to Okta;
  later runs reuse the cookies. Requires an active console login session on the Mac (someone must be
  logged in at the display; they don't need to look at it). 4-minute timeout.
- **`--app`**: the CLI writes `{"command":"login"}` to `~/Library/Application Support/GPConnect/cli.sock`
  (0600, same-user only); the running app performs its normal login and replies with the auth result
  without starting a tunnel itself. Nicer when the app is up: no password prompt, established browser
  context. The CLI errors clearly if the app isn't listening.
- **`--http`**: GP prelogin → Okta `authn` API (push with number-match printed in the terminal, or
  `--mfa totp` with a typed code) → session → SAML hop chain → cookie scrape. No windows at all, but
  see the policy caveat above. Username defaults to `savedUsername`; password from
  `$GPCONNECT_PASSWORD` or a hidden prompt. The CLI never reads the app's keychain item: its ACL
  would raise a GUI consent dialog — invisible over SSH.
- **Split tunnel**: the tunnel slices are exactly the enabled IP ranges in the shared config
  (`gpconnect ranges` to toggle them). With zero enabled ranges, `connect` brings up a full tunnel.
- **Attach mode**: openconnect output streams to the terminal; Ctrl+C shuts the socket down, which is
  the daemon's cue to terminate openconnect (verified in `../../helper/openconnect_helper`).
- **TLS**: `--http` validates certificates trusted-everything for the login hops (same posture as
  the app's prelogin handling), so treat a MITM on the IdP leg as in-scope for untrusted networks.

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

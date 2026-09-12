import AppKit
import WebKit

/// Drives a real WKWebView login off-screen: the SAML form from prelogin is auto-submitted,
/// the Okta sign-in widget is autofilled, proximity/device checks run in-page, and the user
/// approves the Okta Verify push on their phone. The final GP page's DOM is scraped with the
/// same pattern as the app. No window is ever visible or focused.
final class SAMLWebViewLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let username: String
    private var password: String
    private let gateway: String
    private var passwordReprompted = false

    private var webView: WKWebView!
    private var completion: ((Result<SAMLResultCLI, Error>) -> Void)?
    private var pollTimer: Timer?
    private var autofillTimer: Timer?
    private var hasCompleted = false
    private var credentialsAnnounced = false
    private var announcedNumber = false
    private var injectedCode = ""
    private var totpTicks = 0
    private var sentAnnounced = false
    private var pollTicks = 0
    private var evalInFlight = false
    private var lastHTML = ""
    private var dumpedStall = false
    private var awaitingGatewayReport = false

    init(username: String, password: String, gateway: String) {
        self.username = username
        self.password = password
        self.gateway = gateway
    }

    func complete(with result: Result<SAMLResultCLI, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        pollTimer?.invalidate()
        autofillTimer?.invalidate()
        completion?(result)
        NSApp.stop(nil)
        // stop() only takes effect at the next event, and this call site may have just
        // invalidated the last event source — the async post is what wakes a sleeping run loop.
        DispatchQueue.main.async { NSApp.stop(nil) }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file"]
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        verboseLog("committed: \(webView.url?.host ?? "?")\(String(webView.url?.path.prefix(40) ?? "")) ready=\(webView.estimatedProgress)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        verboseLog("load failed: \(error.localizedDescription.prefix(140)) url=\(webView.url?.absoluteString.prefix(90) ?? "?")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        verboseLog("provisional load failed: \(error.localizedDescription.prefix(140)) url=\(webView.url?.absoluteString.prefix(90) ?? "?")")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        verboseLog("!! WebContent process terminated at \(webView.url?.host ?? "?") — evals will never return")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        verboseLog("navigated: \(webView.url?.absoluteString.prefix(90) ?? "?")")
        dumpedStall = false
        awaitingGatewayReport = webView.url?.host == gateway
        inspectPage()
    }

    func windowWillClose(_ notification: Notification) {
        complete(with: .failure(CLIError.message("login window closed before authentication completed")))
    }

    private func inspectPage() {
        let onGateway = webView.url?.host == gateway
        evalInFlight = true
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
            guard let self, !self.hasCompleted else { return }
            self.evalInFlight = false
            if let html = result as? String { self.inspect(html) }
            else { verboseLog("scrape eval failed: \(error?.localizedDescription.prefix(100) ?? "nil result")") }
            if onGateway {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.hasCompleted, self.webView.url?.host == self.gateway else { return }
                    self.inspectPage()
                }
            }
        }
    }

    private func inspect(_ html: String) {
        self.lastHTML = html
        if let saml = scrapeSAMLResult(html, server: self.webView.url?.host ?? self.gateway) {
            self.complete(with: .success(saml))
            return
        }
        if self.awaitingGatewayReport {
            self.awaitingGatewayReport = false
            self.reportState(force: true)
        }
        self.announceNumberIfNeeded(html)
        self.attemptAutofill(html)
        self.reportStateIfNeeded()
        if self.pollTicks % 10 == 5 { self.probeDOM() }
    }

    private func probeDOM() {
        let probe = """
        JSON.stringify({
            ready: document.readyState,
            templates: document.querySelectorAll('template').length,
            root: (document.getElementById('okta-sign-in') || {}).childElementCount ?? -1,
            inputs: document.querySelectorAll('input').length,
            names: Array.prototype.slice.call(document.querySelectorAll('input')).map(function(i){ return i.name || i.type; }),
            visible: document.body.innerText.replace(/\\s+/g, ' ').slice(0, 180)
        })
        """
        webView.evaluateJavaScript(probe) { result, _ in
            verboseLog("dom probe: \(String(describing: result).prefix(300))")
        }
    }

    /// When the page sits unresolved for a while, print what it actually is — the whole
    /// point of the off-screen window is that nobody watches it, so it has to narrate.
    private func reportStateIfNeeded() {
        if pollTicks % 45 == 44 { dumpedStall = false }
        reportState(force: false)
    }

    private func reportState(force: Bool) {
        guard !dumpedStall || force, pollTicks > 2 || force else { return }
        dumpedStall = true
        guard !lastHTML.isEmpty else { return }
        let path = "/tmp/gpconnect-webview.html"
        try? lastHTML.write(toFile: path, atomically: true, encoding: .utf8)
        let title = regexGroups("<title[^>]*>([^<]*)</title>", in: lastHTML).first?.first ?? "(no title)"
        let url = webView.url?.absoluteString ?? "?"
        print("Still waiting (\(pollTicks)s). Page: \(url) — \"\(title)\"")
        print("Visible text: \(pageExcerpt(lastHTML))")
        print("Full page saved to \(path)")
    }

    /// Okta's number-match shows a two-digit number on the page; the off-screen window means
    /// the terminal is the only place the user can read it. Best-effort text scrape.
    private func announceNumberIfNeeded(_ html: String) {
        guard !announcedNumber else { return }
        // Strip scripts/styles first: their asset-hash digits produced a false "22" once.
        var text = html
        for junk in ["<script[^>]*>.*?</script>", "<style[^>]*>.*?</style>", "<!--.*?-->"] {
            text = text.replacingRegex(junk, with: " ")
        }
        text = text.replacingRegex("<[^>]+>", with: " ")
        guard let match = regexGroups("(?:select|choose|match|tap)[^0-9]{0,60}\\b(\\d{1,2})\\b|\\b(\\d{1,2})\\b[^0-9]{0,60}(?:on your (?:phone|screen)|in okta verify|if (?:prompted|asked))",
                                      in: text, options: [.caseInsensitive]).first,
              let digits = match.compactMap({ $0.isEmpty ? nil : $0 }).first
        else { return }
        announcedNumber = true
        if let at = text.range(of: digits) {
            let from = text.index(at.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let to = text.index(at.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            verboseLog("number-match context: …\(text[from..<to].replacingOccurrences(of: "\n", with: " "))…")
        }
        print("In Okta Verify, select the number: \(digits)")
    }

    private func attemptAutofill(_ html: String) {
        // Runs every tick for the whole login. The JS is a throttled state machine:
        // identifier-first pages only show the username input, so submit that first
        // (button click + Enter, deferred so the OIE web-component has synced its
        // model — clicking in the same tick gets preventDefault-ed on an empty value),
        // then fill/submit the password step once it appears.
        let u = jsString(username)
        let p = jsString(password)
        let js = """
        (function() {
            function setNativeValue(el, value) {
                var proto = Object.getPrototypeOf(el);
                var desc = Object.getOwnPropertyDescriptor(proto, 'value') ||
                    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
                if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }
            function firstMatch(selectors) {
                for (var i = 0; i < selectors.length; i++) {
                    var el = document.querySelector(selectors[i]);
                    if (el) return el;
                }
                return null;
            }
            function throttle(key, ms) {
                var now = Date.now();
                if (window['__gp_' + key] && now - window['__gp_' + key] < ms) return false;
                window['__gp_' + key] = now;
                return true;
            }
            function submitStep(el) {
                var form = el.closest('form');
                setTimeout(function() {
                    var f = (el.isConnected ? el.closest('form') : null) || form;
                    var btn = f ? f.querySelector('input[type="submit"], button[type="submit"], [data-type="save"]') : null;
                    if (btn) btn.click();
                    if (f && f.requestSubmit) { try { f.requestSubmit(); } catch (e) {} }
                    ['keydown', 'keypress', 'keyup'].forEach(function(type) {
                        if (el.isConnected) {
                            el.dispatchEvent(new KeyboardEvent(type,
                                { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
                        }
                    });
                }, 300);
            }
            var userField = firstMatch(['input[name="identifier"]', 'input[autocomplete="username"]',
                '#okta-signin-username', 'input[name="username"]']);
            var passField = firstMatch(['#okta-signin-password', 'input[name="credentials.passcode"]',
                'input[name="password"]', 'input[type="password"]']);
            if (passField) {
                if (!throttle('pass', 15000)) { return 'pass-wait'; }
                if (userField) { setNativeValue(userField, \(u)); }
                setNativeValue(passField, \(p));
                submitStep(passField);
                return 'pass';
            }
            if (userField) {
                if (userField.value !== \(u)) { setNativeValue(userField, \(u)); }
                if (throttle('ident', 6000)) { submitStep(userField); }
                return 'ident';
            }
            // On the "push sent" page the body text still contains "Okta Verify" and
            // "resend the push notification" — without this guard the card matcher below
            // re-clicks resend every throttle window and pages the phone repeatedly.
            if (/push notification sent/i.test(document.body.innerText || '')) { return 'sent'; }
            // TOTP screen: prefer bouncing back to pick push; only ask for a typed code
            // as last resort (the caller injects one after a while).
            var totp = document.querySelector('input[name="credentials.totp"]');
            if (totp) {
                var code = \(jsString(injectedCode));
                if (code) {
                    setNativeValue(totp, code);
                    submitStep(totp);
                    return 'totp-sub';
                }
                if (throttle('else', 12000)) {
                    var all = document.querySelectorAll('a, button, span');
                    for (var b of all) {
                        var bt = (b.textContent || '').trim();
                        if (/something else|other options|back to/i.test(bt) && bt.length < 60) { b.click(); return 'else'; }
                    }
                }
                return 'totp';
            }
            // Factor-chooser screen ("Verify it's you…", e.g. after a remembered password
            // step): pick the Okta Verify push card — preferring push wording and never the
            // "enter a code" (TOTP) card.
            var target = null;
            var cards = document.querySelectorAll('a, button, li, div, [data-se], tr');
            for (var el of cards) {
                var t = (el.textContent || '').trim();
                if (!/okta verify/i.test(t) || t.length > 200 || el.children.length >= 25) { continue; }
                if (/enter a code/i.test(t)) { continue; }
                var score = /push|send/i.test(t) ? 2 : 1;
                if (!target || score > target.score) { target = { el: el, score: score }; }
            }
            if (target) {
                if (!throttle('ov', 8000)) { return 'ov-wait'; }
                var inner = target.el.querySelector('button, a, input[type="button"], input[type="submit"], .button');
                (inner || target.el).click();
                target.el.dispatchEvent(new MouseEvent('click', { bubbles: true }));
                return 'ov';
            }
            var verifyBtn = firstMatch(['[data-se="oktaVerify"]', '[data-se="auth-button"]',
                'input[value="Send"]', 'button[value="Send"]', '.auth-btn-wrapper button']);
            if (verifyBtn && throttle('verify', 8000)) { verifyBtn.click(); return 'verify'; }
            return 'none';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error { verboseLog("autofill JS error: \(error.localizedDescription.prefix(120))") }
            let state = (result as? String) ?? "error"
            if self.pollTicks % 5 == 0 { verboseLog("autofill state: \(state)") }
            let fired: [String: String] = ["pass": "Credentials submitted",
                                           "ov": "Chose Okta Verify",
                                           "verify": "Chose Okta Verify"]
            if let message = fired[state], !self.credentialsAnnounced {
                self.credentialsAnnounced = true
                print("\(message) — approve the push on your phone.")
            }
            if state == "sent", !self.sentAnnounced {
                self.sentAnnounced = true
                print("Push sent — check your phone.")
            }
            let onPasswordStep = state == "pass" || state == "pass-wait"
            if onPasswordStep, self.lastHTML.lowercased().contains("unable to sign in"), !self.passwordReprompted {
                self.passwordReprompted = true
                print("Okta rejected that password — re-enter it.")
                if let again = try? readHiddenLine(prompt: "Okta password for \(self.username): "), !again.isEmpty {
                    self.password = again
                    self.webView.evaluateJavaScript("window.__gp_pass = 0;", completionHandler: nil)
                }
            } else if !onPasswordStep {
                self.passwordReprompted = false
            }
            if state == "totp" {
                self.totpTicks += 1
                if self.totpTicks == 30 {
                    print("Still on the code screen — you can type the rolling code from Okta Verify instead of a push.")
                    if let code = try? readHiddenLine(prompt: "6-digit code from Okta Verify: "), !code.isEmpty {
                        self.injectedCode = code
                    }
                }
            }
            if state == "totp-sub" { print("Code submitted.") }
        }
    }

    fileprivate func begin(userAgent: String, target: SPLoginRequest,
                           completion: @escaping (Result<SAMLResultCLI, Error>) -> Void) {
        self.completion = completion

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GPConnect login"
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        // AppKit constrains far off-screen windows back into view on ordering, so the only
        // reliable invisibility is near-zero alpha (0 would let WebKit treat it as hidden).
        window.alphaValue = 0.01
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
        window.delegate = self
        window.contentView?.addSubview(webView)
        // Ordered front so WebKit renders the page; never focused, and effectively invisible.
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))

        webView.loadHTMLString(autoSubmitHTML(target), baseURL: URL(string: "https://\(gateway)")!)

        // The Okta widget updates client-side after the push completes; re-inspect on a timer
        // as well as on navigations (mirrors the app's autofill-timer rationale).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollTicks += 1
            if self.pollTicks % 5 == 0 {
                let url = self.webView.url
                verboseLog("tick \(self.pollTicks) host=\(url?.host ?? "?") loading=\(self.webView.isLoading) evalStuck=\(self.evalInFlight)")
            }
            if self.pollTicks > 240 {
                timer.invalidate()
                self.complete(with: .failure(CLIError.message("login did not complete within 4 minutes")))
                return
            }
            self.inspectPage()
        }
        autofillTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, !self.hasCompleted else { timer.invalidate(); return }
            self.inspectPage()
        }
    }
}

extension String {
    func replacingRegex(_ pattern: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return self }
        let ns = self as NSString
        return re.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
    }
}

func jsString(_ value: String) -> String {
    String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
}

func autoSubmitHTML(_ target: SPLoginRequest) -> String {
    func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    let inputs = target.fields.map { "<input type=\"hidden\" name=\"\(attr($0.name))\" value=\"\(attr($0.value))\">" }.joined()
    return "<html><body><form id=\"f\" method=\"POST\" action=\"\(attr(target.url.absoluteString))\">\(inputs)</form>"
        + "<script>document.getElementById('f').submit();</script></body></html>"
}

@MainActor
func loginViaWebView(gateway: String, userAgent: String, username: String, password: String) throws -> SAMLResultCLI {
    let target = try blockingPrelogin(gateway: gateway, userAgent: userAgent)
    print("IdP:      \(target.url.host ?? "?") (\(target.url.path), \(target.fields.count) form field(s))")

    NSApplication.shared.setActivationPolicy(.accessory)
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "background SAML login webview")
    defer { ProcessInfo.processInfo.endActivity(activity) }

    let login = SAMLWebViewLogin(username: username, password: password, gateway: gateway)
    var outcome: Result<SAMLResultCLI, Error>?
    login.begin(userAgent: idpUserAgent, target: target) { result in
        outcome = result
    }
    NSApp.run()
    return try (outcome ?? .failure(CLIError.message("login run loop ended without a result"))).get()
}

private func blockingPrelogin(gateway: String, userAgent: String) throws -> SPLoginRequest {
    let box = ResultBox<SPLoginRequest>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.set(.success(try await fetchSPLoginRequest(gateway: gateway, userAgent: userAgent, session: makeTrustingSession()))) }
        catch { box.set(throwing: error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    var value: Result<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ result: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = result
    }

    func set(throwing error: Error) {
        set(.failure(error))
    }
}

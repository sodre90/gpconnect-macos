import SwiftUI
import WebKit

struct SAMLAuthView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var isLoading = true
    @State private var preloginResponse: PreloginResponse?
    @State private var error: String?

    var body: some View {
        VStack {
            if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                    Button("Retry") { startPrelogin() }
                    Button("Cancel") {
                        vpnManager.onSAMLFailed("Cancelled")
                        WindowManager.shared.closeSAMLAuth()
                    }
                }
                .padding()
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading SAML login...")
                        .foregroundColor(.secondary)
                }
                .padding()
            } else if let prelogin = preloginResponse {
                SAMLWebView(
                    prelogin: prelogin,
                    gateway: vpnManager.config.gateway,
                    autofillUsername: vpnManager.config.autoFillCredentials == true ? vpnManager.config.savedUsername : nil,
                    autofillPassword: vpnManager.config.autoFillCredentials == true
                        ? CredentialStore.loadPassword(account: vpnManager.config.gateway) : nil,
                    onComplete: { result in
                        vpnManager.onSAMLComplete(result)
                        WindowManager.shared.closeSAMLAuth()
                    },
                    onFailed: { msg in
                        vpnManager.onSAMLFailed(msg)
                        WindowManager.shared.closeSAMLAuth()
                    }
                )
            }
        }
        .frame(minWidth: 500, minHeight: 550)
        .onAppear { startPrelogin() }
    }

    private func startPrelogin() {
        isLoading = true
        error = nil
        Task {
            do {
                let service = SAMLAuthService(
                    gateway: vpnManager.config.gateway,
                    userAgent: vpnManager.config.userAgent
                )
                let response = try await service.fetchPrelogin()
                preloginResponse = response
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
}

struct SAMLWebView: NSViewRepresentable {
    let prelogin: PreloginResponse
    let gateway: String
    let autofillUsername: String?
    let autofillPassword: String?
    let onComplete: (SAMLResult) -> Void
    let onFailed: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "PAN GlobalProtect"

        switch prelogin.method {
        case .post(let html):
            webView.loadHTMLString(html, baseURL: URL(string: "https://\(gateway)"))
        case .redirect(let url):
            if let url = URL(string: url) {
                webView.load(URLRequest(url: url))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            gateway: gateway,
            autofillUsername: autofillUsername,
            autofillPassword: autofillPassword,
            onComplete: onComplete,
            onFailed: onFailed
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let gateway: String
        let autofillUsername: String?
        let autofillPassword: String?
        let onComplete: (SAMLResult) -> Void
        let onFailed: (String) -> Void
        private var hasAttemptedAutofill = false

        private static let samlPattern = try! NSRegularExpression(
            pattern: "<(?<header>saml-.+?|(?:prelogin-|portal-userauth)cookie)>(?<value>.*?)</\\k<header>>",
            options: []
        )

        init(
            gateway: String,
            autofillUsername: String?,
            autofillPassword: String?,
            onComplete: @escaping (SAMLResult) -> Void,
            onFailed: @escaping (String) -> Void
        ) {
            self.gateway = gateway
            self.autofillUsername = autofillUsername
            self.autofillPassword = autofillPassword
            self.onComplete = onComplete
            self.onFailed = onFailed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                guard let self = self, let html = result as? String else { return }
                self.checkForSAMLResult(in: html, from: webView.url)
            }
            attemptAutofill(in: webView)
        }

        /// Best-effort autofill for Okta's standard hosted Sign-In Widget (stable IDs across
        /// most tenants) with generic input-type fallbacks for other IdPs. Only attempted once
        /// per login session to avoid repeatedly re-submitting on later page loads (e.g. the
        /// MFA step). Uses the native property setter before dispatching input/change events
        /// since React-controlled forms (like Okta's widget) ignore a plain `.value =` assignment.
        private func attemptAutofill(in webView: WKWebView) {
            guard !hasAttemptedAutofill,
                  let username = autofillUsername, !username.isEmpty,
                  let password = autofillPassword, !password.isEmpty,
                  let usernameJS = try? String(data: JSONEncoder().encode(username), encoding: .utf8),
                  let passwordJS = try? String(data: JSONEncoder().encode(password), encoding: .utf8) else {
                return
            }

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
                var userField = firstMatch(['#okta-signin-username', 'input[name="identifier"]',
                    'input[name="username"]', 'input[autocomplete="username"]']);
                var passField = firstMatch(['#okta-signin-password', 'input[name="credentials.passcode"]',
                    'input[name="password"]', 'input[type="password"]']);
                if (!passField) { return false; }
                if (userField && !userField.value) { setNativeValue(userField, \(usernameJS)); }
                setNativeValue(passField, \(passwordJS));
                var submitBtn = document.querySelector('#okta-signin-submit');
                if (submitBtn) { submitBtn.click(); return true; }
                var form = passField.closest('form');
                if (form) { form.requestSubmit ? form.requestSubmit() : form.submit(); return true; }
                return false;
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                if (result as? Bool) == true {
                    self?.hasAttemptedAutofill = true
                }
            }
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        private func checkForSAMLResult(in html: String, from url: URL?) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = Self.samlPattern.matches(in: html, range: range)

            var fields: [String: String] = [:]
            for match in matches {
                if let headerRange = Range(match.range(withName: "header"), in: html),
                   let valueRange = Range(match.range(withName: "value"), in: html) {
                    fields[String(html[headerRange])] = String(html[valueRange])
                }
            }

            guard let username = fields["saml-username"],
                  let (cookieName, cookieValue) = fields.first(where: { $0.key == "prelogin-cookie" || $0.key == "portal-userauthcookie" }) else {
                return
            }

            let server = url?.host ?? gateway
            DispatchQueue.main.async {
                self.onComplete(SAMLResult(
                    username: username,
                    cookie: cookieValue,
                    cookieName: cookieName,
                    server: server
                ))
            }
        }
    }
}

import Foundation

struct SAMLResultCLI {
    let username: String
    let cookie: String
    let cookieName: String
    let server: String
}

struct SPLoginRequest {
    let url: URL
    let fields: [(name: String, value: String)]
}

enum CLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

var cliVerbose = false

func verboseLog(_ message: String) {
    if cliVerbose { fputs("… \(message)\n", stderr) }
}

/// A real desktop-Safari UA for the IdP leg; the "PAN GlobalProtect" UA is for GP endpoints only
/// (same split the app's WKWebView makes).
let idpUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

func makeTrustingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = true
    config.httpCookieAcceptPolicy = .always
    config.timeoutIntervalForRequest = 30
    config.httpAdditionalHeaders = ["User-Agent": idpUserAgent]
    return URLSession(configuration: config, delegate: TrustAllDelegate(), delegateQueue: nil)
}

func regexGroups(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (1..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

func wholeMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

func decodeHTMLEntities(_ s: String) -> String {
    var r = s
    r = r.replacingOccurrences(of: "&#x2b;", with: "+", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "&#43;", with: "+")
    r = r.replacingOccurrences(of: "&quot;", with: "\"")
    r = r.replacingOccurrences(of: "&apos;", with: "'")
    r = r.replacingOccurrences(of: "&lt;", with: "<")
    r = r.replacingOccurrences(of: "&gt;", with: ">")
    r = r.replacingOccurrences(of: "&amp;", with: "&")
    return r
}

/// Returns the form's action, or "" when the markup omits it (POST to the current URL
/// is the HTML default). No `<form>` at all returns nil.
func parseForm(_ html: String) -> (action: String, fields: [(name: String, value: String)])? {
    guard let formTag = wholeMatches("<form[^>]*>", in: html).first else { return nil }
    let action = regexGroups("action=[\"']([^\"']*)[\"']", in: formTag).first?.first ?? ""
    var fields: [(String, String)] = []
    for tag in wholeMatches("<input[^>]*>", in: html) {
        guard let name = regexGroups("name=[\"']([^\"']*)[\"']", in: tag).first?.first else { continue }
        let value = regexGroups("value=[\"']([^\"']*)[\"']", in: tag).first?.first ?? ""
        fields.append((name, decodeHTMLEntities(value)))
    }
    return (decodeHTMLEntities(action), fields)
}

func pageExcerpt(_ html: String) -> String {
    let collapsed = html.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return String(collapsed.prefix(400))
}

func urlEncoded(_ fields: [(name: String, value: String)]) -> Data {
    Data(fields.map { "\($0.name)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
        .joined(separator: "&")
        .utf8)
}

// MARK: - GP prelogin

func fetchSPLoginRequest(gateway: String, userAgent: String, session: URLSession) async throws -> SPLoginRequest {
    var request = URLRequest(url: URL(string: "https://\(gateway)/ssl-vpn/prelogin.esp")!)
    request.httpMethod = "POST"
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = Data("tmp=tmp&kerberos-support=yes&ipv6-support=yes&clientVer=4100&clientos=Mac".utf8)

    let (data, _) = try await session.data(for: request)
    let xml = String(decoding: data, as: UTF8.self)
    guard
        let method = regexGroups("<saml-auth-method>([^<]*)</saml-auth-method>", in: xml).first?.first,
        let encoded = regexGroups("<saml-request>([^<]*)</saml-request>", in: xml).first?.first,
        let decoded = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
        let content = String(data: decoded, encoding: .utf8)
    else {
        throw CLIError.message("prelogin response contained no usable <saml-auth-method>/<saml-request>")
    }

    if method.uppercased() == "REDIRECT" {
        guard var components = URLComponents(string: content), components.url != nil else {
            throw CLIError.message("SAML redirect URL is not parseable")
        }
        let fields = (components.queryItems ?? []).compactMap { item -> (String, String)? in
            item.value.map { (item.name, $0) }
        }
        components.query = nil
        return SPLoginRequest(url: components.url!, fields: fields)
    }

    // Some responses carry a bare URL in the saml-request even when the method says POST.
    if !content.contains("<"), let url = URL(string: content.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let fields = (components.queryItems ?? []).compactMap { item -> (String, String)? in
            item.value.map { (item.name, $0) }
        }
        components.query = nil
        return SPLoginRequest(url: components.url!, fields: fields)
    }

    guard let parsed = parseForm(content), !parsed.action.isEmpty, let url = URL(string: parsed.action) else {
        let dumpPath = "/tmp/gpconnect-saml-request.html"
        try? content.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        throw CLIError.message("""
        SAML POST request had no parseable form action.
        Content: \(pageExcerpt(content))
        Full payload saved to \(dumpPath)
        """)
    }
    return SPLoginRequest(url: url, fields: parsed.fields)
}

/// The number the user must tap in Okta Verify during a number-challenge push lives at
/// `_embedded.factor._embedded.challenge.correctAnswer` and is only present in polling
/// responses while the phone is showing the three-number view.
private func pushNumberHint(_ json: [String: Any]) -> Int? {
    guard
        let factor = (json["_embedded"] as? [String: Any])?["factor"] as? [String: Any],
        let challenge = (factor["_embedded"] as? [String: Any])?["challenge"] as? [String: Any]
    else { return nil }
    if let n = challenge["correctAnswer"] as? Int { return n }
    if let s = challenge["correctAnswer"] as? String, let n = Int(s) { return n }
    return nil
}

// MARK: - Okta authn

private func oktaJSON(from data: Data, response: URLResponse) throws -> [String: Any] {
    if let http = response as? HTTPURLResponse, let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") {
        verboseLog("Set-Cookie on \(http.url?.path ?? "?"): \(setCookie.prefix(120))")
    }
    if let http = response as? HTTPURLResponse, http.statusCode >= 400,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let summary = json["errorSummary"] as? String {
        let code = json["errorCode"] as? String ?? "?"
        throw CLIError.message("Okta API \(http.url?.path ?? "?"): \(summary) (\(code))")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError.message("Okta API returned a non-JSON response")
    }
    return json
}

private func postJSON(_ session: URLSession, _ url: URL, _ body: [String: Any], origin: URL? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let origin {
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(origin.absoluteString + "/", forHTTPHeaderField: "Referer")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    return try oktaJSON(from: data, response: response)
}

private func linkURL(_ json: [String: Any], _ key: String) -> URL? {
    guard
        let links = json["_links"] as? [String: Any],
        let target = links[key] as? [String: Any] ?? links["next"] as? [String: Any],
        let href = target["href"] as? String
    else { return nil }
    return URL(string: href)
}

private func authFailure(_ json: [String: Any]) -> CLIError {
    let status = json["status"] as? String ?? "unknown"
    let reasons = ((json["errorCauses"] as? [[String: Any]])?.compactMap { $0["errorSummary"] as? String }) ?? []
    return CLIError.message("Okta authentication failed (\(status))\(reasons.isEmpty ? "" : ": " + reasons.joined(separator: "; "))")
}

func oktaSessionToken(base: URL, user: String, password: String, mfa: String, session: URLSession) async throws -> String {
    let authnURL = URL(string: "/api/v1/authn", relativeTo: base)!.absoluteURL
    var json = try await postJSON(session, authnURL, ["username": user, "password": password], origin: base)
    verboseLog("authn status: \(json["status"] as? String ?? "?")")

    if (json["status"] as? String) == "MFA_REQUIRED" {
        guard var stateToken = json["stateToken"] as? String else {
            throw CLIError.message("IdP offered MFA without a state token")
        }
        let factors = ((json["_embedded"] as? [String: Any])?["factors"] as? [[String: Any]]) ?? []
        let isDesired: ([String: Any]) -> Bool = { factor in
            guard let type = factor["factorType"] as? String else { return false }
            return mfa == "push" ? type == "push" : type == "google" || type.hasPrefix("token")
        }
        guard let factor = factors.first(where: isDesired) else {
            let available = factors.compactMap { $0["factorType"] as? String }.joined(separator: ", ")
            throw CLIError.message("no \(mfa) factor offered by the IdP (available: \(available.isEmpty ? "none" : available))")
        }
        guard
            let factorLinks = factor["_links"] as? [String: Any],
            let verify = factorLinks["verify"] as? [String: Any],
            let href = verify["href"] as? String,
            let verifyURL = URL(string: href)
        else {
            throw CLIError.message("MFA factor offered by the IdP has no verify link")
        }

        // Every authn-transaction request past the first must carry the current stateToken.
        if mfa == "push" {
            print("Approve the sign-in request in Okta Verify…")
            json = try await postJSON(session, verifyURL, ["stateToken": stateToken], origin: base)
            var waited = 0
            var announcedNumber = false
            while (json["status"] as? String) == "MFA_CHALLENGE" {
                if !announcedNumber, let number = pushNumberHint(json) {
                    print("In Okta Verify, select the number: \(number)")
                    announcedNumber = true
                }
                guard let pollURL = linkURL(json, "next") else { break }
                if waited >= 90 { throw CLIError.message("push approval timed out after 90s") }
                if let fresh = json["stateToken"] as? String { stateToken = fresh }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                waited += 2
                json = try await postJSON(session, pollURL, ["stateToken": stateToken], origin: base)
                verboseLog("push poll status: \(json["status"] as? String ?? "?")")
            }
        } else {
            fputs("Enter your authenticator code: ", stderr)
            guard let code = readLine(strippingNewline: true), !code.isEmpty else {
                throw CLIError.message("no code entered")
            }
            json = try await postJSON(session, verifyURL, ["stateToken": stateToken, "passCode": code], origin: base)
        }
    }

    guard (json["status"] as? String) == "SUCCESS", let token = json["sessionToken"] as? String else {
        throw authFailure(json)
    }
    return token
}

func escaped(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
}

func installOktaSidCookie(base: URL, sessionToken: String, session: URLSession) async throws {
    var components = URLComponents(url: base.appendingPathComponent("api/v1/sessions"), resolvingAgainstBaseURL: false)!
    components.percentEncodedQuery = "sessionToken=" + escaped(sessionToken)
    let json = try await postJSON(session, components.url!, [:], origin: base)
    guard let id = json["id"] as? String, let host = base.host,
          let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "sid", .value: id]) else {
        throw CLIError.message("Okta did not create a session for the authenticated token")
    }
    session.configuration.httpCookieStorage?.setCookie(cookie)
}

// MARK: - SAML hop chain

let samlTagPattern = "<(saml-.+?|(?:prelogin-|portal-userauth)cookie)>(.*?)</\\1>"

func scrapeSAMLResult(_ html: String, server: String) -> SAMLResultCLI? {
    var fields: [String: String] = [:]
    for groups in regexGroups(samlTagPattern, in: html, options: [.dotMatchesLineSeparators]) {
        guard groups.count == 2 else { continue }
        fields[groups[0]] = groups[1]
    }
    guard let username = fields["saml-username"],
          let (cookieName, cookie) = fields.first(where: { $0.key == "prelogin-cookie" || $0.key == "portal-userauthcookie" })
    else { return nil }
    return SAMLResultCLI(username: username, cookie: cookie, cookieName: cookieName, server: server)
}

func completeSSOLogin(target: SPLoginRequest, sessionToken: String?, session: URLSession) async throws -> SAMLResultCLI {
    var url = target.url
    var fields = target.fields

    if let sessionToken {
        // No sid cookie was obtainable (/api/v1/sessions fenced off by org policy): the SSO
        // endpoint honors the one-time sessionToken only on the GET, unsolicited-binding
        // leg — Okta starts the SAML response itself, so no SAMLRequest is sent.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "sessionToken=" + escaped(sessionToken)
        url = components.url!
        fields = []
    }

    for _ in 1...6 {
        var request = URLRequest(url: url)
        request.httpMethod = fields.isEmpty ? "GET" : "POST"
        if !fields.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = urlEncoded(fields)
        }

        let (data, response) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let finalURL = (response as? HTTPURLResponse)?.url ?? url
        verboseLog("\(finalURL.host ?? "?") → \(data.count) bytes, HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")

        if let result = scrapeSAMLResult(html, server: finalURL.host ?? target.url.host ?? "") {
            return result
        }
        if let refreshURL = parseMetaRefresh(html, relativeTo: finalURL) {
            url = refreshURL
            fields = []
            continue
        }
        guard let next = parseForm(html) else {
            let dumpPath = "/tmp/gpconnect-saml-chain.html"
            try? html.write(toFile: dumpPath, atomically: true, encoding: .utf8)
            throw CLIError.message("""
            SAML chain reached \(finalURL.host ?? "?") without a login result or form to submit.
            Page: \(pageExcerpt(html))
            Full page saved to \(dumpPath)
            """)
        }
        url = next.action.isEmpty ? finalURL : URL(string: next.action, relativeTo: finalURL)?.absoluteURL ?? finalURL
        fields = next.fields
    }
    throw CLIError.message("SAML chain did not converge within 6 hops (reached \(url.host ?? "?"))")
}

private func parseMetaRefresh(_ html: String, relativeTo base: URL) -> URL? {
    guard let target = regexGroups("http-equiv=[\"']refresh[\"'][^>]*?url=([^\"'>]+)", in: html).first?.first,
          let url = URL(string: decodeHTMLEntities(target), relativeTo: base)?.absoluteURL
    else { return nil }
    return url
}

func loginHeadless(gateway: String, gpUserAgent: String, user: String, password: String, mfa: String) async throws -> SAMLResultCLI {
    let session = makeTrustingSession()
    let target = try await fetchSPLoginRequest(gateway: gateway, userAgent: gpUserAgent, session: session)
    guard let scheme = target.url.scheme, let host = target.url.host else {
        throw CLIError.message("IdP SSO URL is malformed")
    }
    let oktaBase = URL(string: "\(scheme)://\(host)")!
    print("IdP:      \(host) (\(target.url.path), \(target.fields.count) form field(s))")
    verboseLog("IdP SSO endpoint: \(target.url.absoluteString)")

    let token = try await oktaSessionToken(base: oktaBase, user: user, password: password, mfa: mfa, session: session)
    let storedCookies = (session.configuration.httpCookieStorage?.cookies ?? []).map { "\($0.name)@\($0.domain)" }
    verboseLog("cookie jar: \(storedCookies.isEmpty ? "empty" : storedCookies.joined(separator: ", "))")
    let hasSidCookie = storedCookies.contains { $0.hasPrefix("sid@") }
    var tokenForSSO: String?
    if hasSidCookie {
        verboseLog("authn transaction set the sid cookie; skipping sessions API")
    } else {
        do {
            try await installOktaSidCookie(base: oktaBase, sessionToken: token, session: session)
            verboseLog("installed sid cookie via sessions API")
        } catch {
            verboseLog("sessions API failed (\(error)); trying unsolicited SSO with sessionToken")
            tokenForSSO = token
        }
    }
    return try await completeSSOLogin(target: target, sessionToken: tokenForSSO, session: session)
}

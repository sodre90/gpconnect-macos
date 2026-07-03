import Foundation

struct PreloginResponse {
    enum Method {
        case post(html: String)
        case redirect(url: String)
    }
    let method: Method
}

class SAMLAuthService {
    private let gateway: String
    private let userAgent: String

    init(gateway: String, userAgent: String = "PAN GlobalProtect") {
        self.gateway = gateway
        self.userAgent = userAgent
    }

    func fetchPrelogin() async throws -> PreloginResponse {
        let endpoint = "https://\(gateway)/ssl-vpn/prelogin.esp"
        guard let url = URL(string: endpoint) else {
            throw GPConnectError.authFailed("Invalid gateway URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body = "tmp=tmp&kerberos-support=yes&ipv6-support=yes&clientVer=4100&clientos=Mac"
        request.httpBody = body.data(using: .utf8)

        let session = createTrustingSession()
        let (data, _) = try await session.data(for: request)

        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw GPConnectError.authFailed("Invalid prelogin response")
        }

        return try parsePreloginResponse(xmlString)
    }

    private func parsePreloginResponse(_ xml: String) throws -> PreloginResponse {
        guard let data = xml.data(using: .utf8) else {
            throw GPConnectError.authFailed("Invalid XML encoding")
        }

        let parser = PreloginXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()

        guard let method = parser.samlMethod, let request = parser.samlRequest else {
            throw GPConnectError.authFailed("No SAML tags in prelogin response")
        }

        guard let decoded = Data(base64Encoded: request),
              let content = String(data: decoded, encoding: .utf8) else {
            throw GPConnectError.authFailed("Failed to decode SAML request")
        }

        switch method.uppercased() {
        case "POST":
            return PreloginResponse(method: .post(html: content))
        case "REDIRECT":
            return PreloginResponse(method: .redirect(url: content))
        default:
            throw GPConnectError.authFailed("Unknown SAML method: \(method)")
        }
    }

    private func createTrustingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        let delegate = TrustAllDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

private class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

private class PreloginXMLParser: NSObject, XMLParserDelegate {
    var samlMethod: String?
    var samlRequest: String?
    private var currentElement: String?
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "saml-auth-method":
            samlMethod = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "saml-request":
            samlRequest = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            break
        }
        currentElement = nil
    }
}

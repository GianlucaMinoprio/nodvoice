import Foundation

/// SuperGrok / X Premium+ OAuth via the public xAI device-code client.
/// Tokens live in the Keychain. API key remains a fallback in Settings.
struct SuperGrokSession: Codable, Equatable {
    private static let account = "supergrok_oauth_session"

    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var accountHint: String?

    var isAccessTokenFresh: Bool {
        expiresAt.timeIntervalSinceNow > 10 * 60
    }

    static var isSignedIn: Bool {
        load()?.refreshToken.isEmpty == false
    }

    static func load() -> SuperGrokSession? {
        guard let raw = KeychainStore.get(account: account),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SuperGrokSession.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self),
              let raw = String(data: data, encoding: .utf8) else { return }
        KeychainStore.set(raw, account: Self.account)
    }

    static func clear() {
        KeychainStore.delete(account: account)
    }
}

struct SuperGrokDeviceLogin: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let interval: TimeInterval
    let expiresAt: Date
}

enum SuperGrokAuthError: LocalizedError {
    case deviceCodeFailed(String)
    case timedOut
    case denied
    case refreshFailed
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .deviceCodeFailed(let detail):
            return "Could not start SuperGrok sign-in: \(detail)"
        case .timedOut:
            return "Sign-in timed out. Try again."
        case .denied:
            return "Sign-in was denied on the xAI page."
        case .refreshFailed:
            return "SuperGrok session expired. Sign in again."
        case .missingCredential:
            return "Sign in with SuperGrok or add an xAI API key in Settings."
        }
    }
}

actor SuperGrokAuth {
    static let shared = SuperGrokAuth()

    /// Public xAI device-code client used by Hermes / other SuperGrok CLIs.
    /// Not a secret. No client_secret.
    private static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let scope = "openid profile email offline_access grok-cli:access api:access"
    private static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func startDeviceLogin() async throws -> SuperGrokDeviceLogin {
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form([
            "client_id": Self.clientID,
            "scope": Self.scope
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SuperGrokAuthError.deviceCodeFailed(body.prefix(180).description)
        }

        let json = try decodeObject(data)
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String else {
            throw SuperGrokAuthError.deviceCodeFailed("missing device_code")
        }

        let urlString = (json["verification_uri_complete"] as? String)
            ?? (json["verification_url_complete"] as? String)
            ?? (json["verification_uri"] as? String)
            ?? (json["verification_url"] as? String)
            ?? "https://auth.x.ai/activate"
        guard let url = URL(string: urlString) else {
            throw SuperGrokAuthError.deviceCodeFailed("bad verification URL")
        }

        let interval = TimeInterval(intValue(json["interval"]) ?? 5)
        let expires = TimeInterval(intValue(json["expires_in"]) ?? 900)
        return SuperGrokDeviceLogin(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            interval: max(1, interval),
            expiresAt: Date().addingTimeInterval(expires)
        )
    }

    func pollUntilAuthorized(_ login: SuperGrokDeviceLogin) async throws {
        var wait = login.interval
        while Date() < login.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            try Task.checkCancellation()

            let (data, response) = try await postToken([
                "grant_type": Self.deviceGrant,
                "device_code": login.deviceCode,
                "client_id": Self.clientID
            ])
            let http = response as? HTTPURLResponse
            let json = (try? decodeObject(data)) ?? [:]
            let error = json["error"] as? String

            if let http, (200..<300).contains(http.statusCode), json["access_token"] as? String != nil {
                try persistTokens(json)
                return
            }

            switch error {
            case "authorization_pending", nil where http?.statusCode == 400:
                continue
            case "slow_down":
                wait += 5
            case "access_denied":
                throw SuperGrokAuthError.denied
            case "expired_token":
                throw SuperGrokAuthError.timedOut
            default:
                if http?.statusCode == 400 {
                    continue
                }
                let detail = (json["error_description"] as? String) ?? error ?? "token poll failed"
                throw SuperGrokAuthError.deviceCodeFailed(detail)
            }
        }
        throw SuperGrokAuthError.timedOut
    }

    /// Prefer a fresh SuperGrok access token. Fall back to a pasted API key.
    func validAccessToken(fallbackAPIKey: String) async throws -> String {
        if SuperGrokSession.isSignedIn {
            return try await freshAccessToken()
        }
        let key = fallbackAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SuperGrokAuthError.missingCredential }
        return key
    }

    func signOut() {
        SuperGrokSession.clear()
    }

    // MARK: - Private

    private func freshAccessToken() async throws -> String {
        if let session = SuperGrokSession.load(), session.isAccessTokenFresh, !session.accessToken.isEmpty {
            return session.accessToken
        }
        return try await refresh()
    }

    private func refresh() async throws -> String {
        guard let stored = SuperGrokSession.load(), !stored.refreshToken.isEmpty else {
            SuperGrokSession.clear()
            throw SuperGrokAuthError.refreshFailed
        }

        let (data, response) = try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": stored.refreshToken,
            "client_id": Self.clientID
        ])
        let http = response as? HTTPURLResponse
        let json = (try? decodeObject(data)) ?? [:]
        guard let http, (200..<300).contains(http.statusCode), json["access_token"] as? String != nil else {
            SuperGrokSession.clear()
            throw SuperGrokAuthError.refreshFailed
        }
        try persistTokens(json, previous: stored)
        return SuperGrokSession.load()?.accessToken ?? ""
    }

    private func persistTokens(_ json: [String: Any], previous: SuperGrokSession? = SuperGrokSession.load()) throws {
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw SuperGrokAuthError.refreshFailed
        }
        let refresh = (json["refresh_token"] as? String)?.nilIfEmpty ?? previous?.refreshToken ?? ""
        let ttl = TimeInterval(intValue(json["expires_in"]) ?? 21_600)
        let hint = previous?.accountHint
            ?? email(fromIDToken: json["id_token"] as? String)
        SuperGrokSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(ttl),
            accountHint: hint
        ).save()
    }

    private func postToken(_ fields: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(fields)
        return try await session.data(for: request)
    }

    private func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func decodeObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw SuperGrokAuthError.deviceCodeFailed("non-object JSON")
        }
        return dict
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private func email(fromIDToken token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (obj["email"] as? String)
            ?? (obj["preferred_username"] as? String)
            ?? (obj["name"] as? String)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

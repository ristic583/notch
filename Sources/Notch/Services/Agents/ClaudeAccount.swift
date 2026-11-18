import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// Notch's own sign-in to the Claude account, used only to read the official
/// usage numbers: the same ones `/usage` shows in Claude Code.
///
/// It runs Claude Code's sign-in (OAuth with PKCE, redirected to a local port)
/// but asks only for `user:profile`, which can read usage and cannot run Claude.
/// The tokens live in the Keychain and are renewed here, so after the first
/// sign-in it needs no attention. None of this is public API; if it breaks,
/// usage falls back to the Claude Code status line.
@MainActor
@Observable
final class ClaudeAccount {
    private(set) var isSignedIn = false
    private(set) var isSigningIn = false
    /// Last sign-in or usage failure, shown in Settings.
    private(set) var problem: String?

    /// Called after a successful sign-in, so usage can load right away.
    @ObservationIgnored var onSignIn: (() -> Void)?
    /// Called after signing out, so the numbers it brought go with it.
    @ObservationIgnored var onSignOut: (() -> Void)?

    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private var renewal: Task<Tokens, Error>?
    @ObservationIgnored private var catcher: RedirectCatcher?

    private enum Endpoint {
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code's
        static let authorize = URL(string: "https://claude.com/cai/oauth/authorize")!
        static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
        static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        static let scope = "user:profile"
    }

    struct Usage {
        var fiveHour: UsageWindow?
        var sevenDay: UsageWindow?
    }

    init() {
        tokens = Keychain.load()
        isSignedIn = tokens != nil
    }

    // MARK: - Sign-in

    func signIn() {
        guard !isSigningIn else { return }
        problem = nil
        isSigningIn = true
        Task {
            defer {
                isSigningIn = false
                catcher = nil
            }
            do {
                let catcher = try RedirectCatcher()
                self.catcher = catcher
                let redirect = "http://localhost:\(try await catcher.start())/callback"
                let verifier = Self.randomToken()
                let state = Self.randomToken()
                NSWorkspace.shared.open(Self.authorizeURL(redirect: redirect, verifier: verifier, state: state))

                let query = try await catcher.callback(timeout: 300)
                guard query["state"] == state, let code = query["code"] else { throw SignInError.denied }
                store(try await Self.requestTokens([
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": redirect,
                    "client_id": Endpoint.clientID,
                    "code_verifier": verifier,
                    "state": state,
                ]))
                onSignIn?()
            } catch is CancellationError {
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    func cancelSignIn() {
        catcher?.cancel()
    }

    func signOut(problem: String? = nil) {
        Keychain.delete()
        tokens = nil
        isSignedIn = false
        self.problem = problem
        onSignOut?()
    }

    // MARK: - Usage

    /// The official 5-hour and weekly windows. Renews the token when needed.
    func fetchUsage() async throws -> Usage {
        var token = try await accessToken()
        for attempt in 0..<2 {
            var request = URLRequest(url: Endpoint.usage, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401, attempt == 0 {
                token = try await accessToken(renew: true)
                continue
            }
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let error = SignInError.http(status, Self.errorCode(in: data))
                problem = Self.describe(error)
                throw error
            }
            problem = nil
            return Usage(fiveHour: Self.window(json["five_hour"]), sevenDay: Self.window(json["seven_day"]))
        }
        throw SignInError.http(401, nil)
    }

    /// `utilization` is already a percentage; `resets_at` is null until the window starts.
    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let resets = (dict["resets_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return UsageWindow(usedPercent: percent, resetsAt: resets)
    }

    // MARK: - Tokens

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private func store(_ fresh: Tokens) {
        tokens = fresh
        Keychain.save(fresh)
        isSignedIn = true
    }

    /// A token good for at least five more minutes; concurrent callers share one renewal.
    private func accessToken(renew: Bool = false) async throws -> String {
        guard let tokens else { throw SignInError.signedOut }
        if !renew, tokens.expires.timeIntervalSinceNow > 300 { return tokens.access }
        if let renewal { return try await renewal.value.access }

        let task = Task { [refresh = tokens.refresh] in
            try await Self.requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Endpoint.clientID,
                "scope": Endpoint.scope,
            ])
        }
        renewal = task
        defer { renewal = nil }
        do {
            var fresh = try await task.value
            if fresh.refresh.isEmpty { fresh.refresh = tokens.refresh } // not every renewal rotates it
            store(fresh)
            return fresh.access
        } catch SignInError.revoked {
            signOut(problem: "The Claude sign-in expired. Connect again.")
            throw SignInError.revoked
        }
    }

    private static func requestTokens(_ body: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: Endpoint.token, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard status == 200, let access = json?["access_token"] as? String else {
            let code = errorCode(in: data)
            throw code == "invalid_grant" ? SignInError.revoked : SignInError.http(status, code)
        }
        let lifetime = (json?["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Tokens(access: access,
                      refresh: json?["refresh_token"] as? String ?? "",
                      expires: Date().addingTimeInterval(lifetime))
    }

    /// OAuth errors are a plain string, API errors an object with a type.
    private static func errorCode(in data: Data) -> String? {
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
        return error as? String ?? (error as? [String: Any])?["type"] as? String
    }

    // MARK: - Helpers

    private static func authorizeURL(redirect: String, verifier: String, state: String) -> URL {
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: Endpoint.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Endpoint.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: Endpoint.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SignInError.timedOut: "Sign-in timed out. Try again."
        case SignInError.denied: "Sign-in was cancelled in the browser."
        case SignInError.revoked: "The Claude sign-in expired. Connect again."
        case let SignInError.http(status, code): "Claude answered \(status)\(code.map { " (\($0))" } ?? "")."
        default: error.localizedDescription
        }
    }
}

private enum SignInError: Error {
    case signedOut, timedOut, denied, revoked
    case http(Int, String?)
}

// MARK: - Keychain

private enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Notch Claude sign-in",
        kSecAttrAccount as String: "oauth",
    ]

    static func load<T: Decodable>() -> T? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let update = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

// MARK: - Redirect

/// One-shot HTTP listener on the loopback interface that catches the browser
/// coming back from claude.com with the authorization code.
private final class RedirectCatcher: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "notch.claude.sign-in")
    // Touched only on `queue`.
    private var bound: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    /// Binds a free port and returns it.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                bound = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                listener.start(queue: queue)
            }
        }
    }

    /// The query of the `/callback` request.
    func callback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    waiting = continuation
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(SignInError.timedOut)) }
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(.failure(CancellationError())) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            bound?.resume(returning: listener.port?.rawValue ?? 0)
            bound = nil
        case let .failed(error):
            bound?.resume(throwing: error)
            bound = nil
            finish(.failure(error))
        default:
            break
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiting?.resume(with: result)
        waiting = nil
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            // "GET /callback?code=…&state=… HTTP/1.1"
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first
            let target = requestLine?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://localhost" + target),
                  components.path == "/callback" else {
                return reply(connection, status: "404 Not Found", body: "")
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value }
            reply(connection, status: "200 OK", body: Self.page(query["code"] != nil
                ? "Notch is connected to Claude. You can close this tab."
                : "Sign-in was cancelled. You can close this tab."))
            finish(.success(query))
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ message: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Notch</title>
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#161616;color:#eee;font:15px -apple-system,sans-serif">
        <p>\(message)</p></body>
        """
    }
}

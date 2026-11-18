// 편지 서버(Supabase)와 말하는 부분. SDK 없이 HTTPS 요청만 쓴다.
// 서버 주소와 공개용 키는 앱 번들의 server.json 에서 읽는다 (omogi/server.json → build.sh 가 복사). 없으면 서버 기능은 꺼진다.
//   {"url": "https://xxxx.supabase.co", "key": "sb_publishable_..."}
// 이 키는 앱에 넣어 배포하라고 만든 공개용 키다. 관리용 비밀 키(sb_secret_...)는 절대 넣지 말 것.
// 로그인은 가입 절차 없는 익명 로그인이고, 받은 로그인 정보는 키체인에 둔다. 서버 쪽 규칙은 omogi/server/schema.sql.
import Cocoa

struct ServerError: Error {
    let code: String
    /// 사용자에게 보여 줄 말
    var message: String {
        switch code {
        case "omogi:no_such_code": return "그 친구 코드를 찾지 못했어요."
        case "omogi:too_many_requests": return "보낸 친구 요청이 너무 많아요. 수락을 기다려 주세요."
        case "omogi:not_friends": return "아직 친구가 아니에요."
        case "omogi:daily_limit": return "한 친구에게는 하루에 \(letterDailyLimit)통까지만 보낼 수 있어요."
        case "omogi:bad_envelope": return "편지가 너무 길어요."
        case "omogi:not_registered", "omogi:not_signed_in": return "편지 서버에 다시 연결해야 해요."
        case "offline": return "서버에 닿지 못했어요. 인터넷 연결을 확인해 주세요."
        case "anonymous_disabled": return "서버에서 익명 로그인이 꺼져 있어요."
        default: return "서버에서 문제가 생겼어요. (\(code))"
        }
    }
}

final class Server {
    static let shared: Server? = {
        guard let url = Bundle.main.url(forResource: "server", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = (j["url"] as? String).flatMap({ URL(string: $0) }), base.scheme == "https",
              let key = j["key"] as? String, !key.isEmpty, !key.hasPrefix("sb_secret") else { return nil }
        return Server(base: base, key: key)
    }()

    private struct Session: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private let base: URL
    private let key: String
    private let queue = DispatchQueue(label: "omogi.server")      // 한 번에 하나씩 (새로 고침 토큰은 한 번만 쓸 수 있다)
    private var session: Session?
    private let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.omogi.mac",
        kSecAttrAccount as String: "server-session",
    ]

    private init(base: URL, key: String) {
        self.base = base
        self.key = key
        var q = keychain
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            session = try? JSONDecoder().decode(Session.self, from: d)
        }
    }

    private func store(_ s: Session?) {
        session = s
        SecItemDelete(keychain as CFDictionary)
        guard let s = s, let data = try? JSONEncoder().encode(s) else { return }
        var add = keychain
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 이 Mac 의 로그인 정보를 지운다 (서버의 계정은 그대로다).
    func forget() { queue.async { self.store(nil) } }

    // 요청 하나를 보내고 끝날 때까지 기다린다 (queue 위에서만 부른다). 돌려주는 값: HTTP 상태(닿지 못하면 0)와 JSON.
    private func post(_ path: String, _ body: [String: Any], bearer: String?) -> (Int, Any?) {
        guard let url = URL(string: path, relativeTo: base) else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        if let b = bearer { req.setValue("Bearer " + b, forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var result: (Int, Any?) = (0, nil)
        let wait = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            result = (status, json)
            wait.signal()
        }.resume()
        wait.wait()
        return result
    }

    private func adopt(_ json: Any?) -> Session? {
        guard let j = json as? [String: Any], let access = j["access_token"] as? String,
              let refresh = j["refresh_token"] as? String else { return nil }
        let s = Session(access: access, refresh: refresh,
                        expires: Date().addingTimeInterval((j["expires_in"] as? Double) ?? 3600))
        store(s)
        return s
    }

    // 쓸 수 있는 로그인 정보를 돌려준다: 있으면 그대로, 곧 끝나면 새로 고치고, 없으면 익명으로 새로 로그인한다.
    private func ensureSession(forceRefresh: Bool = false) -> Result<Session, ServerError> {
        if let s = session {
            if !forceRefresh, s.expires.timeIntervalSinceNow > 90 { return .success(s) }
            let (status, json) = post("/auth/v1/token?grant_type=refresh_token", ["refresh_token": s.refresh], bearer: nil)
            if let fresh = adopt(json) { return .success(fresh) }
            if status == 0 || status >= 500 { return .failure(ServerError(code: "offline")) }
            Log.write("서버: 로그인 정보를 새로 고치지 못해 새로 로그인함 (\(status))")
            store(nil)                                   // 더는 쓸 수 없는 토큰이다. 아래에서 새로 로그인한다.
        }
        let (status, json) = post("/auth/v1/signup", [:], bearer: nil)
        if let fresh = adopt(json) { return .success(fresh) }
        if status == 0 || status >= 500 { return .failure(ServerError(code: "offline")) }
        Log.write("서버: 익명 로그인 실패 (\(status))")
        return .failure(ServerError(code: status == 422 ? "anonymous_disabled" : "signin_\(status)"))
    }

    /// 서버 함수(public.omogi_*)를 부른다. 결과는 메인 스레드에서 돌려준다.
    func call(_ function: String, _ args: [String: Any] = [:], done: @escaping (Result<Any?, ServerError>) -> Void) {
        queue.async {
            var outcome: Result<Any?, ServerError> = .failure(ServerError(code: "offline"))
            for attempt in 0..<2 {
                switch self.ensureSession(forceRefresh: attempt == 1) {
                case .failure(let e):
                    outcome = .failure(e)
                case .success(let session):
                    let (status, json) = self.post("/rest/v1/rpc/" + function, args, bearer: session.access)
                    if status == 401, attempt == 0 { continue }          // 토큰이 막 끝났으면 새로 고쳐 한 번 더
                    if (200..<300).contains(status) { outcome = .success(json) }
                    else if status == 0 { outcome = .failure(ServerError(code: "offline")) }
                    else {
                        let msg = (json as? [String: Any])?["message"] as? String ?? ""
                        outcome = .failure(ServerError(code: msg.hasPrefix("omogi:") ? msg : "http_\(status)"))
                        Log.write("서버: \(function) 실패 (\(status))")
                    }
                }
                break
            }
            DispatchQueue.main.async { done(outcome) }
        }
    }
}

/// 서버로 편지를 나르는 길.
final class ServerPost: LetterTransport {
    private let server: Server
    init(server: Server) { self.server = server }

    func send(envelope: Data, to friend: Friend, fromName: String, done: @escaping (Result<String, ServerError>) -> Void) {
        server.call("omogi_send_letter", ["p_to": friend.id, "p_envelope": envelope.base64EncodedString()]) { r in
            switch r {
            case .failure(let e): done(.failure(e))
            case .success(let v): done((v as? String).map { .success($0) } ?? .failure(ServerError(code: "bad_reply")))
            }
        }
    }

    func fetch(done: @escaping ([Arrival], [String]) -> Void) {
        server.call("omogi_fetch_mail") { r in
            guard case .success(let v) = r, let j = v as? [String: Any] else { done([], []); return }
            let arrived = (j["arrived"] as? [[String: Any]] ?? []).compactMap { a -> Arrival? in
                guard let id = a["id"] as? String, let env = (a["envelope"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
                return Arrival(id: id, fromName: a["from_name"] as? String ?? "친구", envelope: env)
            }
            done(arrived, j["lost"] as? [String] ?? [])
        }
    }

    func ack(arrived: [String], lost: [String]) {
        guard !arrived.isEmpty || !lost.isEmpty else { return }
        server.call("omogi_ack_mail", ["p_arrived": arrived, "p_lost": lost]) { _ in }
    }
}

// 편지: 친구에게 쓴 쪽지를 오모기가 물고 가서 30분~3시간 뒤에 전한다. 가끔은 잃어버린다.
//
// 나르는 길은 둘이다 (LetterTransport):
//   연습 배달 LoopbackPost — 나에게 보내면 이 Mac 안에서 시간이 지난 뒤 돌아온다. 서버를 쓰지 않는다.
//   서버 배달 ServerPost (server.swift) — 친구 코드로 맺은 친구에게 간다. 사용자가 "친구…" 창에서 시작해야만 켜진다.
//
// 편지는 받는 사람만 열 수 있게 잠가서 보낸다 (LetterCrypto). Windows 판과 맞춰야 하므로 형식을 바꾸지 말 것:
//   봉투 = [버전 1바이트 = 1] + [보내는 쪽 임시 공개 키, P-256 X9.63 비압축 65바이트] + [AES-256-GCM: nonce 12 + 암호문 + tag 16]
//   키   = HKDF-SHA256(ECDH(P-256) 공유 비밀, salt 없음, info = "omogi-letter-v1" + 임시 공개 키 + 받는 사람 공개 키, 32바이트)
import Cocoa
import CryptoKit

// 연습 배달의 규칙 (config.json 의 "letterMinMinutes", "letterMaxMinutes", "letterLossPercent").
// 실제 서버에서는 서버가 정하므로 이 값은 쓰이지 않는다.
var letterMinMinutes = 30.0
var letterMaxMinutes = 180.0
var letterLossPercent = 8.0
let letterMaxChars = 200
let letterDailyLimit = 5          // 친구 한 명에게 하루에 보낼 수 있는 수

// ───────────────────── 잠그기 ─────────────────────
enum LetterCrypto {
    private static let info = Data("omogi-letter-v1".utf8)
    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.omogi.mac",
        kSecAttrAccount as String: "letter-key-p256",
    ]
    private static var cached: P256.KeyAgreement.PrivateKey?

    /// 이 Mac 의 편지 열쇠. 처음 쓸 때 만들어 키체인에 넣는다.
    static func identity() -> P256.KeyAgreement.PrivateKey {
        if let k = cached { return k }
        var q = keychain
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
           let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: d) {
            cached = k
            return k
        }
        let k = P256.KeyAgreement.PrivateKey()
        var add = keychain
        add[kSecValueData as String] = k.rawRepresentation
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.write("편지: 열쇠를 키체인에 넣지 못함 (\(status))") }
        cached = k
        return k
    }

    static var publicKey: Data { return identity().publicKey.x963Representation }

    private static func key(_ secret: SharedSecret, _ eph: Data, _ recipient: Data) -> SymmetricKey {
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info + eph + recipient, outputByteCount: 32)
    }

    static func seal(_ text: String, to recipient: Data) -> Data? {
        guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: recipient) else { return nil }
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.x963Representation
        guard let secret = try? eph.sharedSecretFromKeyAgreement(with: pub),
              let box = try? AES.GCM.seal(Data(text.utf8), using: key(secret, ephPub, recipient)),
              let combined = box.combined else { return nil }
        return Data([1]) + ephPub + combined
    }

    static func open(_ envelope: Data, with me: P256.KeyAgreement.PrivateKey = identity()) -> String? {
        let bytes = [UInt8](envelope)
        guard bytes.count > 1 + 65 + 28, bytes[0] == 1 else { return nil }
        let ephPub = Data(bytes[1..<66])
        guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: ephPub),
              let secret = try? me.sharedSecretFromKeyAgreement(with: pub),
              let box = try? AES.GCM.SealedBox(combined: Data(bytes[66...])),
              let plain = try? AES.GCM.open(box, using: key(secret, ephPub, me.publicKey.x963Representation)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}

// ───────────────────── 배달 ─────────────────────
struct Friend {
    var id: String
    var name: String
    var publicKey: Data?         // 서로 친구가 된 뒤에만 있다
    var status: String           // "practice"(나 자신), "accepted", "pending"
    var incoming: Bool           // 상대가 나에게 보낸 요청
}

struct Arrival {
    var id: String
    var fromName: String
    var envelope: Data
}

/// 편지를 나르는 길.
protocol LetterTransport {
    /// 잠근 편지를 맡긴다. 언제 도착할지, 잃어버릴지는 맡은 쪽이 정하고 보낸 쪽에는 알려 주지 않는다. 돌려주는 값은 편지 ID.
    func send(envelope: Data, to friend: Friend, fromName: String, done: @escaping (Result<String, ServerError>) -> Void)
    /// 나에게 도착한 편지와, 내가 보낸 것 가운데 잃어버린 편지의 ID 를 가져온다.
    func fetch(done: @escaping (_ arrived: [Arrival], _ lost: [String]) -> Void)
    /// 저장을 마쳤으니 맡은 쪽에서 지워도 된다고 알린다.
    func ack(arrived: [String], lost: [String])
}

/// 연습 배달: 서버 노릇을 이 Mac 의 파일 하나가 한다. 보낸 편지가 시간이 지나면 나에게 돌아온다.
final class LoopbackPost: LetterTransport {
    private struct Item: Codable {
        var id: String
        var fromName: String
        var envelope: Data
        var deliverAt: Date
        var lost: Bool
    }
    private let url = supportDir.appendingPathComponent("practice-post.json")

    private func load() -> [Item] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? LetterBox.decoder.decode([Item].self, from: d)) ?? []
    }

    func send(envelope: Data, to friend: Friend, fromName: String, done: @escaping (Result<String, ServerError>) -> Void) {
        let lo = min(letterMinMinutes, letterMaxMinutes), hi = max(letterMinMinutes, letterMaxMinutes)
        let item = Item(id: UUID().uuidString, fromName: fromName, envelope: envelope,
                        deliverAt: Date().addingTimeInterval(Double.random(in: lo...hi) * 60),
                        lost: Double.random(in: 0..<100) < letterLossPercent)
        LetterBox.write(load() + [item], to: url)
        done(.success(item.id))
    }

    func fetch(done: @escaping ([Arrival], [String]) -> Void) {
        let due = load().filter { $0.deliverAt <= Date() }
        done(due.filter { !$0.lost }.map { Arrival(id: $0.id, fromName: $0.fromName, envelope: $0.envelope) },
             due.filter { $0.lost }.map { $0.id })
    }

    func ack(arrived: [String], lost: [String]) {
        let gone = Set(arrived + lost)
        guard !gone.isEmpty else { return }
        LetterBox.write(load().filter { !gone.contains($0.id) }, to: url)
    }
}

// ───────────────────── 편지함 ─────────────────────
final class LetterBox {
    struct Received: Codable {
        var id: String
        var fromName: String
        var body: String
        var at: Date
        var read: Bool
    }
    struct Sent: Codable {
        var id: String
        var toID: String
        var toName: String
        var body: String
        var at: Date
        var lost: Bool
        var lostTold: Bool       // 잃어버렸다고 펫이 알렸는지
    }
    struct Profile: Codable {
        var code: String
        var name: String
    }
    private struct Saved: Codable {
        var inbox: [Received] = []
        var sent: [Sent] = []
        var profile: Profile?    // 편지 서버에 등록한 내 이름과 친구 코드
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        guard let data = try? e.encode(value) else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)   // 나만 읽을 수 있게
    }

    private let url = supportDir.appendingPathComponent("letters.json")
    private var saved = Saved()
    private let practice = LoopbackPost()
    private let server = Server.shared
    private lazy var serverPost = server.map { ServerPost(server: $0) }
    private let pet: Pet?
    private var timer: Timer?
    private var lastServerPoll = Date.distantPast
    private(set) var serverFriends: [Friend] = []      // 친구와 요청 (서버에서 받은 것)
    var onChange: (() -> Void)?

    var inbox: [Received] { return saved.inbox }
    var sent: [Sent] { return saved.sent }
    var unreadCount: Int { return saved.inbox.filter { !$0.read }.count }
    var profile: Profile? { return saved.profile }
    var serverAvailable: Bool { return server != nil }
    /// 편지 서버를 쓰는 중인지. 사용자가 "친구…" 창에서 시작해야 true 가 된다.
    var online: Bool { return server != nil && saved.profile != nil }
    /// 편지를 보낼 수 있는 상대: 연습 상대(나 자신)와 서로 친구가 된 사람들.
    var friends: [Friend] {
        return [Friend(id: "self", name: "나에게 (연습)", publicKey: LetterCrypto.publicKey, status: "practice", incoming: false)]
            + serverFriends.filter { $0.status == "accepted" && $0.publicKey != nil }
    }

    init(pet: Pet?) {
        self.pet = pet
        if let d = try? Data(contentsOf: url), let s = try? LetterBox.decoder.decode(Saved.self, from: d) { saved = s }
    }

    private func save() {
        LetterBox.write(saved, to: url)
        onChange?()
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let s = self else { return }
            // 이미 서버를 쓰고 있었으면 등록을 한 번 더 확인한다 (로그인 정보가 사라졌어도 여기서 다시 이어진다).
            if let p = s.saved.profile, s.server != nil { s.goOnline(name: p.name) { _ in } }
            s.poll()
        }
    }

    // ── 서버: 시작·친구 ──
    /// 편지 서버에 내 이름과 편지 공개 키를 등록하고 친구 코드를 받는다. 실패하면 이유를 돌려준다.
    func goOnline(name: String, done: @escaping (String?) -> Void) {
        guard let server = server else { done("이 앱에는 편지 서버가 연결되어 있지 않아요."); return }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard !clean.isEmpty else { done("이름을 적어 주세요."); return }
        server.call("omogi_register", ["p_name": clean, "p_public_key": LetterCrypto.publicKey.base64EncodedString()]) { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .failure(let e): done(e.message)
            case .success(let v):
                guard let j = v as? [String: Any], let code = j["code"] as? String else { done("서버의 대답을 읽지 못했어요."); return }
                if s.saved.profile?.code != code { Log.write("편지: 서버에 등록함") }
                s.saved.profile = Profile(code: code, name: clean)
                s.save()
                s.refreshFriends { done(nil) }
            }
        }
    }

    /// 서버의 내 계정(친구 관계, 오가는 중인 편지)을 지우고 서버 쓰기를 그만둔다. 이 Mac 에 받은 편지는 남는다.
    func leaveServer(done: @escaping (String?) -> Void) {
        guard let server = server else { done(nil); return }
        server.call("omogi_delete_account") { [weak self] r in
            if case .failure(let e) = r { done(e.message); return }
            server.forget()
            self?.saved.profile = nil
            self?.serverFriends = []
            self?.save()
            Log.write("편지: 서버 계정을 지움")
            done(nil)
        }
    }

    func refreshFriends(done: (() -> Void)? = nil) {
        guard online, let server = server else { done?(); return }
        server.call("omogi_list_friends") { [weak self] r in
            if case .success(let v) = r, let rows = v as? [[String: Any]] {
                self?.serverFriends = rows.compactMap { j in
                    guard let id = j["id"] as? String, let name = j["name"] as? String, let status = j["status"] as? String else { return nil }
                    return Friend(id: id, name: name, publicKey: (j["public_key"] as? String).flatMap { Data(base64Encoded: $0) },
                                  status: status, incoming: j["incoming"] as? Bool ?? false)
                }
                self?.onChange?()
            }
            done?()
        }
    }

    /// 친구 코드로 요청한다. 결과를 한 줄로 돌려준다.
    func requestFriend(code: String, done: @escaping (String) -> Void) {
        guard online, let server = server else { done("먼저 편지 서버를 시작해 주세요."); return }
        server.call("omogi_request_friend", ["p_code": code]) { [weak self] r in
            switch r {
            case .failure(let e): done(e.message)
            case .success(let v):
                let j = v as? [String: Any]
                let name = j?["name"] as? String ?? "친구"
                let accepted = j?["status"] as? String == "accepted"
                self?.refreshFriends { done(accepted ? "\(name)와(과) 친구가 됐어요." : "\(name)에게 요청을 보냈어요. 수락하면 친구가 돼요.") }
            }
        }
    }

    func respond(to friend: Friend, accept: Bool, done: @escaping () -> Void) {
        server?.call("omogi_respond_friend", ["p_friend": friend.id, "p_accept": accept]) { [weak self] _ in self?.refreshFriends(done: done) }
    }

    func remove(_ friend: Friend, block: Bool, done: @escaping () -> Void) {
        server?.call("omogi_remove_friend", ["p_friend": friend.id, "p_block": block]) { [weak self] _ in self?.refreshFriends(done: done) }
    }

    // ── 보내기·받기 ──
    private func transport(for friendID: String) -> LetterTransport? {
        return friendID == "self" ? practice : serverPost
    }

    /// 편지를 맡긴다. 보낼 수 없으면 이유를, 보냈으면 nil 을 돌려준다.
    func send(_ text: String, to friend: Friend, done: @escaping (String?) -> Void) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { done("편지가 비어 있어요."); return }
        if body.count > letterMaxChars { done("\(letterMaxChars)자까지만 쓸 수 있어요."); return }
        let today = saved.sent.filter { $0.toID == friend.id && $0.at > Date().addingTimeInterval(-86400) }.count
        if today >= letterDailyLimit { done("한 친구에게는 하루에 \(letterDailyLimit)통까지만 보낼 수 있어요."); return }
        guard let key = friend.publicKey, let envelope = LetterCrypto.seal(body, to: key),
              let via = transport(for: friend.id) else { done("편지를 잠그지 못했어요."); return }
        via.send(envelope: envelope, to: friend, fromName: "나") { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .failure(let e): done(e.message)
            case .success(let id):
                s.saved.sent.insert(Sent(id: id, toID: friend.id, toName: friend.name, body: body, at: Date(), lost: false, lostTold: false), at: 0)
                s.save()
                Log.write("편지: 한 통을 맡김 (\(friend.id == "self" ? "연습" : "서버"))")
                _ = s.pet?.carryOut()
                done(nil)
            }
        }
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        for i in saved.inbox.indices { saved.inbox[i].read = true }
        save()
    }

    /// 새로 온 것을 가져오고, 펫이 알릴 것이 있으면 알린다. 연습 배달은 매번, 서버는 5분에 한 번 (now 면 바로) 확인한다.
    func poll(serverNow: Bool = false) {
        collect(from: practice)
        if online, let post = serverPost, serverNow || Date().timeIntervalSince(lastServerPoll) > 300 {
            lastServerPoll = Date()
            collect(from: post)
        }
    }

    private func collect(from via: LetterTransport) {
        via.fetch { [weak self] arrived, lost in
            guard let s = self else { return }
            var changed = false
            for a in arrived where !s.saved.inbox.contains(where: { $0.id == a.id }) {
                // 열 수 없는 편지(열쇠가 바뀐 경우 등)도 서버에서는 지워야 하므로, 못 읽었다는 말로 남긴다.
                let body = LetterCrypto.open(a.envelope) ?? "(이 편지는 열 수 없었어요.)"
                s.saved.inbox.insert(Received(id: a.id, fromName: a.fromName, body: body, at: Date(), read: false), at: 0)
                changed = true
            }
            for id in lost {
                if let i = s.saved.sent.firstIndex(where: { $0.id == id }), !s.saved.sent[i].lost {
                    s.saved.sent[i].lost = true
                    changed = true
                }
            }
            if changed {
                Log.write("편지: 도착 \(arrived.count)통, 누락 \(lost.count)통")
                s.save()
            }
            via.ack(arrived: arrived.map { $0.id }, lost: lost)      // 저장한 뒤에 지우게 한다
            s.present()
        }
    }

    // 펫이 지금 나설 수 없으면 다음 확인 때 다시 시도한다.
    private func present() {
        guard let pet = pet else { return }
        if let first = saved.inbox.first(where: { !$0.read }), !pet.isHoldingMail {
            let n = unreadCount
            _ = pet.bringMail(n > 1 ? "편지 \(n)통이 왔어요 — 눌러서 열기" : "\(first.fromName)의 편지가 왔어요 — 눌러서 열기")
            return
        }
        if let i = saved.sent.firstIndex(where: { $0.lost && !$0.lostTold }), !pet.isHoldingMail,
           pet.reportLost("\(saved.sent[i].toName)에게 가던 편지를 잃어버렸어요…") {
            saved.sent[i].lostTold = true
            save()
        }
    }
}

// ───────────────────── 창 ─────────────────────
final class LetterWindows: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private let box: LetterBox
    private var compose: NSWindow?
    private var inbox: NSWindow?
    private var friendsWindow: NSWindow?
    private var composeFriends: [Friend] = []
    private let friendPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor = NSTextView(frame: .zero)
    private let counter = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "오모기에게 맡기기", target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: ["받은 편지", "보낸 편지"], trackingMode: .selectOne, target: nil, action: nil)
    private let list = NSTextView(frame: .zero)
    private let nameField = NSTextField(string: "")
    private let codeField = NSTextField(string: "")
    private var friendsNote = ""
    private var rowFriends: [Friend] = []
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 a h:mm"
        return f
    }()

    init(box: LetterBox) {
        self.box = box
        super.init()
        box.onChange = { [weak self] in
            guard let s = self else { return }
            if s.inbox?.isVisible == true { s.renderList() }
            if s.friendsWindow?.isVisible == true { s.renderFriends() }
        }
    }

    private func makeWindow(_ title: String, _ size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func front(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func warn(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // ── 편지 쓰기 ──
    func showCompose() {
        if compose == nil {
            let w = makeWindow("편지 쓰기", NSSize(width: 380, height: 300))
            let root = w.contentView!
            let toLabel = NSTextField(labelWithString: "받는 사람")
            toLabel.frame = NSRect(x: 20, y: 262, width: 60, height: 18)
            friendPicker.frame = NSRect(x: 84, y: 256, width: 276, height: 28)
            let scroll = NSScrollView(frame: NSRect(x: 20, y: 96, width: 340, height: 150))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            editor.frame = NSRect(x: 0, y: 0, width: 340, height: 150)
            editor.autoresizingMask = [.width]
            editor.isRichText = false
            editor.font = .systemFont(ofSize: 14)
            editor.textContainerInset = NSSize(width: 6, height: 8)
            editor.delegate = self
            scroll.documentView = editor
            counter.frame = NSRect(x: 20, y: 70, width: 340, height: 18)
            counter.alignment = .right
            counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let hint = NSTextField(wrappingLabelWithString: "30분에서 3시간 사이에 도착해요. 가끔은 오모기가 길을 잃기도 해요.")
            hint.frame = NSRect(x: 20, y: 18, width: 190, height: 44)
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            sendButton.frame = NSRect(x: 214, y: 20, width: 150, height: 32)
            sendButton.bezelStyle = .rounded
            sendButton.keyEquivalent = "\r"
            sendButton.keyEquivalentModifierMask = [.command]
            sendButton.target = self
            sendButton.action = #selector(sendTapped)
            for v in [toLabel, friendPicker, scroll, counter, hint, sendButton] as [NSView] { root.addSubview(v) }
            compose = w
        }
        composeFriends = box.friends
        friendPicker.removeAllItems()
        friendPicker.addItems(withTitles: composeFriends.map { $0.name })
        // 친구가 있으면 연습 상대 대신 첫 친구를 골라 둔다.
        if composeFriends.count > 1 { friendPicker.selectItem(at: 1) }
        updateCounter()
        front(compose!)
        compose!.makeFirstResponder(editor)
        box.refreshFriends()
    }

    func textDidChange(_ notification: Notification) { updateCounter() }

    private func updateCounter() {
        let n = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).count
        counter.stringValue = "\(n) / \(letterMaxChars)"
        counter.textColor = n > letterMaxChars ? .systemRed : .secondaryLabelColor
        sendButton.isEnabled = n > 0 && n <= letterMaxChars
    }

    @objc private func sendTapped() {
        let i = friendPicker.indexOfSelectedItem
        guard i >= 0, i < composeFriends.count else { return }
        sendButton.isEnabled = false
        box.send(editor.string, to: composeFriends[i]) { [weak self] problem in
            guard let s = self else { return }
            if let problem = problem {
                s.updateCounter()
                s.warn("편지를 보내지 못했어요", problem)
                return
            }
            s.editor.string = ""
            s.updateCounter()
            s.compose?.orderOut(nil)
        }
    }

    // ── 편지함 ──
    func showInbox() {
        if inbox == nil {
            let w = makeWindow("편지함", NSSize(width: 420, height: 480))
            let root = w.contentView!
            tabs.frame = NSRect(x: 110, y: 440, width: 200, height: 26)
            tabs.selectedSegment = 0
            tabs.target = self
            tabs.action = #selector(tabChanged)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 428))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            list.frame = NSRect(x: 0, y: 0, width: 420, height: 428)
            list.autoresizingMask = [.width]
            list.isEditable = false
            list.drawsBackground = false
            list.textContainerInset = NSSize(width: 16, height: 14)
            scroll.documentView = list
            root.addSubview(tabs)
            root.addSubview(scroll)
            inbox = w
        }
        if box.unreadCount > 0 { tabs.selectedSegment = 0 }
        renderList()
        front(inbox!)
        box.markAllRead()       // 새 편지 표시는 이번에 그린 화면에만 남는다
        box.poll(serverNow: true)
    }

    @objc private func tabChanged() { renderList() }

    private func renderList() {
        let out = NSMutableAttributedString()
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 18
        bodyStyle.lineSpacing = 3
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyStyle]
        let tag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemRed]
        func add(_ title: String, _ mark: String?, _ text: String) {
            out.append(NSAttributedString(string: title, attributes: head))
            if let m = mark { out.append(NSAttributedString(string: "  " + m, attributes: tag)) }
            // 편지 안의 줄바꿈은 문단이 갈리지 않게 줄 나눔 문자로 바꾼다.
            out.append(NSAttributedString(string: "\n" + text.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", attributes: body))
        }
        if tabs.selectedSegment == 0 {
            for l in box.inbox { add("\(l.fromName) · \(stamp.string(from: l.at))", l.read ? nil : "새 편지", l.body) }
            if box.inbox.isEmpty { add("아직 받은 편지가 없어요", nil, "메뉴의 ‘편지 쓰기’에서 나에게 연습 편지를 보내 보세요.") }
        } else {
            for l in box.sent { add("\(l.toName) · \(stamp.string(from: l.at))", l.lost ? "잃어버림" : nil, l.body) }
            if box.sent.isEmpty { add("아직 보낸 편지가 없어요", nil, "") }
        }
        list.textStorage?.setAttributedString(out)
        list.scrollToBeginningOfDocument(nil)
    }

    // ── 친구 ──
    func showFriends() {
        if friendsWindow == nil { friendsWindow = makeWindow("친구", NSSize(width: 400, height: 460)) }
        friendsNote = ""
        renderFriends()
        front(friendsWindow!)
        box.refreshFriends()
    }

    private func label(_ text: String, _ frame: NSRect, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.frame = frame
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func button(_ title: String, _ frame: NSRect, _ action: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.frame = frame
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.tag = tag
        return b
    }

    // 창의 내용을 지금 상태에 맞게 새로 그린다 (서버 없음 / 시작 전 / 사용 중).
    private func renderFriends() {
        guard let root = friendsWindow?.contentView else { return }
        // 글을 쓰던 중이면 지우지 않는다.
        if let editing = friendsWindow?.firstResponder as? NSTextView, editing.delegate === nameField || editing.delegate === codeField,
           !editing.string.isEmpty { return }
        root.subviews.forEach { $0.removeFromSuperview() }
        let W: CGFloat = 400
        var y: CGFloat = 460

        guard box.serverAvailable else {
            root.addSubview(label("아직 편지 서버가 연결되지 않았어요", NSRect(x: 24, y: 400, width: W - 48, height: 22), size: 15, weight: .semibold))
            root.addSubview(label("지금은 ‘편지 쓰기’에서 나에게 보내는 연습 편지만 쓸 수 있어요. 서버가 준비되면 이 창에서 친구 코드를 주고받아 친구를 맺게 됩니다.",
                                  NSRect(x: 24, y: 330, width: W - 48, height: 60), color: .secondaryLabelColor))
            return
        }

        guard let me = box.profile else {
            root.addSubview(label("친구와 편지 주고받기", NSRect(x: 24, y: 404, width: W - 48, height: 22), size: 15, weight: .semibold))
            root.addSubview(label("시작하면 아래 이름과 편지를 잠그는 공개 키가 편지 서버에 저장되고, 친구 코드가 만들어져요. 이메일이나 비밀번호는 필요 없어요.\n\n편지 내용은 받는 친구만 열 수 있게 잠가서 보내므로 서버에서는 읽을 수 없어요. 언제든 이 창에서 서버의 내 정보를 지울 수 있어요.",
                                  NSRect(x: 24, y: 270, width: W - 48, height: 124), color: .secondaryLabelColor))
            root.addSubview(label("친구에게 보일 이름", NSRect(x: 24, y: 236, width: 150, height: 18), size: 12))
            nameField.frame = NSRect(x: 24, y: 206, width: 220, height: 24)
            nameField.placeholderString = "20자까지"
            root.addSubview(nameField)
            let go = button("시작하기", NSRect(x: 252, y: 202, width: 100, height: 30), #selector(startTapped))
            go.controlSize = .regular
            go.font = .systemFont(ofSize: 13)
            root.addSubview(go)
            if !friendsNote.isEmpty { root.addSubview(label(friendsNote, NSRect(x: 24, y: 160, width: W - 48, height: 36), size: 12, color: .systemRed)) }
            return
        }

        root.addSubview(label("\(me.name)의 친구 코드", NSRect(x: 24, y: y - 44, width: 200, height: 18), size: 12, color: .secondaryLabelColor))
        let code = label(me.code, NSRect(x: 24, y: y - 78, width: 200, height: 30), size: 24, weight: .semibold)
        code.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        code.isSelectable = true
        root.addSubview(code)
        root.addSubview(button("코드 복사", NSRect(x: 290, y: y - 74, width: 86, height: 26), #selector(copyCode)))
        y -= 96

        root.addSubview(label("친구의 코드를 받았다면", NSRect(x: 24, y: y - 20, width: 200, height: 18), size: 12, color: .secondaryLabelColor))
        codeField.frame = NSRect(x: 24, y: y - 50, width: 220, height: 24)
        codeField.placeholderString = "8자 코드"
        codeField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        root.addSubview(codeField)
        root.addSubview(button("친구 요청", NSRect(x: 252, y: y - 52, width: 86, height: 26), #selector(requestTapped)))
        y -= 60
        if !friendsNote.isEmpty {
            root.addSubview(label(friendsNote, NSRect(x: 24, y: y - 20, width: W - 48, height: 18), size: 12, color: .secondaryLabelColor))
            y -= 24
        }

        let line = NSBox(frame: NSRect(x: 24, y: y - 8, width: W - 48, height: 1))
        line.boxType = .separator
        root.addSubview(line)
        y -= 16

        rowFriends = box.serverFriends.sorted { ($0.incoming ? 0 : $0.status == "accepted" ? 1 : 2) < ($1.incoming ? 0 : $1.status == "accepted" ? 1 : 2) }
        if rowFriends.isEmpty {
            root.addSubview(label("아직 친구가 없어요. 위의 코드를 친구에게 보내거나, 친구의 코드를 입력해 보세요.",
                                  NSRect(x: 24, y: y - 44, width: W - 48, height: 36), size: 12, color: .secondaryLabelColor))
        }
        for (i, f) in rowFriends.prefix(8).enumerated() {
            let state = f.incoming ? "친구 요청이 왔어요" : f.status == "accepted" ? "친구" : "수락을 기다리는 중"
            root.addSubview(label(f.name, NSRect(x: 24, y: y - 24, width: 150, height: 18), weight: .medium))
            root.addSubview(label(state, NSRect(x: 24, y: y - 40, width: 170, height: 15), size: 11, color: .secondaryLabelColor))
            if f.incoming {
                root.addSubview(button("수락", NSRect(x: 204, y: y - 36, width: 52, height: 24), #selector(acceptTapped(_:)), tag: i))
                root.addSubview(button("거절", NSRect(x: 260, y: y - 36, width: 52, height: 24), #selector(declineTapped(_:)), tag: i))
                root.addSubview(button("차단", NSRect(x: 316, y: y - 36, width: 52, height: 24), #selector(blockTapped(_:)), tag: i))
            } else {
                root.addSubview(button(f.status == "accepted" ? "끊기" : "취소", NSRect(x: 260, y: y - 36, width: 52, height: 24), #selector(removeTapped(_:)), tag: i))
                if f.status == "accepted" {
                    root.addSubview(button("차단", NSRect(x: 316, y: y - 36, width: 52, height: 24), #selector(blockTapped(_:)), tag: i))
                }
            }
            y -= 44
        }
        root.addSubview(button("서버에서 내 정보 지우기…", NSRect(x: 20, y: 14, width: 170, height: 24), #selector(leaveTapped)))
    }

    private func redrawFriends(note: String) {
        friendsNote = note
        nameField.stringValue = ""
        codeField.stringValue = ""
        friendsWindow?.makeFirstResponder(nil)
        renderFriends()
    }

    @objc private func startTapped() {
        let name = nameField.stringValue
        friendsWindow?.makeFirstResponder(nil)
        box.goOnline(name: name) { [weak self] problem in
            if problem == nil { self?.box.poll(serverNow: true) }
            self?.redrawFriends(note: problem ?? "")
        }
    }

    @objc private func copyCode() {
        guard let code = box.profile?.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        redrawFriends(note: "코드를 복사했어요. 친구에게 보내 주세요.")
    }

    @objc private func requestTapped() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        box.requestFriend(code: code) { [weak self] note in self?.redrawFriends(note: note) }
    }

    private func friend(_ sender: NSButton) -> Friend? {
        return sender.tag < rowFriends.count ? rowFriends[sender.tag] : nil
    }

    @objc private func acceptTapped(_ sender: NSButton) {
        guard let f = friend(sender) else { return }
        box.respond(to: f, accept: true) { [weak self] in self?.redrawFriends(note: "\(f.name)와(과) 친구가 됐어요.") }
    }

    @objc private func declineTapped(_ sender: NSButton) {
        guard let f = friend(sender) else { return }
        box.respond(to: f, accept: false) { [weak self] in self?.redrawFriends(note: "") }
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard let f = friend(sender) else { return }
        box.remove(f, block: false) { [weak self] in self?.redrawFriends(note: "") }
    }

    @objc private func blockTapped(_ sender: NSButton) {
        guard let f = friend(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "\(f.name)을(를) 차단할까요?"
        alert.informativeText = "서로 편지를 보낼 수 없게 되고, 이 사람은 다시 친구 요청을 할 수 없어요. 오는 중이던 편지도 사라져요."
        alert.addButton(withTitle: "차단")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        box.remove(f, block: true) { [weak self] in self?.redrawFriends(note: "") }
    }

    @objc private func leaveTapped() {
        let alert = NSAlert()
        alert.messageText = "서버에서 내 정보를 지울까요?"
        alert.informativeText = "친구 관계와 오가는 중인 편지가 모두 사라지고, 친구 코드도 없어져요. 이 Mac 에 이미 받은 편지는 남아요. 되돌릴 수 없어요."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        box.leaveServer { [weak self] problem in self?.redrawFriends(note: problem ?? "") }
    }
}

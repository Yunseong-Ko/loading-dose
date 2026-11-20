import Cocoa

// 마을: 친구들의 오모기를 한 창에서 본다. 친구에게 보이는 것은 입은 옷, 오늘 맞힌 문제 수(끌 수 있다),
// 오늘 공부한 시간, 지금 공부 중인지다. 편지와 달리 이 정보는 잠그지 않고 서버에 올라간다.

/// 공부 시작 / 끝. 켜 둔 동안의 시간을 오늘 공부 시간으로 센다. 5분 넘게 손을 놓으면 저절로 멈춘다.
final class Study {
    static let shared = Study()
    static let changed = Notification.Name("OmogiStudyChanged")
    static let idleLimit = 300.0
    private let d = UserDefaults.standard
    private var since: Date?
    private var timer: Timer?

    var studying: Bool { return since != nil }

    private var stored: Int {
        return d.string(forKey: "study.day") == Wardrobe.today() ? d.integer(forKey: "study.secs") : 0
    }

    /// 오늘 공부한 시간(초). 지금 공부 중이면 지금까지를 더한다.
    var secondsToday: Int {
        return stored + (since.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0)
    }

    func start() {
        guard since == nil else { return }
        since = Date()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.watch() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.post(name: Study.changed, object: nil)
    }

    /// idleCut: 손을 놓고 있던 시간은 빼고 멈춘다.
    func stop(idleCut: Double = 0) {
        guard let s = since else { return }
        let secs = max(0, Int(Date().timeIntervalSince(s) - idleCut))
        d.set(min(86400, stored + secs), forKey: "study.secs")
        d.set(Wardrobe.today(), forKey: "study.day")
        since = nil
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.post(name: Study.changed, object: nil)
    }

    private func watch() {
        let idle = idleSeconds()
        if idle >= Study.idleLimit { stop(idleCut: idle) }
    }

    static func clock(_ secs: Int) -> String {
        let m = secs / 60
        return m >= 60 ? "\(m / 60)시간 \(m % 60)분" : "\(m)분"
    }
}

struct Villager {
    var id: String
    var name: String
    var handle: String?
    var wear: String
    var day: String
    var correct: Int?
    var studySecs: Int
    var studying: Bool
    var seenSecs: Int?
}

final class Village {
    static let changed = Notification.Name("OmogiVillageChanged")
    private let server = Server.shared
    private let letters: LetterBox
    private let pet: Pet
    private var timer: Timer?
    private var lastPushed = "", lastPushAt = Date.distantPast, lastPokeCheck = Date.distantPast
    private(set) var villagers: [Villager] = []
    /// 서버가 아직 마을을 모른다 (schema.sql 을 다시 실행하지 않았다)
    private(set) var unsupported = false
    private(set) var note = ""

    /// 오늘 맞힌 문제 수를 친구에게 보일지
    static var shareCorrect: Bool {
        get { return UserDefaults.standard.object(forKey: "village.shareCorrect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "village.shareCorrect") }
    }

    var online: Bool { return letters.online && server != nil && !unsupported }

    init(letters: LetterBox, pet: Pet) {
        self.letters = letters
        self.pet = pet
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        for name in [Wardrobe.changed, Study.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.push() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.tick() }
    }

    private func tick() {
        push()
        if online, Date().timeIntervalSince(lastPokeCheck) >= 60 { fetchPokes() }
    }

    private static func missing(_ e: ServerError) -> Bool {
        return e.code.contains("404") || e.code.contains("PGRST202") || e.code.contains("not_found")
    }

    /// 내 상태가 바뀌었거나, 공부 중이라 소식을 이어 줘야 할 때 서버에 올린다.
    func push(force: Bool = false) {
        guard online, let server = server else { return }
        let wd = Wardrobe.shared, st = Study.shared
        let correct: Any = Village.shareCorrect ? wd.correctToday : NSNull()
        let sig = "\(wd.wornNames)|\(Wardrobe.today())|\(correct)|\(st.studying)|\(st.secondsToday / 300)"
        let heartbeat = st.studying && Date().timeIntervalSince(lastPushAt) >= 240
        guard force || sig != lastPushed || heartbeat else { return }
        lastPushed = sig
        lastPushAt = Date()
        server.call("omogi_set_status", ["p_wear": wd.wornNames, "p_day": Wardrobe.today(), "p_correct": correct,
                                         "p_study_secs": st.secondsToday, "p_studying": st.studying]) { [weak self] r in
            if case .failure(let e) = r {
                if Village.missing(e) { self?.unsupported = true }
                Log.write("마을: 상태 올리기 실패 \(e.code)")
            }
        }
    }

    /// 친구들의 상태를 받아 온다.
    func refresh(done: (() -> Void)? = nil) {
        guard letters.online, let server = server else { note = "친구를 맺으면 여기에 모여요. 설정 창의 \"친구…\"에서 시작하세요."; done?(); return }
        server.call("omogi_village") { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .success(let v):
                s.unsupported = false
                s.note = ""
                s.villagers = ((v as? [[String: Any]]) ?? []).compactMap { j in
                    guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
                    return Villager(id: id, name: name, handle: j["handle"] as? String, wear: j["wear"] as? String ?? "",
                                    day: j["day"] as? String ?? "", correct: j["correct"] as? Int,
                                    studySecs: j["study_secs"] as? Int ?? 0, studying: j["studying"] as? Bool ?? false,
                                    seenSecs: j["seen_secs"] as? Int)
                }
            case .failure(let e):
                if Village.missing(e) {
                    s.unsupported = true
                    s.note = "서버가 아직 마을 기능을 모릅니다. (서버 준비가 끝나면 보여요.)"
                } else {
                    s.note = "지금은 친구 소식을 받아 오지 못했어요. (\(e.message))"
                }
            }
            NotificationCenter.default.post(name: Village.changed, object: nil)
            done?()
        }
    }

    func poke(_ v: Villager, done: @escaping (String) -> Void) {
        guard let server = server else { return }
        server.call("omogi_poke", ["p_to": v.id]) { r in
            switch r {
            case .success: done("\(v.name)에게 날아갔어요")
            case .failure(let e): done(e.code.contains("daily_limit") ? "오늘은 \(v.name)를 충분히 찔렀어요" : "못 갔어요 (\(e.message))")
            }
        }
    }

    private func fetchPokes() {
        guard let server = server else { return }
        lastPokeCheck = Date()
        server.call("omogi_fetch_pokes") { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .success(let v):
                let list = (v as? [[String: Any]]) ?? []
                // 같은 친구가 여러 번 찔렀으면 한 번만 온다.
                var seen = Set<String>()
                for j in list {
                    guard let name = j["name"] as? String, seen.insert(j["from"] as? String ?? name).inserted else { continue }
                    let n = list.filter { ($0["from"] as? String) == (j["from"] as? String) }.count
                    s.pet.visit(wear: Wardrobe.shared.rows(forNames: j["wear"] as? String ?? ""),
                                text: n > 1 ? "\(name)가 콕콕 \(n)번 찔렀어요" : "\(name)가 콕 찔렀어요")
                }
                if !list.isEmpty { Log.write("마을: 콕 \(list.count)번 받음") }
            case .failure(let e):
                if Village.missing(e) { s.unsupported = true }
            }
        }
    }

    /// 편지가 도착했을 때: 보낸 친구의 새가 그 친구 옷을 입고 잠깐 들른다 (이름이 같은 친구가 하나일 때만).
    func letterArrived(from name: String) {
        guard online else { return }
        refresh { [weak self] in
            guard let s = self else { return }
            let same = s.villagers.filter { $0.name == name }
            guard same.count == 1 else { return }
            s.pet.visit(wear: Wardrobe.shared.rows(forNames: same[0].wear), text: "\(name)가 편지를 보냈어요")
        }
    }
}

/// 마을 창
final class VillageWindow: NSObject {
    private let village: Village
    private let pet: Pet
    private var window: NSWindow?
    private var timer: Timer?
    private var flash = ""
    private let W: CGFloat = 460, rowH: CGFloat = 62

    init(village: Village, pet: Pet) {
        self.village = village
        self.pet = pet
        super.init()
        for name in [Village.changed, Study.changed, Wardrobe.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if self?.window?.isVisible == true { self?.render() }
            }
        }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 560), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "마을"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                guard let s = self, s.window?.isVisible == true else { return }
                s.village.refresh()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        render()
        village.push(force: true)
        village.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String, _ frame: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = frame
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private func picture(_ rows: [Int], _ frame: NSRect, scale: CGFloat) -> NSImageView {
        let v = NSImageView(frame: frame)
        v.image = pet.previewImage(wear: rows, scale: scale)
        v.imageScaling = .scaleNone
        return v
    }

    private func line(_ v: Villager) -> String {
        var parts: [String] = []
        if v.studying { parts.append("공부 중") }
        let today = v.day == Wardrobe.today()
        if today, let c = v.correct { parts.append("오늘 \(c)문제") }
        if today, v.studySecs >= 60 { parts.append("공부 \(Study.clock(v.studySecs))") }
        if parts.isEmpty {
            guard let s = v.seenSecs else { return "아직 소식이 없어요" }
            return s < 3600 ? "조금 전에 다녀감" : s < 86400 ? "\(s / 3600)시간 전에 다녀감" : "\(s / 86400)일 전에 다녀감"
        }
        return parts.joined(separator: "  ·  ")
    }

    private func render() {
        guard let w = window, let root = w.contentView else { return }
        let rows = max(1, min(8, village.villagers.count))
        let H = 150 + rowH * CGFloat(rows) + 46
        if abs(root.bounds.height - H) > 0.5 {
            var f = w.frame
            let dh = H - root.bounds.height
            f.origin.y -= dh
            f.size.height += dh
            w.setFrame(f, display: true)
        }
        root.subviews.forEach { $0.removeFromSuperview() }
        let wd = Wardrobe.shared, st = Study.shared

        // 나
        root.addSubview(picture(wd.wornRows, NSRect(x: 20, y: H - 132, width: 144, height: 112), scale: 4))
        root.addSubview(label("나", NSRect(x: 180, y: H - 50, width: 200, height: 22), size: 17, weight: .semibold))
        var mine = "오늘 \(wd.correctToday)문제"
        if st.secondsToday >= 60 { mine += "  ·  공부 \(Study.clock(st.secondsToday))" }
        if st.studying { mine = "공부 중  ·  " + mine }
        root.addSubview(label(mine, NSRect(x: 180, y: H - 72, width: 260, height: 16), size: 12, color: .secondaryLabelColor))
        let b = NSButton(title: st.studying ? "공부 끝" : "공부 시작", target: self, action: #selector(toggleStudy))
        b.frame = NSRect(x: 176, y: H - 110, width: 110, height: 30)
        b.bezelStyle = .rounded
        root.addSubview(b)
        let share = NSButton(checkboxWithTitle: "오늘 맞힌 수 보이기", target: self, action: #selector(toggleShare(_:)))
        share.frame = NSRect(x: 296, y: H - 104, width: 150, height: 18)
        share.font = .systemFont(ofSize: 11)
        share.state = Village.shareCorrect ? .on : .off
        root.addSubview(share)
        root.addSubview(label("공부 중엔 책을 봐요. 5분 손을 놓으면 저절로 멈춥니다.", NSRect(x: 180, y: H - 132, width: 270, height: 14), size: 10.5, color: .tertiaryLabelColor))
        let sep = NSBox(frame: NSRect(x: 20, y: H - 146, width: W - 40, height: 1))
        sep.boxType = .separator
        root.addSubview(sep)

        // 친구들
        var y = H - 150 - rowH
        if village.villagers.isEmpty {
            let msg = village.note.isEmpty ? "아직 친구가 없어요. 설정 창의 \"친구…\"에서 친구를 맺으면 여기에 모여요." : village.note
            let l = NSTextField(wrappingLabelWithString: msg)
            l.frame = NSRect(x: 24, y: y + 8, width: W - 48, height: 40)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            root.addSubview(l)
        }
        for v in village.villagers.prefix(8) {
            root.addSubview(picture(wd.rows(forNames: v.wear), NSRect(x: 20, y: y, width: 72, height: 56), scale: 2))
            root.addSubview(label(v.handle.map { "\(v.name) (@\($0))" } ?? v.name, NSRect(x: 100, y: y + 32, width: 240, height: 18), size: 13, weight: .medium))
            root.addSubview(label(line(v), NSRect(x: 100, y: y + 13, width: 240, height: 16), size: 11, color: v.studying ? .systemGreen : .secondaryLabelColor))
            let p = NSButton(title: "콕", target: self, action: #selector(poke(_:)))
            p.frame = NSRect(x: W - 92, y: y + 14, width: 72, height: 30)
            p.bezelStyle = .rounded
            p.identifier = NSUserInterfaceItemIdentifier(v.id)
            root.addSubview(p)
            y -= rowH
        }
        let foot = flash.isEmpty ? "친구에게 보이는 것: 입은 옷, 오늘 맞힌 수(끌 수 있음), 공부 시간, 공부 중인지." : flash
        root.addSubview(label(foot, NSRect(x: 20, y: 16, width: W - 40, height: 16), size: 11, color: flash.isEmpty ? .tertiaryLabelColor : .labelColor))
    }

    @objc private func toggleStudy() {
        if Study.shared.studying { Study.shared.stop() } else { Study.shared.start() }
    }

    @objc private func toggleShare(_ sender: NSButton) {
        Village.shareCorrect = sender.state == .on
        village.push(force: true)
    }

    @objc private func poke(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let v = village.villagers.first(where: { $0.id == id }) else { return }
        sender.isEnabled = false
        village.poke(v) { [weak self] text in
            guard let s = self else { return }
            s.flash = text
            s.render()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if s.flash == text { s.flash = ""; s.render() } }
        }
    }

    // 동작 확인용
    func snapshot(to url: URL) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 동작 확인용: 서버 없이 친구 목록을 채워 넣는다.
    func debugFill(_ list: [Villager]) { village.debugSet(list); render() }
}

extension Village {
    func debugSet(_ list: [Villager]) { villagers = list }
}

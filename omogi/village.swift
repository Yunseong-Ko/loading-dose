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

/// 이름 뒤에 붙는 조사 (받침이 있으면 a, 없으면 b). 한글이 아니면 b.
func josa(_ name: String, _ a: String, _ b: String) -> String {
    guard let u = name.unicodeScalars.last?.value, u >= 0xAC00, u <= 0xD7A3 else { return name + b }
    return name + ((u - 0xAC00) % 28 == 0 ? b : a)
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
    private var lastRefresh = Date.distantPast
    private var nextPlayAt = Date().addingTimeInterval(Double.random(in: 180...480))
    private(set) var villagers: [Villager] = []
    /// 서버가 아직 마을을 모른다 (schema.sql 을 다시 실행하지 않았다)
    private(set) var unsupported = false
    private(set) var note = ""

    /// 오늘 맞힌 문제 수를 친구에게 보일지
    static var shareCorrect: Bool {
        get { return UserDefaults.standard.object(forKey: "village.shareCorrect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "village.shareCorrect") }
    }

    /// 접속해 있는 친구의 새가 가끔 내 화면에 놀러 올지
    static var playVisits: Bool {
        get { return UserDefaults.standard.object(forKey: "village.playVisits") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "village.playVisits") }
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
        // 창을 열지 않아도 10분에 한 번은 친구 소식을 받아 둔다 (놀러 올 친구를 고르려고).
        if online, Village.playVisits, Date().timeIntervalSince(lastRefresh) >= 600 { refresh() }
        if online, Village.playVisits, Date() >= nextPlayAt { playVisit() }
    }

    /// 지금 접속해 있는 친구 (공부 중이거나, 15분 안에 소식을 올린 친구)
    static func around(_ v: Villager) -> Bool { return v.studying || (v.seenSecs ?? Int.max) < 900 }

    /// 접속해 있는 친구 가운데 하나가 놀러 와서 30초쯤 뛰어놀다 간다. 25~50분에 한 번.
    @discardableResult
    func playVisit(now: Bool = false) -> Bool {
        guard pet.isShown, pet.visitorCount == 0, let v = villagers.filter(Village.around).randomElement() else {
            if !now { nextPlayAt = Date().addingTimeInterval(120) }
            return false
        }
        nextPlayAt = Date().addingTimeInterval(Double.random(in: 1500...3000))
        let text = v.studying && Study.shared.studying ? "\(v.name)도 공부 중이에요" : "\(josa(v.name, "이", "가")) 놀러 왔어요"
        pet.visit(wear: Wardrobe.shared.rows(forNames: v.wear), text: text, play: true)
        Log.write("마을: 친구 새가 놀러 옴")
        return true
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
        lastRefresh = Date()
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
            case .failure(let e): done(e.code.contains("daily_limit") ? "오늘은 \(josa(v.name, "을", "를")) 충분히 찔렀어요" : "못 갔어요 (\(e.message))")
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
                                text: n > 1 ? "\(josa(name, "이", "가")) 콕콕 \(n)번 찔렀어요" : "\(josa(name, "이", "가")) 콕 찔렀어요")
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
            s.pet.visit(wear: Wardrobe.shared.rows(forNames: same[0].wear), text: "\(josa(name, "이", "가")) 편지를 보냈어요")
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
    private let W: CGFloat = 460, rowH: CGFloat = 62, yardH: CGFloat = 108
    private let yard = YardView()

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
            let a = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let s = self, s.window?.isVisible == true else { return }
                s.yard.step()
            }
            RunLoop.main.add(a, forMode: .common)
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
        let rows = max(1, min(7, village.villagers.count))
        let H = yardH + 20 + 150 + rowH * CGFloat(rows) + 46
        if abs(root.bounds.height - H) > 0.5 {
            var f = w.frame
            let dh = H - root.bounds.height
            f.origin.y -= dh
            f.size.height += dh
            w.setFrame(f, display: true)
        }
        root.subviews.forEach { $0.removeFromSuperview() }
        let wd = Wardrobe.shared, st = Study.shared

        // 마당: 나와 친구들의 새가 모여 있다.
        yard.frame = NSRect(x: 20, y: H - 12 - yardH, width: W - 40, height: yardH)
        var birds = [YardBird(id: "me", name: "나", sprites: pet.yardSprites(wear: wd.wornRows), state: st.studying ? .read : .play)]
        for v in village.villagers.prefix(7) {
            let state: YardBird.State = v.studying ? .read : Village.around(v) ? .play : (v.seenSecs ?? Int.max) < 6 * 3600 ? .rest : .sleep
            birds.append(YardBird(id: v.id, name: v.name, sprites: pet.yardSprites(wear: wd.rows(forNames: v.wear)), state: state))
        }
        yard.set(birds)
        root.addSubview(yard)
        let top = H - yardH - 20

        // 나
        root.addSubview(picture(wd.wornRows, NSRect(x: 20, y: top - 132, width: 144, height: 112), scale: 4))
        root.addSubview(label("나", NSRect(x: 180, y: top - 50, width: 200, height: 22), size: 17, weight: .semibold))
        var mine = "오늘 \(wd.correctToday)문제"
        if st.secondsToday >= 60 { mine += "  ·  공부 \(Study.clock(st.secondsToday))" }
        if st.studying { mine = "공부 중  ·  " + mine }
        root.addSubview(label(mine, NSRect(x: 180, y: top - 72, width: 260, height: 16), size: 12, color: .secondaryLabelColor))
        let b = NSButton(title: st.studying ? "공부 끝" : "공부 시작", target: self, action: #selector(toggleStudy))
        b.frame = NSRect(x: 176, y: top - 110, width: 110, height: 30)
        b.bezelStyle = .rounded
        root.addSubview(b)
        let share = NSButton(checkboxWithTitle: "오늘 맞힌 수 보이기", target: self, action: #selector(toggleShare(_:)))
        share.frame = NSRect(x: 296, y: top - 104, width: 150, height: 18)
        share.font = .systemFont(ofSize: 11)
        share.state = Village.shareCorrect ? .on : .off
        root.addSubview(share)
        let visits = NSButton(checkboxWithTitle: "친구 새가 가끔 놀러 오기", target: self, action: #selector(toggleVisits(_:)))
        visits.frame = NSRect(x: 178, y: top - 134, width: 200, height: 18)
        visits.font = .systemFont(ofSize: 11)
        visits.state = Village.playVisits ? .on : .off
        root.addSubview(visits)
        let sep = NSBox(frame: NSRect(x: 20, y: top - 146, width: W - 40, height: 1))
        sep.boxType = .separator
        root.addSubview(sep)

        // 친구들
        var y = top - 150 - rowH
        if village.villagers.isEmpty {
            let msg = village.note.isEmpty ? "아직 친구가 없어요. 설정 창의 \"친구…\"에서 친구를 맺으면 여기에 모여요." : village.note
            let l = NSTextField(wrappingLabelWithString: msg)
            l.frame = NSRect(x: 24, y: y + 8, width: W - 48, height: 40)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            root.addSubview(l)
        }
        for v in village.villagers.prefix(7) {
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

    @objc private func toggleVisits(_ sender: NSButton) { Village.playVisits = sender.state == .on }

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

struct YardBird {
    /// play: 접속 중이라 뛰어다닌다. read: 공부 중. rest: 얼마 전에 다녀가 앉아 있다. sleep: 한참 안 와서 잔다.
    enum State { case play, read, rest, sleep }
    var id: String, name: String
    var sprites: YardSprites?
    var state: State
    var x: CGFloat = 0, target: CGFloat? = nil, restUntil = 0.0, right = true
}

/// 마을 마당: 풀밭 위에 나와 친구들의 새가 모여 있다. 접속 중인 새는 뛰어다니고, 공부 중인 새는 책을 본다.
final class YardView: NSView {
    private var birds: [YardBird] = []
    private var last = 0.0
    private let k: CGFloat = 2

    /// 새 목록을 바꾼다. 이미 있던 새는 자리를 그대로 둔다.
    func set(_ list: [YardBird]) {
        let lo: CGFloat = 40, hi = max(41, bounds.width - 40)
        var next: [YardBird] = []
        for (i, var b) in list.enumerated() {
            if let old = birds.first(where: { $0.id == b.id }) {
                b.x = old.x; b.target = old.target; b.restUntil = old.restUntil; b.right = old.right
            } else {
                b.x = lo + (hi - lo) * (CGFloat(i) + 0.5) / CGFloat(max(1, list.count))
                b.right = i % 2 == 0
                b.restUntil = CACurrentMediaTime() + Double.random(in: 0.5...4)
            }
            if b.state != .play { b.target = nil }
            next.append(b)
        }
        birds = next
        needsDisplay = true
    }

    func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.3, max(0, now - last)))
        last = now
        let lo: CGFloat = 40, hi = max(41, bounds.width - 40)
        for i in birds.indices where birds[i].state == .play {
            if let tx = birds[i].target {
                let step = dt * 46, dx = tx - birds[i].x
                birds[i].right = dx > 0
                if abs(dx) <= step { birds[i].x = tx; birds[i].target = nil; birds[i].restUntil = now + Double.random(in: 1.5...6) }
                else { birds[i].x += dx > 0 ? step : -step }
            } else if now >= birds[i].restUntil, !reduceMotion() {
                birds[i].target = CGFloat.random(in: lo...hi)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let box = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        (dark ? NSColor(srgbRed: 0.16, green: 0.2, blue: 0.26, alpha: 1) : NSColor(srgbRed: 0.87, green: 0.94, blue: 0.98, alpha: 1)).setFill()
        box.fill()
        ctx.saveGState()
        box.addClip()
        (dark ? NSColor(srgbRed: 0.2, green: 0.34, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.66, green: 0.84, blue: 0.56, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 30).fill()
        (dark ? NSColor(srgbRed: 0.24, green: 0.4, blue: 0.26, alpha: 1) : NSColor(srgbRed: 0.56, green: 0.77, blue: 0.47, alpha: 1)).setFill()
        var gx: CGFloat = 6
        while gx < bounds.width { NSRect(x: gx, y: 30, width: 4, height: 2).fill(); NSRect(x: gx + 9, y: 14, width: 4, height: 2).fill(); gx += 26 }
        ctx.restoreGState()

        let now = CACurrentMediaTime()
        ctx.interpolationQuality = .none
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                    .foregroundColor: dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0.1, alpha: 0.85),
                                                    .paragraphStyle: style]
        for b in birds {
            guard let sp = b.sprites else { continue }
            var image = sp.sit, lift: CGFloat = 0
            switch b.state {
            case .read: image = sp.read[now.truncatingRemainder(dividingBy: 6.5) < 0.35 ? 1 : 0]
            case .sleep: image = sp.sleep[Int(now * 0.8) % 2]
            case .rest: image = now.truncatingRemainder(dividingBy: 4.3) < 0.18 ? sp.blink : sp.sit
            case .play:
                if b.target != nil {
                    let ph = (now * 3).truncatingRemainder(dividingBy: 1)
                    image = sp.hop[min(sp.hop.count - 1, Int(ph * Double(sp.hop.count)))]
                    lift = CGFloat(sin(ph * .pi)) * 7
                } else if now.truncatingRemainder(dividingBy: 3.7) < 0.18 { image = sp.blink }
            }
            let w = sp.size.width * k, h = sp.size.height * k
            let r = CGRect(x: (b.x - w / 2).rounded(), y: 18 + lift.rounded(), width: w, height: h)
            ctx.saveGState()
            if !b.right { ctx.translateBy(x: r.midX * 2, y: 0); ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(image, in: r)
            ctx.restoreGState()
            (b.name as NSString).draw(in: NSRect(x: b.x - 40, y: 3, width: 80, height: 14), withAttributes: attrs)
        }
    }
}

import Cocoa

// 꼬마 뱁새(문제를 맞히면 모이는 것)와 옷장.
// 전부 내 컴퓨터(UserDefaults)에만 저장한다. 서버로는 아무것도 보내지 않는다.

/// 옷 한 가지. row 는 pet/wear.png 의 줄 번호 (tools/make_pet_sprites.py 의 ITEMS 순서).
struct WearItem {
    enum Slot: String { case head = "머리", face = "얼굴", neck = "목" }
    let id: String
    let row: Int
    let name: String
    let slot: Slot
    let price: Int            // 0 이면 살 수 없고 조건을 채우면 받는다
    let note: String
}

final class Wardrobe {
    static let shared = Wardrobe()
    static let dailyCap = 60                  // 하루에 받을 수 있는 꼬마 뱁새
    static let medalGoal = 100                // 한 과목에서 이만큼 맞히면 메달
    static let changed = Notification.Name("OmogiWardrobeChanged")

    static let items: [WearItem] = [
        WearItem(id: "scarf", row: 0, name: "빨간 목도리", slot: .neck, price: 30, note: ""),
        WearItem(id: "straw", row: 1, name: "밀짚모자", slot: .head, price: 40, note: ""),
        WearItem(id: "glasses", row: 2, name: "동그란 안경", slot: .face, price: 40, note: ""),
        WearItem(id: "scrubcap", row: 3, name: "수술모", slot: .head, price: 60, note: ""),
        WearItem(id: "steth", row: 4, name: "청진기", slot: .neck, price: 80, note: ""),
        WearItem(id: "gradcap", row: 5, name: "학사모", slot: .head, price: 120, note: ""),
        WearItem(id: "crown", row: 6, name: "왕관", slot: .head, price: 250, note: ""),
        WearItem(id: "medal", row: 7, name: "메달", slot: .neck, price: 0, note: "한 과목에서 \(Wardrobe.medalGoal)문제를 맞히면 받아요"),
    ]

    private var d = UserDefaults.standard
    private var streak = 0

    /// 동작 확인용: 실제 기록을 건드리지 않게 빈 저장소로 바꾼다.
    func useScratchStore() {
        let name = "omogi.wardrobe.selftest"
        UserDefaults.standard.removePersistentDomain(forName: name)
        if let s = UserDefaults(suiteName: name) { d = s }
    }

    private(set) var minis: Int {
        get { return d.integer(forKey: "wardrobe.minis") }
        set { d.set(newValue, forKey: "wardrobe.minis") }
    }
    private(set) var owned: Set<String> {
        get { return Set(d.stringArray(forKey: "wardrobe.owned") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "wardrobe.owned") }
    }
    /// 자리(머리·얼굴·목)마다 입은 물건의 id
    private(set) var wornIDs: [String: String] {
        get { return d.dictionary(forKey: "wardrobe.worn") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "wardrobe.worn") }
    }
    private(set) var topicCorrect: [String: Int] {
        get { return d.dictionary(forKey: "wardrobe.topicCorrect") as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: "wardrobe.topicCorrect") }
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 오늘 받은 수
    var earnedToday: Int {
        return d.string(forKey: "wardrobe.day") == Wardrobe.today() ? d.integer(forKey: "wardrobe.dayCount") : 0
    }

    /// 꼬마 뱁새를 n 마리 받는다. 하루 상한을 넘는 만큼은 버린다. 실제로 받은 수를 돌려준다.
    @discardableResult
    func earn(_ n: Int) -> Int {
        let got = max(0, min(n, Wardrobe.dailyCap - earnedToday))
        guard got > 0 else { return 0 }
        d.set(Wardrobe.today(), forKey: "wardrobe.day")
        d.set(earnedToday + got, forKey: "wardrobe.dayCount")
        minis += got
        notify()
        return got
    }

    /// 문제에 답했을 때. 스스로 채점하는 빈칸 카드는 세지 않는다.
    /// popped: 5연속에 펑 터지는 동작이 켜져 있는지 (꺼져 있으면 5연속 보너스를 바로 준다).
    /// 돌려주는 값: 이번 답으로 받은 꼬마 뱁새 수
    @discardableResult
    func answered(correct: Bool, topic: String, selfGraded: Bool, popped: Bool) -> Int {
        guard !selfGraded else { return 0 }
        guard correct else { streak = 0; return 0 }
        streak += 1
        var got = earn(1)
        if streak >= 5 {
            streak = 0
            if !popped { got += earn(10) }
        }
        if !topic.isEmpty {
            var t = topicCorrect
            t[topic, default: 0] += 1
            topicCorrect = t
            if t[topic]! >= Wardrobe.medalGoal, !owned.contains("medal") {
                owned.insert("medal")
                notify()
            }
        }
        return got
    }

    func item(_ id: String) -> WearItem? { return Wardrobe.items.first { $0.id == id } }

    func buy(_ id: String) -> Bool {
        guard let it = item(id), it.price > 0, !owned.contains(id), minis >= it.price else { return false }
        minis -= it.price
        owned.insert(id)
        notify()
        return true
    }

    /// 입히거나(같은 자리의 다른 물건은 벗는다), 이미 입고 있으면 벗긴다.
    func toggleWear(_ id: String) {
        guard let it = item(id), owned.contains(id) else { return }
        var w = wornIDs
        if w[it.slot.rawValue] == id { w[it.slot.rawValue] = nil } else { w[it.slot.rawValue] = id }
        wornIDs = w
        notify()
    }

    func isWorn(_ id: String) -> Bool { return wornIDs.values.contains(id) }

    /// 입은 물건의 줄 번호: 목 → 얼굴 → 머리 순서로 겹친다.
    var wornRows: [Int] { return rows(for: wornIDs) }

    func rows(for worn: [String: String]) -> [Int] {
        return [WearItem.Slot.neck, .face, .head].compactMap { worn[$0.rawValue] }.compactMap { item($0)?.row }
    }

    /// 이 물건을 입혀 본 모습 (지금 입은 것에서 같은 자리만 바꾼다)
    func rowsTrying(_ id: String) -> [Int] {
        guard let it = item(id) else { return wornRows }
        var w = wornIDs
        w[it.slot.rawValue] = id
        return rows(for: w)
    }

    /// 메달까지 가장 가까운 과목과 맞힌 수
    var bestTopic: (String, Int)? { return topicCorrect.max { $0.value < $1.value }.map { ($0.key, $0.value) } }

    private func notify() { NotificationCenter.default.post(name: Wardrobe.changed, object: nil) }

    // 동작 확인용
    func debugGrant(_ n: Int) { minis += n; notify() }
}

/// 옷장 창: 가진 꼬마 뱁새 수, 입은 모습, 물건 목록.
final class WardrobeWindow: NSObject {
    private let pet: Pet
    private var window: NSWindow?
    private let W: CGFloat = 440, rowH: CGFloat = 56

    init(pet: Pet) {
        self.pet = pet
        super.init()
        NotificationCenter.default.addObserver(forName: Wardrobe.changed, object: nil, queue: .main) { [weak self] _ in
            if self?.window?.isVisible == true { self?.render() }
        }
    }

    func show() {
        if window == nil {
            let h = 150 + rowH * CGFloat(Wardrobe.items.count) + 44
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: h), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "옷장"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        render()
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
        v.wantsLayer = true
        v.layer?.magnificationFilter = .nearest
        return v
    }

    private func render() {
        guard let root = window?.contentView else { return }
        root.subviews.forEach { $0.removeFromSuperview() }
        let wd = Wardrobe.shared
        let H = root.bounds.height

        // 위: 지금 모습과 가진 수
        root.addSubview(picture(wd.wornRows, NSRect(x: 20, y: H - 132, width: 144, height: 112), scale: 4))
        root.addSubview(label("꼬마 뱁새 \(wd.minis)마리", NSRect(x: 180, y: H - 62, width: 240, height: 26), size: 20, weight: .semibold))
        root.addSubview(label("오늘 받은 수 \(wd.earnedToday) / \(Wardrobe.dailyCap)", NSRect(x: 180, y: H - 84, width: 240, height: 16), size: 12, color: .secondaryLabelColor))
        let how = NSTextField(wrappingLabelWithString: "문제를 맞히면 1마리. 다섯 번 연속으로 맞혀 펑 터지면, 흩어지는 꼬마들을 눌러서 잡으세요.")
        how.frame = NSRect(x: 180, y: H - 128, width: 240, height: 36)
        how.font = .systemFont(ofSize: 11)
        how.textColor = .secondaryLabelColor
        root.addSubview(how)
        let line = NSBox(frame: NSRect(x: 20, y: H - 146, width: W - 40, height: 1))
        line.boxType = .separator
        root.addSubview(line)

        // 물건 목록
        var y = H - 150 - rowH
        for it in Wardrobe.items {
            let have = wd.owned.contains(it.id)
            root.addSubview(picture(have ? wd.rowsTrying(it.id) : [it.row], NSRect(x: 20, y: y + 3, width: 72, height: 50), scale: 2))
            root.addSubview(label(it.name, NSRect(x: 100, y: y + 26, width: 190, height: 18), size: 13, weight: .medium))
            var sub = it.slot.rawValue
            if !have {
                if it.price > 0 { sub += "  ·  꼬마 뱁새 \(it.price)마리" }
                else if let (topic, n) = wd.bestTopic { sub += "  ·  \(it.note) (\(topic) \(n)/\(Wardrobe.medalGoal))" }
                else { sub += "  ·  \(it.note)" }
            } else if wd.isWorn(it.id) { sub += "  ·  입고 있어요" }
            root.addSubview(label(sub, NSRect(x: 100, y: y + 8, width: it.price > 0 || have ? 200 : 320, height: 16), size: 11, color: .secondaryLabelColor))

            if have || it.price > 0 {
                let title = have ? (wd.isWorn(it.id) ? "벗기" : "입히기") : "사기"
                let b = NSButton(title: title, target: self, action: have ? #selector(wear(_:)) : #selector(buy(_:)))
                b.frame = NSRect(x: W - 116, y: y + 12, width: 96, height: 30)
                b.bezelStyle = .rounded
                b.identifier = NSUserInterfaceItemIdentifier(it.id)
                b.isEnabled = have || wd.minis >= it.price
                root.addSubview(b)
            }
            y -= rowH
        }
        root.addSubview(label("꼬마 뱁새와 옷은 이 Mac 에만 저장됩니다.", NSRect(x: 20, y: 16, width: W - 40, height: 16), size: 11, color: .tertiaryLabelColor))
    }

    @objc private func buy(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, Wardrobe.shared.buy(id) else { return }
        Wardrobe.shared.toggleWear(id)          // 사자마자 입혀 본다
    }

    @objc private func wear(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        Wardrobe.shared.toggleWear(id)
    }

    // 동작 확인용: 창을 PNG 로 저장한다.
    func snapshot(to url: URL) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

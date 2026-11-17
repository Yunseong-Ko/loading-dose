// Loading Dose (Mac) — Claude·ChatGPT 데스크톱 앱에서 답변을 기다리는 동안 O/X 카드를 띄운다.
// 메뉴 막대에 상주하며, "손쉬운 사용" 권한으로 Enter 입력과 앱의 "중지" 버튼을 읽어 로딩을 감지한다.

import Cocoa
import ApplicationServices
import SQLite3
import PDFKit
import Security
import UniformTypeIdentifiers

// 감지 기준. ~/Library/Application Support/Enter/config.json 이 있으면 그 값으로 바뀐다 (loadTuning).
// 앱을 다시 빌드하면 손쉬운 사용 권한을 새로 줘야 하므로, 조정은 되도록 이 파일로 한다.
var targetBundleIDs: Set<String> = [   // 감지 대상 앱의 번들 ID
    "com.anthropic.claudefordesktop",
    "com.openai.chat",
    "com.openai.codex",
]
var stopWords = ["stop", "중지", "정지", "중단"]   // 버튼 이름에 이 중 하나가 들어 있으면 "생성 중"으로 본다
var stopExclude: [String] = []                     // 단, 이 중 하나가 들어 있는 버튼은 제외한다
var pendingTimeout: TimeInterval = 6               // Enter 뒤 생성이 시작되지 않으면 접는다
var endGrace: TimeInterval = 1.5                   // 중지 버튼이 사라진 뒤 이만큼 지나면 끝

private var tuningStamp: Date?

// config.json 이 바뀌었으면 다시 읽는다. 예:
// {"targets": ["com.anthropic.claudefordesktop"], "stopWords": ["stop"], "stopExclude": ["stop sharing"],
//  "pendingTimeout": 6, "endGrace": 1.5}
func loadTuning() {
    let url = Deck.dir.appendingPathComponent("config.json")
    guard let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
          stamp != tuningStamp else { return }
    tuningStamp = stamp
    guard let data = try? Data(contentsOf: url),
          let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        Log.write("config.json 을 읽지 못함 (형식 오류)")
        return
    }
    if let v = j["targets"] as? [String], !v.isEmpty { targetBundleIDs = Set(v) }
    if let v = j["stopWords"] as? [String], !v.isEmpty { stopWords = v.map { $0.lowercased() } }
    if let v = j["stopExclude"] as? [String] { stopExclude = v.map { $0.lowercased() } }
    if let v = j["pendingTimeout"] as? Double, v > 0 { pendingTimeout = v }
    if let v = j["endGrace"] as? Double, v > 0 { endGrace = v }
    if let v = j["blockSites"] as? [String] { blockSites = v.map { $0.lowercased() } }
    if let v = j["waterMinutes"] as? Double, v > 0 { waterMinutes = v }
    if let v = j["nestMinutes"] as? Double, v > 0 { nestMinutes = v }
    if let v = j["eyeMinutes"] as? Double, v > 0 { eyeMinutes = v }
    if let v = j["stretchMinutes"] as? Double, v > 0 { stretchMinutes = v }
    if let v = j["calendarLeadMinutes"] as? Double, v > 0 { calendarLeadMinutes = v }
    Log.write("config.json 적용: targets=\(targetBundleIDs.sorted()) stopWords=\(stopWords) stopExclude=\(stopExclude) pendingTimeout=\(pendingTimeout) endGrace=\(endGrace)")
}

let hardCap: TimeInterval = 600
let autoNextDelay: TimeInterval = 4

// ───────────────────────── 카드 ─────────────────────────

struct Card {
    let q: String
    let a: Bool
    let why: String
    var key: String = ""                                 // 기록용 (비우면 문장 자체)
    var cloze: [(text: String, blank: Bool)]? = nil      // 빈칸 카드일 때의 조각들. blank 인 조각이 가려진다
    var hint: String = ""
    var topic: String = ""                               // 단원명
    var statKey: String { return key.isEmpty ? q : key }
}

let defaultCards: [Card] = [
    Card(q: "제1형 당뇨병은 췌장 β세포의 자가면역성 파괴로 발생한다.", a: true, why: "β세포 파괴로 인슐린이 절대적으로 부족해진다."),
    Card(q: "심전도의 P파는 심실의 탈분극을 나타낸다.", a: false, why: "P파는 심방 탈분극, 심실 탈분극은 QRS파다."),
    Card(q: "와파린은 비타민 K 의존성 응고인자(II, VII, IX, X)의 합성을 억제한다.", a: true, why: "비타민 K 환원효소(VKORC1)를 억제한다."),
    Card(q: "좌심실에서 나온 혈액은 폐동맥으로 박출된다.", a: false, why: "좌심실 → 대동맥, 우심실 → 폐동맥."),
    Card(q: "그레이브스병에서는 혈중 TSH가 증가한다.", a: false, why: "갑상샘호르몬 과다에 의한 음성 되먹임으로 TSH는 감소한다."),
    Card(q: "헤파린의 해독제는 프로타민 황산염이다.", a: true, why: "와파린의 해독제는 비타민 K다."),
    Card(q: "부교감신경이 흥분하면 심박수가 증가한다.", a: false, why: "미주신경(부교감) 자극은 심박수를 낮춘다."),
    Card(q: "알도스테론은 집합관에서 Na⁺ 재흡수와 K⁺ 분비를 촉진한다.", a: true, why: "그래서 과다하면 고혈압·저칼륨혈증이 생긴다."),
    Card(q: "페니실린은 세균의 단백질 합성을 억제한다.", a: false, why: "펩티도글리칸 교차결합을 막아 세포벽 합성을 억제한다."),
    Card(q: "대사성 산증에서는 보상으로 과호흡이 나타날 수 있다.", a: true, why: "CO₂를 내보내 pH를 올리려는 호흡성 보상(쿠스마울 호흡)."),
]

// "문장 | O | 해설" 형식. 크롬 확장 프로그램과 같은 형식이다.
func parseCards(_ text: String) -> [Card] {
    var out: [Card] = []
    var topic = ""   // "## 과목" 줄 아래의 문제는 그 과목으로 묶인다
    for line in text.components(separatedBy: .newlines) {
        let raw = line.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("##") {
            topic = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            continue
        }
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        let parts = raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { continue }
        let ans = parts[1].uppercased()
        guard ans == "O" || ans == "X" else { continue }
        out.append(Card(q: parts[0], a: ans == "O", why: parts.dropFirst(2).joined(separator: " | "), topic: topic))
    }
    return out
}

// Anki 에서 가져온 빈칸(Cloze) 노트 하나. text 에는 {{c1::정답::힌트}} 표시가 그대로 들어 있다.
struct AnkiNote {
    let id: String
    let group: String   // 덱 경로의 앞 두 단계. 예: "Allen Cloze::순환기"
    let title: String
    let text: String
    let extra: String
}

let clozePattern = try! NSRegularExpression(pattern: "\\{\\{c(\\d+)::(.*?)\\}\\}", options: [.dotMatchesLineSeparators])

// 노트에서 빈칸 번호 하나를 골라 카드로 만든다. 나머지 빈칸은 정답을 채워서 보여 준다.
func makeClozeCard(_ n: AnkiNote) -> Card {
    let ns = n.text as NSString
    let matches = clozePattern.matches(in: n.text, range: NSRange(location: 0, length: ns.length))
    let indices = Array(Set(matches.map { ns.substring(with: $0.range(at: 1)) }))
    let chosen = indices.randomElement() ?? "1"
    var segs: [(text: String, blank: Bool)] = []
    var hint = ""
    var pos = 0
    for m in matches {
        if m.range.location > pos {
            segs.append((ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), false))
        }
        let inner = ns.substring(with: m.range(at: 2)).components(separatedBy: "::")
        let isBlank = ns.substring(with: m.range(at: 1)) == chosen
        if isBlank && inner.count > 1 { hint = inner[1] }
        segs.append((inner[0], isBlank))
        pos = m.range.location + m.range.length
    }
    if pos < ns.length { segs.append((ns.substring(from: pos), false)) }
    let plain = segs.map { $0.blank ? "[ ? ]" : $0.text }.joined()
    return Card(q: plain, a: true, why: n.extra, key: "a:" + n.id, cloze: segs, hint: hint, topic: n.title)
}

final class Deck {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Enter", isDirectory: true)
    static let file = dir.appendingPathComponent("cards.txt")
    static let ankiFile = dir.appendingPathComponent("anki.tsv")

    private(set) var cards = defaultCards
    private(set) var groups: [(name: String, count: Int)] = []   // 가져온 Anki 범위 목록
    private(set) var scope: Set<String> = []                     // 고른 시험범위
    private var ankiNotes: [AnkiNote] = []
    private var pool: [AnkiNote] = []                            // 시험범위에 드는 노트
    private var stats: [String: [Int]] = [:]  // 문장 → [맞힌 횟수, 틀린 횟수]
    private var lastQ: String?
    private var hasOwnCards = false   // cards.txt 에 직접 넣은(또는 AI 로 만든) 문제가 있는지
    private var own: [Card] = []      // cards.txt 의 문제 중 켜 둔 덱의 것
    private var ownAll: [Card] = []   // cards.txt 의 문제 전부
    private(set) var ownOff: Set<String> = []   // 끈 내 덱 ("## 이름" 단위)
    // 앱에 들어 있는 기본 제공 퀴즈 (packs/kmle.txt)
    private let builtin: [Card] = Bundle.main.url(forResource: "kmle", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(parseCards) ?? []
    private(set) var packOff: Set<String> = []   // 끈 기본 제공 과목

    // 기본 제공 과목 목록 (파일에 나온 순서)
    var packTopics: [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for c in builtin {
            if counts[c.topic] == nil { order.append(c.topic) }
            counts[c.topic, default: 0] += 1
        }
        return order.map { (name: $0, count: counts[$0]!) }
    }

    func togglePack(_ topic: String) {
        if packOff.contains(topic) { packOff.remove(topic) } else { packOff.insert(topic) }
        UserDefaults.standard.set(Array(packOff).sorted(), forKey: "packOff")
        reload()
    }

    func setAllPacks(on: Bool) {
        packOff = on ? [] : Set(packTopics.map { $0.name })
        UserDefaults.standard.set(Array(packOff).sorted(), forKey: "packOff")
        reload()
    }

    // 내 덱 목록: cards.txt 의 "## 이름" 단위 (파일에 나온 순서). 이름 없는 문제는 "" 로 묶인다.
    var ownTopics: [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for c in ownAll {
            if counts[c.topic] == nil { order.append(c.topic) }
            counts[c.topic, default: 0] += 1
        }
        return order.map { (name: $0, count: counts[$0]!) }
    }

    func toggleOwn(_ topic: String) {
        if ownOff.contains(topic) { ownOff.remove(topic) } else { ownOff.insert(topic) }
        UserDefaults.standard.set(Array(ownOff).sorted(), forKey: "ownOff")
        reload()
    }

    var ownCount: Int { return own.count }                                            // 켜 둔 내 덱의 문항 수
    var packCount: Int { return builtin.filter { !packOff.contains($0.topic) }.count }   // 켜 둔 기본 제공 문항 수
    private var day = ""        // 오늘 날짜 (yyyy-MM-dd)
    private var dayDone = 0     // 오늘 푼 문제 수
    private var streak = 0      // 연속 정답

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func rollDay() {
        let t = Deck.today()
        if day != t { day = t; dayDone = 0 }
    }

    var poolCount: Int { return pool.count }
    var hasProgress: Bool { rollDay(); return dayDone > 0 }
    var summary: String {
        rollDay()
        if dayDone == 0 { return "문제 \(pool.isEmpty ? cards.count : pool.count)개 준비됨" }
        return "오늘 \(dayDone)문제" + (streak >= 2 ? " · 연속 \(streak)" : "")
    }

    init() {
        let d = UserDefaults.standard
        stats = (d.dictionary(forKey: "stats") as? [String: [Int]]) ?? [:]
        day = d.string(forKey: "day") ?? ""
        dayDone = d.integer(forKey: "dayDone")
        streak = d.integer(forKey: "streak")
        scope = Set(d.stringArray(forKey: "scope") ?? [])
        packOff = Set(d.stringArray(forKey: "packOff") ?? [])
        ownOff = Set(d.stringArray(forKey: "ownOff") ?? [])
        reload()
        loadAnki()
    }

    func reload() {
        let parsed = (try? String(contentsOf: Deck.file, encoding: .utf8)).map(parseCards) ?? []
        // 예전 판이 파일에 써 넣던 예시 10문제는 내 문제로 치지 않는다.
        ownAll = parsed.filter { c in !defaultCards.contains { $0.q == c.q } }
        own = ownAll.filter { !ownOff.contains($0.topic) }
        hasOwnCards = !own.isEmpty
        cards = own + builtin.filter { !packOff.contains($0.topic) }
        if cards.isEmpty { cards = defaultCards }
    }

    // 시험범위(Anki)를 골랐을 때도 내 O/X 문제를 3문제에 1문제꼴로 섞을지
    var mixOX: Bool {
        get { return UserDefaults.standard.object(forKey: "mixOX") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mixOX") }
    }

    // AI 가 만든 문항을 cards.txt 끝에 덧붙인다.
    func appendGenerated(subject: String, items: [QuizGen.Item]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Deck.dir, withIntermediateDirectories: true)
        var text = (try? String(contentsOf: Deck.file, encoding: .utf8))
            ?? "# 한 줄에 문제 하나: 문장 | O 또는 X | 해설\n# '#'으로 시작하는 줄은 무시됩니다. 저장하면 다음 카드부터 반영됩니다.\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let clean = { (x: String) in x.replacingOccurrences(of: "|", with: "/") }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n## \(clean(subject))\n# AI 출제 \(f.string(from: Date()))\n"
        for it in items {
            let ev = it.evidence.count > 90 ? String(it.evidence.prefix(90)) + "…" : it.evidence
            text += "\(clean(it.q)) | \(it.a ? "O" : "X") | \(clean(it.why)) — 근거: “\(clean(ev))”\n"
        }
        try? text.write(to: Deck.file, atomically: true, encoding: .utf8)
        reload()
    }

    // 가져오기로 만들어 둔 anki.tsv 를 읽는다. 한 줄: id, 범위, 단원, 문장, 해설 (탭 구분)
    func loadAnki() {
        var notes: [AnkiNote] = []
        var counts: [String: Int] = [:]
        if let text = try? String(contentsOf: Deck.ankiFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5 else { continue }
                notes.append(AnkiNote(id: f[0], group: f[1], title: f[2], text: f[3], extra: f[4]))
                counts[f[1], default: 0] += 1
            }
        }
        ankiNotes = notes
        groups = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
        rebuildPool()
    }

    func setScope(_ s: Set<String>, save: Bool = true) {
        scope = s
        if save { UserDefaults.standard.set(Array(s).sorted(), forKey: "scope") }
        rebuildPool()
    }

    private func rebuildPool() {
        pool = scope.isEmpty ? [] : ankiNotes.filter { scope.contains($0.group) }
    }

    // 편집용 파일이 없으면 기본 예시로 만들어 둔다.
    func ensureFile() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Deck.file.path) { return }
        try? fm.createDirectory(at: Deck.dir, withIntermediateDirectories: true)
        let text = "# 내 O/X 문제. 한 줄에 문제 하나: 문장 | O 또는 X | 해설\n# \"## 과목\" 줄을 넣으면 그 아래 문제가 그 과목으로 묶입니다. '#' 하나로 시작하는 줄은 무시됩니다.\n# 저장하면 다음 카드부터 반영됩니다. 기본 제공 퀴즈는 ⏎ 메뉴 → 시험범위에서 켜고 끕니다.\n\n## 내 문제\n"
        try? text.write(to: Deck.file, atomically: true, encoding: .utf8)
    }

    func pick() -> Card {
        if !pool.isEmpty && !(mixOX && hasOwnCards && Int.random(in: 0..<3) == 0) { return pickCloze() }
        // 틀린 문제일수록 자주, 많이 맞힌 문제일수록 드물게.
        // 시험범위(Anki)에 섞어 낼 때는 내 문제에서만, 아니면 내 문제 + 기본 제공 퀴즈에서 뽑는다.
        let source = pool.isEmpty ? cards : own
        let candidates = source.count > 1 ? source.filter { $0.q != lastQ } : source
        let weights = candidates.map { c -> Double in
            let s = stats[c.statKey] ?? [0, 0]
            return max(0.25, 1 + 2 * Double(s[1]) - 0.5 * Double(s[0]))
        }
        var r = Double.random(in: 0..<weights.reduce(0, +))
        var chosen = candidates[candidates.count - 1]
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { chosen = candidates[i]; break }
        }
        lastQ = chosen.q
        return chosen
    }

    // 세 번에 한 번은 "몰랐음"이 더 많은 카드에서, 나머지는 범위 전체에서 무작위로 뽑는다.
    private func pickCloze() -> Card {
        var from = pool
        if Int.random(in: 0..<3) == 0 {
            let missed = pool.filter { n in
                guard let s = stats["a:" + n.id] else { return false }
                return s[1] > s[0]
            }
            if !missed.isEmpty { from = missed }
        }
        var n = from.randomElement()!
        if n.id == lastQ, let other = pool.randomElement() { n = other }
        lastQ = n.id
        return makeClozeCard(n)
    }

    func record(_ c: Card, correct: Bool) {
        var s = stats[c.statKey] ?? [0, 0]
        s[correct ? 0 : 1] += 1
        stats[c.statKey] = s
        rollDay()
        dayDone += 1
        streak = correct ? streak + 1 : 0
        let d = UserDefaults.standard
        d.set(stats, forKey: "stats")
        d.set(day, forKey: "day")
        d.set(dayDone, forKey: "dayDone")
        d.set(streak, forKey: "streak")
    }
}

// ───────────────────── Anki 가져오기 ─────────────────────
// Anki 데이터 파일의 복사본을 열어 빈칸 노트를 읽고 anki.tsv 로 저장한다. 원본은 건드리지 않는다.

enum AnkiImport {
    struct Failure: Error { let message: String }

    static func cleanHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>|</div>|</p>|</li>", with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&amp;": "&"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func collection() -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anki2")
        let found = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("collection.anki2") }
            .filter { fm.fileExists(atPath: $0.path) }
        // 프로필이 여럿이면 가장 최근에 쓴 것
        return found.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let stmt = st else {
            throw Failure(message: "Anki 데이터를 읽지 못했습니다: " + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    private static func text(_ st: OpaquePointer, _ col: Int32) -> String {
        return sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }

    // 가져온 카드 수를 돌려준다.
    static func run() throws -> Int {
        let fm = FileManager.default
        guard let src = collection() else { throw Failure(message: "Anki 데이터를 찾지 못했습니다. 이 Mac에 Anki가 설치되어 있어야 합니다.") }
        let tmp = fm.temporaryDirectory.appendingPathComponent("enter-anki-\(UUID().uuidString).anki2")
        let tmpWal = URL(fileURLWithPath: tmp.path + "-wal")
        defer {
            for p in [tmp.path, tmp.path + "-wal", tmp.path + "-shm"] { try? fm.removeItem(atPath: p) }
        }
        do {
            try fm.copyItem(at: src, to: tmp)
            let wal = URL(fileURLWithPath: src.path + "-wal")
            if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: tmpWal) }
        } catch {
            throw Failure(message: "Anki 데이터를 복사하지 못했습니다: \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Failure(message: "Anki 데이터를 열지 못했습니다.")
        }
        defer { sqlite3_close(db) }
        // Anki 가 쓰는 대소문자 무시 정렬 규칙. 없으면 일부 질의가 실패한다.
        sqlite3_create_collation(db, "unicase", SQLITE_UTF8, nil) { _, l1, p1, l2, p2 in
            let a = String(decoding: UnsafeRawBufferPointer(start: p1, count: Int(l1)), as: UTF8.self).lowercased()
            let b = String(decoding: UnsafeRawBufferPointer(start: p2, count: Int(l2)), as: UTF8.self).lowercased()
            return a < b ? -1 : (a > b ? 1 : 0)
        }

        var decks: [Int64: String] = [:]
        try rows(db, "SELECT id, name FROM decks") { st in
            decks[sqlite3_column_int64(st, 0)] = text(st, 1).replacingOccurrences(of: "\u{1f}", with: "::")
        }
        // 노트 유형마다 Title·Extra 필드가 몇 번째인지
        var titleAt: [Int64: Int] = [:]
        var extraAt: [Int64: Int] = [:]
        try rows(db, "SELECT ntid, ord, name FROM fields") { st in
            let nt = sqlite3_column_int64(st, 0), ord = Int(sqlite3_column_int(st, 1))
            let name = text(st, 2).lowercased()
            if name == "title" { titleAt[nt] = ord }
            if name == "extra" || name == "back extra" { extraAt[nt] = ord }
        }

        var lines: [String] = []
        let sql = "SELECT n.id, n.mid, n.flds, (SELECT did FROM cards WHERE nid = n.id LIMIT 1) FROM notes n WHERE n.flds LIKE '%{{c%::%'"
        try rows(db, sql) { st in
            let fields = text(st, 2).components(separatedBy: "\u{1f}")
            guard let raw = fields.first(where: { $0.contains("{{c") }), !raw.lowercased().contains("<img") else { return }
            let body = cleanHTML(raw)
            guard body.count <= 260 else { return }   // 알약에 들어갈 만큼 짧은 것만
            let mid = sqlite3_column_int64(st, 1)
            let field = { (i: Int?) -> String in
                guard let i = i, i < fields.count else { return "" }
                return cleanHTML(fields[i])
            }
            let path = (decks[sqlite3_column_int64(st, 3)] ?? "기타").components(separatedBy: "::")
            let group = path.prefix(2).joined(separator: "::")
            lines.append([String(sqlite3_column_int64(st, 0)), group, field(titleAt[mid]), body, field(extraAt[mid])]
                .map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t"))
        }
        guard !lines.isEmpty else { throw Failure(message: "빈칸(Cloze) 카드를 찾지 못했습니다.") }
        try? fm.createDirectory(at: Deck.dir, withIntermediateDirectories: true)
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: Deck.ankiFile, atomically: true, encoding: .utf8)
        } catch {
            throw Failure(message: "가져온 카드를 저장하지 못했습니다: \(error.localizedDescription)")
        }
        return lines.count
    }
}

// ───────────────────── 진단 기록 ─────────────────────
// 로딩 감지가 어디서 막히는지 보기 위한 기록. 대화 내용은 남기지 않고, 앱 이름·요소 종류·글자 수·
// "중지"로 판단한 버튼 이름만 남긴다. 파일: ~/Library/Application Support/Enter/debug.log
enum Log {
    static let url = Deck.dir.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "enter.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ s: String) {
        let line = stamp.string(from: Date()) + " " + s + "\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: Deck.dir, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 300_000 {
                try? fm.removeItem(at: url)   // 너무 커지면 새로 시작
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                h.closeFile()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

// ───────────────────── 손쉬운 사용(AX) 읽기 ─────────────────────

func axAttr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func axString(_ e: AXUIElement, _ name: String) -> String {
    return axAttr(e, name) as? String ?? ""
}

func isStopLabel(_ s: String) -> Bool {
    let l = s.lowercased()
    return stopWords.contains { l.contains($0) } && !stopExclude.contains { l.contains($0) }
}

final class Scanner {
    private let queue = DispatchQueue(label: "enter.scan", qos: .utility)
    private var busy = false            // 메인 스레드에서만 만진다
    private var cached: AXUIElement?    // queue 에서만 만진다
    private var prepared = Set<pid_t>()
    private let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXMenuBar", "AXMenuItem", "AXTextField"]

    private func label(_ e: AXUIElement) -> String {
        return (axString(e, "AXTitle") + " " + axString(e, "AXDescription")).trimmingCharacters(in: .whitespaces)
    }

    // 앱의 모든 창을 훑으며 버튼마다 visit 를 부른다. visit 가 true 를 돌려주면 멈춘다. 방문한 노드 수를 돌려준다.
    private func walk(pid: pid_t, visit: (AXUIElement, String) -> Bool) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        if !prepared.contains(pid) {
            // Electron 앱(Claude)은 이 값을 켜야 화면 안쪽 요소를 내보낸다.
            let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            prepared.insert(pid)
            Log.write("prepare pid=\(pid) AXManualAccessibility result=\(r.rawValue)")
        }
        var nodes = (axAttr(app, "AXWindows") as? [AXUIElement]) ?? []
        if nodes.isEmpty { Log.write("walk pid=\(pid): 창 목록을 못 읽음") }
        var i = 0
        while i < nodes.count && i < 6000 {
            let e = nodes[i]
            i += 1
            let role = axString(e, "AXRole")
            if role == "AXButton" && visit(e, label(e)) { return i }
            if leafRoles.contains(role) { continue }
            if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { nodes.append(contentsOf: kids) }
        }
        return i
    }

    // "중지" 버튼이 있는지. 결과는 메인 스레드로 돌려준다. 이전 검사가 안 끝났으면 건너뛴다.
    func findStop(pid: pid_t, done: @escaping (Bool) -> Void) {
        if busy { return }
        busy = true
        queue.async {
            var found = false
            if let c = self.cached, axString(c, "AXRole") == "AXButton", isStopLabel(self.label(c)) {
                found = true
            } else {
                if self.cached != nil { Log.write("scan pid=\(pid): 찾아 둔 중지 버튼이 사라짐") }
                self.cached = nil
                let t0 = Date()
                var hit = ""
                var buttons = 0
                let nodes = self.walk(pid: pid) { e, l in
                    buttons += 1
                    if isStopLabel(l) { self.cached = e; found = true; hit = l }
                    return found
                }
                Log.write("scan pid=\(pid) nodes=\(nodes) buttons=\(buttons) found=\(found) label=\"\(hit)\" ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            }
            DispatchQueue.main.async {
                self.busy = false
                done(found)
            }
        }
    }

    // 대상 앱이 화면 안쪽 요소를 내보내도록 미리 켜 둔다 (켜진 뒤 실제로 채워지기까지 시간이 걸린다).
    func prepare(pid: pid_t) {
        queue.async {
            if self.prepared.contains(pid) { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.4)
            let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            self.prepared.insert(pid)
            Log.write("prepare pid=\(pid) AXManualAccessibility result=\(r.rawValue)")
        }
    }

    // 진단용: 버튼 이름 목록.
    func dump(pids: [(String, pid_t)], done: @escaping (String) -> Void) {
        queue.async {
            var out = ""
            for (name, pid) in pids {
                var labels: [String] = []
                let n = self.walk(pid: pid) { _, l in
                    if !l.isEmpty && labels.count < 300 { labels.append(l) }
                    return false
                }
                let hits = labels.filter(isStopLabel)
                out += "[\(name)] 요소 \(n)개, 이름 있는 버튼 \(labels.count)개, 중지 버튼 후보 \(hits.count)개\n"
                out += labels.map { "  - \($0)" }.joined(separator: "\n") + "\n\n"
            }
            DispatchQueue.main.async { done(out) }
        }
    }
}

// ───────────────────────── 카드 창 ─────────────────────────

// 글자용 초록·빨강. 밝은 배경에서는 기본 시스템 색이 흐려서 더 진한 색을 쓴다.
func textColor(light: NSColor, dark: NSColor) -> NSColor {
    return NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}
let okText = textColor(light: NSColor(srgbRed: 0.10, green: 0.50, blue: 0.29, alpha: 1), dark: .systemGreen)
let badText = textColor(light: NSColor(srgbRed: 0.75, green: 0.22, blue: 0.17, alpha: 1), dark: .systemRed)

func reduceMotion() -> Bool {
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

// 진행 고리. 끝나면 고리가 닫히고 체크가 그려진다.
final class SpinnerView: NSView {
    private let ring = CAShapeLayer()
    private let check = CAShapeLayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        wantsLayer = true
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4.8, y: 8.3))
        p.addLine(to: CGPoint(x: 7.2, y: 5.9))
        p.addLine(to: CGPoint(x: 11.3, y: 10.5))
        check.frame = bounds
        check.path = p
        for l in [ring, check] {
            l.fillColor = nil
            l.lineWidth = 2.2
            l.lineCap = .round
            l.lineJoin = .round
            layer?.addSublayer(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { return NSSize(width: 16, height: 16) }

    private func noImplicit(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    func setRunning() {
        noImplicit {
            ring.removeAllAnimations()
            check.removeAllAnimations()
            ring.strokeColor = NSColor.systemBlue.cgColor
            ring.strokeEnd = 0.32
            check.strokeEnd = 0
        }
        if reduceMotion() { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    func setDone() {
        let green = NSColor.systemGreen.cgColor
        noImplicit {
            ring.removeAllAnimations()
            ring.strokeColor = green
            ring.strokeEnd = 1
            check.strokeColor = green
            check.strokeEnd = 1
        }
        if reduceMotion() { return }
        let close = CABasicAnimation(keyPath: "strokeEnd")
        close.fromValue = 0.32
        close.toValue = 1
        close.duration = 0.4
        ring.add(close, forKey: "close")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.35
        draw.beginTime = CACurrentMediaTime() + 0.25
        draw.fillMode = .backwards
        check.add(draw, forKey: "draw")
    }
}

// 화면 위쪽 가운데의 알약. 진행 표시로 시작해 문제로 펼쳐지고, 답변이 오면 체크로 접힌다.
final class QuizUI: NSObject {
    private let deck: Deck
    let panel: NSPanel
    private let openWidth: CGFloat = 330
    private let pillWidth: CGFloat = 250
    private let padX: CGFloat = 14

    private let bg = NSVisualEffectView()
    private let spinner = SpinnerView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var closeButton: NSButton!
    private let askLabel = NSTextField(labelWithString: "")
    private let topicLabel = NSTextField(labelWithString: "")
    private let qLabel = NSTextField(wrappingLabelWithString: "")
    private var oButton: NSButton!
    private var xButton: NSButton!
    private var answerRow: NSStackView!
    private let verdictLabel = NSTextField(labelWithString: "")
    private let whyLabel = NSTextField(wrappingLabelWithString: "")
    private let scoreLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "⌥O · ⌥X")
    private var nextButton: NSButton!
    private var footer: NSStackView!
    private var stack: NSStackView!
    private var rowWidths: [NSLayoutConstraint] = []

    private var current: Card?
    private var ask = ""
    private(set) var answered = false
    private var revealed = false   // 빈칸 카드에서 정답을 열어 봤는지
    private var isOpen = false
    private var generation = 0
    private var openTimer: Timer?
    private var autoNext: Timer?
    private var collapseTimer: Timer?
    private var hideTimer: Timer?

    var isLoading: () -> Bool = { false }   // 아직 답변을 기다리는 중인지
    var visible: Bool { return panel.isVisible }
    // 펫이 카드 흐름을 따라가도록 알려 준다.
    var onShow: (() -> Void)?
    var onAnswer: ((Bool) -> Void)?
    var onHide: (() -> Void)?
    var canAnswer: Bool { return visible && isOpen && !answered && current != nil }

    init(deck: Deck) {
        self.deck = deck
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 17
        bg.layer?.masksToBounds = true
        panel.contentView = bg
        build()
    }

    private func style(_ l: NSTextField, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isSelectable = false
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 7
        s.alignment = .centerY
        return s
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    private func linkButton(_ title: String, _ action: Selector, size: CGFloat, color: NSColor) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: size, weight: .semibold)
        b.contentTintColor = color
        return b
    }

    // 버튼을 색으로 채운다. nil 이면 원래 모습.
    private func paint(_ b: NSButton, _ letter: String, _ fill: NSColor?) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        // 이 창은 키 창이 되지 않아 시스템 버튼 색이 먹지 않는다. 배경을 직접 칠한다.
        bg.effectiveAppearance.performAsCurrentDrawingAppearance {
            b.layer?.backgroundColor = (fill ?? NSColor.labelColor.withAlphaComponent(0.09)).cgColor
        }
        b.alphaValue = 1
        b.attributedTitle = NSAttributedString(string: letter, attributes: [
            .foregroundColor: fill == nil ? NSColor.labelColor : NSColor.white,
            .font: NSFont.systemFont(ofSize: letter.count == 1 ? 17 : 14, weight: .bold),
            .paragraphStyle: para,
        ])
    }

    private func build() {
        titleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        metaLabel.textColor = .tertiaryLabelColor
        style(askLabel, size: 12, weight: .regular, color: .tertiaryLabelColor)
        askLabel.lineBreakMode = .byTruncatingTail
        style(topicLabel, size: 11, weight: .medium, color: .secondaryLabelColor)
        topicLabel.lineBreakMode = .byTruncatingTail
        style(qLabel, size: 16, weight: .semibold, color: .labelColor)
        style(verdictLabel, size: 14, weight: .bold, color: .labelColor)
        style(whyLabel, size: 13, weight: .regular, color: .secondaryLabelColor)
        scoreLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        scoreLabel.textColor = .tertiaryLabelColor
        style(hintLabel, size: 12, weight: .regular, color: .tertiaryLabelColor)

        closeButton = linkButton("×", #selector(closeTapped), size: 15, color: .secondaryLabelColor)
        closeButton.setAccessibilityLabel("이번에는 닫기")
        let header = row([spinner, titleLabel, spacer(), metaLabel, closeButton])

        oButton = NSButton(title: "O", target: self, action: #selector(oTapped))
        xButton = NSButton(title: "X", target: self, action: #selector(xTapped))
        for b in [oButton!, xButton!] {
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        oButton.setAccessibilityLabel("O (맞다)")
        xButton.setAccessibilityLabel("X (틀리다)")
        answerRow = row([oButton, xButton])
        answerRow.distribution = .fillEqually

        nextButton = linkButton("다음 문제 →", #selector(nextTapped), size: 12, color: .linkColor)
        footer = row([scoreLabel, spacer(), hintLabel, nextButton])

        let rows: [NSView] = [header, askLabel, topicLabel, qLabel, answerRow, verdictLabel, whyLabel, footer]
        stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        // 위·왼쪽에만 붙인다. 창 크기가 움직이는 동안 내용은 그대로 있고 가장자리에서 잘린다.
        rowWidths = rows.map { $0.widthAnchor.constraint(equalToConstant: pillWidth - padX * 2) }
        NSLayoutConstraint.activate(rowWidths + [
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
        ])
    }

    // 접힘/펼침 상태에 맞춰 보일 줄을 정하고, 창을 화면 위쪽 가운데에 맞춘다.
    private func apply(animated: Bool) {
        closeButton.isHidden = !isOpen
        metaLabel.isHidden = isOpen || metaLabel.stringValue.isEmpty
        askLabel.isHidden = !isOpen || ask.isEmpty
        topicLabel.isHidden = !isOpen || topicLabel.stringValue.isEmpty
        qLabel.isHidden = !isOpen
        answerRow.isHidden = !isOpen
        verdictLabel.isHidden = !isOpen || !answered || current?.cloze != nil
        whyLabel.isHidden = !isOpen || !(answered || revealed) || whyLabel.stringValue.isEmpty
        footer.isHidden = !isOpen
        nextButton.isHidden = !answered
        hintLabel.isHidden = answered

        let w = isOpen ? openWidth : pillWidth
        let inner = w - padX * 2
        rowWidths.forEach { $0.constant = inner }
        qLabel.preferredMaxLayoutWidth = inner
        whyLabel.preferredMaxLayoutWidth = inner
        stack.edgeInsets = isOpen
            ? NSEdgeInsets(top: 11, left: padX, bottom: 12, right: padX)
            : NSEdgeInsets(top: 9, left: padX, bottom: 9, right: padX)
        stack.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let frame = NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.maxY - h - 10).rounded(), width: w, height: h)
        if animated && visible && !reduceMotion() {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    private func renderScore() {
        scoreLabel.stringValue = deck.summary
    }

    // 문제 문장. 빈칸 카드는 가려진 자리를 파랑 "[ ? ]"로, 정답을 연 뒤에는 초록 정답으로 보여 준다.
    private func questionText(_ c: Card, reveal: Bool) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let out = NSMutableAttributedString()
        for seg in c.cloze ?? [(text: c.q, blank: false)] {
            if !seg.blank {
                out.append(NSAttributedString(string: seg.text, attributes: base))
                continue
            }
            var a = base
            a[.foregroundColor] = reveal ? okText : NSColor.systemBlue
            a[.font] = NSFont.systemFont(ofSize: 16, weight: .bold)
            out.append(NSAttributedString(string: reveal ? seg.text : (c.hint.isEmpty ? "[ ? ]" : "[ \(c.hint) ]"), attributes: a))
        }
        return out
    }

    private func renderCard() {
        autoNext?.invalidate()
        deck.reload()
        let c = deck.pick()
        current = c
        answered = false
        revealed = false
        topicLabel.stringValue = c.topic
        qLabel.attributedStringValue = questionText(c, reveal: false)
        if c.cloze != nil {
            paint(oButton, "정답 보기", nil)
            xButton.isHidden = true
            hintLabel.stringValue = "⌥O 정답 보기"
        } else {
            paint(oButton, "O", nil)
            paint(xButton, "X", nil)
            xButton.isHidden = false
            hintLabel.stringValue = "⌥O · ⌥X"
        }
        renderScore()
        apply(animated: true)
    }

    func setProgress(seconds: Int) {
        titleLabel.stringValue = "답변 생성 중 · \(seconds)초"
    }

    func show(ask: String) {
        for t in [openTimer, collapseTimer, hideTimer] { t?.invalidate() }
        generation += 1
        self.ask = ask
        askLabel.stringValue = ask.isEmpty ? "" : "내 질문: " + ask
        metaLabel.stringValue = ""
        titleLabel.textColor = .secondaryLabelColor
        setProgress(seconds: 0)
        spinner.setRunning()
        defer { onShow?() }
        if visible && isOpen {   // 지난 답변의 카드가 아직 열려 있으면 그대로 이어 간다
            apply(animated: true)
            return
        }
        isOpen = false
        apply(animated: false)
        if !visible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion() ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        // 알약으로 잠깐 보였다가 문제로 펼쳐진다.
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let s = self, s.isLoading() else { return }
            s.isOpen = true
            s.renderCard()
        }
    }

    func markDone(seconds: Int) {
        autoNext?.invalidate()
        openTimer?.invalidate()
        titleLabel.stringValue = "답변 도착 · \(seconds)초"
        titleLabel.textColor = okText
        spinner.setDone()
        if isOpen { scheduleCollapse(answered ? 2 : 6) }   // 풀던 문제는 마저 풀 수 있게 잠깐 남겨 둔다
        else { collapse() }
    }

    private func scheduleCollapse(_ after: TimeInterval) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in self?.collapse() }
    }

    // 문제를 접고, 오늘 기록을 잠깐 보여 준 뒤 사라진다.
    private func collapse() {
        autoNext?.invalidate()
        openTimer?.invalidate()
        isOpen = false
        metaLabel.stringValue = deck.hasProgress ? deck.summary : ""
        apply(animated: true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() {
        for t in [openTimer, autoNext, collapseTimer, hideTimer] { t?.invalidate() }
        guard visible else { return }
        onHide?()
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion() ? 0 : 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let s = self, s.generation == gen else { return }   // 그 사이 다시 뜬 경우는 그대로 둔다
            s.panel.orderOut(nil)
            s.isOpen = false
        })
    }

    // O/X 카드: O 또는 X 를 고른다.
    // 빈칸 카드: 첫 입력은 정답 보기, 그다음 O = 알았음, X = 몰랐음.
    func answer(_ choseO: Bool) {
        guard canAnswer, let c = current else { return }
        let isCloze = c.cloze != nil
        if isCloze && !revealed {
            revealed = true
            qLabel.attributedStringValue = questionText(c, reveal: true)
            whyLabel.stringValue = c.why
            paint(oButton, "알았음", nil)
            paint(xButton, "몰랐음", nil)
            xButton.isHidden = false
            hintLabel.stringValue = "⌥O 알았음 · ⌥X 몰랐음"
            apply(animated: true)
            return
        }
        answered = true
        let correct = isCloze ? choseO : (choseO == c.a)
        deck.record(c, correct: correct)
        onAnswer?(correct)

        if isCloze {
            paint(choseO ? oButton : xButton, choseO ? "알았음" : "몰랐음", choseO ? .systemGreen : .systemRed)
            (choseO ? xButton : oButton)!.alphaValue = 0.4
        } else {
            // 정답 버튼이 초록으로, 잘못 고른 버튼이 빨강으로 채워진다.
            let rightButton: NSButton = c.a ? oButton : xButton
            let otherButton: NSButton = c.a ? xButton : oButton
            paint(rightButton, c.a ? "O" : "X", .systemGreen)
            if correct { otherButton.alphaValue = 0.4 }
            else { paint(otherButton, c.a ? "X" : "O", .systemRed) }
            verdictLabel.stringValue = correct ? "정답" : "오답 — 답은 \(c.a ? "O" : "X")"
            verdictLabel.textColor = correct ? okText : badText
            whyLabel.stringValue = c.why
        }
        renderScore()
        apply(animated: true)

        // 빈칸 카드는 이미 정답을 본 뒤라 빨리 넘어간다.
        if isLoading() {
            autoNext = Timer.scheduledTimer(withTimeInterval: isCloze ? 1.2 : autoNextDelay, repeats: false) { [weak self] _ in
                guard let s = self, s.isLoading() else { return }
                s.renderCard()
            }
        } else {
            scheduleCollapse(isCloze ? 1.5 : 2.5)
        }
    }

    @objc private func oTapped() { answer(true) }
    @objc private func xTapped() { answer(false) }
    @objc private func nextTapped() { if isLoading() { renderCard() } else { collapse() } }
    @objc private func closeTapped() { hide() }

    // 자기 창을 PNG로 저장한다 (동작 확인용).
    func snapshot(to url: URL) {
        guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { return }
        var image: CGImage? = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution])
        if image == nil {
            bg.cacheDisplay(in: bg.bounds, to: rep)
            image = rep.cgImage
        }
        guard let cg = image, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

// ───────────────────── AI 출제 (Claude API) ─────────────────────
// 정리본(글)이나 강의록(PDF)을 Claude API 로 보내 O/X 문항을 받는다. 문항마다 자료 원문에서
// 근거 구절을 받아, 원문에 실제로 있는 근거만 남긴다.

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.enterquiz.mac",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ key: String) {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(base as CFDictionary) }
}

enum QuizGen {
    struct Failure: Error { let message: String }
    struct Item { let q: String; let a: Bool; let why: String; let evidence: String }
    enum Source {
        case text(String)
        case pdf(data: Data, text: String)   // text = PDF 에서 뽑은 글 (근거 확인용, 스캔본이면 비어 있다)
    }
    struct Output { let items: [Item]; let dropped: Int; let verified: Bool }

    static let model = "claude-opus-5-5"
    static let maxNotesLength = 150_000

    private static let system = """
    너는 의대생의 시험 대비를 돕는 출제자다. 사용자가 주는 자료(정리본 또는 강의록)만을 근거로 O/X 문항을 만든다.

    규칙:
    - 자료에 적힌 내용만 쓴다. 자료에 없는 사실은 네가 알고 있더라도 문항이나 해설에 넣지 않는다. \
    이 문항들은 검토 없이 바로 학생에게 보이므로, 자료로 확인할 수 없는 문항은 만들지 않는 것이 낫다.
    - 강의록이면 표지, 목차, 학습목표 나열, 참고문헌 같은 부분은 건너뛰고 시험에 나올 본문 내용에서 낸다.
    - statement: 참/거짓을 가릴 수 있는 한 문장. 80자 이내. 답변을 기다리는 몇 초 사이에 읽고 답할 수 있어야 한다.
    - 참(O)과 거짓(X) 문항을 대략 반반 섞는다. 거짓 문항은 참인 문장에서 시험에 나올 만한 핵심 사실 하나만 \
    바꿔 만든다(수치, 방향, 원인, 약물, 부위 등). 말꼬리나 애매한 표현으로 틀리게 만들지 않는다.
    - explanation: 왜 맞거나 틀린지 한 문장. 60자 이내. 거짓 문항은 올바른 사실을 적는다.
    - evidence: 정답의 근거가 되는 자료의 구절을 글자 그대로 옮긴다. 고치거나 줄이지 않는다.
    - 문항끼리 같은 사실을 반복해 묻지 않는다. 자료에서 중요한 내용을 고르게 다룬다.
    - 자료가 요청한 문항 수를 채우기에 부족하면 만들 수 있는 만큼만 만든다.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "cards": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "statement": ["type": "string"],
                        "answer": ["type": "boolean", "description": "문장이 참이면 true, 거짓이면 false"],
                        "explanation": ["type": "string"],
                        "evidence": ["type": "string"],
                    ] as [String: Any],
                    "required": ["statement", "answer", "explanation", "evidence"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        "required": ["cards"],
        "additionalProperties": false,
    ]

    private static func squash(_ s: String) -> String {
        return s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // 근거 대조용: 공백과 문장부호를 모두 뺀다. PDF 는 줄바꿈과 띄어쓰기가 원문과 다르게 뽑히기 때문이다.
    private static func bare(_ s: String) -> String {
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    // 완료되면 메인 스레드에서 done 을 부른다. dropped = 근거가 원문에 없어 뺀 문항 수.
    static func generate(source: Source, count: Int, apiKey: String,
                         done: @escaping (Result<Output, Failure>) -> Void) {
        let finish = { (r: Result<Output, Failure>) in DispatchQueue.main.async { done(r) } }
        let content: Any
        let sourceText: String
        switch source {
        case .text(let notes):
            sourceText = notes
            content = "아래 정리본에서 O/X 문항을 \(count)개 만들어 줘.\n\n<정리본>\n\(notes)\n</정리본>"
        case .pdf(let data, let text):
            sourceText = text
            content = [
                ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]],
                ["type": "text", "text": "이 강의록에서 O/X 문항을 \(count)개 만들어 줘."],
            ] as [[String: Any]]
        }
        // 주소 바꾸기는 명령줄 동작 확인(--gen-test) 때만 허용한다. 평소에는 키가 다른 곳으로 가지 않게 고정.
        let testBase = CommandLine.arguments.contains("--gen-test") ? ProcessInfo.processInfo.environment["ENTER_API_BASE"] : nil
        let base = testBase ?? "https://api.anthropic.com"
        guard let url = URL(string: base + "/v1/messages") else { return finish(.failure(Failure(message: "주소가 잘못됐습니다."))) }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": ["format": ["type": "json_schema", "schema": schema] as [String: Any]],
            // 안전 분류기가 요청을 거절하면 다른 모델로 자동 재시도한다.
            "fallbacks": "default",
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 900
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, err in
            if let err = err { return finish(.failure(Failure(message: "연결하지 못했습니다: \(err.localizedDescription)"))) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard status == 200, let root = json else {
                let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
                let msg: String
                switch status {
                case 401: msg = "API 키가 올바르지 않습니다. 키를 다시 입력하세요."
                case 403: msg = "이 API 키로는 요청할 권한이 없습니다."
                case 429: msg = "요청 한도를 넘었습니다. 잠시 뒤 다시 시도하세요."
                case 500...599: msg = "Claude API 쪽 문제입니다. 잠시 뒤 다시 시도하세요."
                default: msg = "요청이 거부됐습니다 (HTTP \(status))."
                }
                return finish(.failure(Failure(message: detail.isEmpty ? msg : msg + "\n" + detail)))
            }
            let stop = root["stop_reason"] as? String ?? ""
            if stop == "refusal" { return finish(.failure(Failure(message: "이 자료로는 문항을 만들 수 없다고 거절됐습니다."))) }
            if stop == "max_tokens" { return finish(.failure(Failure(message: "문항이 너무 길어 잘렸습니다. 문항 수를 줄여 다시 시도하세요."))) }
            let text = ((root["content"] as? [[String: Any]]) ?? []).first { $0["type"] as? String == "text" }?["text"] as? String
            guard let t = text, let parsed = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any],
                  let cards = parsed["cards"] as? [[String: Any]] else {
                return finish(.failure(Failure(message: "응답을 읽지 못했습니다.")))
            }
            // 근거가 자료 원문에 그대로 있는 문항만 남긴다.
            // 글자를 뽑을 수 없는 PDF(스캔본)는 대조할 원문이 없어 확인 없이 모두 남긴다.
            let haystack = bare(sourceText)
            let canVerify = haystack.count >= 200
            var items: [Item] = []
            var dropped = 0
            for c in cards {
                guard let q = c["statement"] as? String, let a = c["answer"] as? Bool else { continue }
                let ev = squash(c["evidence"] as? String ?? "")
                if canVerify && (bare(ev).count < 4 || !haystack.contains(bare(ev))) { dropped += 1; continue }
                items.append(Item(q: squash(q), a: a, why: squash(c["explanation"] as? String ?? ""), evidence: ev))
            }
            if items.isEmpty {
                return finish(.failure(Failure(message: "자료에서 근거를 확인할 수 있는 문항이 없었습니다. 다른 자료로 다시 시도하세요.")))
            }
            finish(.success(Output(items: items, dropped: dropped, verified: canVerify)))
        }.resume()
    }
}

// 정리본을 붙여넣어 문항을 만드는 창.
final class GenWindow: NSObject {
    let window: NSWindow
    private let deck: Deck
    private let subject = NSTextField()
    private var notes: NSTextView!
    private let countPopup = NSPopUpButton()
    private let keyField = NSSecureTextField()
    private var button: NSButton!
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pdfLabel = NSTextField(labelWithString: "")
    private var clearPDFButton: NSButton!
    private var pdf: (data: Data, text: String, name: String, pages: Int)?
    var onSaved: (() -> Void)?   // 덱이 저장되면 설정 창 목록을 새로 그린다

    init(deck: Deck) {
        self.deck = deck
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "새 덱 만들기 — 강의록 PDF·정리본으로 O/X"
        window.isReleasedWhenClosed = false
        build()
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = NSFont.systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        subject.placeholderString = "덱 이름 (예: 순환기 — 심부전). 같은 이름의 덱이 있으면 거기에 추가됩니다"
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        notes = scroll.documentView as? NSTextView
        notes.isRichText = false
        notes.font = NSFont.systemFont(ofSize: 13)
        notes.textContainerInset = NSSize(width: 6, height: 8)
        notes.isAutomaticQuoteSubstitutionEnabled = false
        notes.isAutomaticDashSubstitutionEnabled = false

        countPopup.addItems(withTitles: ["10문항", "20문항", "30문항", "50문항"])
        countPopup.selectItem(at: 1)
        keyField.placeholderString = Keychain.load() == nil ? "Claude API 키 (sk-ant-…)" : "저장된 키 사용 중 — 바꾸려면 새 키 입력"
        button = NSButton(title: "문제 만들기", target: self, action: #selector(generate))
        button.keyEquivalent = "\r"
        button.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = NSFont.systemFont(ofSize: 12)

        let keyRow = NSStackView(views: [keyField, countPopup, spinner, button])
        keyRow.spacing = 8
        let pick = NSButton(title: "강의록 PDF 선택…", target: self, action: #selector(choosePDF))
        pick.bezelStyle = .rounded
        clearPDFButton = NSButton(title: "PDF 빼기", target: self, action: #selector(clearPDF))
        clearPDFButton.bezelStyle = .rounded
        clearPDFButton.isHidden = true
        pdfLabel.font = NSFont.systemFont(ofSize: 12)
        pdfLabel.textColor = .secondaryLabelColor
        pdfLabel.lineBreakMode = .byTruncatingMiddle
        pdfLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pdfRow = NSStackView(views: [pick, clearPDFButton, pdfLabel])
        pdfRow.spacing = 8
        let stack = NSStackView(views: [
            subject,
            caption("정리본을 아래에 붙여넣거나 강의록 PDF를 고르세요. 그 자료에 적힌 내용만으로 문항을 만들고, 원문에서 근거를 확인할 수 있는 문항만 저장합니다."),
            scroll,
            pdfRow,
            keyRow,
            caption("넣은 자료는 Anthropic의 Claude API로 전송되고, API 사용료가 키 주인에게 부과됩니다 (모델: Claude Opus 5.5). 키는 이 Mac의 키체인에만 저장됩니다."),
            status,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        var cs = [
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ]
        cs += stack.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32) }
        NSLayoutConstraint.activate(cs)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(notes)
    }

    private func say(_ s: String, bad: Bool = false) {
        status.stringValue = s
        status.textColor = bad ? badText : .labelColor
    }

    @objc private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else {
            return say("PDF를 열지 못했습니다.", bad: true)
        }
        // API 한도: 요청 32MB(인코딩하면 1/3 커진다), 600쪽
        guard data.count <= 22_000_000, doc.pageCount <= 600 else {
            return say("PDF가 너무 큽니다 (\(data.count / 1_000_000)MB, \(doc.pageCount)쪽). 22MB·600쪽 이하로 나눠서 넣으세요.", bad: true)
        }
        let name = url.deletingPathExtension().lastPathComponent
        pdf = (data, doc.string ?? "", name, doc.pageCount)
        pdfLabel.stringValue = "\(url.lastPathComponent) · \(doc.pageCount)쪽 — 이 PDF로 만듭니다 (위 글은 쓰지 않음)"
        clearPDFButton.isHidden = false
        if subject.stringValue.isEmpty { subject.stringValue = name }
        say("")
    }

    @objc private func clearPDF() {
        pdf = nil
        pdfLabel.stringValue = ""
        clearPDFButton.isHidden = true
    }

    @objc private func generate() {
        let source: QuizGen.Source
        if let p = pdf {
            source = .pdf(data: p.data, text: p.text)
        } else {
            let text = notes.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 50 else { return say("정리본을 붙여넣거나 강의록 PDF를 고르세요.", bad: true) }
            guard text.count <= QuizGen.maxNotesLength else {
                return say("정리본이 너무 깁니다 (\(text.count)자). 단원별로 나눠 \(QuizGen.maxNotesLength)자 이하로 넣으세요.", bad: true)
            }
            source = .text(text)
        }
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let key = typed.isEmpty ? Keychain.load() : typed, !key.isEmpty else {
            return say("Claude API 키를 입력하세요.", bad: true)
        }
        let name = subject.stringValue.trimmingCharacters(in: .whitespaces)
        let count = [10, 20, 30, 50][max(0, countPopup.indexOfSelectedItem)]
        button.isEnabled = false
        spinner.startAnimation(nil)
        say("문항을 만드는 중입니다. 1~2분 걸릴 수 있습니다…")
        QuizGen.generate(source: source, count: count, apiKey: key) { [weak self] result in
            guard let s = self else { return }
            s.button.isEnabled = true
            s.spinner.stopAnimation(nil)
            switch result {
            case .failure(let f):
                s.say(f.message, bad: true)
            case .success(let r):
                if !typed.isEmpty {   // 실제로 통한 키만 저장한다
                    Keychain.save(typed)
                    s.keyField.stringValue = ""
                    s.keyField.placeholderString = "저장된 키 사용 중 — 바꾸려면 새 키 입력"
                }
                s.deck.appendGenerated(subject: name.isEmpty ? "정리본" : name, items: r.items)
                var note = r.dropped > 0 ? " (근거를 원문에서 찾지 못한 \(r.dropped)문항은 뺐습니다)" : ""
                if !r.verified { note = " (글자를 뽑을 수 없는 PDF라 근거 확인은 하지 못했습니다)" }
                let deckName = name.isEmpty ? "정리본" : name
                s.say("\(r.items.count)문항을 ‘\(deckName)’ 덱에 저장했습니다" + note + ". 설정 창의 ‘내 덱’에서 켜고 끌 수 있고, ‘내 문제 직접 편집’에서 고칠 수 있습니다.")
                s.onSaved?()
            }
        }
    }
}

// ───────────────────────── 설정 창 ─────────────────────────
// 앱을 열면(또는 ⏎ 메뉴 → 설정 열기) 뜨는 창. 어떤 과목·덱에서 문제를 낼지 고르고, 새 덱을 만든다.

final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let deck: Deck
    private unowned let app: AppController
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "")
    private var permButton: NSButton!
    private let list = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var packNames: [String] = []
    private var ownNames: [String] = []
    private var ankiTops: [String] = []
    private var centered = false

    init(deck: Deck, app: AppController) {
        self.deck = deck
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Loading Dose"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 480)
        window.delegate = self
        build()
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = NSFont.systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func smallButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 11)
        return b
    }

    private func build() {
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        permButton = NSButton(title: "권한 설정 열기…", target: app, action: #selector(AppController.openSettings))
        permButton.bezelStyle = .rounded
        let demo = NSButton(title: "카드 미리 보기", target: app, action: #selector(AppController.startDemo))
        demo.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [statusDot, statusLabel, spacer, permButton, demo])
        header.spacing = 8

        let title = NSTextField(labelWithString: "출제 범위")
        title.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        let sub = caption("체크한 과목과 덱에서 문제가 나옵니다. 바꾸면 다음 카드부터 반영됩니다.")

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = doc

        summary.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let newDeck = NSButton(title: "새 덱 만들기 (PDF·정리본)…", target: app, action: #selector(AppController.openGen))
        newDeck.bezelStyle = .rounded
        newDeck.keyEquivalent = "\r"
        let edit = NSButton(title: "내 문제 직접 편집…", target: app, action: #selector(AppController.editCards))
        edit.bezelStyle = .rounded
        let anki = NSButton(title: "Anki에서 가져오기…", target: app, action: #selector(AppController.importAnki))
        anki.bezelStyle = .rounded
        let actions = NSStackView(views: [newDeck, edit, anki])
        actions.spacing = 8
        let foot = caption("새 덱 만들기는 강의록 PDF나 정리본을 Claude API로 보내 O/X 문항을 만듭니다. 본인 Claude API 키가 필요합니다.")

        let stack = NSStackView(views: [header, title, sub, scroll, summary, actions, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: header)
        stack.setCustomSpacing(2, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        var cs = [
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 14),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -14),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ]
        cs += [header, sub, scroll, summary, foot].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36) }
        NSLayoutConstraint.activate(cs)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !centered { window.center(); centered = true }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func refreshStatus() {
        let on = app.isActive
        statusDot.textColor = on ? NSColor.systemGreen : NSColor.systemOrange
        statusLabel.stringValue = on
            ? "작동 중 — Claude·ChatGPT 앱에서 Enter를 누르면 카드가 뜹니다"
            : "권한 필요 — 손쉬운 사용에서 ‘Loading Dose’를 켜야 카드가 뜹니다"
        permButton.isHidden = on
    }

    // ── 목록 ──
    private func sectionHeader(_ title: String, _ buttons: [NSButton] = []) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer] + buttons)
        row.spacing = 6
        return row
    }

    private func check(_ title: String, _ sel: Selector, tag: Int, state: NSControl.StateValue, mixed: Bool = false) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: sel)
        b.tag = tag
        b.allowsMixedState = mixed
        b.state = state
        b.font = NSFont.systemFont(ofSize: 13)
        b.lineBreakMode = .byTruncatingTail
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // 긴 이름이 줄 맞춤을 밀지 않게
        return b
    }

    // 체크박스를 두 줄로 나란히 놓는다.
    private func addGrid(_ boxes: [NSButton]) {
        var i = 0
        while i < boxes.count {
            let pair = Array(boxes[i..<min(i + 2, boxes.count)])
            let row = NSStackView(views: pair)
            row.spacing = 12
            row.distribution = .fillEqually
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if pair.count == 1 { row.addArrangedSubview(NSView()) }
            i += 2
        }
    }

    private func addFull(_ v: NSView, gapBefore: CGFloat? = nil) {
        if let g = gapBefore, let last = list.arrangedSubviews.last { list.setCustomSpacing(g, after: last) }
        list.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    func refresh() {
        refreshStatus()
        deck.reload()
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // 기본 제공
        let packs = deck.packTopics
        packNames = packs.map { $0.name }
        addFull(sectionHeader("기본 제공 O/X — KMLE 대비 (\(packs.reduce(0) { $0 + $1.count })문항)",
                              [smallButton("모두 켜기", #selector(allPacksOn)), smallButton("모두 끄기", #selector(allPacksOff))]))
        addGrid(packs.enumerated().map { i, t in
            check("\(t.name)  \(t.count)", #selector(packToggled(_:)), tag: i, state: deck.packOff.contains(t.name) ? .off : .on)
        })

        // 내 덱
        let owns = deck.ownTopics
        ownNames = owns.map { $0.name }
        addFull(sectionHeader("내 덱 — PDF·정리본으로 만들었거나 직접 쓴 문제"), gapBefore: 18)
        if owns.isEmpty {
            addFull(caption("아직 없습니다. 아래 ‘새 덱 만들기’로 강의록 PDF나 정리본에서 O/X 덱을 만들 수 있습니다."))
        } else {
            addGrid(owns.enumerated().map { i, t in
                check("\(t.name.isEmpty ? "분류 없음" : t.name)  \(t.count)", #selector(ownToggled(_:)), tag: i,
                      state: deck.ownOff.contains(t.name) ? .off : .on)
            })
        }

        // Anki
        addFull(sectionHeader("Anki 빈칸 카드", deck.scope.isEmpty ? [] : [smallButton("모두 해제", #selector(ankiClear))]), gapBefore: 18)
        if deck.groups.isEmpty {
            ankiTops = []
            addFull(caption("가져온 카드가 없습니다. 아래 ‘Anki에서 가져오기’를 누르면 내 Anki의 빈칸 카드를 읽어 옵니다 (Anki 원본은 바꾸지 않습니다)."))
        } else {
            var order: [String] = []
            var total: [String: Int] = [:]
            var all: [String: Int] = [:]
            var picked: [String: Int] = [:]
            for g in deck.groups {
                let top = g.name.components(separatedBy: "::")[0]
                if total[top] == nil { order.append(top) }
                total[top, default: 0] += g.count
                all[top, default: 0] += 1
                if deck.scope.contains(g.name) { picked[top, default: 0] += 1 }
            }
            ankiTops = order
            addGrid(order.enumerated().map { i, top in
                let on = picked[top] ?? 0
                let state: NSControl.StateValue = on == 0 ? .off : (on == all[top]! ? .on : .mixed)
                return check("\(top)  \(total[top]!)장", #selector(ankiToggled(_:)), tag: i, state: state, mixed: true)
            })
            addFull(caption("Anki 범위를 고르면 빈칸 카드가 주로 나오고, O/X는 내 덱에서만 3문제 중 1문제꼴로 섞입니다. 과목별 세부 범위는 메뉴 막대 ⏎ → 시험범위에서 고릅니다."))
        }

        // 요약
        if deck.poolCount > 0 {
            var s = "지금 범위: Anki 빈칸 카드 \(deck.poolCount)장"
            if deck.ownCount > 0 && deck.mixOX { s += " + 내 덱 O/X \(deck.ownCount)문항" }
            summary.stringValue = s + "  (Anki 범위를 고른 동안 기본 제공 O/X는 나오지 않습니다)"
        } else {
            let n = deck.ownCount + deck.packCount
            summary.stringValue = n > 0
                ? "지금 범위: O/X \(n)문항 (기본 제공 \(deck.packCount) + 내 덱 \(deck.ownCount))"
                : "고른 과목이 없습니다. 하나 이상 켜지 않으면 예시 문제 10개만 나옵니다."
        }
    }

    @objc private func packToggled(_ b: NSButton) {
        guard packNames.indices.contains(b.tag) else { return }
        deck.togglePack(packNames[b.tag])
        refresh()
    }

    @objc private func ownToggled(_ b: NSButton) {
        guard ownNames.indices.contains(b.tag) else { return }
        deck.toggleOwn(ownNames[b.tag])
        refresh()
    }

    @objc private func ankiToggled(_ b: NSButton) {
        guard ankiTops.indices.contains(b.tag) else { return }
        let top = ankiTops[b.tag]
        let under = Set(deck.groups.map { $0.name }.filter { $0 == top || $0.hasPrefix(top + "::") })
        // 하나라도 꺼져 있으면 전부 켜고, 전부 켜져 있으면 전부 끈다.
        deck.setScope(under.isSubset(of: deck.scope) ? deck.scope.subtracting(under) : deck.scope.union(under))
        refresh()
    }

    @objc private func allPacksOn() { deck.setAllPacks(on: true); refresh() }
    @objc private func allPacksOff() { deck.setAllPacks(on: false); refresh() }
    @objc private func ankiClear() { deck.setScope([]); refresh() }

    // 동작 확인용: 창 내용을 PNG 로 저장한다.
    func snapshot(to url: URL) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// ───────────────────────── 앱 ─────────────────────────

enum Phase { case idle, pending, streaming }

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let deck = Deck()
    lazy var ui = QuizUI(deck: deck)
    let scanner = Scanner()
    let pet = Pet()
    private let petItem = NSMenuItem(title: "펫 보이기", action: #selector(togglePet), keyEquivalent: "")
    private let focusItem = NSMenuItem(title: "집중 모드 — 유튜브를 열면 펫이 닫음", action: #selector(toggleFocus), keyEquivalent: "")
    private lazy var focus = FocusGuard(pet: pet)
    private let habitsItem = NSMenuItem(title: "습관 알림 — 물·눈 쉬기·스트레칭", action: #selector(toggleHabits), keyEquivalent: "")
    private let calendarItem = NSMenuItem(title: "일정 알림 — 시작 10분 전에 펫이 알려 줌", action: #selector(toggleCalendar), keyEquivalent: "")
    private lazy var calendarWatch = CalendarWatch(pet: pet)

    private var phase = Phase.idle
    private var pendingAt = Date()
    private var lastSeen = Date()
    private var startedAt = Date()
    private var targetPid: pid_t?
    private var demoUntil: Date?
    fileprivate var tap: CFMachPort?

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let scopeMenu = NSMenu()
    private lazy var genWindow = GenWindow(deck: deck)
    private lazy var settings = SettingsWindow(deck: deck, app: self)
    var isActive: Bool { return tap != nil }

    @objc func openMain() { settings.show() }

    // 실행 중에 앱 아이콘을 다시 열면(Finder·Launchpad·Spotlight) 설정 창을 보여 준다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        ui.isLoading = { [weak self] in self?.phase != .idle }
        buildMenu()
        buildMainMenu()

        let args = CommandLine.arguments
        // 동작 확인용: 펫의 자세들을 PNG 로 저장하고 끝낸다.
        if let i = args.firstIndex(of: "--pet-snapshot"), i + 1 < args.count {
            pet.snapshotPoses(to: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
            return
        }
        // 펫은 카드 왼쪽 위에 앉는다 (카드를 바라보는 방향).
        pet.perchTarget = { [weak self] in
            guard let s = self, s.ui.visible else { return nil }
            let f = s.ui.panel.frame
            return CGPoint(x: f.minX - 34, y: f.maxY - 60)
        }
        ui.onShow = { [weak self] in self?.pet.goToCard() }
        ui.onAnswer = { [weak self] correct in self?.pet.react(correct: correct) }
        ui.onHide = { [weak self] in self?.pet.goHome() }
        let demo = args.contains("--demo")
        // 실제 사용 때만 권한 요청 창을 띄운다.
        let shotSettings = args.firstIndex(of: "--snapshot-settings")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !demo && shotSettings == nil] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        loadTuning()
        Log.write("──── 실행 v0.1.1 trusted=\(trusted) demo=\(demo)")
        if trusted { installTap() }
        updateStatus()

        // 대상 앱이 켜져 있거나 앞으로 나오면 화면 요소를 내보내도록 미리 준비시킨다.
        let prepareTarget = { [weak self] (a: NSRunningApplication) in
            guard let b = a.bundleIdentifier, targetBundleIDs.contains(b) else { return }
            self?.scanner.prepare(pid: a.processIdentifier)
        }
        if trusted { NSWorkspace.shared.runningApplications.forEach(prepareTarget) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            guard AXIsProcessTrusted(),
                  let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            prepareTarget(a)
        }

        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let s = self, s.tap == nil, AXIsProcessTrusted() else { return }
            Log.write("권한이 허용된 것을 확인함")
            s.installTap()
            s.updateStatus()
            NSWorkspace.shared.runningApplications.forEach(prepareTarget)
        }

        // 동작 확인용: 가져오기와 시험범위를 명령줄에서 지정
        if args.contains("--import-anki") {
            do { print("imported", try AnkiImport.run()) }
            catch { print("import failed:", (error as? AnkiImport.Failure)?.message ?? "\(error)") }
            deck.loadAnki()
            print("groups", deck.groups.count)
        }
        if let i = args.firstIndex(of: "--scope"), i + 1 < args.count {
            deck.setScope(Set(args[i + 1].components(separatedBy: ",")), save: false)
            print("pool", deck.poolCount)
        }
        // 동작 확인용: 글 파일이나 PDF 로 AI 출제를 돌려 결과만 출력한다 (키는 ANTHROPIC_API_KEY 환경 변수)
        if let i = args.firstIndex(of: "--gen-test"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let source: QuizGen.Source
            if url.pathExtension.lowercased() == "pdf", let data = try? Data(contentsOf: url) {
                source = .pdf(data: data, text: PDFDocument(data: data)?.string ?? "")
            } else {
                source = .text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            QuizGen.generate(source: source, count: 5, apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "") { r in
                switch r {
                case .failure(let f): print("gen failed:", f.message)
                case .success(let o):
                    print("gen ok: \(o.items.count) items, dropped \(o.dropped), verified \(o.verified)")
                    for it in o.items { print(" ", it.a ? "O" : "X", "|", it.q, "|", it.why, "|", it.evidence) }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if demo { startDemo() }
        genWindow.onSaved = { [weak self] in self?.settings.refresh() }
        // 동작 확인용: 설정 창을 띄워 PNG 로 저장하고 끝낸다.
        if let i = shotSettings, i + 1 < args.count {
            settings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.settings.snapshot(to: URL(fileURLWithPath: args[i + 1]))
                NSApp.terminate(nil)
            }
            return
        }
        // 평소 실행: 앱을 열면 설정 창이 보인다 (메뉴 막대 전용 앱이라 아무것도 안 뜨면 켜진 줄 모른다).
        let testing = demo || ["--snapshot", "--import-anki", "--scope", "--gen-test"].contains { args.contains($0) }
        if !testing { settings.show() }
        if !testing || demo { pet.start() }
        if !testing {
            loadTuning()
            pet.setOverFullScreen(FocusGuard.enabled)
            focus.start()
            calendarWatch.start()
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            let shot = { (name: String) in self.ui.snapshot(to: dir.appendingPathComponent(name)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { shot("0-pill.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { shot("1-loading.png"); self.ui.answer(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { shot("2-answered.png"); self.ui.answer(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) { shot("2b-graded.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) { shot("3-done.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 17.3) { shot("4-collapsed.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19.5) { NSApp.terminate(nil) }
        }
    }

    // ── 메뉴 막대 ──
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏎"
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let items: [(String, Selector)] = [
            ("설정 열기… (과목·덱 선택)", #selector(openMain)),
            ("카드 미리 보기 (8초)", #selector(startDemo)),
            ("Anki에서 빈칸 카드 가져오기…", #selector(importAnki)),
            ("정리본·강의록으로 O/X 만들기 (AI)…", #selector(openGen)),
            ("O/X 문제 편집…", #selector(editCards)),
            ("손쉬운 사용 설정 열기…", #selector(openSettings)),
            ("진단 정보 복사", #selector(copyDiagnostics)),
            ("진단 기록 파일 열기", #selector(openLog)),
        ]
        for (title, sel) in items {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        let scopeItem = NSMenuItem(title: "시험범위", action: nil, keyEquivalent: "")
        scopeMenu.delegate = self
        scopeMenu.autoenablesItems = false
        scopeItem.submenu = scopeMenu
        menu.insertItem(scopeItem, at: 4)
        petItem.target = self
        petItem.state = Pet.enabled ? .on : .off
        menu.addItem(petItem)
        let previewItem = NSMenuItem(title: "펫 동작 보기", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for (title, key) in [("물 마시기", "drink"), ("둥지 짓고 자기", "nest"), ("꾸벅꾸벅 졸기", "nod"),
                             ("졸다가 구르기", "roll"), ("날아서 옮겨 가기", "fly"), ("앞 보고 기우뚱", "tilt"),
                             ("눈 쉬기", "eyes"), ("기지개 켜기", "stretch"), ("일정 알림 (예시)", "calendar")] {
            let it = NSMenuItem(title: title, action: #selector(previewPet(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            previewMenu.addItem(it)
        }
        previewItem.submenu = previewMenu
        menu.addItem(previewItem)
        focusItem.target = self
        focusItem.state = FocusGuard.enabled ? .on : .off
        menu.addItem(focusItem)
        habitsItem.target = self
        habitsItem.state = Pet.habitsOn ? .on : .off
        menu.addItem(habitsItem)
        calendarItem.target = self
        calendarItem.state = CalendarWatch.enabled ? .on : .off
        menu.addItem(calendarItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Loading Dose 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatus() {
        settings.refreshStatus()
        statusLine.title = tap != nil
            ? "작동 중 — Claude·ChatGPT 앱에서 Enter를 누르면 카드가 뜹니다"
            : "권한 필요 — 손쉬운 사용에서 'Loading Dose'를 허용하세요"
    }

    @objc func previewPet(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { pet.preview(key) }
    }

    @objc func toggleHabits() {
        Pet.habitsOn = !Pet.habitsOn
        habitsItem.state = Pet.habitsOn ? .on : .off
    }

    // 일정 알림을 켤 때 캘린더 접근을 요청한다. 거절되면 켜지 않고 이유를 알려 준다.
    @objc func toggleCalendar() {
        if CalendarWatch.enabled {
            CalendarWatch.enabled = false
            calendarItem.state = .off
            return
        }
        calendarWatch.requestAccess { [weak self] ok in
            guard let s = self else { return }
            CalendarWatch.enabled = ok
            s.calendarItem.state = ok ? .on : .off
            Log.write("일정 알림 \(ok ? "켬" : "켜지 못함 (캘린더 접근 거절)")")
            if ok { s.calendarWatch.check() }
            else {
                let alert = NSAlert()
                alert.messageText = "캘린더를 읽을 수 없습니다"
                alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서 Loading Dose를 허용한 뒤 다시 켜 주세요."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func toggleFocus() {
        FocusGuard.enabled = !FocusGuard.enabled
        focusItem.state = FocusGuard.enabled ? .on : .off
        pet.setOverFullScreen(FocusGuard.enabled)
        Log.write("집중 모드 \(FocusGuard.enabled ? "켬" : "끔")")
    }

    @objc func togglePet() {
        pet.setEnabled(!Pet.enabled)
        petItem.state = Pet.enabled ? .on : .off
    }

    @objc func startDemo() {
        guard phase == .idle else { return }
        demoUntil = Date().addingTimeInterval(8)
        begin(pid: nil, ask: "미리 보기입니다")
    }

    @objc func editCards() {
        deck.ensureFile()
        NSWorkspace.shared.open(Deck.file)
    }

    // ── 시험범위 메뉴 (열 때마다 새로 만든다) ──
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === scopeMenu else { return }
        menu.removeAllItems()
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ obj: Any? = nil, _ state: NSControl.StateValue = .off) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.representedObject = obj
            it.state = state
            it.isEnabled = sel != nil
            m.addItem(it)
        }
        add(menu, "기본 제공 O/X (KMLE 대비)", nil)
        for t in deck.packTopics {
            add(menu, "\(t.name) — \(t.count)문항", #selector(togglePack(_:)), t.name, deck.packOff.contains(t.name) ? .off : .on)
        }
        menu.addItem(.separator())
        add(menu, "Anki 빈칸 카드", nil)
        if deck.groups.isEmpty {
            add(menu, "먼저 'Anki에서 빈칸 카드 가져오기'를 실행하세요", nil)
            return
        }
        add(menu, deck.scope.isEmpty ? "고른 범위 없음 — O/X 문제만 나옵니다" : "고른 범위: 카드 \(deck.poolCount)장", nil)
        add(menu, "모두 해제", #selector(clearScope))
        add(menu, "내 O/X 문제도 섞기 (3문제 중 1문제)", #selector(toggleMix), nil, deck.mixOX ? .on : .off)
        menu.addItem(.separator())

        var order: [String] = []
        var byTop: [String: [(name: String, count: Int)]] = [:]
        for g in deck.groups {
            let top = g.name.components(separatedBy: "::")[0]
            if byTop[top] == nil { order.append(top) }
            byTop[top, default: []].append(g)
        }
        for top in order {
            let gs = byTop[top]!
            let on = gs.filter { deck.scope.contains($0.name) }.count
            let state: NSControl.StateValue = on == 0 ? .off : (on == gs.count ? .on : .mixed)
            if gs.count == 1 {
                add(menu, "\(top) — \(gs[0].count)장", #selector(toggleGroup(_:)), gs[0].name, state)
                continue
            }
            let sub = NSMenu()
            sub.autoenablesItems = false
            add(sub, "모두 선택", #selector(selectTop(_:)), top)
            add(sub, "모두 해제", #selector(clearTop(_:)), top)
            sub.addItem(.separator())
            for g in gs {
                let label = g.name.components(separatedBy: "::").dropFirst().joined(separator: "::")
                add(sub, "\(label.isEmpty ? top : label) — \(g.count)장", #selector(toggleGroup(_:)), g.name,
                    deck.scope.contains(g.name) ? .on : .off)
            }
            let it = NSMenuItem(title: "\(top) — \(gs.reduce(0) { $0 + $1.count })장", action: nil, keyEquivalent: "")
            it.state = state
            it.submenu = sub
            menu.addItem(it)
        }
    }

    private func groups(under top: String) -> [String] {
        return deck.groups.map { $0.name }.filter { $0 == top || $0.hasPrefix(top + "::") }
    }

    @objc func toggleGroup(_ sender: NSMenuItem) {
        guard let g = sender.representedObject as? String else { return }
        var s = deck.scope
        if s.contains(g) { s.remove(g) } else { s.insert(g) }
        deck.setScope(s)
    }

    @objc func selectTop(_ sender: NSMenuItem) {
        guard let top = sender.representedObject as? String else { return }
        deck.setScope(deck.scope.union(groups(under: top)))
    }

    @objc func clearTop(_ sender: NSMenuItem) {
        guard let top = sender.representedObject as? String else { return }
        deck.setScope(deck.scope.subtracting(groups(under: top)))
    }

    @objc func clearScope() { deck.setScope([]) }
    @objc func toggleMix() { deck.mixOX = !deck.mixOX }
    @objc func togglePack(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? String { deck.togglePack(t) }
    }
    @objc func openGen() { genWindow.show() }

    // 메뉴 막대 전용 앱에는 기본 메뉴가 없어서, 입력 창에서 붙여넣기(⌘V) 등이 되도록 편집 메뉴를 만든다.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Loading Dose 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func importAnki() {
        statusLine.title = "Anki에서 가져오는 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            var count = 0
            var failure: String?
            do { count = try AnkiImport.run() }
            catch { failure = (error as? AnkiImport.Failure)?.message ?? error.localizedDescription }
            DispatchQueue.main.async {
                self.deck.loadAnki()
                self.updateStatus()
                self.settings.refresh()
                let alert = NSAlert()
                if let f = failure {
                    alert.messageText = "가져오지 못했습니다"
                    alert.informativeText = f
                } else {
                    alert.messageText = "빈칸 카드 \(count)장을 가져왔습니다"
                    alert.informativeText = "⏎ 메뉴 → 시험범위에서 과목을 고르면 그 범위에서 문제가 나옵니다. Anki 원본은 바뀌지 않습니다."
                }
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func copyDiagnostics() {
        let pids = NSWorkspace.shared.runningApplications.compactMap { a -> (String, pid_t)? in
            guard let b = a.bundleIdentifier, targetBundleIDs.contains(b) else { return nil }
            return (b, a.processIdentifier)
        }
        let head = "Loading Dose 진단 — 권한: \(AXIsProcessTrusted() ? "허용됨" : "없음"), 키 감지: \(tap != nil ? "켜짐" : "꺼짐"), 대상 앱 \(pids.count)개 실행 중\n\n"
        scanner.dump(pids: pids) { body in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(head + body, forType: .string)
            let alert = NSAlert()
            alert.messageText = "진단 정보를 복사했습니다"
            alert.informativeText = "버튼 이름 목록이 클립보드에 들어 있습니다. 대화 제목이 섞여 있을 수 있으니 붙여넣기 전에 확인하세요."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // ── 키 입력 ──
    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyTapCallback, userInfo: nil) else {
            Log.write("키 감지를 켜지 못함 (tapCreate 실패)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        Log.write("키 감지 켜짐")
    }

    private var sawKey = false
    private var lastOtherApp = ""

    // true 를 돌려주면 그 키 입력을 삼킨다.
    func handleKey(code: Int64, flags: CGEventFlags) -> Bool {
        if !sawKey { sawKey = true; Log.write("첫 키 입력을 받음 (키 감지 정상)") }
        let mods = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if mods == .maskAlternate && (code == 31 || code == 7) && ui.canAnswer {
            ui.answer(code == 31)   // 31 = O, 7 = X
            return true
        }
        if (code == 36 || code == 76) && mods.isEmpty { enterPressed() }
        return false
    }

    private func enterPressed() {
        if phase == .idle { loadTuning() }   // 진행 중에는 검사 스레드가 쓰고 있으니 건드리지 않는다
        let front = NSWorkspace.shared.frontmostApplication
        let bid = front?.bundleIdentifier ?? "(알 수 없음)"
        guard let front = front, targetBundleIDs.contains(bid) else {
            if bid != lastOtherApp { lastOtherApp = bid; Log.write("Enter: 대상 앱이 아님 (\(bid))") }
            return
        }
        lastOtherApp = ""
        guard phase == .idle else {
            Log.write("Enter: \(bid), 이미 진행 중이라 무시")
            return
        }
        // 입력창에 쓴 글을 읽어 온다. 못 읽어도 카드는 띄운다.
        var ask = ""
        var note = "입력창을 못 읽음"
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let f = axAttr(app, "AXFocusedUIElement") {
            let el = f as! AXUIElement
            let role = axString(el, "AXRole")
            if let v = axAttr(el, "AXValue") as? String {
                ask = v.trimmingCharacters(in: .whitespacesAndNewlines)
                note = "role=\(role) 글자 수=\(ask.count)"
            } else {
                note = "role=\(role) 값 없음"
            }
        }
        Log.write("Enter: \(bid) pid=\(front.processIdentifier) \(note) → 카드 시작")
        begin(pid: front.processIdentifier, ask: ask)
    }

    // ── 로딩 상태 ──
    private func begin(pid: pid_t?, ask: String) {
        guard phase == .idle else { return }
        phase = .pending
        pendingAt = Date()
        startedAt = pendingAt
        targetPid = pid
        let oneLine = ask.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        ui.show(ask: String(oneLine.prefix(80)))
    }

    private var elapsed: Int { return max(0, Int(Date().timeIntervalSince(startedAt).rounded())) }

    private func tick() {
        guard phase != .idle else { return }
        ui.setProgress(seconds: elapsed)
        if let d = demoUntil {
            handle(found: Date() < d)
        } else if let pid = targetPid {
            scanner.findStop(pid: pid) { [weak self] found in self?.handle(found: found) }
        }
    }

    private func handle(found: Bool) {
        guard phase != .idle else { return }
        let now = Date()
        if found && now.timeIntervalSince(startedAt) < hardCap {
            lastSeen = now
            if phase != .streaming { Log.write("생성 중으로 판단 (\(elapsed)초째)") }
            phase = .streaming
            return
        }
        if phase == .streaming && (now.timeIntervalSince(lastSeen) > endGrace || found) { finish() }
        else if phase == .pending && now.timeIntervalSince(pendingAt) > pendingTimeout { finish() }
    }

    private func finish() {
        let wasStreaming = phase == .streaming
        Log.write(wasStreaming ? "끝: 답변 도착으로 판단 (\(elapsed)초)" : "끝: 중지 버튼을 못 찾고 시간 초과 (\(elapsed)초)")
        phase = .idle
        demoUntil = nil
        guard ui.visible else { return }
        if !wasStreaming { ui.hide(); return }   // Enter만 누르고 생성이 시작되지 않은 경우
        ui.markDone(seconds: elapsed)
    }
}

let controller = AppController()

func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Log.write("키 감지가 꺼져 다시 켬 (\(type == .tapDisabledByTimeout ? "시간 초과" : "사용자 입력"))")
        if let t = controller.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown,
       controller.handleKey(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()

// 퀴즈의 공용 부분: 문항(Card·Deck), Anki 가져오기, 로딩 감지에 쓰는 화면 읽기(Scanner), 카드 화면(QuizUI).
// Loading Dose(mac/main.swift)와 Omogi(omogi/)가 이 파일을 같이 쓴다.
// 이 파일이 기대하는 것(각 앱의 main.swift 에 있다): Log, axAttr, axString, reduceMotion.

import Cocoa
import ApplicationServices
import SQLite3

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
let hardCap: TimeInterval = 600
let autoNextDelay: TimeInterval = 4

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
    /// 내 문제(cards.txt)와 가져온 Anki 카드(anki.tsv)를 두는 폴더. Loading Dose 는 예전 이름 Enter 를 그대로 쓰고,
    /// Omogi 는 시작할 때 자기 폴더로 바꾼다 (Deck 을 만들기 전에).
    static var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Enter", isDirectory: true)
    static var file: URL { return dir.appendingPathComponent("cards.txt") }
    static var ankiFile: URL { return dir.appendingPathComponent("anki.tsv") }

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

// ───────────────────── 로딩 감지: 화면 읽기 ─────────────────────

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
    /// 답했을 때: (맞았는지, 과목, 스스로 채점하는 빈칸 카드인지)
    var onAnswerCard: ((Bool, String, Bool) -> Void)?
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

    /// 답변을 기다리는 것과 상관없이 문제 하나를 바로 펼쳤는지 (Omogi 가 물어 온 문제)
    private(set) var standalone = false

    /// 문제 하나를 바로 펼친다. 답하면 해설을 읽을 시간을 두고 접히고, "다음"을 누르면 이어서 풀 수 있다.
    func showStandalone(title: String) {
        for t in [openTimer, autoNext, collapseTimer, hideTimer] { t?.invalidate() }
        generation += 1
        standalone = true
        ask = ""
        askLabel.stringValue = ""
        metaLabel.stringValue = ""
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = title
        spinner.setDone()
        isOpen = true
        renderCard()
        if !visible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion() ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        onShow?()
        scheduleCollapse(90)        // 안 풀고 두면 알아서 접힌다
    }

    func show(ask: String) {
        for t in [openTimer, collapseTimer, hideTimer] { t?.invalidate() }
        standalone = false
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
        onAnswerCard?(correct, c.topic, isCloze)

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
            scheduleCollapse(standalone ? 12 : (isCloze ? 1.5 : 2.5))
        }
    }

    @objc private func oTapped() { answer(true) }
    @objc private func xTapped() { answer(false) }
    @objc private func nextTapped() {
        if isLoading() { renderCard() }
        else if standalone { renderCard(); scheduleCollapse(90) }
        else { collapse() }
    }
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

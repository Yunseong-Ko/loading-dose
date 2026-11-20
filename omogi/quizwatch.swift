// O/X 퀴즈 (Omogi). 문항·카드 화면·화면 읽기는 Loading Dose 와 같은 것을 쓴다 (mac/quiz.swift).
// 문제가 뜨는 길은 둘이고, 둘 다 기본은 꺼져 있다:
//   Enter 감지 — Claude·ChatGPT 데스크톱 앱에서 Enter 를 누르고 답을 기다리는 동안 카드가 뜬다.
//                키 입력과 그 앱의 "중지" 버튼을 읽어야 해서 손쉬운 사용 권한이 필요하다.
//                읽는 것은 어떤 키인지(Enter, ⌥O, ⌥X)뿐이고, 친 글자는 보지도 남기지도 않는다.
//   물어 오기   — 컴퓨터를 쓰는 동안 가끔 오모기가 문제를 물고 온다. 누르면 한 문제가 펼쳐진다. 권한이 필요 없다.
// 로딩을 판단하는 흐름은 Loading Dose 의 AppController 와 같다 (고칠 때는 양쪽을 같이 볼 것).
import Cocoa
import ApplicationServices

var quizBringMinutes = 25.0        // 물어 오는 간격 (config.json 의 "quizBringMinutes")

private func quizTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let watcher = Unmanaged<QuizWatcher>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        watcher.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown,
       watcher.handleKey(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

final class QuizWatcher {
    static var enterOn: Bool {
        get { return UserDefaults.standard.bool(forKey: "quizEnterOn") }
        set { UserDefaults.standard.set(newValue, forKey: "quizEnterOn") }
    }
    static var bringOn: Bool {
        get { return UserDefaults.standard.bool(forKey: "quizBringOn") }
        set { UserDefaults.standard.set(newValue, forKey: "quizBringOn") }
    }

    private enum Phase { case idle, pending, streaming }

    let deck: Deck
    let ui: QuizUI
    private let pet: Pet
    private let scanner = Scanner()
    private var phase = Phase.idle
    private var pendingAt = Date()
    private var lastSeen = Date()
    private var startedAt = Date()
    private var targetPid: pid_t?
    private var tap: CFMachPort?
    private var tapEnabled = false
    private var lastOtherApp = ""
    private var nextBring = Date().addingTimeInterval(quizBringMinutes * 60)
    private var started = false

    /// Enter 감지가 실제로 돌고 있는지 (켜져 있고 권한도 있다)
    var watching: Bool { return tap != nil && tapEnabled }

    init(pet: Pet) {
        self.pet = pet
        Deck.dir = supportDir          // 내 문제 파일과 Anki 카드는 Omogi 폴더에 둔다
        deck = Deck()
        ui = QuizUI(deck: deck)
        ui.isLoading = { [weak self] in self?.phase != .idle }
        // 카드가 뜨면 오모기가 카드 왼쪽 위에 와서 앉고, 정답·오답에 반응한다.
        pet.comboGrowth = true
        pet.perchTarget = { [weak self] in
            guard let s = self, s.ui.visible else { return nil }
            let f = s.ui.panel.frame
            return CGPoint(x: f.minX - 34, y: f.maxY - 60)
        }
        ui.onShow = { [weak pet] in pet?.goToCard() }
        ui.onAnswer = { [weak pet] correct in pet?.react(correct: correct) }
        // 맞히면 꼬마 뱁새 1마리. 5연속으로 터지면 흩어지는 꼬마들을 눌러 잡는다 (터지는 동작이 꺼져 있으면 바로 준다).
        ui.onAnswerCard = { [weak pet] correct, topic, selfGraded in
            let got = Wardrobe.shared.answered(correct: correct, topic: topic, selfGraded: selfGraded, popped: !reduceMotion())
            if got > 1 { pet?.cheer("꼬마 뱁새 +\(got)") }
        }
        pet.onMiniCaught = { Wardrobe.shared.earn(1) }
        ui.onHide = { [weak pet] in pet?.goHome() }
        pet.onQuizOpen = { [weak self] in self?.solveOne() }
    }

    func start() {
        guard !started else { return }
        started = true
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        let slow = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.housekeeping() }
        RunLoop.main.add(slow, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard QuizWatcher.enterOn, AXIsProcessTrusted(),
                  let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let b = a.bundleIdentifier, targetBundleIDs.contains(b) else { return }
            self?.scanner.prepare(pid: a.processIdentifier)
        }
        housekeeping()
    }

    /// 지금 한 문제를 펼친다 (오모기가 물어 온 문제를 눌렀을 때, 메뉴에서 골랐을 때).
    func solveOne() {
        guard phase == .idle else { return }       // 답변을 기다리는 카드가 떠 있으면 그대로 둔다
        ui.showStandalone(title: "오모기가 물어 온 문제")
        nextBring = Date().addingTimeInterval(quizBringMinutes * 60)
    }

    // 2초마다: 설정과 권한에 맞춰 키 감지를 켜고 끄고, 물어 올 때가 됐는지 본다.
    private func housekeeping() {
        let want = QuizWatcher.enterOn && AXIsProcessTrusted()
        if want && tap == nil { installTap() }
        if let t = tap, tapEnabled != want {
            CGEvent.tapEnable(tap: t, enable: want)
            tapEnabled = want
            Log.write("퀴즈: 키 감지 \(want ? "켬" : "끔")")
            if want {
                for a in NSWorkspace.shared.runningApplications {
                    if let b = a.bundleIdentifier, targetBundleIDs.contains(b) { scanner.prepare(pid: a.processIdentifier) }
                }
            }
        }
        guard QuizWatcher.bringOn else { nextBring = Date().addingTimeInterval(quizBringMinutes * 60); return }
        // 컴퓨터를 쓰고 있고, 카드도 편지도 없을 때만 물어 온다.
        if Date() >= nextBring, phase == .idle, !ui.visible, idleSeconds() < 120, !pet.isHoldingMail,
           pet.bringQuiz("O/X 한 문제 풀래요? — 눌러서 풀기") {
            nextBring = Date().addingTimeInterval(quizBringMinutes * 60)
            Log.write("퀴즈: 오모기가 문제를 물어 옴")
        }
    }

    // ── 키 입력 ──
    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: quizTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.write("퀴즈: 키 감지를 켜지 못함 (tapCreate 실패)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: false)
        tap = t
        tapEnabled = false
    }

    fileprivate func reenableTap() {
        guard let t = tap, tapEnabled else { return }
        CGEvent.tapEnable(tap: t, enable: true)
        Log.write("퀴즈: 키 감지가 꺼져 다시 켬")
    }

    // true 를 돌려주면 그 키 입력을 삼킨다.
    fileprivate func handleKey(code: Int64, flags: CGEventFlags) -> Bool {
        let mods = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if mods == .maskAlternate && (code == 31 || code == 7) && ui.canAnswer {
            ui.answer(code == 31)   // 31 = O, 7 = X
            return true
        }
        if (code == 36 || code == 76) && mods.isEmpty { enterPressed() }
        return false
    }

    private func enterPressed() {
        guard QuizWatcher.enterOn else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let bid = front?.bundleIdentifier ?? "(알 수 없음)"
        guard let front = front, targetBundleIDs.contains(bid) else {
            if bid != lastOtherApp { lastOtherApp = bid; Log.write("퀴즈 Enter: 대상 앱이 아님 (\(bid))") }
            return
        }
        lastOtherApp = ""
        guard phase == .idle else { return }
        // Loading Dose 가 같이 켜져 있으면 그쪽 카드가 같은 자리에 뜨므로 양보한다.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.enterquiz.mac").isEmpty {
            Log.write("퀴즈 Enter: Loading Dose 가 켜져 있어 카드를 띄우지 않음")
            return
        }
        // 입력창에 쓴 글을 읽어 카드 위에 한 줄로 보여 준다. 기록에는 글자 수만 남긴다.
        var ask = ""
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let f = axAttr(app, "AXFocusedUIElement"), let v = axAttr(f as! AXUIElement, "AXValue") as? String {
            ask = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        Log.write("퀴즈 Enter: \(bid) 글자 수=\(ask.count) → 카드 시작")
        phase = .pending
        pendingAt = Date()
        startedAt = pendingAt
        targetPid = front.processIdentifier
        let oneLine = ask.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        ui.show(ask: String(oneLine.prefix(80)))
    }

    // ── 로딩 상태 ──
    private var elapsed: Int { return max(0, Int(Date().timeIntervalSince(startedAt).rounded())) }

    private func tick() {
        guard phase != .idle, let pid = targetPid else { return }
        ui.setProgress(seconds: elapsed)
        scanner.findStop(pid: pid) { [weak self] found in self?.handle(found: found) }
    }

    private func handle(found: Bool) {
        guard phase != .idle else { return }
        let now = Date()
        if found && now.timeIntervalSince(startedAt) < hardCap {
            lastSeen = now
            if phase != .streaming { Log.write("퀴즈: 생성 중으로 판단 (\(elapsed)초째)") }
            phase = .streaming
            return
        }
        if phase == .streaming && (now.timeIntervalSince(lastSeen) > endGrace || found) { finish() }
        else if phase == .pending && now.timeIntervalSince(pendingAt) > pendingTimeout { finish() }
    }

    private func finish() {
        let wasStreaming = phase == .streaming
        Log.write(wasStreaming ? "퀴즈 끝: 답변 도착으로 판단 (\(elapsed)초)" : "퀴즈 끝: 중지 버튼을 못 찾고 시간 초과 (\(elapsed)초)")
        phase = .idle
        guard ui.visible else { return }
        if !wasStreaming { ui.hide(); return }   // Enter만 누르고 생성이 시작되지 않은 경우
        ui.markDone(seconds: elapsed)
    }
}

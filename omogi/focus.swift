// 집중 모드: 브라우저에서 유튜브를 열면 펫이 날아가 탭을 닫는다.
// 기본은 꺼져 있고 메뉴에서 켠다. 브라우저 맨 앞 창의 제목만 읽어 판단하며, 제목은 기록하지 않는다.
// 닫을 때는 그 창이 여전히 맨 앞이고 제목이 그대로인지 다시 확인한 뒤 ⌘W 를 보낸다.
import Cocoa
import ApplicationServices

// 막을 사이트. 창 제목에서 브라우저 이름을 뗀 마지막 토막이 사이트 이름이거나 "… • 사이트 이름" 꼴이면 막는다.
// (유튜브 페이지 제목은 "… - YouTube", 인스타그램은 "Instagram" 또는 "이름 • Instagram 사진 및 동영상" 이다.
//  사이트 이름을 검색한 결과 페이지나 그 이름이 들어간 글 제목은 해당하지 않는다.)
// config.json 의 "blockSites" 로 바꿀 수 있다.
var blockSites = ["youtube", "instagram"]

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, "AXPosition"), let s = axAttr(e, "AXSize") else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}

final class FocusGuard {
    private static let defaultsKey = "focusOn"
    static var enabled: Bool {
        get { return UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private let pet: Pet
    private let queue = DispatchQueue(label: "enter.focus", qos: .utility)
    private var timer: Timer?
    private var busy = false        // 제목을 읽는 중
    private var chasing = false     // 펫이 출동해 있는 중
    private var lastClosed = Date.distantPast
    private var warned = false
    private var lastFound = Date.distantPast
    private let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.naver.Whale", "org.mozilla.firefox",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    private let browserNames = ["google chrome", "chrome", "safari", "arc", "microsoft edge", "brave",
                                "whale", "naver whale", "mozilla firefox", "firefox", "opera", "vivaldi"]

    init(pet: Pet) { self.pet = pet }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // 창 제목이 막을 사이트의 것인지. 제목은 " - " 로 나뉜 토막들이고 끝에 브라우저 이름(과 프로필 이름)이 붙는다.
    private func matches(_ title: String) -> Bool {
        var parts = title.lowercased()
            .replacingOccurrences(of: " – ", with: " - ").replacingOccurrences(of: " — ", with: " - ")
            .components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { browserNames.contains($0) }) { parts = Array(parts[..<i]) }
        guard var last = parts.last else { return false }
        // 알림 개수 "(3) " 를 뗀다.
        if last.hasPrefix("("), let close = last.firstIndex(of: ")"),
           last[last.index(after: last.startIndex)..<close].allSatisfy({ $0.isNumber || $0 == "+" }) {
            last = last[last.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        return blockSites.contains { last == $0 || last.contains("• " + $0) }
    }

    private func check() {
        if FocusGuard.enabled && !AXIsProcessTrusted() && !warned {
            warned = true
            Log.write("집중 모드: 손쉬운 사용 권한이 없어 동작하지 않음")
        }
        guard FocusGuard.enabled, AXIsProcessTrusted(), !busy, !chasing,
              Date().timeIntervalSince(lastClosed) > 3,
              let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier, browsers.contains(bid) else { return }
        busy = true
        let pid = front.processIdentifier
        queue.async {
            let spot = self.inspect(pid: pid)          // 화면 왼쪽 위가 원점인 좌표
            DispatchQueue.main.async {
                self.busy = false
                guard let spot = spot, let primary = NSScreen.screens.first else { return }
                if Date().timeIntervalSince(self.lastFound) > 10 { Log.write("집중 모드: 막을 창을 발견 (\(bid))") }
                self.lastFound = Date()
                guard self.pet.isShown else {          // 펫을 꺼 둔 경우에는 바로 닫는다
                    self.close(pid: pid, bid: bid)
                    return
                }
                // 부리가 닫기 버튼에 닿도록 발 위치를 잡는다 (오른쪽을 볼 때 부리는 발에서 오른쪽 27pt, 위 33pt).
                let target = CGPoint(x: spot.x - 30, y: primary.frame.height - spot.y - 33)
                self.chasing = true
                Log.write("집중 모드: 펫 출동")
                self.pet.chase(to: target,
                               act: { [weak self] in self?.close(pid: pid, bid: bid) },
                               done: { [weak self] in self?.chasing = false })
            }
        }
    }

    // 맨 앞 창이 막을 사이트면 펫이 쫄 자리(고른 탭의 닫기 버튼 근처)를 돌려준다.
    private func inspect(pid: pid_t) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let w = axAttr(app, "AXFocusedWindow") else { return nil }
        let win = w as! AXUIElement
        guard matches(axString(win, "AXTitle")), let frame = axFrame(win) else { return nil }
        if let tab = selectedTab(in: win), let tf = axFrame(tab),
           frame.insetBy(dx: -8, dy: -8).contains(tf), tf.width > 30, tf.height < 80 {
            return CGPoint(x: tf.maxX - 16, y: tf.midY)
        }
        return CGPoint(x: frame.minX + min(260, frame.width / 3), y: frame.minY + 22)   // 못 찾으면 탭 막대 왼쪽쯤
    }

    // 창 위쪽 막대에서 고른 탭을 찾는다 (크롬·사파리 모두 탭은 값이 1인 AXRadioButton). 웹 페이지 안은 보지 않는다.
    private func selectedTab(in win: AXUIElement) -> AXUIElement? {
        var nodes = [win]
        var i = 0
        while i < nodes.count && i < 500 {
            let e = nodes[i]
            i += 1
            let role = axString(e, "AXRole")
            if role == "AXRadioButton", (axAttr(e, "AXValue") as? NSNumber)?.intValue == 1 { return e }
            if role == "AXWebArea" || role == "AXStaticText" || role == "AXImage" { continue }
            if let kids = axAttr(e, "AXChildren") as? [AXUIElement] { nodes.append(contentsOf: kids) }
        }
        return nil
    }

    // 그 창이 아직 맨 앞이고 제목이 그대로면 ⌘W 로 탭을 닫는다.
    private func close(pid: pid_t, bid: String) {
        guard FocusGuard.enabled, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == pid else {
            Log.write("집중 모드: 닫지 않음 (다른 앱으로 넘어감)")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let w = axAttr(app, "AXFocusedWindow"), matches(axString(w as! AXUIElement, "AXTitle")) else {
            Log.write("집중 모드: 닫지 않음 (이미 다른 페이지)")
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: down)   // 13 = W
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        lastClosed = Date()
        Log.write("집중 모드: 탭을 닫음 (\(bid))")
    }
}

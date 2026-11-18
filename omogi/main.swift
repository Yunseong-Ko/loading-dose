// Omogi — 화면에 사는 작은 뱁새 (메뉴 막대 앱).
// 펫이 화면 아래에서 돌아다니고(pet.swift), 집중 모드(focus.swift)·습관 알림·일정 알림(calendar.swift)을 맡는다.
// 손쉬운 사용 권한은 집중 모드를 켤 때만, 캘린더 접근은 일정 알림을 켤 때만 요청한다.
// 조정: ~/Library/Application Support/Omogi/config.json   기록: 같은 폴더의 debug.log
import Cocoa
import ApplicationServices
import CryptoKit

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Omogi", isDirectory: true)

// ───────────────────── 진단 기록 ─────────────────────
// 창 제목이나 일정 내용은 남기지 않는다. 무엇을 했는지만 남긴다.
enum Log {
    static let url = supportDir.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "omogi.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ s: String) {
        let line = stamp.string(from: Date()) + " " + s + "\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
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

// ───────────────────── 공통 도우미 (pet.swift·focus.swift 가 쓴다) ─────────────────────
func axAttr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func axString(_ e: AXUIElement, _ name: String) -> String {
    return axAttr(e, name) as? String ?? ""
}

func reduceMotion() -> Bool {
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

// config.json 예: {"blockSites": ["youtube", "instagram"], "waterMinutes": 45, "eyeMinutes": 20,
//                  "stretchMinutes": 50, "nestMinutes": 5, "calendarLeadMinutes": 10,
//                  "letterMinMinutes": 30, "letterMaxMinutes": 180, "letterLossPercent": 8}   (편지 값은 연습 배달에만 쓰인다)
func loadTuning() {
    let url = supportDir.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url) else { return }
    guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        Log.write("config.json 을 읽지 못함 (형식 오류)")
        return
    }
    if let v = j["blockSites"] as? [String] { blockSites = v.map { $0.lowercased() } }
    if let v = j["waterMinutes"] as? Double, v > 0 { waterMinutes = v }
    if let v = j["nestMinutes"] as? Double, v > 0 { nestMinutes = v }
    if let v = j["eyeMinutes"] as? Double, v > 0 { eyeMinutes = v }
    if let v = j["stretchMinutes"] as? Double, v > 0 { stretchMinutes = v }
    if let v = j["calendarLeadMinutes"] as? Double, v > 0 { calendarLeadMinutes = v }
    if let v = j["letterMinMinutes"] as? Double, v > 0 { letterMinMinutes = v }
    if let v = j["letterMaxMinutes"] as? Double, v > 0 { letterMaxMinutes = v }
    if let v = j["letterLossPercent"] as? Double, v >= 0 { letterLossPercent = v }
    Log.write("config.json 적용")
}

// ───────────────────────── 앱 ─────────────────────────
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let pet = Pet()
    private lazy var focus = FocusGuard(pet: pet)
    private lazy var calendarWatch = CalendarWatch(pet: pet)
    private lazy var letters = LetterBox(pet: pet)
    private lazy var letterWindows = LetterWindows(box: letters)
    private let inboxItem = NSMenuItem(title: "편지함…", action: #selector(openInbox), keyEquivalent: "")

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let petItem = NSMenuItem(title: "오모기 보이기", action: #selector(togglePet), keyEquivalent: "")
    private let focusItem = NSMenuItem(title: "집중 모드 — 유튜브·인스타그램을 열면 오모기가 닫음", action: #selector(toggleFocus), keyEquivalent: "")
    private let habitsItem = NSMenuItem(title: "습관 알림 — 물·눈 쉬기·스트레칭", action: #selector(toggleHabits), keyEquivalent: "")
    private let calendarItem = NSMenuItem(title: "일정 알림 — 시작 10분 전에 알려 줌", action: #selector(toggleCalendar), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        // 동작 확인용: 펫의 자세들을 PNG 로 저장하고 끝낸다.
        if let i = args.firstIndex(of: "--pet-snapshot"), i + 1 < args.count {
            pet.snapshotPoses(to: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
            return
        }
        // 동작 확인용: 편지 잠그기·열기를 키체인 없이 시험한다.
        if args.contains("--letters-selftest") {
            let a = P256.KeyAgreement.PrivateKey(), b = P256.KeyAgreement.PrivateKey()
            let text = "안녕, 오모기 ✉️ 200자 시험"
            let env = LetterCrypto.seal(text, to: a.publicKey.x963Representation)
            var bad = env ?? Data()
            if !bad.isEmpty { bad[bad.count - 1] ^= 1 }
            print("round-trip:", env.flatMap { LetterCrypto.open($0, with: a) } == text,
                  "| wrong key rejected:", env.flatMap { LetterCrypto.open($0, with: b) } == nil,
                  "| tampered rejected:", LetterCrypto.open(bad, with: a) == nil,
                  "| bytes:", env?.count ?? 0)
            NSApp.terminate(nil)
            return
        }
        // 동작 확인용: 편지 서버에 로그인해서 함수 하나를 불러 본다 (등록은 하지 않는다).
        if args.contains("--server-selftest") {
            guard let server = Server.shared else { print("server.json 없음"); NSApp.terminate(nil); return }
            server.call("omogi_list_friends") { r in
                switch r {
                case .success(let v): print("server ok:", v ?? "nil")
                case .failure(let e): print("server failed:", e.code)
                }
                NSApp.terminate(nil)
            }
            return
        }
        loadTuning()
        buildMenu()
        buildMainMenu()
        pet.onMailOpen = { [weak self] in self?.letterWindows.showInbox() }
        letters.start()
        // 동작 확인용: 실행한 뒤 연습 편지 한 통을 보낸다.
        if let i = args.firstIndex(of: "--send-test"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.letters.send(args[i + 1], to: self.letters.friends[0]) { problem in
                    Log.write("편지: 시험 발송 \(problem ?? "성공")")
                }
            }
        }
        Log.write("──── 실행 v0.1.0 trusted=\(AXIsProcessTrusted()) focus=\(FocusGuard.enabled) calendar=\(CalendarWatch.enabled) server=\(Server.shared != nil)")
        pet.setOverFullScreen(FocusGuard.enabled)
        pet.start()
        focus.start()
        calendarWatch.start()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let face = pet.faceImage(height: 18) { statusItem.button?.image = face }
        else { statusItem.button?.title = "오모기" }
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for (item, on) in [(petItem, Pet.enabled), (focusItem, FocusGuard.enabled),
                           (habitsItem, Pet.habitsOn), (calendarItem, CalendarWatch.enabled)] {
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let writeItem = NSMenuItem(title: "편지 쓰기…", action: #selector(openCompose), keyEquivalent: "")
        writeItem.target = self
        menu.addItem(writeItem)
        inboxItem.target = self
        menu.addItem(inboxItem)
        let friendsItem = NSMenuItem(title: "친구…", action: #selector(openFriends), keyEquivalent: "")
        friendsItem.target = self
        menu.addItem(friendsItem)
        menu.addItem(.separator())
        let previewItem = NSMenuItem(title: "동작 보기", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for (title, key) in [("물 마시기", "drink"), ("둥지 짓고 자기", "nest"), ("꾸벅꾸벅 졸기", "nod"),
                             ("졸다가 구르기", "roll"), ("날아서 옮겨 가기", "fly"), ("앞 보고 기우뚱", "tilt"),
                             ("눈 쉬기", "eyes"), ("기지개 켜기", "stretch"), ("일정 알림 (예시)", "calendar"),
                             ("편지 물고 나가기", "mailOut"), ("편지 받아 오기 (예시)", "mailIn"), ("편지 잃어버림 (예시)", "lost")] {
            let it = NSMenuItem(title: title, action: #selector(previewPet(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            previewMenu.addItem(it)
        }
        previewItem.submenu = previewMenu
        menu.addItem(previewItem)
        menu.addItem(.separator())
        for (title, sel) in [("손쉬운 사용 설정 열기…", #selector(openAXSettings)), ("진단 기록 파일 열기", #selector(openLog))] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Omogi 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // 메뉴를 열 때마다 맨 윗줄에 지금 상태를 적는다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let unread = letters.unreadCount
        inboxItem.title = unread > 0 ? "편지함… (새 편지 \(unread)통)" : "편지함…"
        if FocusGuard.enabled && !AXIsProcessTrusted() {
            statusLine.title = "집중 모드: 권한 필요 — 손쉬운 사용에서 'Omogi'를 허용하세요"
        } else if !Pet.enabled {
            statusLine.title = "오모기가 숨어 있어요"
        } else {
            statusLine.title = "오모기가 화면 아래에 있어요 — 집어서 옮길 수 있어요"
        }
    }

    // 편지 창에서 복사·붙여넣기·창 닫기 단축키가 되도록 (메뉴 막대 전용 앱이라 눈에 보이지는 않는다).
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Omogi 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    @objc func openCompose() { letterWindows.showCompose() }
    @objc func openInbox() { letterWindows.showInbox() }
    @objc func openFriends() { letterWindows.showFriends() }

    @objc func previewPet(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { pet.preview(key) }
    }

    @objc func togglePet() {
        pet.setEnabled(!Pet.enabled)
        petItem.state = Pet.enabled ? .on : .off
    }

    @objc func toggleHabits() {
        Pet.habitsOn = !Pet.habitsOn
        habitsItem.state = Pet.habitsOn ? .on : .off
    }

    // 집중 모드는 브라우저 창 제목을 읽어야 해서, 켤 때 손쉬운 사용 권한이 없으면 요청 창을 띄운다.
    @objc func toggleFocus() {
        FocusGuard.enabled = !FocusGuard.enabled
        focusItem.state = FocusGuard.enabled ? .on : .off
        pet.setOverFullScreen(FocusGuard.enabled)
        Log.write("집중 모드 \(FocusGuard.enabled ? "켬" : "끔")")
        if FocusGuard.enabled && !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
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
                alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서 Omogi를 허용한 뒤 다시 켜 주세요."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openLog() {
        Log.write("기록 파일을 엶")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSWorkspace.shared.open(Log.url) }
    }
}

let controller = AppController()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()

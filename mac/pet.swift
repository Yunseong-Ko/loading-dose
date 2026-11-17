// 화면 아래 가장자리에 사는 작은 펫 (흰오목눈이, 픽셀 스프라이트).
// 평소에는 앉아 있거나 콩콩 뛰어 조금 옮겨 가거나 존다. 질문을 보내 카드가 뜨면 카드 옆으로 날아가 앉고,
// 정답·오답에 반응한 뒤 카드가 사라지면 제자리로 돌아간다.
// 방해하지 않는 것이 원칙이다: 작고, 가장자리에서만 움직이고, 마우스 클릭은 그대로 통과한다.
// 그림은 tools/make_pet_sprites.py 가 만든 pet/sprites.png (36x28 픽셀 프레임을 가로로 이어 붙인 것).
import Cocoa

// 생활 습관 동작의 기준. config.json 의 "waterMinutes", "nestMinutes" 로 바꿀 수 있다.
var waterMinutes = 45.0     // 컴퓨터를 쓰는 동안 이 간격으로 펫이 물을 마신다 (같이 마시라는 신호)
var eyeMinutes = 20.0       // 이 간격으로 펫이 눈을 감고 20초 쉰다
var stretchMinutes = 50.0   // 이 간격으로 펫이 기지개를 켠다
var nestMinutes = 5.0       // 이만큼 아무 입력이 없으면 둥지를 짓고 잔다

// 마지막 마우스·키보드 입력 뒤로 지난 시간(초)
func idleSeconds() -> Double {
    let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
    return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
}

// 펫 창의 내용 뷰: 집어서 옮길 수 있게 마우스 누름·끌기·놓기를 펫에게 넘긴다.
final class PetView: NSView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseUp(with event: NSEvent) { onUp?() }
}

final class Pet: NSObject {
    private static let defaultsKey = "petOn"
    /// 물·눈 쉬기·스트레칭 알림을 할지 (기본 켬)
    static var habitsOn: Bool {
        get { return UserDefaults.standard.object(forKey: "habitsOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "habitsOn") }
    }
    static var enabled: Bool {
        get { return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    // 순서는 tools/make_pet_sprites.py 의 FRAMES 와 같아야 한다.
    private enum Frame: Int, CaseIterable {
        case sit0, sit1, blink, hop0, hop1, hop2, fly0, fly1, fly2, happy0, happy1, sad, sleep0, sleep1
        case front, frontBlink, tilt
        case nod1, nod2, roll1, roll2, roll3
        case build1, build2, nest0, nest1, drink0, drink1, drink2
        case stretch, cal0, cal1
    }
    private enum Mode { case sit, hop, sleep, flyOut, perch, flyHome, roam, roll, chase, peck, held, fall, nest, drink, eyes, stretch, calendar }

    private let framePx = CGSize(width: 36, height: 28)
    private let zoom: CGFloat = 3                 // 스프라이트 1픽셀 = 화면 3포인트 (몸 지름 약 48pt)
    private let feetPx: CGFloat = 18              // 스프라이트 안에서 발 가운데의 x (한가운데라 뒤집어도 제자리)
    private let floorInset: CGFloat = 3           // 창 아래 끝에서 발바닥까지
    private let hopStep: CGFloat = 16             // 한 번 뛸 때 가는 거리
    private let hopPeriod = 0.54                  // 웅크림 → 공중 → 착지 → 잠깐 멈춤

    private let panel: NSPanel
    private let sprite = CALayer()
    private var frames: [CGImage] = []
    private var panelSize: CGSize { return CGSize(width: framePx.width * zoom, height: framePx.height * zoom) }

    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var mode = Mode.sit
    private var pos = CGPoint.zero                // 발바닥 가운데의 화면 좌표
    private var faceRight = true
    private var modeStart = CACurrentMediaTime()
    private var from = CGPoint.zero, to = CGPoint.zero
    private var duration: Double = 1
    private var hops = 0
    private var arc: CGFloat = 36                 // 날 때 솟는 높이
    private var lookUntil = 0.0, tiltAt = 0.0     // 정면을 보는 동안, 그중 고개를 기우뚱하는 때
    private var rollAt = Double.infinity          // 졸다가 구르는 때 (잠든 뒤 몇 초째). 안 구르면 무한대
    private let nodPeriod = 3.4                   // 꾸벅 한 번: 버팀 → 고개가 떨어짐 → 푹 숙임 → 화들짝
    private let rollTime = 0.9, rollDistance: CGFloat = 130
    private var nextAction = 0.0
    private var nextBlink = 0.0, blinkUntil = 0.0
    private var reactStart = 0.0, reactUntil = 0.0, reactHappy = false
    private var homeX: CGFloat = 0
    private var sitsInARow = 0
    private var shown = false
    private var chaseAct: (() -> Void)?           // 쪼는 순간에 할 일 (집중 모드: 탭 닫기)
    private var chaseDone: (() -> Void)?          // 출동이 끝났거나 취소됐을 때
    var isShown: Bool { return shown }
    private var grab = CGPoint.zero               // 집었을 때 마우스와 발 사이의 거리
    private var fallSpeed: CGFloat = 0
    private var lastTick = CACurrentMediaTime()
    private var mouseMonitors: [Any] = []
    private var nextDrink = CACurrentMediaTime() + waterMinutes * 60   // 다음에 물 마실 때
    private var nestHold = 0.0                    // 미리 보기로 둥지에 들어갔을 때 이때까지는 깨지 않는다
    private var nextEye = CACurrentMediaTime() + eyeMinutes * 60
    private var nextStretch = CACurrentMediaTime() + stretchMinutes * 60
    private var lastNudge = 0.0                   // 마지막으로 습관 알림을 한 때 (연달아 하지 않는다)
    // 한 줄짜리 말풍선 (무슨 알림인지 알려 준다)
    private let bubble = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let bubbleLabel = NSTextField(labelWithString: "")
    private var bubbleUntil = 0.0

    /// 카드 옆에 앉을 자리(발바닥 좌표). 카드가 없으면 nil.
    var perchTarget: (() -> CGPoint?)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 108, height: 84),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true           // 클릭은 펫을 통과한다
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = PetView(frame: NSRect(origin: .zero, size: panelSize))
        view.wantsLayer = true
        view.onDown = { [weak self] in self?.pickUp() }
        view.onUp = { [weak self] in self?.drop() }
        panel.contentView = view

        sprite.frame = CGRect(origin: .zero, size: panelSize)
        sprite.contentsGravity = .resize
        sprite.magnificationFilter = .nearest     // 픽셀이 뭉개지지 않게
        sprite.minificationFilter = .nearest
        view.layer?.addSublayer(sprite)
        loadFrames()
        show(.sit0)

        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.ignoresMouseEvents = true
        bubble.level = .floating
        bubble.hidesOnDeactivate = false
        bubble.isReleasedWhenClosed = false
        bubble.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0, alpha: 0.14).cgColor
        bubbleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        bubbleLabel.textColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1)
        bubbleLabel.lineBreakMode = .byTruncatingTail
        box.addSubview(bubbleLabel)
        bubble.contentView = box
    }

    // ── 말풍선 ──
    private func say(_ text: String, seconds: Double) {
        bubbleLabel.stringValue = text
        bubbleLabel.sizeToFit()
        let w = min(260, bubbleLabel.frame.width + 22)
        bubble.setContentSize(NSSize(width: w, height: 26))
        bubbleLabel.frame = NSRect(x: 11, y: 5, width: w - 22, height: 16)
        bubbleUntil = CACurrentMediaTime() + seconds
        placeBubble()
        bubble.orderFrontRegardless()
    }

    private func placeBubble() {
        let size = bubble.frame.size
        let vf = currentScreen().visibleFrame
        let x = min(vf.maxX - size.width - 6, max(vf.minX + 6, pos.x - size.width / 2))
        bubble.setFrameOrigin(CGPoint(x: x.rounded(), y: (pos.y + 62).rounded()))
    }

    private func updateBubble(_ now: Double) {
        guard bubble.isVisible else { return }
        let talking = mode == .drink || mode == .eyes || mode == .stretch || mode == .calendar
        if now > bubbleUntil || !talking { bubble.orderOut(nil) } else { placeBubble() }
    }

    /// 일정이 가까울 때: 달력을 들고 한 줄로 알려 준다. 지금 나설 수 없으면 false.
    func announce(_ text: String) -> Bool {
        guard shown, mode == .sit || mode == .hop || mode == .sleep || mode == .nest || mode == .drink
                || mode == .eyes || mode == .stretch else { return false }
        lookUntil = 0
        setMode(.calendar)
        say(text, seconds: 10)
        return true
    }

    // 습관 알림 가운데 지금 할 것을 시작한다. 하나도 때가 아니면 false.
    private func startNudge(_ now: Double) -> Bool {
        if now >= nextStretch {
            nextStretch = now + stretchMinutes * 60
            setMode(.stretch)
            say("기지개 한번 켜요", seconds: 7)
        } else if now >= nextDrink {
            nextDrink = now + waterMinutes * 60
            setMode(.drink)
            say("물 한 잔 마실 시간이에요", seconds: 6)
        } else if now >= nextEye {
            nextEye = now + eyeMinutes * 60
            setMode(.eyes)
            say("눈을 20초만 쉬어요", seconds: 20)
        } else { return false }
        lookUntil = 0
        lastNudge = now
        return true
    }

    private func loadFrames() {
        guard let url = Bundle.main.url(forResource: "sprites", withExtension: "png", subdirectory: "pet"),
              let sheet = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        for i in 0..<Frame.allCases.count {
            let r = CGRect(x: CGFloat(i) * framePx.width, y: 0, width: framePx.width, height: framePx.height)
            if let f = sheet.cropping(to: r) { frames.append(f) }
        }
    }

    private func show(_ f: Frame) {
        guard f.rawValue < frames.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = frames[f.rawValue]
        sprite.transform = CATransform3DMakeScale(faceRight ? 1 : -1, 1, 1)
        CATransaction.commit()
    }

    // ── 켜고 끄기 ──
    func start() {
        guard Pet.enabled, !shown, !frames.isEmpty else { return }
        guard let screen = NSScreen.main else { return }
        pos = CGPoint(x: screen.visibleFrame.maxX - 170, y: floorY(on: screen))
        homeX = pos.x
        faceRight = false
        shown = true
        movePanel(lift: 0)
        panel.orderFrontRegardless()
        setMode(.sit)
        // 마우스가 펫 몸 위에 있을 때만 클릭을 받는다. 그 밖에서는 클릭이 그대로 통과한다.
        if mouseMonitors.isEmpty {
            let update: (NSEvent) -> Void = { [weak self] _ in self?.updateHit() }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: update) { mouseMonitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in update(e); return e }) { mouseMonitors.append(m) }
        }
    }

    private func updateHit() {
        guard shown, mode != .held else { return }
        let m = NSEvent.mouseLocation
        let over = hypot(m.x - pos.x, m.y - (pos.y + 30)) < 27     // 몸은 발 위 30pt 를 중심으로 한 원
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    // ── 메뉴에서 동작 미리 보기 ──
    func preview(_ what: String) {
        guard shown, mode == .sit || mode == .hop || mode == .sleep || mode == .nest || mode == .drink
                || mode == .eyes || mode == .stretch || mode == .calendar else { return }
        let now = CACurrentMediaTime()
        lookUntil = 0
        switch what {
        case "drink": setMode(.drink); say("물 한 잔 마실 시간이에요", seconds: 6)
        case "eyes": setMode(.eyes); say("눈을 20초만 쉬어요", seconds: 20)
        case "stretch": setMode(.stretch); say("기지개 한번 켜요", seconds: 7)
        case "calendar": _ = announce("10분 뒤 · 병리 실습 (예시)")
        case "nest": nestHold = now + 12; setMode(.nest)
        case "nod": setMode(.sleep); rollAt = .infinity; nextAction = now + 11
        case "roll": setMode(.sleep); rollAt = 0
        case "fly":
            let vf = currentScreen().visibleFrame
            let x = pos.x < vf.midX ? min(vf.maxX - 60, pos.x + 480) : max(vf.minX + 60, pos.x - 480)
            fly(to: CGPoint(x: x, y: floorY(on: currentScreen())), as: .roam)
        case "tilt":
            setMode(.sit)
            lookUntil = now + 3
            tiltAt = now + 0.6
            nextAction = now + 6
        default: break
        }
    }

    // ── 집어서 옮기기 ──
    private func pickUp() {
        guard shown else { return }
        if mode == .chase || mode == .peck { endChase() }
        let m = NSEvent.mouseLocation
        grab = CGPoint(x: m.x - pos.x, y: m.y - pos.y)
        lookUntil = 0
        reactUntil = 0
        setMode(.held)
    }

    private func drop() {
        guard shown, mode == .held else { return }
        fallSpeed = 0
        setMode(.fall)
    }

    func stop() {
        endChase()
        bubble.orderOut(nil)
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors = []
        panel.ignoresMouseEvents = true
        shown = false
        timer?.invalidate()
        timer = nil
        interval = 0
        panel.orderOut(nil)
    }

    func setEnabled(_ on: Bool) {
        Pet.enabled = on
        if on { start() } else { stop() }
    }

    // 전체 화면 앱 위에도 나타날지 (집중 모드에서는 전체 화면 영상도 닫으러 가야 한다).
    func setOverFullScreen(_ on: Bool) {
        panel.collectionBehavior = on ? [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                                      : [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    // ── 집중 모드: 정해 준 자리로 날아가 콕콕 쪼고(이때 act 실행) 돌아온다 ──
    func chase(to target: CGPoint, act: @escaping () -> Void, done: @escaping () -> Void) {
        // 카드 옆에 앉아 있다가도 간다 (답을 기다리며 딴짓하는 때가 바로 막을 때다). 이미 출동 중이거나 구르는 중일 때만 미룬다.
        guard shown, mode != .chase, mode != .peck, mode != .roll, mode != .held, mode != .fall else { done(); return }
        if mode == .sit || mode == .hop || mode == .sleep { homeX = pos.x }
        lookUntil = 0
        chaseAct = act
        chaseDone = done
        fly(to: target, as: .chase)
    }

    private func endChase() {
        chaseAct = nil
        let done = chaseDone
        chaseDone = nil
        done?()
    }

    // ── 카드와 이어지는 동작 ──
    func goToCard() {
        // 탭을 닫으러 간 중이면 그 일을 마친 뒤 카드로 온다 (peck 이 끝날 때 카드가 떠 있으면 카드로 날아간다).
        guard shown, mode != .flyOut, mode != .perch, mode != .chase, mode != .peck, mode != .held, mode != .fall,
              let target = perchTarget?() else { return }
        if mode != .flyHome { homeX = pos.x }
        lookUntil = 0
        fly(to: target, as: .flyOut)
    }

    func react(correct: Bool) {
        guard shown, mode == .perch || mode == .flyOut else { return }
        reactHappy = correct
        reactStart = CACurrentMediaTime()
        reactUntil = reactStart + (correct ? 0.8 : 1.1)
        retime()
    }

    func goHome() {
        guard shown, mode == .perch || mode == .flyOut else { return }
        fly(to: CGPoint(x: homeX, y: floorY(on: currentScreen())), as: .flyHome)
    }

    private func fly(to target: CGPoint, as m: Mode) {
        from = pos
        to = target
        let dist = hypot(to.x - from.x, to.y - from.y)
        if m == .roam {                            // 혼자 날 때는 느긋하고 높게
            duration = Double(min(2.4, max(1.0, dist / 330)))
            arc = min(170, max(70, dist * 0.35))
        } else {
            duration = Double(min(1.4, max(0.7, dist / 700)))
            arc = 36
        }
        faceRight = to.x >= from.x
        setMode(m)
    }

    // ── 상태 ──
    private func setMode(_ m: Mode) {
        let now = CACurrentMediaTime()
        mode = m
        modeStart = now
        switch m {
        case .sit: nextAction = now + Double.random(in: 5...14)
        case .sleep:
            nextAction = now + Double.random(in: 20...45)
            // 절반쯤은 두세 번 꾸벅인 뒤, 푹 숙였을 때 데굴 구른다.
            rollAt = Bool.random() ? nodPeriod * Double(Int.random(in: 2...3)) + 2.0 : .infinity
        case .perch, .peck: faceRight = true       // 카드(또는 닫기 버튼) 쪽을 본다
        default: break
        }
        if nextBlink < now { nextBlink = now + Double.random(in: 1.5...4) }
        retime()
    }

    // 움직일 때만 자주, 가만히 있을 때는 드물게 그린다.
    private func retime() {
        let moving = mode == .hop || mode == .flyOut || mode == .flyHome || mode == .roam || mode == .roll
            || mode == .chase || mode == .peck || mode == .held || mode == .fall || CACurrentMediaTime() < reactUntil
        let want: TimeInterval = moving ? 1.0 / 30 : 1.0 / 12
        guard want != interval || timer == nil else { return }
        interval = want
        timer?.invalidate()
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func currentScreen() -> NSScreen {
        let probe = CGPoint(x: pos.x, y: pos.y + 6)
        return NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // 다니는 바닥: Dock 위쪽 끝 (Dock 이 숨어 있으면 화면 아래 끝).
    private func floorY(on screen: NSScreen) -> CGFloat {
        return max(screen.visibleFrame.minY, screen.frame.minY + floorInset)
    }

    private func chooseNext(_ now: Double) {
        sitsInARow += 1
        if reduceMotion() { nextAction = now + 20; return }
        if sitsInARow >= 4 && Bool.random() {
            sitsInARow = 0
            setMode(.sleep)
            return
        }
        let screen = currentScreen()
        let vf = screen.visibleFrame
        let lo = vf.minX + 60, hi = vf.maxX - 60
        let roll = Int.random(in: 0..<100)
        if roll < 35 {                             // 정면을 보고 고개를 한 번 기우뚱
            lookUntil = now + Double.random(in: 2.6...4.2)
            tiltAt = now + Double.random(in: 0.7...1.4)
            faceRight = Bool.random()              // 기우는 방향
            nextAction = lookUntil + Double.random(in: 2...6)
            return
        }
        if roll < 55 {                             // 멀리 날아서 자리를 옮긴다
            var x = CGFloat.random(in: lo...hi)
            if abs(x - pos.x) < 220 { x = pos.x < (lo + hi) / 2 ? min(hi, pos.x + 420) : max(lo, pos.x - 420) }
            sitsInARow = 0
            fly(to: CGPoint(x: x, y: floorY(on: screen)), as: .roam)
            return
        }
        var dx = CGFloat(Int.random(in: 3...12)) * hopStep * (Bool.random() ? 1 : -1)
        if pos.x + dx < lo || pos.x + dx > hi { dx = -dx }    // 화면 끝이면 반대쪽으로
        let x = min(hi, max(lo, pos.x + dx))
        hops = Int((abs(x - pos.x) / hopStep).rounded(.down))
        if hops < 1 { nextAction = now + 6; return }
        faceRight = x >= pos.x
        from = CGPoint(x: pos.x, y: floorY(on: screen))
        setMode(.hop)
    }

    private func tick() {
        guard shown else { return }
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.1, now - lastTick))
        lastTick = now
        let t = now - modeStart
        var frame = Frame.sit0
        var lift: CGFloat = 0
        switch mode {
        case .nest:
            // 가지를 물어다 놓고(2.4초) 둥지에 들어가 잔다. 다시 컴퓨터를 쓰기 시작하면 깬다.
            if t < 1.2 { frame = Int(t / 0.2) % 2 == 0 ? .build1 : .sit0 }
            else if t < 2.4 { frame = Int(t / 0.2) % 2 == 0 ? .build2 : .build1 }
            else { frame = Int(t / 1.8) % 2 == 0 ? .nest0 : .nest1 }
            if now > nestHold, idleSeconds() < 3 {
                if t > 240 {                             // 한참 쉬고 왔으면 습관 알림을 처음부터 다시 센다
                    nextDrink = now + waterMinutes * 60
                    nextEye = now + eyeMinutes * 60
                    nextStretch = now + stretchMinutes * 60
                }
                setMode(.sit)
                lookUntil = now + 2.2
                tiltAt = now + 0.5
                nextAction = lookUntil + Double.random(in: 3...7)
                frame = .front
            }
        case .eyes:
            // 눈 쉬기: 정면을 보고 20초 동안 눈을 감고 있는다.
            frame = t < 19.2 ? .frontBlink : .front
            if t >= 20 { setMode(.sit); frame = .sit0 }
        case .stretch:
            // 기지개: 날개를 쭉 펴고, 좌우로 한 번씩 몸을 기울인다.
            switch t {
            case ..<1.3: frame = .stretch
            case ..<2.3: frame = .tilt; faceRight = true
            case ..<3.3: frame = .stretch
            case ..<4.3: frame = .tilt; faceRight = false
            case ..<5.6: frame = .stretch
            case ..<6.4: frame = .front
            default: setMode(.sit); frame = .sit0
            }
        case .calendar:
            // 일정 알림: 달력을 들고 서서 처음 3초는 들썩인다.
            faceRight = true
            frame = t < 3 && Int(t / 0.4) % 2 == 1 ? .cal1 : .cal0
            if t >= 10 { setMode(.sit); frame = .sit0 }
        case .drink:
            // 컵을 보고(0.8초) 세 모금 마신 뒤 개운해한다.
            if t < 0.8 { frame = .drink0 }
            else if t < 4.4 { frame = Int((t - 0.8) / 0.6) % 2 == 0 ? .drink1 : .drink0 }
            else if t < 5.8 { frame = .drink2 }
            else { setMode(.sit); frame = .sit0 }
        case .sit:
            if now < lookUntil { frame = (now >= tiltAt && now < tiltAt + 0.8) ? .tilt : .front }
            else { frame = Int(now / 0.9) % 2 == 0 ? .sit0 : .sit1 }
            // 생활 습관: 오래 손을 놓으면 둥지를 짓고, 계속 쓰고 있으면 가끔 물을 마신다.
            let idle = idleSeconds()
            if idle > nestMinutes * 60 { lookUntil = 0; setMode(.nest) }
            else if Pet.habitsOn, idle < 120, now - lastNudge > 90, startNudge(now) { }
            else if now >= nextAction { chooseNext(now) }
        case .sleep:
            // 꾸벅꾸벅: 눈 감고 버티다가 고개가 천천히 떨어지고, 푹 숙였다가 화들짝 든다.
            let u = t.truncatingRemainder(dividingBy: nodPeriod)
            if u < 1.1 { frame = Int(u / 0.55) % 2 == 0 ? .blink : .sleep1 }
            else if u < 1.7 { frame = .nod1 }
            else if u < 2.6 { frame = .nod2 }
            else if u < 2.75 { frame = .nod1 }
            else { frame = .blink }
            if t >= rollAt, frame == .nod2 {         // 너무 숙여서 그대로 앞으로 구른다
                rollAt = .infinity
                let vf = currentScreen().visibleFrame
                if faceRight, pos.x + rollDistance > vf.maxX - 60 { faceRight = false }
                else if !faceRight, pos.x - rollDistance < vf.minX + 60 { faceRight = true }
                from = pos
                setMode(.roll)
            } else if now >= nextAction { setMode(.sit) }
        case .roll:
            let k = CGFloat(min(1, t / rollTime))
            pos = CGPoint(x: from.x + (faceRight ? 1 : -1) * rollDistance * k, y: from.y)
            frame = [Frame.nod2, .roll1, .roll2, .roll3][min(3, Int(k * 4))]
            if k >= 1 {                              // 굴러서 깼다: 어리둥절하게 앞을 보고 갸웃
                sitsInARow = 0
                setMode(.sit)
                lookUntil = now + 2.4
                tiltAt = now + 0.6
                nextAction = lookUntil + Double.random(in: 3...7)
                frame = .front
            }
        case .hop:
            // 한 번의 뜀: 웅크림(0.08초) → 공중(0.24초, 이때만 앞으로 간다) → 착지(0.10초) → 멈춤
            let n = Int(t / hopPeriod)
            if n >= hops {
                pos = CGPoint(x: from.x + (faceRight ? 1 : -1) * hopStep * CGFloat(hops), y: from.y)
                sitsInARow = 0
                setMode(.sit)
                frame = .sit0
            } else {
                let u = t - Double(n) * hopPeriod
                var air: CGFloat = 0
                if u < 0.08 { frame = .hop0 }
                else if u < 0.32 { frame = .hop1; air = CGFloat((u - 0.08) / 0.24) }
                else if u < 0.42 { frame = .hop2; air = 1 }
                else { frame = .sit0; air = 1 }
                pos = CGPoint(x: from.x + (faceRight ? 1 : -1) * hopStep * (CGFloat(n) + air), y: from.y)
                if frame == .hop1 { lift = sin(air * .pi) * 9 }
            }
        case .flyOut, .flyHome, .roam, .chase:
            if mode == .flyOut, let target = perchTarget?() { to = target }   // 카드 크기가 바뀌면 따라간다
            let raw = CGFloat(min(1, t / duration))
            let k = raw * raw * (3 - 2 * raw)
            pos = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k + sin(k * .pi) * arc)
            frame = [Frame.fly0, .fly1, .fly2, .fly1][Int(t * 14) % 4]
            if raw >= 1 {
                pos = to
                setMode(mode == .flyOut ? .perch : mode == .chase ? .peck : .sit)
                if mode == .sit { faceRight = false }
                frame = .sit0
            }
        case .held:
            // 집힌 동안: 마우스를 따라가며 대롱대롱
            let m = NSEvent.mouseLocation
            pos = CGPoint(x: m.x - grab.x, y: m.y - grab.y)
            frame = Int(now / 0.28) % 2 == 0 ? .front : .tilt
        case .fall:
            // 놓으면 그 자리 아래 바닥으로 떨어져 앉는다. 카드가 떠 있으면 다시 카드로 간다.
            let floor = floorY(on: currentScreen())
            fallSpeed += 1800 * dt
            pos.y -= fallSpeed * dt
            frame = .hop1
            if pos.y <= floor {
                pos.y = floor
                homeX = pos.x
                sitsInARow = 0
                setMode(.sit)
                frame = .hop2
                if perchTarget?() != nil { goToCard() }
                else { lookUntil = now + 1.6; tiltAt = now + 0.5 }
            }
        case .peck:
            // 콕콕 쪼다가(0.7초) 할 일을 하고, 잠깐 뿌듯해한 뒤 돌아간다.
            if t < 0.7 { frame = Int(t / 0.12) % 2 == 0 ? .sit0 : .nod1 }
            else {
                if let act = chaseAct { chaseAct = nil; act() }
                frame = Int(t * 9) % 2 == 0 ? .happy0 : .happy1
                if t >= 1.5 {
                    endChase()
                    if let card = perchTarget?() { fly(to: card, as: .flyOut) }     // 카드가 떠 있으면 카드 옆으로
                    else { fly(to: CGPoint(x: homeX, y: floorY(on: NSScreen.main ?? currentScreen())), as: .flyHome) }
                }
            }
        case .perch:
            if let target = perchTarget?() { pos = target } else { goHome() }
            frame = Int(now / 0.9) % 2 == 0 ? .sit0 : .sit1
        }

        // 정답·오답 반응 (카드 옆에 앉아 있을 때)
        if now < reactUntil {
            if mode == .perch {
                if reactHappy { frame = Int((now - reactStart) * 9) % 2 == 0 ? .happy0 : .happy1 }
                else { frame = now - reactStart < 0.55 ? .tilt : .sad }   // 갸웃한 뒤 시무룩
            }
        } else if reactUntil != 0 {
            reactUntil = 0
            retime()
        }

        // 눈 깜빡임 (앉아 있을 때만)
        if now >= nextBlink {
            blinkUntil = now + 0.18
            nextBlink = now + Double.random(in: 2.5...6)
        }
        if now < blinkUntil {
            if frame == .sit0 || frame == .sit1 { frame = .blink }
            else if frame == .front { frame = .frontBlink }
        }

        movePanel(lift: lift)
        show(frame)
        updateBubble(now)
    }

    private func movePanel(lift: CGFloat) {
        // 스프라이트의 발은 가운데가 아니라서, 보는 방향에 따라 창을 다르게 놓는다.
        let feetX = (faceRight ? feetPx : framePx.width - feetPx) * zoom
        let origin = CGPoint(x: (pos.x - feetX).rounded(), y: (pos.y - floorInset + lift).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    // ── 동작 확인용: 앱이 읽은 프레임을 전부(오른쪽 보기 + 왼쪽 보기) 한 장의 PNG 로 저장한다 ──
    func snapshotPoses(to url: URL) {
        let k: CGFloat = 2
        let n = Frame.allCases.count
        let w = Int(panelSize.width * k) * n, h = Int(panelSize.height * k) * 2
        guard !frames.isEmpty,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let root = panel.contentView?.layer else { print("pet: 프레임을 읽지 못함"); return }
        ctx.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for row in 0..<2 {
            faceRight = row == 0
            for f in Frame.allCases {
                show(f)
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(f.rawValue) * panelSize.width * k, y: CGFloat(1 - row) * panelSize.height * k)
                ctx.scaleBy(x: k, y: k)
                root.render(in: ctx)
                ctx.restoreGState()
            }
        }
        guard let img = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        print("pet: \(frames.count)프레임")
    }
}

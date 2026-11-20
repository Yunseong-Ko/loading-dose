// 화면 아래 가장자리에 사는 작은 펫 (흰오목눈이, 픽셀 스프라이트).
// Omogi 앱에서는 평소에 앉아 있거나 콩콩 뛰어 조금 옮겨 가거나 졸고, 습관·일정 알림과 집중 모드 출동을 맡는다.
// Loading Dose 앱에서는 cardOnly 로 쓴다: 카드가 뜨면 화면 아래에서 날아와 카드 옆에 앉아
// 정답·오답에 반응하고, 카드가 사라지면 날아가 사라진다. (두 앱이 이 파일을 같이 쓴다.)
// 방해하지 않는 것이 원칙이다: 작고, 가장자리에서만 움직이고, 마우스 클릭은 그대로 통과한다.
// 그림은 tools/make_pet_sprites.py 가 만든 pet/sprites.png (36x28 픽셀 프레임을 가로로 이어 붙인 것).
import Cocoa

// 생활 습관 동작의 기준. Omogi 의 config.json 에서 "waterMinutes", "nestMinutes" 등으로 바꿀 수 있다.
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
    override func mouseUp(with event: NSEvent) { onUp?() }
    /// 오른쪽 클릭(또는 Control-클릭)하면 뜨는 메뉴. 메뉴 막대 아이콘이 가려져 안 보일 때도 여기로 들어갈 수 있다.
    var contextMenu: NSMenu?
    override func rightMouseDown(with event: NSEvent) {
        if let m = contextMenu { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let m = contextMenu { NSMenu.popUpContextMenu(m, with: event, for: self); return }
        onDown?()
    }
}

struct YardSprites {
    let sit: CGImage, blink: CGImage, hop: [CGImage], read: [CGImage], sleep: [CGImage]
    let size: CGSize
}

/// 놀러 온 친구의 새: 화면 밖에서 날아와 내 오모기 옆에 앉아 말풍선을 띄우고, 잠깐 좋아하다가 날아간다.
fileprivate final class Visitor {
    private let panel: NSPanel
    private let layer = CALayer()
    private let note: NSPanel
    private let fly: [CGImage], happy: [CGImage], hop: [CGImage]
    private let sit: CGImage
    private let from: CGPoint, land: CGPoint
    /// 놀다 가는 손님: 인사한 뒤 바닥을 이리저리 뛰어다니다가 돌아간다.
    private let play: Bool
    private let range: ClosedRange<CGFloat>
    private var cur: CGPoint
    private var target: CGFloat?
    private var restUntil = 0.0, last = 0.0
    private var facing = true
    private let born = CACurrentMediaTime()
    private let stay: Double
    private let size = CGSize(width: 108, height: 84)
    private let faceRight: Bool

    init(fly: [CGImage], happy: [CGImage], hop: [CGImage], sit: CGImage, from: CGPoint, land: CGPoint, text: String,
         stay: Double, play: Bool, range: ClosedRange<CGFloat>) {
        self.fly = fly
        self.happy = happy
        self.hop = hop
        self.sit = sit
        self.play = play
        self.range = range
        cur = land
        self.from = from
        self.land = land
        self.stay = stay
        faceRight = land.x >= from.x
        func make(_ r: NSRect) -> NSPanel {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            return p
        }
        panel = make(NSRect(origin: .zero, size: size))
        panel.hasShadow = false
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        panel.contentView = view
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        view.layer?.addSublayer(layer)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        let w = min(280, label.frame.width + 22)
        note = make(NSRect(x: 0, y: 0, width: w, height: 26))
        note.hasShadow = true
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 26))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0, alpha: 0.14).cgColor
        label.frame = NSRect(x: 11, y: 5, width: w - 22, height: 16)
        box.addSubview(label)
        note.contentView = box
        place(fly[0], at: from, right: faceRight)
        panel.orderFrontRegardless()
    }

    private func place(_ image: CGImage, at feet: CGPoint, right: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.transform = CATransform3DMakeScale(right ? 1 : -1, 1, 1)
        CATransaction.commit()
        panel.setFrameOrigin(CGPoint(x: (feet.x - size.width / 2).rounded(), y: (feet.y - 3).rounded()))
    }

    /// 한 틱 움직인다. 다 날아갔으면 false.
    func update(now: Double) -> Bool {
        let t = now - born
        let arrive = 1.3, leave = 1.3
        if t < arrive {
            let k = CGFloat(t / arrive), e = 1 - (1 - k) * (1 - k)
            let p = CGPoint(x: from.x + (land.x - from.x) * e, y: from.y + (land.y - from.y) * e + sin(k * .pi) * 30)
            place(fly[Int(t * 14) % fly.count], at: p, right: faceRight)
        } else if play, t < arrive + stay, t - arrive > 4 {
            if note.isVisible { note.orderOut(nil) }
            let dt = CGFloat(min(0.2, max(0, now - last)))
            if let tx = target {
                let step = dt * 70, dx = tx - cur.x
                facing = dx > 0
                if abs(dx) <= step { cur.x = tx; target = nil; restUntil = now + Double.random(in: 1.2...3.5) } else { cur.x += dx > 0 ? step : -step }
                let ph = (now * 3).truncatingRemainder(dividingBy: 1)
                place(hop[min(hop.count - 1, Int(ph * Double(hop.count)))], at: CGPoint(x: cur.x, y: land.y + CGFloat(sin(ph * .pi)) * 10), right: facing)
            } else {
                place(sit, at: cur, right: facing)
                if now >= restUntil, !reduceMotion() { target = CGFloat.random(in: range) }
            }
        } else if t < arrive + stay {
            let u = t - arrive
            let hop = abs(sin(u * 6)) * 8
            place(happy[Int(u * 5) % happy.count], at: CGPoint(x: land.x, y: land.y + hop), right: !faceRight)   // 내 오모기 쪽을 본다
            if !note.isVisible {
                let vf = (NSScreen.screens.first { $0.frame.contains(land) } ?? NSScreen.main)?.visibleFrame ?? .zero
                let w = note.frame.width
                note.setFrameOrigin(CGPoint(x: min(vf.maxX - w - 6, max(vf.minX + 6, land.x - w / 2)).rounded(), y: (land.y + 66).rounded()))
                note.orderFrontRegardless()
            }
        } else if t < arrive + stay + leave {
            if note.isVisible { note.orderOut(nil) }
            let k = CGFloat((t - arrive - stay) / leave), e = k * k
            let p = CGPoint(x: cur.x + (from.x - cur.x) * e, y: land.y + (from.y - land.y) * e + sin(k * .pi) * 30)
            place(fly[Int(t * 14) % fly.count], at: p, right: !faceRight)
        } else {
            remove()
            return false
        }
        last = now
        return true
    }

    func remove() { panel.orderOut(nil); note.orderOut(nil) }
}

/// 꼬마 뱁새를 누를 수 있게 하는 뷰
fileprivate final class CatchView: NSView {
    var onDown: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override func mouseDown(with event: NSEvent) { onDown?() }
}

/// 펑 터졌을 때 잠깐 나타나는 작은 새 한 마리. 튀어 나가 잠시 파닥이다가 화면 밖으로 날아간다.
/// onCatch 가 있으면 누를 수 있고, 눌리면 그 자리에서 사라진다(잡힘).
fileprivate final class MiniBird {
    private var caught = false
    private let panel: NSPanel
    private let layer = CALayer()
    private let hop: CGImage
    private let fly: [CGImage]
    private var pos: CGPoint                       // 창의 가운데
    private var vel: CGPoint
    private let born = CACurrentMediaTime()
    private let leaveAfter: Double
    private let exit: CGPoint
    private var from = CGPoint.zero
    private var leaving = false
    private let size = CGSize(width: 72, height: 56)      // 본래 크기의 3분의 2

    init(hop: CGImage, fly: [CGImage], at start: CGPoint, velocity: CGPoint, leaveAfter: Double, exit: CGPoint, onCatch: (() -> Void)? = nil) {
        self.hop = hop
        self.fly = fly
        pos = start
        vel = velocity
        self.leaveAfter = leaveAfter
        self.exit = exit
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = onCatch == nil
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = CatchView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.onDown = { [weak self] in
            guard let s = self, !s.caught else { return }
            s.caught = true
            s.remove()
            onCatch?()
        }
        panel.contentView = view
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        view.layer?.addSublayer(layer)
        place(hop, right: velocity.x >= 0)
        panel.orderFrontRegardless()
    }

    private func place(_ image: CGImage, right: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.transform = CATransform3DMakeScale(right ? 1 : -1, 1, 1)
        CATransaction.commit()
        panel.setFrameOrigin(CGPoint(x: (pos.x - size.width / 2).rounded(), y: (pos.y - size.height / 2).rounded()))
    }

    /// 한 틱 움직인다. 화면 밖으로 다 나갔으면 false.
    func update(dt: CGFloat, now: Double) -> Bool {
        if caught { return false }
        let t = now - born
        if t < leaveAfter {
            // 튀어 나간 뒤 속도가 줄면서 그 자리에서 파닥인다.
            let drag = CGFloat(exp(-3.2 * Double(dt)))
            vel = CGPoint(x: vel.x * drag, y: vel.y * drag)
            pos = CGPoint(x: pos.x + vel.x * dt, y: pos.y + vel.y * dt + CGFloat(sin(t * 9)) * 0.6)
            place(t < 0.3 ? hop : fly[Int(t * 14) % fly.count], right: vel.x >= 0)
            return true
        }
        if !leaving { leaving = true; from = pos }
        let k = CGFloat(min(1, (t - leaveAfter) / 1.3))
        let e = k * k
        pos = CGPoint(x: from.x + (exit.x - from.x) * e, y: from.y + (exit.y - from.y) * e + sin(k * .pi) * 40)
        place(fly[Int(t * 14) % fly.count], right: exit.x >= from.x)
        if k >= 1 { remove(); return false }
        return true
    }

    func remove() { panel.orderOut(nil) }
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
        case mailFly0, mailFly1, mailFly2, mail0, mail1
        case read0, read1
    }
    private enum Mode {
        case sit, hop, sleep, flyOut, perch, flyHome, roam, roll, chase, peck, held, fall, nest, drink, eyes, stretch, calendar
        case tumble                                // 던져져서 바닥을 구르는 중
        case depart, away, arrive, mail, lost      // 편지 심부름: 화면 밖으로 나감 → 밖에 있음 → 돌아옴 → 편지를 물고 기다림 / 잃어버림
    }
    private enum Errand { case send, receive }

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

    // 편지 심부름
    private var errand = Errand.send
    private var carrying = false                  // 지금 부리에 편지가 있는지
    private var errandScreen: NSScreen?
    private var mailText = ""                     // 편지를 물고 기다리는 동안의 말풍선
    private var heldFromMail = false              // 편지를 물고 있다가 집힌 경우
    private var downAt = 0.0, downPos = CGPoint.zero
    /// 편지를 물고 기다리는 펫을 눌렀을 때
    var onMailOpen: (() -> Void)?
    /// 문제를 물고 기다리는 펫을 눌렀을 때
    var onQuizOpen: (() -> Void)?
    private var holdingQuiz = false               // 물고 있는 것이 편지가 아니라 퀴즈인지
    /// 연속 정답에 몸이 커지다가 터지는 동작을 할지 (카드가 있는 앱에서 켠다)
    var comboGrowth = false
    var isHoldingMail: Bool { return mode == .mail || heldFromMail || (errand == .receive && (mode == .depart || mode == .away || mode == .arrive)) }

    // 던지기: 집은 채로 빠르게 움직이다 놓으면 그 속도로 날아가 바닥을 구른다.
    private var heldVel = CGPoint.zero            // 집힌 동안의 속도 (pt/초, 부드럽게 평균 낸 값)
    private var throwVX: CGFloat = 0              // 던져진 뒤의 가로 속도
    private var rollPhase: CGFloat = 0            // 구른 거리(자세를 고르는 데 쓴다)

    // 연속 정답 (cardOnly): 맞힐수록 몸이 커지다가 다섯 번째에 펑 터져 여러 마리가 되고, 곧 한 마리만 남는다.
    private var streak = 0
    private var growth: CGFloat = 1               // 지금 그려지는 배율
    private var growthTarget: CGFloat = 1
    private var popAt = 0.0                       // 터질 때 (0 이면 예정 없음)
    private var minis: [MiniBird] = []
    private let popStreak = 5
    /// 공부 중: 가만히 앉아 책을 본다 (돌아다니지 않는다).
    var studying = false { didSet { if studying != oldValue { retime() } } }
    private var visitors: [Visitor] = []
    /// 터져 나온 꼬마 뱁새를 눌러 잡았을 때 (있으면 꼬마들을 누를 수 있고, 조금 더 오래 머문다)
    var onMiniCaught: (() -> Void)?

    // 옷: wear.png 의 줄 번호들. 맨몸 그림 위에 겹쳐 frames 를 다시 만든다.
    private var bareFrames: [CGImage] = []
    private var wearRows: [[CGImage]] = []
    private var lastFrame = Frame.sit0
    private(set) var worn: [Int] = []

    /// 펫을 오른쪽 클릭하면 뜨는 메뉴
    var menu: NSMenu? {
        get { return (panel.contentView as? PetView)?.contextMenu }
        set { (panel.contentView as? PetView)?.contextMenu = newValue }
    }

    /// 카드 옆에 앉을 자리(발바닥 좌표). 카드가 없으면 nil.
    var perchTarget: (() -> CGPoint?)?
    /// 카드가 떠 있을 때만 나타난다 (Loading Dose). 돌아다니기·습관 알림·집어 옮기기는 하지 않는다.
    var cardOnly = false
    private var offstageY: CGFloat = 0            // cardOnly: 화면 밖에서 드나드는 높이 (카드에 가까운 쪽 가장자리 바깥)

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
        let talking = mode == .drink || mode == .eyes || mode == .stretch || mode == .calendar || mode == .mail || mode == .lost
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

    // ── 편지 심부름 ──
    private var canRunErrand: Bool {
        return shown && (mode == .sit || mode == .hop || mode == .sleep || mode == .nest || mode == .drink
                         || mode == .eyes || mode == .stretch)
    }

    private func startErrand(_ e: Errand) {
        let screen = currentScreen()
        let vf = screen.visibleFrame
        errand = e
        errandScreen = screen
        carrying = e == .send
        homeX = pos.x
        lookUntil = 0
        bubble.orderOut(nil)
        // 화면 위쪽 바깥으로 비스듬히 날아 나간다.
        let x = pos.x < vf.midX ? min(vf.maxX - 60, pos.x + 280) : max(vf.minX + 60, pos.x - 280)
        fly(to: CGPoint(x: x, y: screen.frame.maxY + 10), as: .depart)
    }

    /// 편지를 보낼 때: 편지를 물고 화면 밖으로 날아갔다가 빈 부리로 돌아온다. 지금 나설 수 없으면 false.
    func carryOut() -> Bool {
        guard canRunErrand else { return false }
        startErrand(.send)
        return true
    }

    /// 편지가 왔을 때: 화면 밖으로 나갔다가 편지를 물고 돌아와, 누를 때까지 기다린다. 지금 나설 수 없으면 false.
    func bringMail(_ text: String) -> Bool {
        guard canRunErrand else { return false }
        holdingQuiz = false
        mailText = text
        startErrand(.receive)
        return true
    }

    /// 문제를 물어 온다: 편지처럼 나갔다가 물고 돌아와 기다린다. 누르면 onQuizOpen. 한참 안 누르면 그만둔다.
    func bringQuiz(_ text: String) -> Bool {
        guard canRunErrand else { return false }
        holdingQuiz = true
        mailText = text
        startErrand(.receive)
        return true
    }

    /// 보낸 편지가 누락됐을 때: 시무룩하게 한 줄로 알린다. 지금 나설 수 없으면 false.
    func reportLost(_ text: String) -> Bool {
        guard canRunErrand else { return false }
        lookUntil = 0
        setMode(.lost)
        say(text, seconds: 7)
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
        bareFrames = frames
        // 옷 그림은 있을 때만 (Loading Dose 에는 없다).
        guard frames.count == Frame.allCases.count,
              let wurl = Bundle.main.url(forResource: "wear", withExtension: "png", subdirectory: "pet"),
              let wsheet = NSImage(contentsOf: wurl)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        for row in 0..<(wsheet.height / Int(framePx.height)) {
            var line: [CGImage] = []
            for i in 0..<Frame.allCases.count {
                let r = CGRect(x: CGFloat(i) * framePx.width, y: CGFloat(row) * framePx.height, width: framePx.width, height: framePx.height)
                if let f = wsheet.cropping(to: r) { line.append(f) }
            }
            if line.count == Frame.allCases.count { wearRows.append(line) }
        }
    }

    /// 입힐 수 있는 물건의 수 (wear.png 의 줄 수)
    var wearCount: Int { return wearRows.count }

    private func dressed(_ i: Int, _ rows: [Int]) -> CGImage {
        let base = bareFrames[i]
        let w = Int(framePx.width), h = Int(framePx.height)
        guard !rows.isEmpty,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        ctx.interpolationQuality = .none
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(base, in: r)
        for row in rows where row >= 0 && row < wearRows.count { ctx.draw(wearRows[row][i], in: r) }
        return ctx.makeImage() ?? base
    }

    /// 옷을 갈아입힌다 (wear.png 의 줄 번호들, 겹치는 순서대로).
    func setWear(_ rows: [Int]) {
        guard !bareFrames.isEmpty else { return }
        worn = rows.filter { $0 >= 0 && $0 < wearRows.count }
        frames = (0..<bareFrames.count).map { dressed($0, worn) }
        show(lastFrame)
    }

    /// 옷장 창에 보여 줄 앞모습 그림 (주어진 옷을 입힌 채로, 한 픽셀을 scale 포인트로)
    func previewImage(wear rows: [Int], scale: CGFloat) -> NSImage? {
        let i = Frame.front.rawValue
        guard i < bareFrames.count else { return nil }
        // 미리 크게 찍어 둔다 (이미지 뷰가 늘리면 픽셀이 뭉개진다).
        let k = Int(scale * 2), w = Int(framePx.width) * k, h = Int(framePx.height) * k
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(dressed(i, rows), in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let big = ctx.makeImage() else { return nil }
        return NSImage(cgImage: big, size: NSSize(width: framePx.width * scale, height: framePx.height * scale))
    }

    /// 친구의 새가 놀러 온다: 그 친구가 입은 옷 그대로 날아와 옆에 앉고, 말풍선을 띄웠다가 돌아간다.
    func visit(wear rows: [Int], text: String, play: Bool = false) {
        guard shown, !bareFrames.isEmpty, visitors.count < 3 else { return }      // 오모기를 숨겨 두었으면 손님도 오지 않는다
        let screen = currentScreen()
        let vf = screen.visibleFrame
        let base = pos
        // 내 오모기 옆자리 (화면 가운데 쪽), 이미 온 친구가 있으면 그만큼 더 옆으로
        let side: CGFloat = base.x > vf.midX ? -1 : 1
        let land = CGPoint(x: min(vf.maxX - 60, max(vf.minX + 60, base.x + side * CGFloat(76 + visitors.count * 64))), y: floorY(on: screen))
        let from = CGPoint(x: side < 0 ? vf.minX - 80 : vf.maxX + 80, y: vf.minY + vf.height * 0.55)
        let valid = rows.filter { $0 >= 0 && $0 < wearRows.count }
        func img(_ f: Frame) -> CGImage { return dressed(f.rawValue, valid) }
        let lo = max(vf.minX + 60, land.x - 200), hi = max(lo, min(vf.maxX - 60, land.x + 200))
        visitors.append(Visitor(fly: [img(.fly0), img(.fly1), img(.fly2), img(.fly1)], happy: [img(.happy0), img(.happy1)],
                                hop: [img(.hop0), img(.hop1), img(.hop2)], sit: img(.sit0),
                                from: from, land: land, text: text,
                                stay: play ? Double.random(in: 28...40) : (reduceMotion() ? 5 : 4), play: play, range: lo...hi))
        retime()
    }
    var visitorCount: Int { return visitors.count }

    /// 마을 마당에 그릴 그림들 (주어진 옷을 입힌 채로)
    func yardSprites(wear rows: [Int]) -> YardSprites? {
        guard !bareFrames.isEmpty else { return nil }
        let valid = rows.filter { $0 >= 0 && $0 < wearRows.count }
        func img(_ f: Frame) -> CGImage { return dressed(f.rawValue, valid) }
        return YardSprites(sit: img(.sit0), blink: img(.blink), hop: [img(.hop0), img(.hop1), img(.hop2)],
                           read: [img(.read0), img(.read1)], sleep: [img(.sleep0), img(.sleep1)], size: framePx)
    }

    /// 짧은 말풍선 (꼬마 뱁새를 얻었을 때 등)
    func cheer(_ text: String) {
        guard shown else { return }
        say(text, seconds: 2.2)
    }

    private func show(_ f: Frame) {
        guard f.rawValue < frames.count else { return }
        lastFrame = f
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = frames[f.rawValue]
        sprite.transform = CATransform3DMakeScale(faceRight ? 1 : -1, 1, 1)
        CATransaction.commit()
    }

    // ── 켜고 끄기 ──
    func start() {
        guard !cardOnly, Pet.enabled, !shown, !frames.isEmpty else { return }
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
        case "quizIn": _ = bringQuiz("O/X 한 문제 풀래요? — 눌러서 풀기")
        case "mailOut": _ = carryOut()
        case "mailIn": _ = bringMail("편지가 왔어요 (예시) — 눌러서 열기")
        case "lost": _ = reportLost("편지를 잃어버렸어요… (예시)")
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
        guard shown, mode != .away else { return }
        if mode == .chase || mode == .peck { endChase() }
        heldFromMail = mode == .mail
        let m = NSEvent.mouseLocation
        downAt = CACurrentMediaTime()
        downPos = m
        heldVel = .zero
        grab = CGPoint(x: m.x - pos.x, y: m.y - pos.y)
        lookUntil = 0
        reactUntil = 0
        setMode(.held)
    }

    private func drop() {
        guard shown, mode == .held else { return }
        // 놓는 순간의 속도를 이어받는다 (위로 던지면 잠깐 솟았다가 떨어진다).
        let fast = hypot(heldVel.x, heldVel.y) > 320 && !reduceMotion()
        throwVX = fast ? max(-1700, min(1700, heldVel.x)) : 0
        fallSpeed = fast ? -max(-300, min(1000, heldVel.y)) : 0
        rollPhase = 0
        // 편지를 물고 있을 때 옮기지 않고 살짝 누르기만 했으면 편지를 연다.
        let m = NSEvent.mouseLocation
        if heldFromMail, CACurrentMediaTime() - downAt < 0.4, hypot(m.x - downPos.x, m.y - downPos.y) < 6 {
            heldFromMail = false
            bubble.orderOut(nil)
            setMode(.fall)
            if holdingQuiz { holdingQuiz = false; onQuizOpen?() } else { onMailOpen?() }
            return
        }
        setMode(.fall)
    }

    func stop() {
        minis.forEach { $0.remove() }
        minis = []
        visitors.forEach { $0.remove() }
        visitors = []
        popAt = 0
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
        guard shown, mode != .chase, mode != .peck, mode != .roll, mode != .held, mode != .fall,
              mode != .depart, mode != .away, mode != .arrive, mode != .tumble else { done(); return }
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
        if cardOnly, !shown {
            // 카드에 가까운 쪽(위 또는 아래) 화면 바깥에서 날아 들어온다.
            guard Pet.enabled, !frames.isEmpty, let target = perchTarget?() else { return }
            let screen = NSScreen.screens.first { $0.frame.contains(target) } ?? NSScreen.main ?? NSScreen.screens[0]
            offstageY = target.y > screen.frame.midY ? screen.frame.maxY + 8 : screen.frame.minY - 96
            pos = CGPoint(x: max(screen.frame.minX + 40, target.x - 140), y: offstageY)
            homeX = pos.x
            shown = true
            lastTick = CACurrentMediaTime()
            growthTarget = growthFor(streak)             // 지난 카드까지의 연속 정답만큼 큰 채로 온다
            growth = growthTarget
            movePanel(lift: 0)
            panel.orderFrontRegardless()
            fly(to: target, as: .flyOut)
            return
        }
        // 탭을 닫으러 간 중이면 그 일을 마친 뒤 카드로 온다 (peck 이 끝날 때 카드가 떠 있으면 카드로 날아간다).
        guard shown, mode != .flyOut, mode != .perch, mode != .chase, mode != .peck, mode != .held, mode != .fall,
              let target = perchTarget?() else { return }
        if mode != .flyHome { homeX = pos.x }
        lookUntil = 0
        if comboGrowth { growthTarget = growthFor(streak) }      // 지난 카드까지의 연속 정답만큼 커진 채로 간다
        fly(to: target, as: .flyOut)
    }

    func react(correct: Bool) {
        guard shown, mode == .perch || mode == .flyOut else { return }
        reactHappy = correct
        reactStart = CACurrentMediaTime()
        reactUntil = reactStart + (correct ? 0.8 : 1.1)
        if comboGrowth, !reduceMotion() {
            if correct {
                streak += 1
                growthTarget = growthFor(streak)
                if streak >= popStreak {                 // 화면을 가릴 만큼 부풀었다가 펑
                    popAt = reactStart + 0.9
                    reactUntil = reactStart + 2.0
                }
            } else {
                streak = 0
                growthTarget = 1
            }
        }
        retime()
    }

    func goHome() {
        guard shown, mode == .perch || mode == .flyOut else { return }
        let screen = currentScreen()
        if !cardOnly { growthTarget = 1 }                        // 카드를 떠나 돌아다닐 때는 원래 크기로
        fly(to: CGPoint(x: homeX, y: cardOnly ? offstageY : floorY(on: screen)), as: .flyHome)
    }

    // 화면 옆 끝에 닿으면 튕겨 나온다.
    private func bounceOffWalls() {
        let vf = currentScreen().visibleFrame
        if pos.x < vf.minX + 30 { pos.x = vf.minX + 30; throwVX = abs(throwVX) * 0.55 }
        else if pos.x > vf.maxX - 30 { pos.x = vf.maxX - 30; throwVX = -abs(throwVX) * 0.55 }
    }

    // 떨어지거나 구르기를 마치고 그 자리에 자리 잡는다.
    private func settle(_ now: Double, dizzy: Bool) {
        homeX = pos.x
        sitsInARow = 0
        setMode(.sit)
        if heldFromMail {                                // 편지를 문 채로 옮겨졌으면 계속 물고 기다린다
            heldFromMail = false
            setMode(.mail)
            say(mailText, seconds: 3600)
        } else if perchTarget?() != nil { goToCard() }
        else {
            lookUntil = now + (dizzy ? 2.8 : 1.6)
            tiltAt = now + 0.5
            if dizzy { nextAction = lookUntil + Double.random(in: 2...5) }
        }
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
            || mode == .chase || mode == .peck || mode == .held || mode == .fall || mode == .depart || mode == .arrive
            || mode == .tumble || !minis.isEmpty || !visitors.isEmpty || popAt > 0 || abs(growthTarget - growth) > 0.004
            || CACurrentMediaTime() < reactUntil
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
            else if studying { frame = now.truncatingRemainder(dividingBy: 6.5) < 0.35 ? .read1 : .read0 }     // 가끔 한 장 넘긴다
            else { frame = Int(now / 0.9) % 2 == 0 ? .sit0 : .sit1 }
            // 생활 습관: 오래 손을 놓으면 둥지를 짓고, 계속 쓰고 있으면 가끔 물을 마신다.
            let idle = idleSeconds()
            if idle > nestMinutes * 60 { lookUntil = 0; setMode(.nest) }
            else if Pet.habitsOn, idle < 120, now - lastNudge > 90, startNudge(now) { }
            else if now >= nextAction, !studying { chooseNext(now) }
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
        case .away:
            // 화면 밖에서 잠깐 머문 뒤(편지를 건네거나 받아 오는 시간) 제자리로 돌아온다.
            frame = .fly1
            if t >= 2.2 {
                carrying = errand == .receive
                let screen = errandScreen ?? NSScreen.main ?? NSScreen.screens[0]
                fly(to: CGPoint(x: homeX, y: floorY(on: screen)), as: .arrive)
            }
        case .mail:
            // 편지를 물고 기다린다. 가끔 들썩여서 눈에 띄게 한다.
            faceRight = true
            frame = Int(t / 0.45) % 7 == 0 ? .mail1 : .mail0
            if !bubble.isVisible { say(mailText, seconds: 3600) }
            if holdingQuiz, t > 90 {                 // 문제는 한참 안 누르면 내려놓는다
                holdingQuiz = false
                bubble.orderOut(nil)
                setMode(.sit)
                frame = .sit0
            }
        case .lost:
            frame = .sad
            if t >= 7 { setMode(.sit); frame = .sit0 }
        case .flyOut, .flyHome, .roam, .chase, .depart, .arrive:
            if mode == .flyOut, let target = perchTarget?() { to = target }   // 카드 크기가 바뀌면 따라간다
            let raw = CGFloat(min(1, t / duration))
            let k = raw * raw * (3 - 2 * raw)
            pos = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k + sin(k * .pi) * arc)
            frame = (carrying ? [Frame.mailFly0, .mailFly1, .mailFly2, .mailFly1] : [Frame.fly0, .fly1, .fly2, .fly1])[Int(t * 14) % 4]
            if raw >= 1 {
                pos = to
                if cardOnly, mode == .flyHome { stop(); return }      // 화면 밖으로 나갔으면 사라진다
                switch mode {
                case .flyOut: setMode(.perch)
                case .chase: setMode(.peck)
                case .depart: setMode(.away)
                case .arrive where errand == .receive:
                    carrying = false
                    setMode(.mail)
                    say(mailText, seconds: 3600)
                default:
                    carrying = false
                    setMode(.sit)
                    faceRight = false
                }
                frame = mode == .mail ? .mail0 : mode == .away ? .fly1 : .sit0
            }
        case .held:
            // 집힌 동안: 마우스를 따라가며 대롱대롱
            let m = NSEvent.mouseLocation
            let next = CGPoint(x: m.x - grab.x, y: m.y - grab.y)
            if dt > 0.001 {
                heldVel = CGPoint(x: heldVel.x * 0.55 + (next.x - pos.x) / dt * 0.45, y: heldVel.y * 0.55 + (next.y - pos.y) / dt * 0.45)
            }
            pos = next
            frame = Int(now / 0.28) % 2 == 0 ? .front : .tilt
        case .fall:
            // 놓으면 그 자리 아래 바닥으로 떨어져 앉는다. 카드가 떠 있으면 다시 카드로 간다.
            let floor = floorY(on: currentScreen())
            fallSpeed += 1800 * dt
            pos.y -= fallSpeed * dt
            pos.x += throwVX * dt
            bounceOffWalls()
            if abs(throwVX) > 220 {                      // 던져졌으면 공중에서 빙글빙글
                faceRight = throwVX > 0
                rollPhase += dt * 11
                frame = [Frame.nod2, .roll1, .roll2, .roll3][Int(rollPhase) % 4]
            } else { frame = .hop1 }
            if pos.y <= floor {
                pos.y = floor
                if abs(throwVX) > 220 {                  // 그대로 바닥을 데굴데굴
                    setMode(.tumble)
                } else {
                    settle(now, dizzy: false)
                    frame = .hop2
                }
            }
        case .tumble:
            // 바닥에 닿은 뒤: 마찰로 느려지면서 구르다가 멈추면 어리둥절해한다.
            throwVX *= CGFloat(exp(-2.4 * Double(dt)))
            pos.x += throwVX * dt
            bounceOffWalls()
            faceRight = throwVX > 0
            rollPhase += abs(throwVX) * dt / 34          // 34pt 마다 사분의 일 바퀴
            frame = [Frame.nod2, .roll1, .roll2, .roll3][Int(rollPhase) % 4]
            if abs(throwVX) < 55 {
                throwVX = 0
                settle(now, dizzy: true)
                frame = .front
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
            // 몸이 커져도 카드를 가리지 않게, 커진 만큼 왼쪽으로 물러난다.
            if let target = perchTarget?() { pos = CGPoint(x: target.x - (growth - 1) * 26, y: target.y) } else { goHome() }
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

        // 연속 정답: 배율을 부드럽게 따라가고, 때가 되면 터뜨린다.
        if abs(growthTarget - growth) > 0.004 { growth += (growthTarget - growth) * min(1, dt * 9) }
        else if growth != growthTarget { growth = growthTarget; retime() }
        if popAt > 0, now >= popAt { pop() }
        if !minis.isEmpty {
            minis = minis.filter { $0.update(dt: dt, now: now) }
            if minis.isEmpty { retime() }
        }
        if !visitors.isEmpty {
            visitors = visitors.filter { $0.update(now: now) }
            if visitors.isEmpty { retime() }
        }

        movePanel(lift: lift)
        show(frame)
        updateBubble(now)
    }

    // 연속 정답 수에 따른 배율. 한 번 맞힐 때마다 같은 비율로 커져서, 다섯 번째에는 몸이 화면 높이의 절반 가까이 된다.
    private func growthFor(_ n: Int) -> CGFloat {
        guard n > 0 else { return 1 }
        let screenH = (NSScreen.screens.first { $0.frame.contains(pos) } ?? NSScreen.main)?.frame.height ?? 900
        let full = max(3, screenH * 0.46 / (17 * zoom))          // 몸 높이는 스프라이트 17픽셀
        return CGFloat(pow(Double(full), Double(min(n, popStreak)) / Double(popStreak)))
    }

    // 펑: 큰 몸이 사라지고 작은 새 여럿이 튀어 나갔다가, 잠시 뒤 하나씩 날아가고 원래 한 마리만 남는다.
    private func pop() {
        popAt = 0
        streak = 0
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        growth = 1
        growthTarget = 1
        guard Frame.hop1.rawValue < bareFrames.count else { return }
        let screen = currentScreen().frame
        let flyImages = [Frame.fly0, .fly1, .fly2, .fly1].map { bareFrames[$0.rawValue] }
        let catchable = onMiniCaught != nil
        let n = 14
        let up: CGFloat = center.y > screen.midY ? -0.8 : 1      // 화면 위쪽에 있으면 아래로, 아래쪽에 있으면 위로 퍼진다
        for i in 0..<n {
            let angle = Double.pi * (0.12 + 0.76 * Double(i) / Double(n - 1)) + Double.random(in: -0.12...0.12)   // 반원으로 퍼진다
            let speed = CGFloat.random(in: 380...900)
            let goRight = cos(angle) > 0
            let exit = CGPoint(x: goRight ? screen.maxX + 80 : screen.minX - 80, y: center.y + CGFloat.random(in: -160...220))
            minis.append(MiniBird(hop: bareFrames[Frame.hop1.rawValue], fly: flyImages, at: center,
                                  velocity: CGPoint(x: CGFloat(cos(angle)) * speed, y: CGFloat(sin(angle)) * speed * up),
                                  leaveAfter: catchable ? 3.0 + Double(i) * 0.4 : 1.6 + Double(i) * 0.22, exit: exit,
                                  onCatch: catchable ? { [weak self] in self?.onMiniCaught?() } : nil))
        }
        retime()
    }

    private func movePanel(lift: CGFloat) {
        // 연속 정답으로 커졌으면 창도 그만큼 키운다 (발 위치는 그대로).
        let size = CGSize(width: (panelSize.width * growth).rounded(), height: (panelSize.height * growth).rounded())
        if panel.frame.size != size {
            panel.setContentSize(size)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.frame = CGRect(origin: .zero, size: size)
            CATransaction.commit()
        }
        // 스프라이트의 발은 가운데가 아니라서, 보는 방향에 따라 창을 다르게 놓는다.
        let feetX = (faceRight ? feetPx : framePx.width - feetPx) * zoom * growth
        var origin = CGPoint(x: (pos.x - feetX).rounded(), y: (pos.y - floorInset * growth + lift).rounded())
        if growth > 1.01, let screen = NSScreen.screens.first(where: { $0.frame.contains(pos) }) {
            // 크게 부풀었을 때 화면 위로 넘치지 않게 아래로 내린다.
            origin.y = min(origin.y, screen.visibleFrame.maxY - size.height)
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// 메뉴 막대에 쓸 작은 얼굴 그림 (정면 프레임에서 몸만 잘라 낸 것).
    func faceImage(height: CGFloat) -> NSImage? {
        guard Frame.front.rawValue < bareFrames.count,
              let cut = bareFrames[Frame.front.rawValue].cropping(to: CGRect(x: 8, y: 5, width: 20, height: 23)) else { return nil }
        return NSImage(cgImage: cut, size: NSSize(width: (height * 20 / 23).rounded(), height: height))
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

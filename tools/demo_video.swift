// Loading Dose 홍보 영상 생성기: 프레임을 직접 그려 MP4로 저장한다.
// 가상의 데스크톱 화면을 그리고, 그 위를 카메라가 확대·축소하며 따라간다.
//   1장면: Mac 데스크톱의 채팅 앱에서 질문 → 카드 → 채점 → 접힘
//   2장면: 설정 창에서 과목 고르기 (실제 설정 창 화면을 잘라 넣는다)
//   3장면: Windows 데스크톱의 크롬에서 같은 동작
//   마무리 화면
// 사용: demo <출력.mp4> <아이콘.png> <설정창 화면.png> [정지 화면 시각(초), 쉼표 구분] [PNG 폴더]
// 채팅 화면은 특정 서비스를 닮지 않은 중립 디자인이다. 실제 화면 녹화가 아니다.
import AppKit
import AVFoundation

let W = 1920, H = 1080, FPS = 30
let DURATION = 24.4

// ── 색 ──
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let cardBG = rgb(226, 223, 217)
let ink = rgb(28, 28, 30)
let sub = rgb(92, 90, 86)
let faint = rgb(160, 156, 150)
let blue = rgb(52, 120, 246)
let green = rgb(46, 139, 58)
let btnIdle = rgb(204, 201, 195)
let btnO = rgb(92, 191, 78)
let btnX = rgb(226, 69, 54)

// ── 시간 도우미 ──
func clamp(_ x: Double) -> CGFloat { CGFloat(max(0, min(1, x))) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { clamp((t - a) / (b - a)) }
func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }

// ── 그리기 도우미 (좌표: 왼쪽 위 원점) ──
func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

func attr(_ s: String, _ f: NSFont, _ c: NSColor, align: NSTextAlignment = .left, lineHeight: CGFloat? = nil) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.lineBreakMode = .byWordWrapping
    if let lh = lineHeight { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
    return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: p])
}

@discardableResult
func text(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, y: CGFloat, w: CGFloat = 3000,
          align: NSTextAlignment = .left, lineHeight: CGFloat? = nil) -> CGFloat {
    let a = attr(s, f, c, align: align, lineHeight: lineHeight)
    let r = a.boundingRect(with: NSSize(width: w, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    a.draw(with: NSRect(x: x, y: y, width: w, height: ceil(r.height) + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return ceil(r.height)
}

func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
    ceil(attr(s, f, .black).boundingRect(with: NSSize(width: 4000, height: 400), options: [.usesLineFragmentOrigin]).width)
}

func rrect(_ r: NSRect, _ radius: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

func oval(_ r: NSRect, _ c: NSColor) {
    c.setFill()
    NSBezierPath(ovalIn: r).fill()
}

func withAlpha(_ a: CGFloat, _ body: () -> Void) {
    guard a > 0.004, let cg = NSGraphicsContext.current?.cgContext else { return }
    cg.saveGState()
    cg.setAlpha(a)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

func drawImage(_ image: NSImage?, in r: CGRect) {
    guard let image = image, let cg = NSGraphicsContext.current?.cgContext,
          let img = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    cg.saveGState()
    cg.translateBy(x: 0, y: r.minY + r.maxY)   // 뒤집힌 좌표에서 그림을 바로 세운다
    cg.scaleBy(x: 1, y: -1)
    cg.interpolationQuality = .high
    cg.draw(img, in: r)
    cg.restoreGState()
}

var appIcon: NSImage?
var settingsShot: NSImage?

// ── 카드 한 번의 흐름 ──
struct Flow {
    var typeA, typeB, enter, pill, openA, openB, answer, stream, done, foldA, foldB, hide: Double
}
struct Quiz {
    var ask, topic, q, why: String
    var answer: Bool      // 정답
    var pick: Bool        // 영상에서 고르는 답
    var keys: String      // 단축키 안내
}

let flowMac = Flow(typeA: 0.7, typeB: 1.8, enter: 2.1, pill: 2.35, openA: 2.9, openB: 3.4, answer: 5.5,
                   stream: 6.6, done: 8.6, foldA: 9.2, foldB: 9.7, hide: 10.3)
let quizMac = Quiz(ask: "심방세동 항응고 기준 정리해줘", topic: "내분비",
                   q: "급성 증상성 저칼슘혈증에는 calcium gluconate를\n정맥주사한다.",
                   why: "저마그네슘혈증이 동반되면 Mg도 보충해야 칼슘이 교정된다.",
                   answer: true, pick: true, keys: "⌥O · ⌥X")

let tSetA = 10.7, tSetB = 15.0            // 설정 창
let tAllOff = 11.9                        // "모두 끄기" 누름
let tPicks: [Double] = [12.6, 13.2, 13.8] // 과목을 다시 켜는 시각
let tWin = 15.2                           // Windows·크롬 장면 시작

let flowWin = Flow(typeA: 15.8, typeB: 16.6, enter: 16.8, pill: 17.0, openA: 17.35, openB: 17.75, answer: 19.2,
                   stream: 19.4, done: 20.3, foldA: 20.6, foldB: 21.0, hide: 21.3)
let quizWin = Quiz(ask: "아편유사제 금단 증상 알려줘", topic: "약리학",
                   q: "opioid 금단에서는 동공이 축소되고 변비가 생긴다.",
                   why: "급성 효과와 반대로 동공 산대, 설사, 발한, 근육통이 나타난다.",
                   answer: false, pick: false, keys: "Alt+O · Alt+X")
let tEnd = 21.5

// ── 카메라: (시각, 중심 x, 중심 y, 배율). 사이는 부드럽게 잇는다. ──
let cameraKeys: [(Double, CGFloat, CGFloat, CGFloat)] = [
    (0.0, 960, 540, 1.0),
    (0.5, 960, 540, 1.0), (1.5, 1090, 760, 1.7),      // 입력창으로
    (2.25, 1090, 760, 1.7), (3.2, 960, 330, 1.55),    // 화면 위 카드로
    (7.3, 960, 330, 1.55), (8.3, 960, 540, 1.0),      // 물러나 전체 보기
    (10.8, 960, 540, 1.0), (11.7, 960, 520, 1.42),    // 설정 창으로
    (14.5, 960, 520, 1.42), (15.0, 960, 540, 1.0),
    (16.7, 960, 540, 1.0), (17.5, 960, 420, 1.45),    // 크롬의 카드로
    (20.5, 960, 420, 1.45), (21.2, 960, 540, 1.0),
    (DURATION, 960, 540, 1.0),
]

func camera(_ t: Double) -> (CGFloat, CGFloat, CGFloat) {
    var a = cameraKeys[0], b = cameraKeys[cameraKeys.count - 1]
    for i in 0..<(cameraKeys.count - 1) where t >= cameraKeys[i].0 && t <= cameraKeys[i + 1].0 {
        a = cameraKeys[i]; b = cameraKeys[i + 1]; break
    }
    let p = b.0 > a.0 ? ease(prog(t, a.0, b.0)) : 0
    let z = lerp(a.3, b.3, p)
    // 화면 밖이 보이지 않게 중심을 가둔다
    let hx = CGFloat(W) / 2 / z, hy = CGFloat(H) / 2 / z
    let cx = min(max(lerp(a.1, b.1, p), hx), CGFloat(W) - hx)
    let cy = min(max(lerp(a.2, b.2, p), hy), CGFloat(H) - hy)
    return (cx, cy, z)
}

// ── 대화 영역 (말풍선, 답변, 입력창) ──
func drawConversation(_ t: Double, _ f: Flow, _ q: Quiz, left: CGFloat, right: CGFloat, bubbleY: CGFloat, inputY: CGFloat) {
    let sent = t >= f.enter
    let tf = font(25)
    let input = NSRect(x: left, y: inputY, width: right - left, height: 66)
    rrect(input, 22, rgb(238, 238, 234))
    if !sent {
        let n = Int(prog(t, f.typeA, f.typeB) * CGFloat(q.ask.count))
        let typed = String(q.ask.prefix(n))
        if typed.isEmpty { text("메시지 입력", tf, rgb(170, 170, 166), x: input.minX + 26, y: input.minY + 17) }
        else { text(typed, tf, ink, x: input.minX + 26, y: input.minY + 17) }
        if Int(t * 2.2) % 2 == 0 || (t > f.typeA && t < f.typeB) {
            ink.setFill()
            NSRect(x: input.minX + 28 + (typed.isEmpty ? 0 : textWidth(typed, tf)), y: input.minY + 16, width: 2.5, height: 34).fill()
        }
    } else {
        text("메시지 입력", tf, rgb(170, 170, 166), x: input.minX + 26, y: input.minY + 17)
    }
    guard sent else { return }

    let p = easeOut(prog(t, f.enter, f.enter + 0.35))
    let bw = textWidth(q.ask, tf) + 52
    let by = lerp(input.minY - 20, bubbleY, p)
    withAlpha(p) {
        rrect(NSRect(x: right - bw, y: by, width: bw, height: 62), 24, rgb(44, 50, 66))
        text(q.ask, tf, .white, x: right - bw + 26, y: by + 15)
    }
    let ay = bubbleY + 86
    withAlpha(prog(t, f.enter + 0.3, f.enter + 0.6)) {
        oval(NSRect(x: left, y: ay, width: 40, height: 40), rgb(196, 196, 190))
        if t < f.stream {
            for i in 0..<3 {
                let ph = CGFloat(max(0, sin((t * 5.2) - Double(i) * 0.7)))
                oval(NSRect(x: left + 60 + CGFloat(i) * 24, y: ay + 13 - ph * 5, width: 13, height: 13), rgb(150, 150, 146, 0.45 + 0.4 * ph))
            }
        } else {
            // 답변이 흘러나오는 모습 (글자 대신 줄 막대)
            let full = right - left - 60
            let widths: [CGFloat] = [full * 0.92, full, full * 0.78, full * 0.55]
            var shown = prog(t, f.stream, f.done) * widths.reduce(0, +)
            for (i, wd) in widths.enumerated() {
                let w = min(wd, shown)
                if w <= 0 { break }
                rrect(NSRect(x: left + 60, y: ay + 10 + CGFloat(i) * 30, width: w, height: 14), 7, rgb(205, 205, 200))
                shown -= wd
            }
        }
    }
}

// 이전 대화(이미 끝난 문답)를 흐릿하게 깔아 둔다.
func drawHistory(left: CGFloat, right: CGFloat, y: CGFloat) {
    let tf = font(25)
    let s = "심부전 약물치료 한 장으로 요약해줘"
    let bw = textWidth(s, tf) + 52
    rrect(NSRect(x: right - bw, y: y, width: bw, height: 62), 24, rgb(44, 50, 66))
    text(s, tf, .white, x: right - bw + 26, y: y + 15)
    oval(NSRect(x: left, y: y + 86, width: 40, height: 40), rgb(196, 196, 190))
    let full = right - left - 60
    for (i, k) in [0.95, 1.0, 0.86, 0.97, 0.6].enumerated() {
        rrect(NSRect(x: left + 60, y: y + 96 + CGFloat(i) * 30, width: full * CGFloat(k), height: 14), 7, rgb(205, 205, 200))
    }
}

// Enter 키가 눌리는 모습
func drawEnterKey(_ t: Double, at: Double, cx: CGFloat, cy: CGFloat) {
    let kp = prog(t, at - 0.35, at - 0.15) * (1 - prog(t, at + 0.4, at + 0.7))
    guard kp > 0 else { return }
    let press = prog(t, at - 0.08, at) * (1 - prog(t, at + 0.12, at + 0.3))
    let size: CGFloat = 104 - press * 9
    withAlpha(kp) {
        rrect(NSRect(x: cx - size / 2, y: cy - size / 2 + 8, width: size, height: size), 22, rgb(0, 0, 0, 0.3))
        rrect(NSRect(x: cx - size / 2, y: cy - size / 2 + press * 6, width: size, height: size), 22, press > 0.5 ? blue : rgb(38, 40, 48))
        text("⏎", font(52, .semibold), .white, x: cx - 60, y: cy - 34 + press * 6, w: 120, align: .center)
    }
}

// ── 알약·카드 ──
var lastO = NSPoint.zero   // 가장 최근에 그린 O 단추의 중심 (커서가 찾아간다)

func drawSpinner(cx: CGFloat, cy: CGFloat, t: Double) {
    let path = NSBezierPath()
    let start = CGFloat(t * 300).truncatingRemainder(dividingBy: 360)
    path.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 11, startAngle: start, endAngle: start + 250)
    path.lineWidth = 4
    path.lineCapStyle = .round
    blue.setStroke()
    path.stroke()
}

func drawCheck(cx: CGFloat, cy: CGFloat) {
    let ring = NSBezierPath(ovalIn: NSRect(x: cx - 13, y: cy - 13, width: 26, height: 26))
    ring.lineWidth = 3.5
    btnO.setStroke()
    ring.stroke()
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx - 6, y: cy))
    p.line(to: NSPoint(x: cx - 1.5, y: cy + 5))
    p.line(to: NSPoint(x: cx + 6.5, y: cy - 5))
    p.lineWidth = 3.5
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    btnO.setStroke()
    p.stroke()
}

func drawCard(_ t: Double, _ f: Flow, _ q: Quiz, centerX: CGFloat, top: CGFloat, today: Int) {
    guard t >= f.pill, t < f.hide + 0.4 else { return }
    let pillW: CGFloat = 430, pillH: CGFloat = 64, cardW: CGFloat = 640
    let lines: CGFloat = q.q.contains("\n") || textWidth(q.q, font(28, .bold)) > cardW - 60 ? 2 : 1
    let qh = 39 * lines
    let hAsk = 150 + qh + 22 + 68 + 20 + 28 + 26
    let hGraded = hAsk + 94

    let open = ease(prog(t, f.openA, f.openB))
    let graded = ease(prog(t, f.answer + 0.05, f.answer + 0.4))
    let fold = ease(prog(t, f.foldA, f.foldB))
    let body = open * (1 - fold)                     // 0 = 알약, 1 = 카드
    let w = lerp(pillW, cardW, body)
    let h = lerp(pillH, lerp(hAsk, hGraded, graded), body)
    let appear = easeOut(prog(t, f.pill, f.pill + 0.3))
    let gone = prog(t, f.hide, f.hide + 0.35)
    let y = top - (1 - appear) * 38 - gone * 20
    let rect = NSRect(x: centerX - w / 2, y: y, width: w, height: h)
    let radius = lerp(pillH / 2, 36, body)
    let done = t >= f.done
    let correct = q.pick == q.answer

    withAlpha(appear * (1 - gone)) {
        rrect(rect.offsetBy(dx: 0, dy: 10).insetBy(dx: 8, dy: 4), radius, rgb(0, 0, 0, 0.30))
        rrect(rect, radius, cardBG)
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

        // 머리줄: 진행 상태
        let secs = max(0, Int(min(t, f.done) - f.enter))
        let hx = rect.minX + 30, hy = rect.minY + 32
        if done { drawCheck(cx: hx + 6, cy: hy) } else { drawSpinner(cx: hx + 6, cy: hy, t: t) }
        text(done ? "답변 도착 · \(secs)초" : "답변 생성 중 · \(secs)초", font(23, .medium), done ? green : rgb(58, 58, 60),
             x: hx + 34, y: hy - 15)
        withAlpha(fold) {
            text("오늘 \(today + 1)문제", font(21, .medium), faint, x: rect.maxX - 230, y: hy - 14, w: 200, align: .right)
        }

        withAlpha(body) {
            let x = rect.minX + 30, cw = cardW - 60
            text("×", font(30, .medium), rgb(110, 108, 104), x: rect.maxX - 54, y: rect.minY + 10)
            text("내 질문: \(q.ask)", font(20), faint, x: x, y: rect.minY + 72)
            text(q.topic, font(18, .medium), sub, x: x, y: rect.minY + 116)
            text(q.q, font(28, .bold), ink, x: x, y: rect.minY + 150, w: cw, lineHeight: 39)
            let by = rect.minY + 150 + qh + 22
            let bw = (cw - 14) / 2
            let pressed = prog(t, f.answer - 0.12, f.answer) * (1 - prog(t, f.answer, f.answer + 0.2))
            var oRect = NSRect(x: x, y: by, width: bw, height: 68)
            var xRect = NSRect(x: x + bw + 14, y: by, width: bw, height: 68)
            lastO = NSPoint(x: oRect.midX, y: oRect.midY)
            if q.pick { oRect = oRect.insetBy(dx: pressed * 5, dy: pressed * 3) } else { xRect = xRect.insetBy(dx: pressed * 5, dy: pressed * 3) }
            let answered = t >= f.answer
            let down = rgb(184, 181, 175)
            rrect(oRect, 15, answered ? btnO : (pressed > 0 && q.pick ? down : btnIdle))
            rrect(xRect, 15, answered ? btnX : (pressed > 0 && !q.pick ? down : btnIdle))
            text("O", font(28, .bold), answered ? .white : ink, x: oRect.minX, y: by + 15, w: oRect.width, align: .center)
            text("X", font(28, .bold), answered ? .white : ink, x: xRect.minX, y: by + 15, w: xRect.width, align: .center)

            withAlpha(1 - graded) {
                text("오늘 \(today)문제 · 연속 3", font(20), faint, x: x, y: by + 88)
                text(q.keys, font(20, .medium), faint, x: x, y: by + 88, w: cw, align: .right)
            }
            withAlpha(graded) {
                text((correct ? "정답" : "오답") + " — 답은 " + (q.answer ? "O" : "X"), font(25, .bold), correct ? green : rgb(190, 50, 40),
                     x: x, y: by + 86)
                text(q.why, font(20), sub, x: x, y: by + 128, w: cw)
                text("오늘 \(today + 1)문제 · 연속 4", font(20), faint, x: x, y: by + 170)
                text("다음 문제 →", font(21, .semibold), blue, x: x, y: by + 169, w: cw, align: .right)
            }
        }
        cg.restoreGState()
    }
}

// ── 커서 ──
func drawCursor(at p: NSPoint, click: CGFloat) {
    if click > 0 && click < 1 {
        let r = 10 + click * 26
        let ring = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 4
        blue.withAlphaComponent(1 - click).setStroke()
        ring.stroke()
    }
    let a = NSBezierPath()
    a.move(to: p)
    a.line(to: NSPoint(x: p.x, y: p.y + 30))
    a.line(to: NSPoint(x: p.x + 8, y: p.y + 23))
    a.line(to: NSPoint(x: p.x + 14, y: p.y + 36))
    a.line(to: NSPoint(x: p.x + 19, y: p.y + 33.5))
    a.line(to: NSPoint(x: p.x + 13, y: p.y + 21))
    a.line(to: NSPoint(x: p.x + 23, y: p.y + 21))
    a.close()
    NSColor.black.setFill()
    a.fill()
    a.lineWidth = 2.2
    a.lineJoinStyle = .round
    NSColor.white.setStroke()
    a.stroke()
}

// 경유점 사이를 부드럽게 움직인다. (시각, 위치)
func cursorPos(_ t: Double, _ keys: [(Double, NSPoint)]) -> NSPoint {
    var a = keys[0], b = keys[keys.count - 1]
    if t <= a.0 { return a.1 }
    if t >= b.0 { return b.1 }
    for i in 0..<(keys.count - 1) where t >= keys[i].0 && t <= keys[i + 1].0 { a = keys[i]; b = keys[i + 1]; break }
    let p = ease(prog(t, a.0, b.0))
    return NSPoint(x: lerp(a.1.x, b.1.x, p), y: lerp(a.1.y, b.1.y, p))
}

func clickPhase(_ t: Double, _ times: [Double]) -> CGFloat {
    for c in times where t >= c && t <= c + 0.45 { return prog(t, c, c + 0.45) }
    return 0
}

// ── 1·2장면: Mac 데스크톱 ──
let macWin = NSRect(x: 330, y: 96, width: 1260, height: 840)

func drawMacDesktop(_ t: Double) {
    NSGradient(colors: [rgb(92, 108, 190), rgb(170, 120, 190), rgb(238, 170, 150)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 60)
    // 메뉴 막대
    rgb(255, 255, 255, 0.62).setFill()
    NSRect(x: 0, y: 0, width: W, height: 34).fill()
    text("AI 채팅", font(17, .bold), ink, x: 28, y: 6)
    for (i, s) in ["파일", "편집", "보기", "창", "도움말"].enumerated() {
        text(s, font(17), ink, x: 118 + CGFloat(i) * 62, y: 6)
    }
    text("11월 16일 (월)  오후 9:41", font(17), ink, x: CGFloat(W) - 330, y: 6, w: 310, align: .right)
    text("⏎", font(18, .semibold), ink, x: CGFloat(W) - 372, y: 5)   // Loading Dose 메뉴 막대 아이콘
    // 독
    let dock = NSRect(x: 660, y: 986, width: 600, height: 82)
    rrect(dock, 24, rgb(255, 255, 255, 0.36))
    let tiles = [rgb(72, 136, 244), rgb(250, 190, 70), rgb(92, 196, 110), rgb(240, 96, 96), rgb(150, 110, 230), rgb(70, 190, 200)]
    for (i, c) in tiles.enumerated() {
        rrect(NSRect(x: dock.minX + 22 + CGFloat(i) * 80, y: dock.minY + 12, width: 58, height: 58), 14, c)
    }
    drawImage(appIcon, in: CGRect(x: dock.minX + 22 + 6 * 80 - 4, y: dock.minY + 8, width: 66, height: 66))
    oval(NSRect(x: dock.minX + 22 + 6 * 80 + 26, y: dock.maxY - 8, width: 5, height: 5), rgb(40, 40, 40, 0.7))

    // 채팅 앱 창
    let w = macWin
    rrect(w.offsetBy(dx: 0, dy: 18).insetBy(dx: 4, dy: 0), 22, rgb(0, 0, 0, 0.30))
    rrect(w, 18, rgb(250, 250, 248))
    // 옆 목록
    if let cg = NSGraphicsContext.current?.cgContext {
        cg.saveGState()
        NSBezierPath(roundedRect: w, xRadius: 18, yRadius: 18).addClip()
        rgb(240, 240, 236).setFill()
        NSRect(x: w.minX, y: w.minY, width: 250, height: w.height).fill()
        cg.restoreGState()
    }
    for (i, c) in [rgb(237, 106, 94), rgb(245, 191, 79), rgb(98, 197, 84)].enumerated() {
        oval(NSRect(x: w.minX + 22 + CGFloat(i) * 25, y: w.minY + 19, width: 15, height: 15), c)
    }
    rrect(NSRect(x: w.minX + 22, y: w.minY + 66, width: 206, height: 42), 12, rgb(226, 226, 220))
    text("+  새 대화", font(18, .medium), sub, x: w.minX + 40, y: w.minY + 75)
    for (i, k) in [0.78, 0.62, 0.86, 0.55, 0.7, 0.48, 0.8].enumerated() {
        rrect(NSRect(x: w.minX + 26, y: w.minY + 140 + CGFloat(i) * 44, width: 198 * CGFloat(k), height: 13), 6.5,
              i == 0 ? rgb(170, 170, 164) : rgb(214, 214, 208))
    }
    text("AI 채팅", font(18, .medium), rgb(120, 120, 120), x: w.minX + 250, y: w.minY + 16, w: w.width - 250, align: .center)

    let left = w.minX + 300, right = w.maxX - 50
    drawHistory(left: left, right: right, y: w.minY + 96)
    drawConversation(t, flowMac, quizMac, left: left, right: right, bubbleY: w.minY + 470, inputY: w.maxY - 96)
    drawEnterKey(t, at: flowMac.enter, cx: right - 60, cy: w.maxY - 180)
}

// 설정 창: 실제 설정 창 화면을 잘라 넣고, 체크 상태만 덧그린다.
// 잘라 넣은 그림 안에서의 체크박스 위치 (그림 폭 1240 기준)
let boxLeftX: CGFloat = 80, boxRightX: CGFloat = 646, boxTopY: CGFloat = 192, boxStep: CGFloat = 44
let allOffButton = NSPoint(x: 1116, y: 148)
// 다시 켜는 과목: (오른쪽 줄인가, 몇 번째 줄) — 순환기, 호흡기, 신장
let picks: [(Bool, Int)] = [(true, 2), (false, 3), (false, 4)]
var setScale: CGFloat = 1
var setOrigin = NSPoint.zero
func setPoint(_ p: NSPoint) -> NSPoint { NSPoint(x: setOrigin.x + p.x * setScale, y: setOrigin.y + p.y * setScale) }
func boxPoint(_ right: Bool, _ row: Int) -> NSPoint {
    setPoint(NSPoint(x: right ? boxRightX : boxLeftX, y: boxTopY + CGFloat(row) * boxStep))
}

func drawSettingsWindow(_ t: Double) {
    let p = ease(prog(t, tSetA, tSetA + 0.4)) * (1 - ease(prog(t, tSetB - 0.05, tSetB + 0.25)))
    guard p > 0, let shot = settingsShot, let rep = shot.representations.first else { return }
    let iw: CGFloat = 860
    setScale = iw / CGFloat(rep.pixelsWide)
    let ih = CGFloat(rep.pixelsHigh) * setScale
    let win = NSRect(x: (CGFloat(W) - iw) / 2 - 22, y: 150, width: iw + 44, height: ih + 46 + 30)
    setOrigin = NSPoint(x: win.minX + 22, y: win.minY + 46 + 8)
    withAlpha(p) {
        rrect(win.offsetBy(dx: 0, dy: 20).insetBy(dx: 2, dy: 0), 20, rgb(0, 0, 0, 0.36))
        rrect(win, 16, rgb(250, 250, 248))
        for (i, c) in [rgb(237, 106, 94), rgb(245, 191, 79), rgb(98, 197, 84)].enumerated() {
            oval(NSRect(x: win.minX + 20 + CGFloat(i) * 24, y: win.minY + 16, width: 14, height: 14), c)
        }
        text("Loading Dose", font(17, .semibold), rgb(90, 90, 90), x: win.minX, y: win.minY + 12, w: win.width, align: .center)
        drawImage(shot, in: CGRect(x: setOrigin.x, y: setOrigin.y, width: iw, height: ih))
        // "모두 끄기" 뒤에는 고른 과목만 켜진 모습
        guard t >= tAllOff else { return }
        for right in [false, true] {
            for row in 0..<(right ? 12 : 13) {
                if let i = picks.firstIndex(where: { $0.0 == right && $0.1 == row }), t >= tPicks[i] { continue }
                let c = boxPoint(right, row)
                rgb(250, 250, 248).setFill()
                NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26).fill()
                let b = NSBezierPath(roundedRect: NSRect(x: c.x - 9.5, y: c.y - 9.5, width: 19, height: 19), xRadius: 4.5, yRadius: 4.5)
                NSColor.white.setFill()
                b.fill()
                b.lineWidth = 1.2
                rgb(190, 190, 186).setStroke()
                b.stroke()
            }
        }
    }
}

func drawMacCursor(_ t: Double) {
    guard t >= 4.2, t < tSetB + 0.2 else { return }
    let keys: [(Double, NSPoint)] = [
        (4.2, NSPoint(x: 1180, y: 560)), (5.3, lastO), (6.4, lastO),
        (7.6, NSPoint(x: 1240, y: 640)), (11.0, NSPoint(x: 1240, y: 640)),
        (tAllOff - 0.1, setPoint(allOffButton)), (tAllOff + 0.15, setPoint(allOffButton)),
        (tPicks[0] - 0.1, boxPoint(picks[0].0, picks[0].1)), (tPicks[0] + 0.1, boxPoint(picks[0].0, picks[0].1)),
        (tPicks[1] - 0.1, boxPoint(picks[1].0, picks[1].1)), (tPicks[1] + 0.1, boxPoint(picks[1].0, picks[1].1)),
        (tPicks[2] - 0.1, boxPoint(picks[2].0, picks[2].1)), (tPicks[2] + 0.4, boxPoint(picks[2].0, picks[2].1)),
        (tSetB, NSPoint(x: 1300, y: 760)),
    ]
    let a = prog(t, 4.2, 4.5) * (1 - prog(t, tSetB, tSetB + 0.2))
    withAlpha(a) {
        drawCursor(at: cursorPos(t, keys), click: clickPhase(t, [flowMac.answer, tAllOff] + tPicks))
    }
}

// ── 3장면: Windows 데스크톱의 크롬 ──
let winBrowser = NSRect(x: 230, y: 56, width: 1460, height: 880)

func drawWinDesktop(_ t: Double) {
    NSGradient(colors: [rgb(20, 70, 140), rgb(40, 140, 190), rgb(130, 200, 220)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)
    // 작업 표시줄
    rgb(24, 28, 36, 0.86).setFill()
    NSRect(x: 0, y: 1028, width: W, height: 52).fill()
    let tiles = [rgb(90, 160, 250), rgb(250, 200, 80), rgb(240, 110, 100), rgb(110, 200, 130), rgb(170, 130, 240)]
    for (i, c) in tiles.enumerated() {
        rrect(NSRect(x: 820 + CGFloat(i) * 58, y: 1036, width: 36, height: 36), 8, c)
    }
    rgb(255, 255, 255, 0.85).setFill()
    NSRect(x: 820 + 58 + 10, y: 1074, width: 16, height: 3).fill()
    text("오후 9:41\n2026-11-16", font(14), .white, x: CGFloat(W) - 150, y: 1034, w: 130, align: .right)

    let w = winBrowser
    rrect(w.offsetBy(dx: 0, dy: 16).insetBy(dx: 4, dy: 0), 14, rgb(0, 0, 0, 0.32))
    rrect(w, 10, rgb(222, 226, 232))
    // 탭 줄
    rrect(NSRect(x: w.minX + 12, y: w.minY + 8, width: 250, height: 44), 10, rgb(250, 250, 248))
    oval(NSRect(x: w.minX + 28, y: w.minY + 21, width: 18, height: 18), rgb(196, 196, 190))
    text("AI 채팅", font(16), ink, x: w.minX + 56, y: w.minY + 19)
    text("×", font(18), sub, x: w.minX + 232, y: w.minY + 16)
    text("+", font(22), sub, x: w.minX + 276, y: w.minY + 13)
    text("—      ☐      ✕", font(17), rgb(70, 70, 70), x: w.maxX - 170, y: w.minY + 14, w: 150, align: .right)
    // 주소 줄
    rgb(250, 250, 248).setFill()
    NSRect(x: w.minX, y: w.minY + 46, width: w.width, height: 54).fill()
    text("←    →    ⟳", font(20), rgb(110, 110, 110), x: w.minX + 22, y: w.minY + 58)
    rrect(NSRect(x: w.minX + 170, y: w.minY + 54, width: w.width - 330, height: 38), 19, rgb(236, 238, 242))
    text("chatgpt.com", font(17), rgb(60, 60, 60), x: w.minX + 196, y: w.minY + 62)
    drawImage(appIcon, in: CGRect(x: w.maxX - 132, y: w.minY + 55, width: 36, height: 36))   // 확장 프로그램 아이콘
    oval(NSRect(x: w.maxX - 70, y: w.minY + 58, width: 30, height: 30), rgb(190, 196, 206))
    // 페이지
    if let cg = NSGraphicsContext.current?.cgContext {
        cg.saveGState()
        NSBezierPath(roundedRect: w, xRadius: 10, yRadius: 10).addClip()
        rgb(252, 252, 250).setFill()
        NSRect(x: w.minX, y: w.minY + 100, width: w.width, height: w.height - 100).fill()
        cg.restoreGState()
    }
    let left = w.minX + 300, right = w.maxX - 300
    drawHistory(left: left, right: right, y: w.minY + 130)
    drawConversation(t, flowWin, quizWin, left: left, right: right, bubbleY: w.minY + 560, inputY: w.maxY - 104)
    drawEnterKey(t, at: flowWin.enter, cx: right + 110, cy: w.maxY - 78)
    drawCard(t, flowWin, quizWin, centerX: w.midX, top: w.minY + 108, today: 27)

    // Alt+X 단축키
    let kp = prog(t, flowWin.answer - 0.5, flowWin.answer - 0.3) * (1 - prog(t, flowWin.answer + 0.5, flowWin.answer + 0.8))
    if kp > 0 {
        let press = prog(t, flowWin.answer - 0.08, flowWin.answer) * (1 - prog(t, flowWin.answer + 0.12, flowWin.answer + 0.3))
        withAlpha(kp) {
            var x = w.midX + 360
            for (label, width) in [("Alt", CGFloat(96)), ("X", CGFloat(70))] {
                let r = NSRect(x: x, y: w.minY + 330 + press * 5, width: width, height: 70)
                rrect(r.offsetBy(dx: 0, dy: 7 - press * 5), 14, rgb(0, 0, 0, 0.3))
                rrect(r, 14, press > 0.5 ? blue : rgb(38, 40, 48))
                text(label, font(28, .semibold), .white, x: r.minX, y: r.minY + 17, w: width, align: .center)
                x += width + 12
            }
        }
    }
}

// ── 자막 (화면 기준) ──
let captions: [(Double, Double, String)] = [
    (0.3, 2.3, "Claude · ChatGPT에 질문을 보내고"),
    (2.6, 5.3, "답을 기다리는 몇 초에 한 문제"),
    (5.6, 8.3, "바로 채점하고 해설까지"),
    (8.6, 10.4, "답이 오면 알아서 접힙니다"),
    (11.0, 14.9, "25과목 2,800문항 · 시험 범위만 골라서"),
    (15.4, 18.6, "크롬에서도 똑같이 (claude.ai · chatgpt.com)"),
    (18.9, 21.3, "Alt+O · Alt+X로 바로 답하기"),
]

func drawCaption(_ t: Double) {
    for (a, b, s) in captions where t >= a && t <= b {
        let alpha = prog(t, a, a + 0.25) * (1 - prog(t, b - 0.25, b))
        withAlpha(alpha) {
            let f = font(46, .bold)
            let w = textWidth(s, f) + 72
            rrect(NSRect(x: (CGFloat(W) - w) / 2, y: 954, width: w, height: 84), 42, rgb(16, 18, 26, 0.82))
            text(s, f, .white, x: 0, y: 967, w: CGFloat(W), align: .center)
        }
    }
}

// ── 마무리 화면 ──
func drawEnd(_ t: Double) {
    let p = ease(prog(t, tEnd, tEnd + 0.5))
    guard p > 0 else { return }
    withAlpha(p) {
        NSGradient(colors: [rgb(58, 66, 100), rgb(34, 38, 60)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
        let rise = (1 - easeOut(prog(t, tEnd, tEnd + 0.7))) * 24
        drawImage(appIcon, in: CGRect(x: 960 - 110, y: 190 + rise, width: 220, height: 220))
        text("Loading Dose", font(96, .bold), .white, x: 0, y: 450 + rise, w: CGFloat(W), align: .center)
        text("로딩 중에 한 문제씩", font(46, .medium), rgb(200, 204, 216), x: 0, y: 584 + rise, w: CGFloat(W), align: .center)
        text("Claude · ChatGPT용   |   Mac 앱 · 크롬 확장   |   테스트 버전", font(30), rgb(176, 182, 200),
             x: 0, y: 700 + rise, w: CGFloat(W), align: .center)
        text("국시 대비 O/X 2,800문항 · 기초부터 임상까지 25과목 · 내 Anki 덱 연결", font(30), rgb(176, 182, 200),
             x: 0, y: 750 + rise, w: CGFloat(W), align: .center)
    }
}

func drawFrame(_ t: Double) {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    let (cx, cy, z) = camera(t)
    cg.saveGState()
    cg.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
    cg.scaleBy(x: z, y: z)
    cg.translateBy(x: -cx, y: -cy)
    if t < tWin + 0.4 {
        drawMacDesktop(t)
        drawCard(t, flowMac, quizMac, centerX: CGFloat(W) / 2, top: 46, today: 12)
        drawSettingsWindow(t)
        drawMacCursor(t)
    }
    if t >= tWin {
        withAlpha(ease(prog(t, tWin, tWin + 0.4))) { drawWinDesktop(t) }
    }
    cg.restoreGState()
    drawCaption(t)
    drawEnd(t)
}

// ── 프레임 → 픽셀 버퍼 ──
func render(_ t: Double, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8,
                             bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    cg.translateBy(x: 0, y: CGFloat(H))
    cg.scaleBy(x: 1, y: -1)
    let ns = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    drawFrame(t)
    NSGraphicsContext.restoreGraphicsState()
}

func makeBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA, attrs, &pb)
    return pb!
}

// ── 실행 ──
let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: demo out.mp4 icon.png settings.png [t1,t2,...] [pngdir]"); exit(1) }
let outURL = URL(fileURLWithPath: args[1])
appIcon = NSImage(contentsOfFile: args[2])
settingsShot = NSImage(contentsOfFile: args[3])

if args.count >= 6 {
    // 확인용 정지 화면
    for s in args[4].split(separator: ",") {
        guard let t = Double(s) else { continue }
        let pb = makeBuffer()
        render(t, into: pb)
        let rep = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: pb))
        let url = URL(fileURLWithPath: args[5]).appendingPathComponent(String(format: "f%05.2f.png", t))
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    exit(0)
}

try? FileManager.default.removeItem(at: outURL)
let writer = try! AVAssetWriter(outputURL: outURL, fileType: .mp4)
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_500_000,
                                      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel] as [String: Any],
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
guard writer.startWriting() else { print("writer failed:", writer.error ?? "?"); exit(1) }
writer.startSession(atSourceTime: .zero)

let frames = Int(DURATION * Double(FPS))
for i in 0..<frames {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    let pb = makeBuffer()
    render(Double(i) / Double(FPS), into: pb)
    if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS))) {
        print("append failed at", i, writer.error ?? "?"); exit(1)
    }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print(writer.status == .completed ? "ok \(frames) frames" : "failed: \(String(describing: writer.error))")

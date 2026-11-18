// 일정 알림: Mac 캘린더의 일정이 곧 시작하면 펫이 달력을 들고 한 줄로 알려 준다.
// 기본은 꺼져 있고 메뉴에서 켠다. 켤 때 macOS 가 캘린더 접근을 허용할지 묻는다.
// 일정 제목은 화면에 보여 주기만 하고, 기록 파일에 남기거나 밖으로 보내지 않는다.
import Cocoa
import EventKit

var calendarLeadMinutes = 10.0     // 일정 시작 몇 분 전에 알릴지 (config.json 의 "calendarLeadMinutes")

final class CalendarWatch {
    private static let defaultsKey = "calendarOn"
    static var enabled: Bool {
        get { return UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private let pet: Pet
    private let store = EKEventStore()
    private var timer: Timer?
    private var notified = Set<String>()     // 이미 알린 일정 (일정 ID + 시작 시각)

    init(pet: Pet) { self.pet = pet }

    var authorized: Bool {
        // 이 빌드 도구(macOS 13 SDK)에는 macOS 14 의 새 이름(.fullAccess)이 없어 숫자로 비교한다.
        // 3 = 읽기까지 허용(예전 .authorized, 새 .fullAccess). 쓰기 전용(4)은 읽을 수 없으니 제외한다.
        return EKEventStore.authorizationStatus(for: .event).rawValue == 3
    }

    func requestAccess(done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { done(ok) } }
        store.requestAccess(to: .event, completion: finish)
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
    }

    func check() {
        guard CalendarWatch.enabled, authorized else { return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(calendarLeadMinutes * 60), calendars: nil)
        let soon = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
        for e in soon {
            let key = (e.eventIdentifier ?? "") + "|" + String(Int(e.startDate.timeIntervalSince1970))
            if notified.contains(key) { continue }
            let mins = max(1, Int((e.startDate.timeIntervalSince(now) / 60).rounded()))
            let title = (e.title ?? "").isEmpty ? "일정" : e.title!
            // 펫이 지금 나설 수 없으면(카드 옆 등) 다음 확인 때 다시 시도한다.
            if pet.announce("\(mins)분 뒤 · \(title.prefix(20))") {
                notified.insert(key)
                Log.write("일정 알림을 보여 줌 (\(mins)분 전)")
            }
            break
        }
    }
}

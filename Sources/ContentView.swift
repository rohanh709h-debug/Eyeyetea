import SwiftUI
import UserNotifications

/// Lets banners/sounds show even while the app is open.
final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct ContentView: View {
    @AppStorage("startedAt") private var startedAt: Double = 0   // 0 = stopped
    @AppStorage("workMin") private var workMin: Int = 20
    @AppStorage("restSec") private var restSec: Int = 20
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var wasRest = false
    @State private var notifDenied = false
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var running: Bool { startedAt > 0 }
    private var work: TimeInterval { Double(workMin) * 60 }
    private var rest: TimeInterval { Double(restSec) }
    private var cycle: TimeInterval { work + rest }

    private var phase: (isRest: Bool, remaining: TimeInterval, total: TimeInterval) {
        guard running else { return (false, work, work) }
        let elapsed = max(0, now.timeIntervalSince1970 - startedAt)
        let pos = elapsed.truncatingRemainder(dividingBy: cycle)
        return pos < work ? (false, work - pos, work) : (true, cycle - pos, rest)
    }

    var body: some View {
        let p = phase
        VStack(spacing: 36) {
            Spacer()

            Text(running ? (p.isRest ? "LOOK AWAY" : "FOCUS") : "READY")
                .font(.system(size: 13, weight: .medium))
                .tracking(4)
                .foregroundStyle(.secondary)

            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: running ? 1 - p.remaining / p.total : 0)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: p.remaining)
                Text(format(p.remaining))
                    .font(.system(size: 60, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 260, height: 260)

            Text(running && p.isRest ? "Focus on something 20 feet away"
                                     : "\(workMin) min · 20 ft · \(restSec) sec")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            if !running {
                VStack(spacing: 12) {
                    row("Focus", "\(workMin) min", $workMin, 1...120, 1)
                    row("Break", "\(restSec) sec", $restSec, 5...300, 5)
                }
                .padding(.horizontal, 48)
            }

            if notifDenied {
                Text("Notifications are off. Enable them in Settings › 20-20-20.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            }

            Spacer()

            Button(action: toggle) {
                Text(running ? "Stop" : "Start")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 48)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            UNUserNotificationCenter.current().delegate = NotifDelegate.shared
            refreshAuth()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                refreshAuth()
                if running { schedule() }   // top up the 64-notification window
            }
        }
        .onReceive(tick) { date in
            now = date
            let r = phase.isRest
            if running && r != wasRest { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            wasRest = r
        }
    }

    private func row(_ title: String, _ valueText: String, _ value: Binding<Int>,
                     _ range: ClosedRange<Int>, _ step: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(valueText).monospacedDigit()
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
        .font(.system(size: 15))
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(ceil(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func refreshAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifDenied = (s.authorizationStatus == .denied) }
        }
    }

    private func toggle() {
        let center = UNUserNotificationCenter.current()
        if running {
            startedAt = 0
            center.removeAllPendingNotificationRequests()
        } else {
            startedAt = Date().timeIntervalSince1970
            wasRest = false
            schedule()
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                DispatchQueue.main.async { refreshAuth() }
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Schedules the next 60 alerts (iOS keeps max 64 pending per app).
    private func schedule() {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        let t0 = Date().timeIntervalSince1970
        var count = 0, k = 0
        while count < 60 && k < 2000 {
            let base = startedAt + Double(k) * cycle
            let lookIn = base + work - t0
            let backIn = base + cycle - t0
            if lookIn > 1 {
                add(c, "w\(k)", lookIn, "Look away",
                    "Look at something 20 feet away for \(restSec) seconds.")
                count += 1
            }
            if backIn > 1 {
                add(c, "b\(k)", backIn, "Break over", "Back to work.")
                count += 1
            }
            k += 1
        }
    }

    private func add(_ c: UNUserNotificationCenter, _ id: String, _ after: TimeInterval,
                     _ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false)
        c.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

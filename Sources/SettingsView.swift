import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var state = AppState.shared
    @State private var trusted = AppState.shared.guardService.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Familiar").font(.headline)
                    Text("Окно Safari не закроется на последней вкладке")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Включить Familiar", isOn: $state.isEnabled)
            Toggle("Запускать при входе в систему", isOn: $state.launchAtLogin)

            Divider()

            // Горячая клавиша для переключения профилей Safari по кругу.
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Переключение профиля Safari").font(.callout)
                    Text("Хоткей переключает профили по кругу")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HotKeyRecorder(combo: $state.profileHotKey)
            }

            // Статус разрешения Accessibility
            HStack(spacing: 8) {
                Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? .green : .orange)
                Text(trusted ? "Доступ к Универсальному доступу выдан"
                             : "Нужен доступ в «Универсальный доступ»")
                    .font(.callout)
                Spacer()
                if !trusted {
                    Button("Выдать…") {
                        state.guardService.requestAccessibility()
                        refreshTrust()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrust()
        }
    }

    private func refreshTrust() {
        trusted = state.guardService.isTrusted
    }
}

/// Поле-рекордер горячей клавиши: по нажатию ловит следующую комбинацию.
struct HotKeyRecorder: View {
    @Binding var combo: HotKey.Combo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(title) { toggle() }
                .frame(minWidth: 110)
            if combo != nil && !recording {
                Button { combo = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Убрать хоткей")
            }
        }
    }

    private var title: String {
        if recording { return "Нажмите клавиши…" }
        return combo?.display ?? "Назначить…"
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // глушим клавишу, пока записываем
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }   // Escape — отмена записи
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = HotKey.carbonModifiers(from: flags)
        guard carbon != 0 else { return }   // нужен хотя бы один модификатор
        combo = HotKey.Combo(
            keyCode: UInt32(event.keyCode),
            modifiers: carbon,
            display: glyphs(flags) + keyName(event))
        stop()
    }

    private func glyphs(_ f: NSEvent.ModifierFlags) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s
    }

    private func keyName(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let s = special[event.keyCode] { return s }
        if let c = event.charactersIgnoringModifiers, !c.isEmpty { return c.uppercased() }
        return "key\(event.keyCode)"
    }
}

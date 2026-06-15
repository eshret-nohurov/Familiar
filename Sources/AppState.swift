import Foundation
import ServiceManagement

/// Состояние приложения + сохранение настроек. Единый источник правды для меню и окна настроек.
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard
    let guardService = TabGuard()
    private let profileSwitcher = ProfileSwitcher()
    private lazy var hotKey = HotKey { [weak self] in self?.profileSwitcher.cycleToNext() }
    private var timer: Timer?

    /// Включён ли перехват ⌘W (желание пользователя).
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.isEnabled)
            refresh()
        }
    }

    /// Запускать ли Familiar при входе в систему.
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Реально работает: включён И права Accessibility выданы И tap поднят.
    @Published private(set) var isActive = false

    /// Глобальная комбинация для циклического переключения профилей Safari (nil — не задана).
    @Published var profileHotKey: HotKey.Combo? {
        didSet { applyHotKey() }
    }

    private enum Keys {
        static let isEnabled = "isEnabled"
        static let hotKeyCode = "profileHotKeyCode"
        static let hotKeyMods = "profileHotKeyMods"
        static let hotKeyText = "profileHotKeyDisplay"
    }

    private init() {
        isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        if let code = defaults.object(forKey: Keys.hotKeyCode) as? Int {
            profileHotKey = HotKey.Combo(
                keyCode: UInt32(code),
                modifiers: UInt32(defaults.integer(forKey: Keys.hotKeyMods)),
                display: defaults.string(forKey: Keys.hotKeyText) ?? "")
        }
    }

    /// Запустить наблюдение: один раз спросить права и далее поддерживать tap в нужном состоянии.
    func startMonitoring() {
        if isEnabled && !guardService.isTrusted {
            guardService.requestAccessibility()   // системный промпт (показывается один раз)
        }
        refresh()
        applyHotKey()   // didSet не срабатывает при инициализации — регистрируем сохранённую комбинацию
        // Подхватываем выдачу/отзыв прав без перезапуска приложения.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Переключить профиль Safari немедленно (пункт меню / для отладки).
    func switchProfileNow() { profileSwitcher.cycleToNext() }

    private func applyHotKey() {
        guard let combo = profileHotKey else {
            hotKey.unregister()
            defaults.removeObject(forKey: Keys.hotKeyCode)
            defaults.removeObject(forKey: Keys.hotKeyMods)
            defaults.removeObject(forKey: Keys.hotKeyText)
            return
        }
        defaults.set(Int(combo.keyCode), forKey: Keys.hotKeyCode)
        defaults.set(Int(combo.modifiers), forKey: Keys.hotKeyMods)
        defaults.set(combo.display, forKey: Keys.hotKeyText)
        hotKey.register(combo)
    }

    private func refresh() {
        guardService.sync(enabled: isEnabled)
        let active = isEnabled && guardService.isRunning
        if active != isActive { isActive = active }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Familiar: ошибка автозапуска — \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.launchAtLogin = (SMAppService.mainApp.status == .enabled)
            }
        }
    }
}

import AppKit
import ApplicationServices

/// Циклическое переключение профилей Safari.
///
/// Профили не представлены в AppleScript-словаре Safari, поэтому работаем напрямую
/// через Accessibility API (те же права, что нужны для перехвата ⌘W):
///   - текущий профиль читаем из AXIdentifier кнопки-переключателя в тулбаре
///     («TabGroupPickerButton?Profile=<name>&…»);
///   - список профилей по порядку — из пунктов меню «New <Profile> Window»
///     (их AXIdentifier — «New<Name>Window?isDefaultProfile=…»; у Private его нет).
/// «Переключиться» = поднять существующее окно профиля (AXRaise), а если его нет —
/// открыть новое окно этого профиля (AXPress пункта меню).
final class ProfileSwitcher {
    private let safariBundleID = "com.apple.Safari"

    // Чтение/нажатие UI делаем не на главном потоке, чтобы не подвешивать обработчик хоткея.
    private let queue = DispatchQueue(label: "com.eshret.Familiar.profiles")

    /// Имена AX-атрибутов и действий заданы строками: это стабильные константы
    /// Accessibility, и так не зависим от наличия именованных констант в SDK.
    private enum AX {
        static let children = "AXChildren"
        static let role = "AXRole"
        static let identifier = "AXIdentifier"
        static let menuBar = "AXMenuBar"
        static let windows = "AXWindows"
        static let mainWindow = "AXMainWindow"
        static let focusedWindow = "AXFocusedWindow"
        static let toolbar = "AXToolbar"
        static let raise = "AXRaise"
        static let press = "AXPress"
    }

    /// Переключиться на следующий профиль по кругу.
    func cycleToNext() {
        queue.async { [weak self] in self?.run() }
    }

    private func run() {
        guard let safari = NSRunningApplication
            .runningApplications(withBundleIdentifier: safariBundleID).first else { return }
        let app = AXUIElementCreateApplication(safari.processIdentifier)

        let profiles = profileOrder(app: app)
        guard profiles.count > 1 else { return }   // переключать нечего

        let current = currentProfile(app: app)
        let target: String
        if let current, let i = profiles.firstIndex(of: current) {
            target = profiles[(i + 1) % profiles.count]
        } else {
            target = profiles[0]
        }
        guard target != current else { return }

        // Активируем Safari ПЕРЕД переупорядочиванием окон: если активировать после
        // AXRaise, система вернёт вперёд последнее активное окно и отменит подъём.
        DispatchQueue.main.sync { safari.activate() }
        usleep(150_000)

        if !raiseWindow(ofProfile: target, app: app) {
            openWindow(ofProfile: target, app: app)
        }
    }

    // MARK: - Чтение состояния

    private func currentProfile(app: AXUIElement) -> String? {
        guard let win = mainWindow(app: app),
              let btn = profileButton(in: win) else { return nil }
        return queryValue("Profile", in: identifier(btn))
    }

    /// Профили в порядке, заданном в Safari, по пунктам «New <Profile> Window».
    private func profileOrder(app: AXUIElement) -> [String] {
        guard let menuBar = element(app, AX.menuBar) else { return [] }
        var result: [String] = []
        for barItem in children(menuBar) {                  // строки меню (File, Edit, …)
            guard let menu = children(barItem).first else { continue }   // AXMenu
            for entry in children(menu) {
                if let name = profileName(fromMenuItemID: identifier(entry)),
                   !result.contains(name) {
                    result.append(name)
                }
            }
        }
        return result
    }

    // MARK: - Действия

    private func raiseWindow(ofProfile profile: String, app: AXUIElement) -> Bool {
        for win in windows(app: app) {
            guard let btn = profileButton(in: win),
                  queryValue("Profile", in: identifier(btn)) == profile else { continue }
            AXUIElementPerformAction(win, AX.raise as CFString)
            return true
        }
        return false
    }

    /// Открыть новое окно профиля через пункт меню «New <Profile> Window».
    /// Сначала раскрываем родительскую строку меню — иначе AXPress пункта не сработает.
    private func openWindow(ofProfile profile: String, app: AXUIElement) {
        guard let menuBar = element(app, AX.menuBar) else { return }
        for barItem in children(menuBar) {
            guard let menu = children(barItem).first else { continue }
            for entry in children(menu) {
                if profileName(fromMenuItemID: identifier(entry)) == profile {
                    AXUIElementPerformAction(barItem, AX.press as CFString)   // открыть меню
                    usleep(60_000)
                    AXUIElementPerformAction(entry, AX.press as CFString)     // выбрать пункт
                    return
                }
            }
        }
    }

    // MARK: - Парсинг идентификаторов

    /// «New<Name>Window?isDefaultProfile=…» → «Name». Без isDefaultProfile (Private) → nil.
    private func profileName(fromMenuItemID id: String) -> String? {
        guard let q = id.firstIndex(of: "?") else { return nil }
        let head = String(id[id.startIndex..<q])
        let query = id[id.index(after: q)...]
        guard query.hasPrefix("isDefaultProfile"),
              head.hasPrefix("New"), head.hasSuffix("Window") else { return nil }
        let name = head.dropFirst("New".count).dropLast("Window".count)
        return name.isEmpty ? nil : String(name)
    }

    /// Значение параметра query-строки внутри AXIdentifier, например «Profile» в
    /// «TabGroupPickerButton?Profile=work&Icon=curlybraces».
    private func queryValue(_ key: String, in id: String) -> String? {
        guard let q = id.firstIndex(of: "?") else { return nil }
        for pair in id[id.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key { return String(kv[1]) }
        }
        return nil
    }

    // MARK: - Навигация по AX-дереву

    private func mainWindow(app: AXUIElement) -> AXUIElement? {
        element(app, AX.mainWindow) ?? element(app, AX.focusedWindow) ?? windows(app: app).first
    }

    private func windows(app: AXUIElement) -> [AXUIElement] {
        (value(app, AX.windows) as? [AXUIElement]) ?? []
    }

    private func profileButton(in window: AXUIElement) -> AXUIElement? {
        guard let toolbar = children(window).first(where: { role($0) == AX.toolbar })
        else { return nil }
        return children(toolbar).first { identifier($0).hasPrefix("TabGroupPickerButton") }
    }

    // MARK: - AX-обёртки

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, AX.children) as? [AXUIElement]) ?? []
    }

    private func role(_ el: AXUIElement) -> String { (value(el, AX.role) as? String) ?? "" }

    private func identifier(_ el: AXUIElement) -> String { (value(el, AX.identifier) as? String) ?? "" }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var out: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success ? out : nil
    }
}

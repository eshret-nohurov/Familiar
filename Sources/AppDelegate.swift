import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let state = AppState.shared
    private var cancellable: AnyCancellable?

    private var statusInfoItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    // MARK: - Жизненный цикл

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        state.startMonitoring()

        // Иконка в строке меню отражает реальный статус (вкл + права).
        cancellable = state.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
    }

    // MARK: - Иконка в строке меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self

        statusInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)
        menu.addItem(.separator())

        enabledItem = menu.addItem(withTitle: "Включено", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        loginItem = menu.addItem(withTitle: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        let switchItem = menu.addItem(withTitle: "Переключить профиль Safari", action: #selector(switchProfile), keyEquivalent: "")
        switchItem.target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        // target = NSApp: terminate: реализует приложение, а не AppDelegate,
        // иначе пункт становится серым (невалидным).
        let quit = menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let active = state.isActive
        let symbol = "wand.and.stars"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Familiar")
        image?.isTemplate = true
        button.image = image
        button.alphaValue = active ? 1.0 : 0.45
        button.toolTip = statusText()
    }

    private func statusText() -> String {
        if state.isActive { return "Familiar активен" }
        if state.isEnabled { return "Familiar: нет доступа в «Универсальный доступ»" }
        return "Familiar выключен"
    }

    /// Синхронизируем меню перед открытием.
    func menuWillOpen(_ menu: NSMenu) {
        statusInfoItem.title = statusText()
        enabledItem.state = state.isEnabled ? .on : .off
        loginItem.state = state.launchAtLogin ? .on : .off
    }

    // MARK: - Действия меню

    @objc private func toggleEnabled() { state.isEnabled.toggle() }

    @objc private func toggleLogin() { state.launchAtLogin.toggle() }

    @objc private func switchProfile() { state.switchProfileNow() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Настройки Familiar"
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

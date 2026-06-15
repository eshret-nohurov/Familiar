import Cocoa
import Carbon.HIToolbox   // kVK_ANSI_W

/// Перехват ⌘W в Safari и логика «не закрывать окно на последней вкладке».
///
/// Важно: event tap создаётся ТОЛЬКО когда выданы права Accessibility.
/// Tap, созданный без прав, существует, но не получает события («немой»),
/// поэтому мы ждём прав и пересоздаём tap, как только они появляются.
final class TabGuard {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wasTrusted = false
    private let safariBundleID = "com.apple.Safari"

    private(set) var isRunning = false

    /// Выданы ли права Accessibility.
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показать системный запрос на доступ Accessibility.
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Приводит tap в соответствие с желаемым состоянием.
    /// Вызывать при старте, периодически по таймеру и при смене настройки.
    func sync(enabled: Bool) {
        let trusted = isTrusted
        if enabled && trusted {
            // Создаём tap только при наличии прав; если права появились
            // только что — пересоздаём, чтобы tap гарантированно «слышал» события.
            if !isRunning || !wasTrusted { restart() }
        } else if isRunning {
            stop()
        }
        wasTrusted = trusted
    }

    // MARK: - Жизненный цикл tap

    private func restart() { stop(); start() }

    @discardableResult
    private func start() -> Bool {
        guard !isRunning else { return true }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<TabGuard>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Familiar: не удалось создать event tap")
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = src
        isRunning = true
        NSLog("Familiar: event tap активен")
        return true
    }

    private func stop() {
        guard isRunning, let tap, let runLoopSource else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
        isRunning = false
    }

    // MARK: - Обработка событий

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Система может отключить tap при «тормозном» callback — переподнимаем.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              Int(event.getIntegerValueField(.keyboardEventKeycode)) == kVK_ANSI_W
        else { return Unmanaged.passUnretained(event) }

        // Только «чистый» ⌘W (не трогаем ⇧⌘W — закрыть окно, ⌥⌘W и пр.).
        let f = event.flags
        guard f.contains(.maskCommand),
              !f.contains(.maskShift),
              !f.contains(.maskAlternate),
              !f.contains(.maskControl)
        else { return Unmanaged.passUnretained(event) }

        // Только когда Safari — активное приложение.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariBundleID
        else { return Unmanaged.passUnretained(event) }

        closeTabKeepingWindow()
        return nil   // гасим ⌘W — закрытием управляем сами
    }

    // MARK: - Управление вкладками Safari

    // Отдельная очередь: AppleScript умеет ждать создания вкладки, не блокируя
    // главный поток (на нём работает event tap).
    private let scriptQueue = DispatchQueue(label: "com.eshret.Familiar.applescript")

    /// Вызывается после перехвата ⌘W: закрыть текущую вкладку, не дав закрыться окну.
    private func closeTabKeepingWindow() {
        scriptQueue.async {
            let count = Self.run(Self.countSource)?.int32Value ?? 0
            guard count > 0 else { return }            // окон нет — ничего не делаем
            if count > 1 {
                Self.run(Self.closeCurrentSource)      // обычное закрытие вкладки
            } else {
                self.postCommandT()                    // открыть новую вкладку = Start Page
                Self.run(Self.closeOldTabSource)       // дождаться её и закрыть прежнюю
            }
        }
    }

    /// Синтез ⌘T — Safari открывает новую вкладку согласно настройке
    /// «В новых вкладках открывать» (Стартовая страница и т.п.).
    private func postCommandT() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_T)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err { NSLog("Familiar: AppleScript error \(err)"); return nil }
        return result
    }

    private static let countSource = """
    tell application "Safari"
        if (count of windows) is 0 then return 0
        return count of tabs of front window
    end tell
    """

    private static let closeCurrentSource = """
    tell application "Safari" to close current tab of front window
    """

    // Ждём появления новой вкладки (после ⌘T), затем закрываем все, кроме текущей
    // (текущая — новая Start Page). Идём с конца, чтобы не сбить индексы.
    private static let closeOldTabSource = """
    tell application "Safari"
        set w to front window
        repeat 30 times
            if (count of tabs of w) > 1 then exit repeat
            delay 0.02
        end repeat
        set cur to current tab of w
        repeat with i from (count of tabs of w) to 1 by -1
            if (tab i of w) is not cur then close (tab i of w)
        end repeat
    end tell
    """
}

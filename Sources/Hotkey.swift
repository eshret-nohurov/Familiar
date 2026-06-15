import AppKit
import Carbon.HIToolbox

/// Глобальный горячий ключ через Carbon `RegisterEventHotKey`.
///
/// Системный и не требует Accessibility — права нужны только действию, которое он
/// запускает (переключение профиля Safari). Поддерживается одна комбинация за раз.
final class HotKey {
    /// Комбинация: виртуальный keyCode (как у kVK_*) + Carbon-модификаторы (cmdKey | …).
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String     // например «⌥⌘P» — для отображения в настройках
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id = EventHotKeyID(signature: 0x50454B31 /* 'PEK1' */, id: 1)

    init(action: @escaping () -> Void) { self.action = action }

    var isRegistered: Bool { ref != nil }

    /// Регистрирует комбинацию. Возвращает false, если ключ уже занят другим приложением.
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        unregister()
        installHandler()
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, id,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            NSLog("Familiar: не удалось зарегистрировать хоткей (OSStatus \(status))")
            ref = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
    }

    /// Carbon-обработчик ставим один раз и держим до конца жизни объекта.
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
                me.action()
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Перевод модификаторов AppKit → Carbon (для `RegisterEventHotKey`).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }
}

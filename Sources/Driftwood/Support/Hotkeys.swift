import AppKit
import Carbon.HIToolbox

/// A parsed global-hotkey binding: keyCode + Carbon modifier mask.
struct HotkeySpec {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Parse "modifier+modifier+key" (e.g. "control+option+t", "cmd+shift+k").
    /// Returns nil for empty / "none" / "disabled" / malformed strings.
    init?(_ string: String) {
        let raw = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty, raw != "none", raw != "disabled" else { return nil }

        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods: UInt32 = 0
        var key: UInt32?

        for part in parts {
            if let m = Self.modifierMap[part] {
                mods |= m
            } else if let k = Self.keyMap[part] {
                if key != nil { return nil }
                key = k
            } else {
                return nil
            }
        }

        guard let k = key else { return nil }
        // At least one of ⌃⌥⌘. A registered hotkey *consumes* the keystroke
        // system-wide, so "space" or "a" would kill that key in every
        // application for as long as Driftwood runs. Shift doesn't count on
        // its own — "shift+a" is just A — but is fine alongside another.
        guard mods & Self.requiredModifiers != 0 else { return nil }
        keyCode = k
        modifiers = mods
    }

    private static let requiredModifiers = UInt32(controlKey | optionKey | cmdKey)

    /// "control+option+t" → "⌃⌥T", for UI hints. Nil when the binding is
    /// empty, disabled, or malformed. Modifiers render in the macOS
    /// convention order ⌃⌥⇧⌘ regardless of how the string spells them.
    static func display(_ string: String) -> String? {
        guard Self(string) != nil else { return nil }
        let parts = string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let order: [(names: Set<String>, symbol: String)] = [
            (["control", "ctrl"], "⌃"), (["option", "alt"], "⌥"),
            (["shift"], "⇧"), (["command", "cmd"], "⌘"),
        ]
        var out = ""
        for (names, symbol) in order where parts.contains(where: names.contains) {
            out += symbol
        }
        for part in parts where modifierMap[part] == nil {
            out += keyLabels[part] ?? part.uppercased()
        }
        return out
    }

    private static let keyLabels: [String: String] = [
        "space": "Space", "tab": "⇥", "return": "↩", "enter": "↩",
        "escape": "⎋", "esc": "⎋", "delete": "⌫", "backspace": "⌫",
    ]

    /// The `NSMenuItem` representation of the binding. Display-only — the real
    /// hotkey is Carbon-registered — but derived from the *same parse*, so the
    /// menu can never show a key equivalent that no registered hotkey backs,
    /// or hide one that works. (Chestnut's pet window used to tokenize the
    /// string itself with its own tables; the grammars drifted — its parser
    /// took "shift+a", which Carbon registration refuses, and rejected "f1",
    /// which it accepts.)
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let key = Self.keyEquivalents[keyCode] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return (key, flags)
    }

    /// keyCode → NSMenuItem `keyEquivalent` string: the reverse of `keyMap`,
    /// built from it so a key can't exist in one direction only.
    private static let keyEquivalents: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        // Letters and digits are their own equivalents.
        for (name, code) in keyMap where name.count == 1 { m[code] = name }
        m[UInt32(kVK_Space)] = " "
        m[UInt32(kVK_Tab)] = "\t"
        m[UInt32(kVK_Return)] = "\r"
        m[UInt32(kVK_Escape)] = "\u{1B}"
        m[UInt32(kVK_Delete)] = "\u{08}"
        // NSMenuItem draws function keys via the Unicode function-key scalars.
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                     kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in fkeys.enumerated() {
            m[UInt32(code)] = String(UnicodeScalar(NSF1FunctionKey + index)!)
        }
        return m
    }()

    private static let modifierMap: [String: UInt32] = [
        "control": UInt32(controlKey),
        "ctrl": UInt32(controlKey),
        "option": UInt32(optionKey),
        "alt": UInt32(optionKey),
        "command": UInt32(cmdKey),
        "cmd": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
    ]

    private static let keyMap: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B),
            "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
            "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
            "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J),
            "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N),
            "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
            "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
            "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V),
            "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
            "space": UInt32(kVK_Space),
            "tab": UInt32(kVK_Tab),
            "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
            "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
        ]
        let fkeys: [(String, Int)] = [
            ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
            ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ]
        for (name, code) in fkeys { m[name] = UInt32(code) }
        return m
    }()
}

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Unlike an `NSEvent` global monitor this needs **no Accessibility
/// permission** — which is most of why Driftwood needs no TCC grant at all,
/// and why there is no certificate-pinning install script here the way there
/// is in Starboard. The Carbon dispatcher delivers hotkey events on the main
/// thread.
@MainActor
final class HotkeyCenter {
    var onToggle: (() -> Void)?
    var onFocus: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onCommands: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Fired when a quick command's own hotkey is pressed, with that command's
    /// id. One closure rather than one per command: the set of commands comes
    /// from the config and is not known when this class is written.
    var onQuickCommand: ((String) -> Void)?

    private var registeredKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Carbon hotkey id → quick command id, for the ids allocated above
    /// `firstQuickCommandID`.
    private var quickCommandIDs: [UInt32: String] = [:]

    /// `"DRFT"`. The signature scopes hotkey ids to this app, so the dispatch
    /// switch can trust that an id it recognizes is one it registered.
    private static let signature = OSType(0x4452_4654)
    private static let toggleID: UInt32 = 1
    private static let focusID: UInt32 = 2
    private static let newTabID: UInt32 = 3
    private static let commandsID: UInt32 = 4
    private static let quitID: UInt32 = 5
    /// Quick commands take ids from here up, so adding an app binding above
    /// never renumbers them.
    private static let firstQuickCommandID: UInt32 = 100

    func start(config: HotkeyConfig, quickCommands: [QuickCommand]) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    center.dispatch(hotKeyID)
                }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        // `RegisterEventHotKey` does not depend on the handler having
        // installed — it returns `noErr` either way — so without this check a
        // failed install would leave every binding claimed system-wide and
        // none of them dispatching: ⌃⌥T dead in Driftwood *and* in every other
        // app, with nothing said anywhere. Registering nothing is strictly
        // better than registering keys that can't fire, hence the early
        // return: at least the keystrokes stay available to whatever else
        // wants them.
        guard status == noErr else {
            NSLog(
                "HotkeyCenter: event handler install failed (OSStatus %d); no hotkey can fire",
                status
            )
            return
        }

        register(config.toggle, id: Self.toggleID, label: "toggle")
        register(config.focus, id: Self.focusID, label: "focus")
        register(config.newTab, id: Self.newTabID, label: "newTab")
        register(config.commands, id: Self.commandsID, label: "commands")
        register(config.quit, id: Self.quitID, label: "quit")

        for (offset, command) in quickCommands.enumerated() {
            guard let binding = command.hotkey else { continue }
            let id = Self.firstQuickCommandID + UInt32(offset)
            quickCommandIDs[id] = command.id
            register(binding, id: id, label: "quick command \"\(command.id)\"")
        }
    }

    /// True for the strings that mean "no hotkey, on purpose" — the same set
    /// `HotkeySpec.init` maps to nil deliberately rather than by rejection.
    private static func isOptedOut(_ binding: String) -> Bool {
        QuickCommands.isOptedOut(binding)
    }

    /// Give every registered key back to the system while an `NSMenu` tracks,
    /// and take them again when it closes.
    ///
    /// `RegisterEventHotKey` *consumes* the keystroke, and while a menu tracks,
    /// its nested run loop doesn't dispatch our Carbon handler — so presses are
    /// captured, queued, and delivered the instant tracking ends. Left
    /// registered, pressing the summon hotkey while the right-click menu is
    /// open does nothing visible and then fires the moment Esc dismisses the
    /// menu, once per press. Idempotent in both directions.
    func setEnabled(_ enabled: Bool, config: HotkeyConfig, quickCommands: [QuickCommand]) {
        if enabled {
            guard registeredKeys.isEmpty, handler != nil else { return }
            register(config.toggle, id: Self.toggleID, label: "toggle")
            register(config.focus, id: Self.focusID, label: "focus")
            register(config.newTab, id: Self.newTabID, label: "newTab")
            register(config.commands, id: Self.commandsID, label: "commands")
            register(config.quit, id: Self.quitID, label: "quit")
            for (id, commandID) in quickCommandIDs {
                guard let binding = quickCommands.first(where: { $0.id == commandID })?.hotkey
                else { continue }
                register(binding, id: id, label: "quick command \"\(commandID)\"")
            }
        } else {
            for (_, ref) in registeredKeys { UnregisterEventHotKey(ref) }
            registeredKeys.removeAll()
        }
    }

    func stop() {
        for (_, ref) in registeredKeys { UnregisterEventHotKey(ref) }
        registeredKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(_ binding: String, id: UInt32, label: String) {
        guard let spec = HotkeySpec(binding) else {
            if !Self.isOptedOut(binding) {
                NSLog("HotkeyCenter: invalid %@ hotkey \"%@\"", label, binding)
                DebugLog.log("hotkey: \(label) binding \"\(binding)\" did not parse")
            }
            return
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers,
            hotKeyID, GetEventDispatcherTarget(), 0, &ref
        )
        if status != noErr {
            NSLog("HotkeyCenter: could not register %@ hotkey (OSStatus %d)", label, status)
            DebugLog.log("hotkey: register \(label) FAILED (OSStatus \(status))")
        } else if let ref {
            registeredKeys[id] = ref
            DebugLog.log("hotkey: registered \(label) (keyCode=\(spec.keyCode), mods=\(spec.modifiers))")
        }
    }

    private func dispatch(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        switch id.id {
        case Self.toggleID:
            DebugLog.log("hotkey: dispatched toggle")
            onToggle?()
        case Self.focusID:
            DebugLog.log("hotkey: dispatched focus")
            onFocus?()
        case Self.newTabID:
            DebugLog.log("hotkey: dispatched newTab")
            onNewTab?()
        case Self.commandsID:
            DebugLog.log("hotkey: dispatched commands")
            onCommands?()
        case Self.quitID:
            DebugLog.log("hotkey: dispatched quit")
            onQuit?()
        default:
            guard let commandID = quickCommandIDs[id.id] else { return }
            DebugLog.log("hotkey: dispatched quick command \(commandID)")
            onQuickCommand?(commandID)
        }
    }
}

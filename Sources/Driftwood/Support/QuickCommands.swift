import Foundation

/// One saved command, as it appears in `config.json`.
struct QuickCommandConfig: Codable, Equatable {
    var id: String
    var title: String
    var command: String
    /// A global hotkey for this command, in the same grammar as the app's own
    /// bindings. Optional: a command with no hotkey is still reachable from
    /// the palette and the menu.
    var hotkey: String?
    /// Whether to press Return after typing the command. See
    /// `QuickCommand.runsImmediately` for why this defaults to false.
    var run: Bool?

    init(id: String, title: String, command: String, hotkey: String? = nil, run: Bool? = nil) {
        self.id = id
        self.title = title
        self.command = command
        self.hotkey = hotkey
        self.run = run
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        run = try c.decodeIfPresent(Bool.self, forKey: .run)
    }
}

/// A validated saved command.
struct QuickCommand: Equatable {
    let id: String
    let title: String
    let command: String
    /// The hotkey string as written, kept verbatim for display and for the
    /// Carbon registration — both go through `HotkeySpec`, so the menu can
    /// never show a key equivalent no registered hotkey backs.
    let hotkey: String?

    /// Whether firing this command presses Return, or only types it.
    ///
    /// **Defaults to false, and that is a safety decision rather than a style
    /// one.** A global hotkey that fires a shell command runs whatever the
    /// string says, verbatim, in a real login shell with the user's full
    /// environment, with no confirmation — and possibly while the panel is
    /// hidden, so the window showing what just ran is not even on screen. With
    /// `run` absent or false the command is typed at the prompt and left
    /// there, for the user to read and press Return themselves. Opting in is
    /// one word in `config.json`; opting out after a `rm -rf` fired from a
    /// keystroke is not.
    let runsImmediately: Bool
}

/// Parsing and validating the saved command list.
///
/// Pure and checked: no AppKit, no panel, no shell. The one thing it cannot
/// check is whether a command is a good idea, which is why nothing here runs
/// one.
enum QuickCommands {
    /// One rejected or downgraded entry, with the reason to log.
    struct Problem: Equatable {
        let id: String
        let reason: String
        /// Whether the entry was dropped entirely, or kept with its hotkey
        /// ignored. A bad hotkey costs the hotkey; a bad command costs the
        /// entry.
        let dropped: Bool
    }

    struct Result: Equatable {
        let commands: [QuickCommand]
        let problems: [Problem]
    }

    /// Validate the list. `reservedHotkeys` is the app's own bindings, so a
    /// command that claims ⌃⌥T is reported rather than silently losing to (or
    /// stealing from) the summon hotkey — Carbon registers whichever asks
    /// first, and which one that is depends on ordering nobody should have to
    /// reason about.
    static func validate(
        _ entries: [QuickCommandConfig], reservedHotkeys: [String: String] = [:]
    ) -> Result {
        var commands: [QuickCommand] = []
        var problems: [Problem] = []
        var seenIDs = Set<String>()
        // Keyed by the parsed binding, not the string, so "control+option+1"
        // and "ctrl+alt+1" collide the way the keyboard does.
        var claimed: [HotkeyKey: String] = [:]
        for (name, binding) in reservedHotkeys {
            if let spec = HotkeySpec(binding) { claimed[HotkeyKey(spec)] = name }
        }

        for entry in entries {
            let id = entry.id.trimmingCharacters(in: .whitespaces)
            if id.isEmpty {
                problems.append(Problem(id: entry.id, reason: "empty id", dropped: true))
                continue
            }
            if seenIDs.contains(id) {
                problems.append(Problem(id: id, reason: "duplicate id", dropped: true))
                continue
            }
            if entry.command.isEmpty {
                problems.append(Problem(id: id, reason: "empty command", dropped: true))
                continue
            }

            var hotkey = entry.hotkey
            if let binding = hotkey, !isOptedOut(binding) {
                if let spec = HotkeySpec(binding) {
                    let key = HotkeyKey(spec)
                    if let owner = claimed[key] {
                        problems.append(Problem(
                            id: id,
                            reason: "hotkey \"\(binding)\" is already bound to \(owner)",
                            dropped: false
                        ))
                        hotkey = nil
                    } else {
                        claimed[key] = "quick command \"\(id)\""
                    }
                } else {
                    problems.append(Problem(
                        id: id, reason: "invalid hotkey \"\(binding)\"", dropped: false
                    ))
                    hotkey = nil
                }
            } else {
                hotkey = nil
            }

            seenIDs.insert(id)
            commands.append(QuickCommand(
                id: id,
                title: entry.title.isEmpty ? entry.command : entry.title,
                command: entry.command,
                hotkey: hotkey,
                runsImmediately: entry.run ?? false
            ))
        }

        return Result(commands: commands, problems: problems)
    }

    /// The strings that mean "no hotkey, on purpose" — the same set
    /// `HotkeySpec.init` maps to nil deliberately rather than by rejection.
    /// Duplicated from `HotkeyCenter.isOptedOut` because that one is private
    /// to a `@MainActor` class this file must not depend on; the two are
    /// asserted equal in `make check`.
    static func isOptedOut(_ binding: String) -> Bool {
        let raw = binding.trimmingCharacters(in: .whitespaces).lowercased()
        return raw.isEmpty || raw == "none" || raw == "disabled"
    }

    /// A parsed binding reduced to something hashable, so two spellings of the
    /// same chord compare equal.
    struct HotkeyKey: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
        init(_ spec: HotkeySpec) {
            keyCode = spec.keyCode
            modifiers = spec.modifiers
        }
    }
}

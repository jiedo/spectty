import UIKit

enum HardwareKeyInterpreter {
    static func terminalCharacters(
        rawCharacters: String,
        charactersIgnoringModifiers: String,
        modifiers: UIKeyModifierFlags
    ) -> String {
        let normalizedModifiers = modifiers.intersection([.shift, .alternate, .control, .command])

        guard normalizedModifiers.intersection([.alternate, .control, .command]).isEmpty == false else {
            return rawCharacters
        }

        // Prefer the post-layout printable character when modifiers still
        // produce one, so combinations such as Alt+Shift+, preserve "<".
        if !rawCharacters.isEmpty,
           rawCharacters.rangeOfCharacter(from: .controlCharacters) == nil {
            return rawCharacters
        }

        guard !charactersIgnoringModifiers.isEmpty else { return rawCharacters }

        if normalizedModifiers.contains(.shift),
           charactersIgnoringModifiers.count == 1,
           let scalar = charactersIgnoringModifiers.unicodeScalars.first,
           CharacterSet.letters.contains(scalar) {
            return charactersIgnoringModifiers.uppercased()
        }

        return charactersIgnoringModifiers
    }
}

import XCTest
@testable import SpecttyUI

final class HardwareKeyInterpreterTests: XCTestCase {
    func testAltLetterFallsBackToASCIIBaseCharacter() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "ƒ",
            charactersIgnoringModifiers: "f",
            modifiers: [.alternate]
        )

        XCTAssertEqual(value, "f")
    }

    func testAltShiftCommaPreservesShiftedSymbol() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "<",
            charactersIgnoringModifiers: ",",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, "<")
    }

    func testAltShiftDigitUsesShiftedASCIISymbol() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "¡",
            charactersIgnoringModifiers: "1",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, "!")
    }

    func testControlShiftSixPreservesCaretForControlMapping() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "^",
            charactersIgnoringModifiers: "6",
            modifiers: [.control, .shift]
        )

        XCTAssertEqual(value, "^")
    }

    func testControlLeftBracketFallsBackToIgnoringModifiersWhenRawIsControlCharacter() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "\u{1B}",
            charactersIgnoringModifiers: "[",
            modifiers: [.control]
        )

        XCTAssertEqual(value, "[")
    }

    func testCommandShiftLetterPreservesShiftedLetter() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "C",
            charactersIgnoringModifiers: "c",
            modifiers: [.command, .shift]
        )

        XCTAssertEqual(value, "C")
    }

    func testAltShiftPeriodPreservesGreaterThan() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: ">",
            charactersIgnoringModifiers: ".",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, ">")
    }

    func testAltShiftFivePreservesPercent() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "%",
            charactersIgnoringModifiers: "5",
            modifiers: [.alternate, .shift]
        )

        XCTAssertEqual(value, "%")
    }

    func testControlShiftTwoPreservesAtSign() {
        let value = HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: "@",
            charactersIgnoringModifiers: "2",
            modifiers: [.control, .shift]
        )

        XCTAssertEqual(value, "@")
    }
}

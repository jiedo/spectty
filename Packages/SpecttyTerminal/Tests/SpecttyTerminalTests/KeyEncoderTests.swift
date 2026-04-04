import XCTest
@testable import SpecttyTerminal

final class KeyEncoderTests: XCTestCase {
    func testAltPrintableCharacterUsesEscapePrefix() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: .alt,
            isKeyDown: true,
            characters: "a"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data("\u{1B}a".utf8))
    }

    func testAltControlPrintableCharacterUsesEscapePrefixedControlCode() {
        let encoder = KeyEncoder()
        let event = KeyEvent(
            keyCode: 0,
            modifiers: [.alt, .control],
            isKeyDown: true,
            characters: "a"
        )

        XCTAssertEqual(encoder.encode(event, modes: []), Data([0x1B, 0x01]))
    }
}

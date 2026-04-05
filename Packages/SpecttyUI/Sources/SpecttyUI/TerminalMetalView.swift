import UIKit
import MetalKit
import SpecttyTerminal

private final class TerminalTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
    }
}

private final class TerminalTextRange: UITextRange {
    let startPosition: TerminalTextPosition
    let endPosition: TerminalTextPosition

    init(start: Int, end: Int) {
        self.startPosition = TerminalTextPosition(offset: start)
        self.endPosition = TerminalTextPosition(offset: end)
    }

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.offset == endPosition.offset }
}

private final class TerminalIMETextField: UITextField {
    var accessoryProvider: (() -> UIView?)?
    var emptyDeleteHandler: (() -> Void)?

    override var inputAccessoryView: UIView? {
        get { accessoryProvider?() }
        set {}
    }

    override func deleteBackward() {
        let hasMarkedText = markedTextRange != nil
        let hasBufferedText = !(text?.isEmpty ?? true)
        super.deleteBackward()

        if !hasMarkedText && !hasBufferedText {
            emptyDeleteHandler?()
        }
    }
}

/// MTKView subclass that renders the terminal using Metal.
/// Conforms to UITextInput so iOS IMEs can use marked-text composition.
public final class TerminalMetalView: MTKView, UITextInput {
    private struct HardwareSequenceBinding {
        let keyCode: UIKeyboardHIDUsage
        let modifiers: UIKeyModifierFlags
        let sequence: String
    }

    private var renderer: TerminalMetalRenderer?
    private weak var terminalEmulator: (any TerminalEmulator)?
    private var scrollOffset: Int = 0
    private let imeTextField = TerminalIMETextField(frame: .zero)
    private var markedTextStorage: String = ""
    private var markedSelection: NSRange = NSRange(location: 0, length: 0)
    private var textInputMarkedTextStyle: [NSAttributedString.Key: Any]?
    private weak var textInputDelegateRef: UITextInputDelegate?
    private lazy var textInputTokenizer = UITextInputStringTokenizer(textInput: self)
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    private lazy var _inputAccessory: TerminalInputAccessory = {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 44))
        bar.autoresizingMask = .flexibleWidth
        bar.onKeyPress = { [weak self] event in
            self?.feedbackGenerator.impactOccurred()
            self?.onKeyInput?(event)
        }
        return bar
    }()
    private var hardwareKeyboardConnected = false
    private var pendingDisplayWorkItem: DispatchWorkItem?
    private var lastDisplayTime: CFTimeInterval = 0

    /// Callback for when the view is resized and a new grid size is computed.
    public var onResize: ((Int, Int) -> Void)?

    /// Callback for key input.
    public var onKeyInput: ((KeyEvent) -> Void)?

    /// Callback for paste data (bracketed paste aware).
    public var onPaste: ((Data) -> Void)?

    /// Callback for edge-swipe gestures (session switching).
    public var onEdgeSwipe: ((EdgeSwipeEvent) -> Void)?

    /// Current font configuration.
    public private(set) var terminalFont = TerminalFont()

    /// Built-in text gutter so terminal glyphs do not touch view edges.
    private let terminalContentInsets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    /// Gesture handler for scroll, pinch, selection.
    private var gestureHandler: GestureHandler?

    /// Last reported grid size — avoids duplicate and zero-size resize notifications.
    private var lastReportedGridSize: (columns: Int, rows: Int) = (0, 0)

    /// Debounce timer for resize — prevents sending intermediate sizes during keyboard animation.
    private var resizeDebounce: DispatchWorkItem?

    /// Text selection overlay.
    private let selectionView = TextSelectionView()
    private let preeditLabel = UILabel()

    /// Edit menu interaction (replaces deprecated UIMenuController).
    private var editMenuInteraction: UIEditMenuInteraction?

    /// Visual bell flash layer.
    private var bellLayer: CALayer?
    private var currentTheme: TerminalTheme = .default
    private static let maxContentFramesPerSecond: CFTimeInterval = 10
    private static let minimumDisplayInterval: CFTimeInterval = 1.0 / maxContentFramesPerSecond
    private static let commandSequenceBindings: [HardwareSequenceBinding] = [
        HardwareSequenceBinding(
            keyCode: .keyboardR,
            modifiers: .command,
            sequence: "\u{1B}[3~,"
        ),
        HardwareSequenceBinding(
            keyCode: .keyboardZ,
            modifiers: .command,
            sequence: "\u{1B}[3~p"
        ),
        HardwareSequenceBinding(
            keyCode: .keyboardX,
            modifiers: .command,
            sequence: "\u{1B}[3~n"
        ),
        HardwareSequenceBinding(
            keyCode: .keyboardC,
            modifiers: .command,
            sequence: "\u{1B}[3~c"
        ),
    ]
    private static let keypadSequenceBindings: [HardwareSequenceBinding] = [
        HardwareSequenceBinding(
            keyCode: .keypad1,
            modifiers: [],
            sequence: "\u{1B}[3~p"
        ),
        HardwareSequenceBinding(
            keyCode: .keypad2,
            modifiers: [],
            sequence: "\u{1B}[3~n"
        ),
        HardwareSequenceBinding(
            keyCode: .keypad3,
            modifiers: [],
            sequence: "\u{1B}[3~c"
        ),
        HardwareSequenceBinding(
            keyCode: .keypad0,
            modifiers: [],
            sequence: "\u{1B}[3~s"
        ),
    ]

    public init(frame: CGRect, emulator: any TerminalEmulator) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        super.init(frame: frame, device: device)
        self.terminalEmulator = emulator
        self.renderer = TerminalMetalRenderer(device: device, scaleFactor: UIScreen.main.scale)
        feedbackGenerator.prepare()
        configure()
        setupGestureHandler(emulator: emulator)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1.0)
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.delegate = self
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        installDisplayChangeHandler(for: terminalEmulator)

        imeTextField.autocorrectionType = .no
        imeTextField.autocapitalizationType = .none
        imeTextField.smartQuotesType = .no
        imeTextField.smartDashesType = .no
        imeTextField.smartInsertDeleteType = .no
        imeTextField.spellCheckingType = .no
        imeTextField.keyboardType = .default
        imeTextField.returnKeyType = .default
        imeTextField.delegate = self
        imeTextField.tintColor = .clear
        imeTextField.textColor = .clear
        imeTextField.backgroundColor = .clear
        imeTextField.accessoryProvider = { [weak self] in
            self?.activeInputAccessoryView
        }
        imeTextField.emptyDeleteHandler = { [weak self] in
            self?.sendDeleteBackwardToTerminal()
        }
        imeTextField.addTarget(self, action: #selector(handleIMETextChanged), for: .editingChanged)
        imeTextField.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        imeTextField.alpha = 0.01
        addSubview(imeTextField)

        preeditLabel.isHidden = true
        preeditLabel.backgroundColor = .clear
        preeditLabel.numberOfLines = 1
        preeditLabel.isUserInteractionEnabled = false
        addSubview(preeditLabel)

        // Selection overlay — hit tests only near drag handles, passes through otherwise.
        selectionView.frame = bounds
        selectionView.contentInsets = terminalContentInsets
        selectionView.cellSize = cellSize
        addSubview(selectionView)

        // Edit menu interaction for copy/paste — nil delegate uses default
        // behavior, building the menu from canPerformAction/copy/paste.
        let interaction = UIEditMenuInteraction(delegate: nil)
        addInteraction(interaction)
        self.editMenuInteraction = interaction

        // Pause Metal rendering while backgrounded — drawables are unavailable
        // and attempting to render produces blank frames.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidChange),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidChange),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        refreshHardwareKeyboardState(shouldReloadInputViews: false)
    }

    @objc private func appDidEnterBackground() {
        isPaused = true
        pendingDisplayWorkItem?.cancel()
        pendingDisplayWorkItem = nil
    }

    @objc private func appWillEnterForeground() {
        refreshHardwareKeyboardState()
        requestDisplay()
    }

    private func handleLocalTap() {
        // Clear any active selection on tap before focusing the terminal.
        if selectionView.selection != nil {
            selectionView.selection = nil
            editMenuInteraction?.dismissMenu()
        }

        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    /// Swap the terminal emulator without recreating the view.
    /// Preserves first-responder status (keyboard stays up).
    public func setEmulator(_ emulator: any TerminalEmulator) {
        installDisplayChangeHandler(for: nil)
        self.terminalEmulator = emulator
        installDisplayChangeHandler(for: emulator)
        self.scrollOffset = 0
        gestureHandler?.removeGestures()
        setupGestureHandler(emulator: emulator)
        // Reset so the new emulator gets the current grid size.
        lastReportedGridSize = (0, 0)
        notifyResizeIfNeeded()
        requestDisplay()
    }

    private func installDisplayChangeHandler(for emulator: (any TerminalEmulator)?) {
        emulator?.onDisplayChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestDisplay()
            }
        }
    }

    private func requestDisplay() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.window != nil else { return }
            let now = CACurrentMediaTime()
            let earliestNextDisplay = self.lastDisplayTime + Self.minimumDisplayInterval

            if now >= earliestNextDisplay {
                self.pendingDisplayWorkItem?.cancel()
                self.pendingDisplayWorkItem = nil
                self.lastDisplayTime = now
                self.setNeedsDisplay()
                return
            }

            guard self.pendingDisplayWorkItem == nil else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingDisplayWorkItem = nil
                guard self.window != nil else { return }
                self.lastDisplayTime = CACurrentMediaTime()
                self.setNeedsDisplay()
            }
            self.pendingDisplayWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (earliestNextDisplay - now),
                execute: work
            )
        }
    }

    private func setupGestureHandler(emulator: any TerminalEmulator) {
        let handler = GestureHandler(metalView: self, emulator: emulator)
        handler.onMouseEvent = { [weak self] data in
            self?.onPaste?(data)
        }
        handler.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            self.selectionView.cellSize = self.cellSize
            self.selectionView.selection = selection
        }
        handler.onShowMenu = { [weak self] point in
            self?.presentEditMenu(at: point)
        }
        handler.onEdgeSwipe = { [weak self] event in
            self?.onEdgeSwipe?(event)
        }
        handler.onLocalTap = { [weak self] in
            self?.handleLocalTap()
        }
        // Handle-drag updates from the selection overlay.
        selectionView.onSelectionChanged = { [weak self, weak handler] selection in
            handler?.updateSelection(selection)
            self?.selectionView.cellSize = self?.cellSize ?? .zero
        }
        selectionView.onShowMenu = { [weak self] point in
            self?.presentEditMenu(at: point)
        }
        self.gestureHandler = handler
    }

    /// Present the edit menu at the given point in this view's coordinates.
    /// Deferred to the next run loop tick so UIKit finishes processing the
    /// gesture touch (avoids nil-window warnings and unsafeForcedSync).
    private func presentEditMenu(at point: CGPoint) {
        Task { @MainActor [weak self] in
            guard let self, self.selectionView.selection != nil else { return }
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            self.editMenuInteraction?.presentEditMenu(with: config)
        }
    }

    // MARK: - First Responder + Software Keyboard

    public override var canBecomeFirstResponder: Bool { true }

    public override var inputAccessoryView: UIView? { activeInputAccessoryView }

    private var activeInputAccessoryView: UIView? {
        hardwareKeyboardConnected ? nil : _inputAccessory
    }

    @objc private func hardwareKeyboardDidChange() {
        refreshHardwareKeyboardState()
    }

    private var isHardwareKeyboardInputExpected: Bool {
        UITextInputContext.current()?.isHardwareKeyboardInputExpected ?? false
    }

    private func refreshHardwareKeyboardState(shouldReloadInputViews: Bool = true) {
        let isConnected = isHardwareKeyboardInputExpected
        guard hardwareKeyboardConnected != isConnected else { return }
        hardwareKeyboardConnected = isConnected
        guard shouldReloadInputViews else { return }
        imeTextField.reloadInputViews()
        reloadInputViews()
        setNeedsLayout()
    }

    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        refreshHardwareKeyboardState()
        updateIMETextFieldFrame()
        return imeTextField.becomeFirstResponder()
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        imeTextField.resignFirstResponder()
    }

    public override var isFirstResponder: Bool {
        imeTextField.isFirstResponder
    }

    /// UIKeyInput: tells iOS we always accept text (keeps keyboard open).
    public var hasText: Bool { true }

    private func resetMarkedText() {
        guard !markedTextStorage.isEmpty else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        markedTextStorage = ""
        markedSelection = NSRange(location: 0, length: 0)
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        updateIMETextFieldFrame()
        updatePreeditOverlay()
    }

    private func commitInputText(_ text: String) {
        guard !text.isEmpty else { return }

        var modifiers = KeyModifiers()
        if _inputAccessory.ctrlActive { modifiers.insert(.control) }
        if _inputAccessory.shiftActive { modifiers.insert(.shift) }
        let hasModifiers = !modifiers.isEmpty

        // QuickPath/swipe and IME commit may submit multi-character text at
        // once. Preserve that as a single payload when no control mapping is
        // needed.
        if !modifiers.contains(.control), !text.contains("\n") {
            let event = KeyEvent(
                keyCode: 0,
                modifiers: modifiers,
                isKeyDown: true,
                characters: text
            )
            onKeyInput?(event)

            if hasModifiers {
                _inputAccessory.deactivateModifiers()
            }
            return
        }

        for char in text {
            let characters: String
            if char == "\n" {
                characters = "\r"
            } else if modifiers.contains(.control), let ascii = char.asciiValue,
                      (0x61...0x7A).contains(ascii) || (0x41...0x5A).contains(ascii) {
                let upper = ascii & 0x1F
                characters = String(UnicodeScalar(upper))
            } else {
                characters = String(char)
            }

            let event = KeyEvent(
                keyCode: char == "\n" ? 0x28 : 0,
                modifiers: modifiers,
                isKeyDown: true,
                characters: characters
            )
            onKeyInput?(event)
        }

        if hasModifiers {
            _inputAccessory.deactivateModifiers()
        }
    }

    private func sendDeleteBackwardToTerminal() {
        var modifiers = KeyModifiers()
        if _inputAccessory.ctrlActive { modifiers.insert(.control) }
        if _inputAccessory.shiftActive { modifiers.insert(.shift) }
        let hasModifiers = !modifiers.isEmpty

        let event = KeyEvent(
            keyCode: 0x2A,
            modifiers: modifiers,
            isKeyDown: true,
            characters: "\u{7F}"
        )
        onKeyInput?(event)

        if hasModifiers {
            _inputAccessory.deactivateModifiers()
        }
    }

    private var hasActiveIMEComposition: Bool {
        if imeTextField.markedTextRange != nil { return true }
        return !activePreeditText.isEmpty
    }

    private func clearIMECompositionState() {
        imeTextField.text = ""
        resetMarkedText()
        updateIMETextFieldFrame()
        updatePreeditOverlay()
    }

    private func cancelIMEComposition() {
        guard hasActiveIMEComposition else { return }
        imeTextField.text = ""
        imeTextField.unmarkText()
        clearIMECompositionState()
    }

    @objc private func handleIMETextChanged() {
        updatePreeditOverlay()
        guard imeTextField.markedTextRange == nil else { return }
        guard let text = imeTextField.text, !text.isEmpty else { return }
        commitInputText(text)
        clearIMECompositionState()
    }

    /// UIKeyInput: software keyboard character input.
    public func insertText(_ text: String) {
        resetMarkedText()
        commitInputText(text)
    }

    /// UIKeyInput: software keyboard backspace.
    public func deleteBackward() {
        if !markedTextStorage.isEmpty {
            inputDelegate?.selectionWillChange(self)
            inputDelegate?.textWillChange(self)

            if markedSelection.length > 0 {
                let start = markedSelection.location
                let end = start + markedSelection.length
                let startIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: start)
                let endIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: end)
                markedTextStorage.removeSubrange(startIndex..<endIndex)
                markedSelection = NSRange(location: start, length: 0)
            } else if markedSelection.location > 0 {
                let deleteIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: markedSelection.location - 1)
                markedTextStorage.remove(at: deleteIndex)
                markedSelection = NSRange(location: markedSelection.location - 1, length: 0)
            }

            inputDelegate?.textDidChange(self)
            inputDelegate?.selectionDidChange(self)
            return
        }
        sendDeleteBackwardToTerminal()
    }

    /// Disable autocorrect/autocapitalize — raw terminal input.
    public var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    public var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    public var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    public var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    public var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    public var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    public var keyboardType: UIKeyboardType {
        get { .default }
        set {}
    }

    public var selectedTextRange: UITextRange? {
        get {
            let end = markedSelection.location + markedSelection.length
            return TerminalTextRange(start: markedSelection.location, end: end)
        }
        set {
            guard let range = newValue as? TerminalTextRange else { return }
            let start = max(0, min(range.startPosition.offset, markedTextStorage.count))
            let end = max(start, min(range.endPosition.offset, markedTextStorage.count))
            markedSelection = NSRange(location: start, length: end - start)
        }
    }

    public var markedTextRange: UITextRange? {
        guard !markedTextStorage.isEmpty else { return nil }
        return TerminalTextRange(start: 0, end: markedTextStorage.count)
    }

    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { textInputMarkedTextStyle }
        set { textInputMarkedTextStyle = newValue }
    }

    public var beginningOfDocument: UITextPosition { TerminalTextPosition(offset: 0) }

    public var endOfDocument: UITextPosition { TerminalTextPosition(offset: markedTextStorage.count) }

    public var inputDelegate: UITextInputDelegate? {
        get { textInputDelegateRef }
        set { textInputDelegateRef = newValue }
    }

    public var tokenizer: UITextInputTokenizer { textInputTokenizer }

    public func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalTextRange else { return nil }
        let start = max(0, min(range.startPosition.offset, markedTextStorage.count))
        let end = max(start, min(range.endPosition.offset, markedTextStorage.count))
        let startIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: start)
        let endIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: end)
        return String(markedTextStorage[startIndex..<endIndex])
    }

    public func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? TerminalTextRange else { return }
        let start = max(0, min(range.startPosition.offset, markedTextStorage.count))
        let end = max(start, min(range.endPosition.offset, markedTextStorage.count))
        let startIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: start)
        let endIndex = markedTextStorage.index(markedTextStorage.startIndex, offsetBy: end)
        let replacesMarkedText = !markedTextStorage.isEmpty

        if replacesMarkedText {
            inputDelegate?.selectionWillChange(self)
            inputDelegate?.textWillChange(self)
        }

        markedTextStorage.replaceSubrange(startIndex..<endIndex, with: text)
        let caret = start + text.count
        markedSelection = NSRange(location: caret, length: 0)

        if replacesMarkedText {
            inputDelegate?.textDidChange(self)
            inputDelegate?.selectionDidChange(self)
            commitInputText(markedTextStorage)
            resetMarkedText()
        } else {
            commitInputText(text)
        }
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        markedTextStorage = markedText ?? ""
        let location = max(0, min(selectedRange.location, markedTextStorage.count))
        let length = max(0, min(selectedRange.length, markedTextStorage.count - location))
        markedSelection = NSRange(location: location, length: length)
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        updateIMETextFieldFrame()
        updatePreeditOverlay()
    }

    public func unmarkText() {
        resetMarkedText()
    }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(start: min(from.offset, to.offset), end: max(from.offset, to.offset))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        let next = position.offset + offset
        guard next >= 0, next <= markedTextStorage.count else { return nil }
        return TerminalTextPosition(offset: next)
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: offset)
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let lhs = position as? TerminalTextPosition,
              let rhs = other as? TerminalTextPosition else { return .orderedSame }
        if lhs.offset < rhs.offset { return .orderedAscending }
        if lhs.offset > rhs.offset { return .orderedDescending }
        return .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition else { return 0 }
        return to.offset - from.offset
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? TerminalTextRange else { return nil }
        switch direction {
        case .left, .up:
            return range.start
        case .right, .down:
            return range.end
        @unknown default:
            return range.end
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TerminalTextPosition else { return nil }
        let offset = position.offset
        switch direction {
        case .left, .up:
            guard offset > 0 else { return nil }
            return TerminalTextRange(start: offset - 1, end: offset)
        case .right, .down:
            guard offset < markedTextStorage.count else { return nil }
            return TerminalTextRange(start: offset, end: offset + 1)
        @unknown default:
            return nil
        }
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }

    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    private func rectForMarkedText(offset: Int = 0, width: Int = 1) -> CGRect {
        guard let emulator = terminalEmulator else { return .zero }

        let screen = emulator.state.activeScreen
        let row = max(0, min(screen.cursor.row, max(0, screen.rows - 1)))
        let col = max(0, min(screen.cursor.col + offset, max(0, screen.columns - 1)))
        let visibleWidth = max(1, width)
        let contentRect = terminalContentRect.isEmpty ? bounds : terminalContentRect

        return CGRect(
            x: contentRect.minX + CGFloat(col) * cellSize.width,
            y: contentRect.minY + CGFloat(row) * cellSize.height,
            width: max(cellSize.width, CGFloat(visibleWidth) * cellSize.width),
            height: max(cellSize.height, 1)
        )
    }

    private func updateIMETextFieldFrame() {
        let targetRect: CGRect
        let preeditText = activePreeditText
        if !preeditText.isEmpty {
            let width = max(1, preeditText.count)
            targetRect = rectForMarkedText(offset: 0, width: width)
        } else {
            targetRect = rectForMarkedText()
        }

        let frame = targetRect.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : CGRect(
                x: targetRect.minX,
                y: targetRect.minY,
                width: max(1, targetRect.width),
                height: max(1, targetRect.height)
            )

        if imeTextField.frame != frame {
            imeTextField.frame = frame
        }
    }

    private var activePreeditText: String {
        if let text = imeTextField.text, !text.isEmpty, imeTextField.markedTextRange != nil {
            return text
        }
        return markedTextStorage
    }

    private func updatePreeditOverlay() {
        let preeditText = activePreeditText
        guard !preeditText.isEmpty else {
            preeditLabel.isHidden = true
            preeditLabel.attributedText = nil
            renderer?.setCursorSuppressed(false)
            setNeedsDisplay()
            return
        }

        let font = UIFont(name: terminalFont.name, size: terminalFont.size)
            ?? UIFont.monospacedSystemFont(ofSize: terminalFont.size, weight: .regular)
        let fg = UIColor(
            red: CGFloat(currentTheme.foreground.0) / 255.0,
            green: CGFloat(currentTheme.foreground.1) / 255.0,
            blue: CGFloat(currentTheme.foreground.2) / 255.0,
            alpha: 1.0
        )

        preeditLabel.attributedText = NSAttributedString(
            string: preeditText,
            attributes: [
                .font: font,
                .foregroundColor: fg,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        preeditLabel.sizeToFit()

        let anchorRect = rectForMarkedText(offset: 0, width: max(1, preeditText.count))
        preeditLabel.frame = CGRect(
            x: anchorRect.minX,
            y: anchorRect.minY + max(0, (anchorRect.height - preeditLabel.bounds.height) / 2.0),
            width: max(anchorRect.width, preeditLabel.bounds.width),
            height: max(anchorRect.height, preeditLabel.bounds.height)
        )
        preeditLabel.isHidden = false
        renderer?.setCursorSuppressed(true)
        setNeedsDisplay()
    }

    public func firstRect(for range: UITextRange) -> CGRect {
        guard let range = range as? TerminalTextRange else { return rectForMarkedText() }
        let width = max(1, range.endPosition.offset - range.startPosition.offset)
        return rectForMarkedText(offset: range.startPosition.offset, width: width)
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? TerminalTextPosition else { return rectForMarkedText() }
        return rectForMarkedText(offset: position.offset)
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        TerminalTextPosition(offset: markedTextStorage.count)
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = range as? TerminalTextRange else { return nil }
        return range.end
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        guard !markedTextStorage.isEmpty else { return nil }
        return TerminalTextRange(start: 0, end: markedTextStorage.count)
    }

    // MARK: - External Keyboard Shortcuts

    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "r", modifierFlags: .command, action: #selector(handleRenameTmuxWindow)),
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(handlePreviousTmuxWindow)),
            UIKeyCommand(input: "x", modifierFlags: .command, action: #selector(handleNextTmuxWindow)),
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(handleCreateTmuxWindow)),
            UIKeyCommand(input: "v", modifierFlags: [.command, .shift], action: #selector(handlePaste)),
            UIKeyCommand(input: "k", modifierFlags: [.command, .shift], action: #selector(handleClearScreen)),
            UIKeyCommand(input: "c", modifierFlags: [.command, .shift], action: #selector(handleCopy)),
        ]
    }

    @objc private func handleRenameTmuxWindow() {
        sendHardwareSequence("\u{1B}[3~,")
    }

    @objc private func handlePreviousTmuxWindow() {
        sendHardwareSequence("\u{1B}[3~p")
    }

    @objc private func handleNextTmuxWindow() {
        sendHardwareSequence("\u{1B}[3~n")
    }

    @objc private func handleCreateTmuxWindow() {
        sendHardwareSequence("\u{1B}[3~c")
    }

    @objc private func handlePaste() {
        guard let text = UIPasteboard.general.string else { return }
        if let emulator = terminalEmulator, emulator.state.modes.contains(.bracketedPaste) {
            let bracketed = "\u{1B}[200~" + text + "\u{1B}[201~"
            onPaste?(Data(bracketed.utf8))
        } else {
            onPaste?(Data(text.utf8))
        }
    }

    @objc private func handleClearScreen() {
        // Send Ctrl+L (form feed — clears screen in most shells).
        let event = KeyEvent(keyCode: 0, modifiers: .control, isKeyDown: true, characters: "l")
        onKeyInput?(event)
    }

    @objc private func handleCopy() {
        copyScreenText()
    }

    private func sendHardwareSequence(_ sequence: String) {
        let event = KeyEvent(
            keyCode: 0,
            modifiers: [],
            isKeyDown: true,
            characters: sequence
        )
        onKeyInput?(event)
    }

    private func copyScreenText() {
        guard let emulator = terminalEmulator else { return }

        // If there's an active selection, copy only the selected text.
        if selectionView.selection != nil,
           let selectedText = selectionView.selectedText(from: emulator.state.activeScreen),
           !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
            selectionView.selection = nil
            return
        }

        // Fallback: copy entire visible screen.
        let text = emulator.state.activeScreen.text()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    // MARK: - UIResponder Copy/Paste Menu

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectionView.selection != nil }
        return false
    }

    @objc public override func copy(_ sender: Any?) {
        copyScreenText()
    }

    @objc public override func paste(_ sender: Any?) {
        handlePaste()
    }

    // MARK: - Visual Bell

    public func flashBell() {
        if bellLayer == nil {
            let flash = CALayer()
            flash.backgroundColor = UIColor.white.withAlphaComponent(0.15).cgColor
            flash.frame = bounds
            flash.opacity = 0
            layer.addSublayer(flash)
            bellLayer = flash
        }

        guard let flash = bellLayer else { return }
        flash.frame = bounds

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 0.0]
        anim.keyTimes = [0, 0.1, 1.0]
        anim.duration = 0.15
        flash.add(anim, forKey: "bell")

        feedbackGenerator.impactOccurred(intensity: 0.5)
    }

    // MARK: - Appearance

    public func setFont(_ font: TerminalFont) {
        guard font.name != terminalFont.name || font.size != terminalFont.size else { return }
        self.terminalFont = font
        renderer?.setFont(font)
        updatePreeditOverlay()
        notifyResizeIfNeeded()
        requestDisplay()
    }

    public func setTheme(_ theme: TerminalTheme) {
        currentTheme = theme
        renderer?.setTheme(theme)
        // Update the clear color to match the theme background.
        self.clearColor = MTLClearColor(
            red: Double(theme.background.0) / 255.0,
            green: Double(theme.background.1) / 255.0,
            blue: Double(theme.background.2) / 255.0,
            alpha: 1.0
        )
        updatePreeditOverlay()
        requestDisplay()
    }

    public func setCursorStyle(_ style: CursorStyle) {
        renderer?.setCursorStyle(style)
        requestDisplay()
    }

    // MARK: - Scrollback

    public func scrollBy(_ lines: Int) {
        guard let emulator = terminalEmulator else { return }
        let maxScroll = emulator.scrollbackCount
        scrollOffset = max(0, min(scrollOffset + lines, maxScroll))
        setNeedsDisplay()
    }

    public func scrollToBottom() {
        scrollOffset = 0
        setNeedsDisplay()
    }

    // MARK: - Grid Size

    /// The size of a single terminal cell in points.
    public var cellSize: CGSize {
        renderer?.cellSize ?? CGSize(width: 8, height: 17)
    }

    /// Drawable content rect after applying terminal insets.
    var terminalContentRect: CGRect {
        let rect = bounds.inset(by: terminalContentInsets)
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return rect
    }

    public var gridSize: (columns: Int, rows: Int) {
        guard let renderer = renderer else { return (80, 24) }
        let cellSize = renderer.cellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        let rect = terminalContentRect
        guard rect.width > 0, rect.height > 0 else { return (80, 24) }
        let columns = max(1, Int(rect.width / cellSize.width))
        let rows = max(1, Int(rect.height / cellSize.height))
        return (columns, rows)
    }

    /// Convert a point in view coordinates to a clamped terminal grid coordinate.
    func gridCoordinate(for point: CGPoint) -> (row: Int, col: Int) {
        let grid = gridSize
        guard grid.columns > 0, grid.rows > 0 else { return (0, 0) }
        let rect = terminalContentRect.isEmpty ? bounds : terminalContentRect
        let localX = point.x - rect.minX
        let localY = point.y - rect.minY
        let col = max(0, min(Int(localX / cellSize.width), grid.columns - 1))
        let row = max(0, min(Int(localY / cellSize.height), grid.rows - 1))
        return (row, col)
    }

    /// Center point for a row/column selection in view coordinates.
    func selectionCenterPoint(row: Int, startCol: Int, endCol: Int) -> CGPoint {
        let rect = terminalContentRect.isEmpty ? bounds : terminalContentRect
        let centerX = rect.minX + CGFloat(startCol + endCol + 1) / 2.0 * cellSize.width
        let centerY = rect.minY + CGFloat(row) * cellSize.height + cellSize.height / 2.0
        return CGPoint(x: centerX, y: centerY)
    }

    private func notifyResizeIfNeeded() {
        let (columns, rows) = gridSize
        // Don't send resize for views that haven't been laid out yet.
        guard columns > 1, rows > 1 else { return }

        // Keep the local emulator aligned with the current view grid
        // immediately. The remote PTY resize can stay debounced, but the
        // visible terminal should not spend a frame interpreting content with
        // stale dimensions.
        if let emulator = terminalEmulator,
           emulator.state.columns != columns || emulator.state.rows != rows {
            emulator.resize(columns: columns, rows: rows)
            scrollOffset = 0
            selectionView.selection = nil
            setNeedsDisplay()
        }

        // Don't send duplicate resizes upstream.
        guard columns != lastReportedGridSize.columns || rows != lastReportedGridSize.rows else { return }

        // Debounce: keyboard animations trigger many intermediate layouts.
        // Only send the resize once the layout stabilizes.
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let (cols, rows) = self.gridSize
            guard cols > 1, rows > 1 else { return }
            guard cols != self.lastReportedGridSize.columns || rows != self.lastReportedGridSize.rows else { return }
            self.lastReportedGridSize = (cols, rows)
            self.scrollOffset = 0
            self.onResize?(cols, rows)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        selectionView.frame = bounds
        selectionView.contentInsets = terminalContentInsets
        selectionView.cellSize = cellSize
        bellLayer?.frame = bounds
        updateIMETextFieldFrame()
        updatePreeditOverlay()
        notifyResizeIfNeeded()
    }

    // MARK: - Hardware Key Input (external keyboards)

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var terminalPresses = Set<UIPress>()
        var systemPresses = Set<UIPress>()

        for press in presses {
            guard let key = press.key else {
                systemPresses.insert(press)
                continue
            }

            if let sequence = customHardwareSequence(for: key) {
                sendHardwareSequence(sequence)
                continue
            }

            if shouldRouteHardwareKeyToTerminal(key) {
                terminalPresses.insert(press)
            } else {
                systemPresses.insert(press)
            }
        }

        if !systemPresses.isEmpty {
            super.pressesBegan(systemPresses, with: event)
        }

        for press in terminalPresses {
            guard let key = press.key else { continue }
            let keyEvent = KeyEvent(
                keyCode: UInt32(key.keyCode.rawValue),
                modifiers: modifiersFromUIKey(key),
                isKeyDown: true,
                characters: terminalCharacters(for: key)
            )
            onKeyInput?(keyEvent)
        }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var terminalPresses = Set<UIPress>()
        var systemPresses = Set<UIPress>()

        for press in presses {
            guard let key = press.key else {
                systemPresses.insert(press)
                continue
            }

            if customHardwareSequence(for: key) != nil {
                continue
            }

            if shouldRouteHardwareKeyToTerminal(key) {
                terminalPresses.insert(press)
            } else {
                systemPresses.insert(press)
            }
        }

        if !systemPresses.isEmpty {
            super.pressesEnded(systemPresses, with: event)
        }

        for press in terminalPresses {
            guard let key = press.key else { continue }
            let keyEvent = KeyEvent(
                keyCode: UInt32(key.keyCode.rawValue),
                modifiers: modifiersFromUIKey(key),
                isKeyDown: false,
                characters: terminalCharacters(for: key)
            )
            onKeyInput?(keyEvent)
        }
    }

    private func shouldRouteHardwareKeyToTerminal(_ key: UIKey) -> Bool {
        if customHardwareSequence(for: key) != nil {
            return true
        }

        if shouldAllowSystemInputMethodShortcut(key) {
            return false
        }

        if shouldCancelCompositionOnEscape(key) {
            cancelIMEComposition()
            return false
        }

        if shouldAllowSystemReturnHandling(key) {
            return false
        }

        if shouldAllowSystemDeleteHandling(key) {
            return false
        }

        if isTerminalSpecialKey(key.keyCode) {
            return true
        }

        let modifiers = key.modifierFlags.intersection([.shift, .alternate, .control, .command, .alphaShift])

        if modifiers.contains(.command) || modifiers.contains(.alternate) || modifiers.contains(.control) {
            return true
        }

        let charactersIgnoringModifiers = key.charactersIgnoringModifiers
        if modifiers.isSubset(of: [.shift, .alphaShift]),
           !charactersIgnoringModifiers.isEmpty {
            return false
        }

        let characters = key.characters
        if !characters.isEmpty,
           characters.rangeOfCharacter(from: .controlCharacters) == nil {
            return false
        }

        return true
    }

    private func customHardwareSequence(for key: UIKey) -> String? {
        let modifiers = normalizedHardwareModifiers(key.modifierFlags)
        let binding = (Self.commandSequenceBindings + Self.keypadSequenceBindings).first {
            $0.keyCode == key.keyCode && $0.modifiers == modifiers
        }
        return binding?.sequence
    }

    private func terminalCharacters(for key: UIKey) -> String {
        HardwareKeyInterpreter.terminalCharacters(
            rawCharacters: key.characters ?? "",
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: normalizedHardwareModifiers(key.modifierFlags)
        )
    }

    private func normalizedHardwareModifiers(_ modifiers: UIKeyModifierFlags) -> UIKeyModifierFlags {
        modifiers.intersection([.shift, .alternate, .control, .command])
    }

    private func shouldAllowSystemReturnHandling(_ key: UIKey) -> Bool {
        guard key.keyCode == .keyboardReturnOrEnter else { return false }
        return hasActiveIMEComposition
    }

    private func shouldCancelCompositionOnEscape(_ key: UIKey) -> Bool {
        guard key.keyCode == .keyboardEscape else { return false }
        return hasActiveIMEComposition
    }

    private func shouldAllowSystemDeleteHandling(_ key: UIKey) -> Bool {
        guard key.keyCode == .keyboardDeleteOrBackspace else { return false }
        return hasActiveIMEComposition
    }

    private func shouldAllowSystemInputMethodShortcut(_ key: UIKey) -> Bool {
        let modifiers = key.modifierFlags.intersection([.shift, .control, .alternate, .command, .alphaShift])
        guard modifiers == [.control] || modifiers == [.control, .shift] else { return false }

        let candidates = [key.charactersIgnoringModifiers, key.characters]
        return candidates.contains { value in
            return value == " "
        }
    }

    private func isTerminalSpecialKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        switch keyCode {
        case .keyboardUpArrow,
             .keyboardDownArrow,
             .keyboardLeftArrow,
             .keyboardRightArrow,
             .keyboardHome,
             .keyboardEnd,
             .keyboardPageUp,
             .keyboardPageDown,
             .keyboardInsert,
             .keyboardDeleteForward,
             .keyboardDeleteOrBackspace,
             .keyboardReturnOrEnter,
             .keyboardEscape,
             .keyboardTab,
             .keyboardF1,
             .keyboardF2,
             .keyboardF3,
             .keyboardF4,
             .keyboardF5,
             .keyboardF6,
             .keyboardF7,
             .keyboardF8,
             .keyboardF9,
             .keyboardF10,
             .keyboardF11,
             .keyboardF12:
            return true
        default:
            return false
        }
    }

    private func modifiersFromUIKey(_ key: UIKey) -> KeyModifiers {
        var mods = KeyModifiers()
        if key.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if key.modifierFlags.contains(.alternate) { mods.insert(.alt) }
        if key.modifierFlags.contains(.control) { mods.insert(.control) }
        if key.modifierFlags.contains(.command) { mods.insert(.super) }
        return mods
    }
}

// MARK: - MTKViewDelegate

extension TerminalMetalView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        notifyResizeIfNeeded()
    }

    public func draw(in view: MTKView) {
        guard let emulator = terminalEmulator,
              let renderer = renderer,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        let state = emulator.state.activeScreen
        renderer.update(
            state: state,
            scrollback: emulator.state.scrollback,
            scrollOffset: scrollOffset,
            viewportSize: bounds.size,
            contentRect: terminalContentRect
        )
        renderer.render(to: renderPassDescriptor, drawable: drawable)
    }
}

extension TerminalMetalView: UITextFieldDelegate {
    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string == "\n" || string == "\r" {
            if hasActiveIMEComposition {
                if let committedText = imeTextField.text, !committedText.isEmpty {
                    commitInputText(committedText)
                }
                clearIMECompositionState()
                return false
            }
            commitInputText("\n")
            textField.text = ""
            return false
        }
        return true
    }
}

import AppKit

private final class TopAlignedStackView:NSStackView {
    override var isFlipped:Bool { true }
}

final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        actionHandler = action; target = self; self.action = #selector(invoke)
        bezelStyle = .rounded; controlSize = .small
    }
    @objc private func invoke() { actionHandler?() }
}

final class ActionSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    var onReset: (() -> Void)?
    convenience init(value: Double, min: Double, max: Double, label: String, change: @escaping (Double) -> Void) {
        self.init(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        onChange = change; target = self; action = #selector(invoke)
        isContinuous = true; controlSize = .small
        setAccessibilityLabel(label)
    }
    @objc private func invoke() { onChange?(doubleValue) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onReset { onReset(); return }
        super.mouseDown(with: event)
    }
}

final class ActionPopUp: NSPopUpButton {
    var onSelect: ((String) -> Void)?
    convenience init(label: String, change: @escaping (String) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        onSelect = change; target = self; action = #selector(invoke)
        controlSize = .small; setAccessibilityLabel(label)
    }
    @objc private func invoke() {
        if let value = selectedItem?.representedObject as? String { onSelect?(value) }
    }
    func setItems(_ items: [(String, String)], selected: String?) {
        let current = itemArray.map { ($0.title, $0.representedObject as? String ?? "") }
        if current.map({ $0.0 + $0.1 }) != items.map({ $0.0 + $0.1 }) {
            removeAllItems()
            for (title, id) in items { addItem(withTitle: title); lastItem?.representedObject = id }
        }
        if let item = itemArray.first(where: { ($0.representedObject as? String) == selected }) { select(item) }
    }
}

enum UI {
    static func text(_ string: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    static func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal
        stack.spacing = spacing; stack.alignment = .centerY
        return stack
    }
    static func vertical(_ views: [NSView] = [], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.spacing = spacing; stack.alignment = .leading
        return stack
    }
    static func documentStack(spacing:CGFloat = 10) -> NSStackView {
        let stack = TopAlignedStackView(); stack.orientation = .vertical
        stack.spacing = spacing; stack.alignment = .leading
        return stack
    }
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    static func symbol(_ name: String, label: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: label) }
    static func prompt(title: String, message: String, initial: String = "", window: NSWindow?, completion: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0,y: 0,width: 280,height: 24)
        alert.accessoryView = field
        if let window { alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn ? field.stringValue : nil) }; window.makeFirstResponder(field) }
        else { completion(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    static func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    static func openAudioPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") { NSWorkspace.shared.open(url) }
    }
}

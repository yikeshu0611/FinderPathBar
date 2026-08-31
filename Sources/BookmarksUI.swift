import AppKit

/// Folder chip on the toolbar (FinderPathBar-style); drag to reorder.
final class BookmarkFolderButton: NSButton {
    var folderName: String = ""
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onOrderChanged: (() -> Void)?

    private var dragStartPoint: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        font = .systemFont(ofSize: 13)
        contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = hypot(current.x - start.x, current.y - start.y)

        if !isDragging {
            guard distance > 5 else { return }
            isDragging = true
            alphaValue = 0.65
            NSCursor.closedHand.push()
        }

        guard let stack = superview as? NSStackView else { return }
        let location = stack.convert(event.locationInWindow, from: nil)
        let target = targetIndex(for: location.x, in: stack)
        guard let currentIndex = stack.arrangedSubviews.firstIndex(of: self),
              target != currentIndex else { return }
        stack.insertArrangedSubview(self, at: target)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPoint = nil
            isDragging = false
            alphaValue = 1
            if NSCursor.current == NSCursor.closedHand {
                NSCursor.pop()
            }
        }

        if isDragging {
            onOrderChanged?()
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    private func targetIndex(for locationX: CGFloat, in stack: NSStackView) -> Int {
        var target = 0
        for view in stack.arrangedSubviews {
            guard view !== self else { continue }
            if locationX > view.frame.midX {
                target += 1
            }
        }
        return min(max(0, target), stack.arrangedSubviews.count - 1)
    }
}

/// Menu row: left-click opens, right-click edits.
final class BookmarkMenuRowView: NSView {
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?
    private let label: NSTextField
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, path: String, font: NSFont, width: CGFloat) {
        self.label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        toolTip = path
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedMenuItemColor.cgColor
        label.textColor = .selectedMenuItemTextColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = .labelColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onOpen?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEdit?()
    }
}

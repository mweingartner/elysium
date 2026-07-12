import AppKit
import Darwin
import PebbleCore

private enum RPGUIHarnessRuntimeError: Error {
    case invalidFixture
    case unsafeOutput
    case renderFailed
    case outputFailed
}

private final class RPGUIHarnessApplicationDelegate: NSObject, NSApplicationDelegate,
    NSWindowDelegate {
    let window: NSWindow
    let cleanup: () -> Void

    init(window: NSWindow, cleanup: @escaping () -> Void) {
        self.window = window
        self.cleanup = cleanup
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { cleanup() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private final class RPGUIHarnessAccessibilityElement: NSAccessibilityElement {
    init(role: NSAccessibility.Role, label: String, value: String?,
         help: String?, enabled: Bool, selected: Bool,
         frame: NSRect, parent: RPGUIHarnessView) {
        super.init()
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityHelp(help)
        setAccessibilityEnabled(enabled)
        setAccessibilitySelected(selected)
        setAccessibilityFrame(frame)
        setAccessibilityParent(parent)
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] { [] }
}

private final class RPGUIHarnessView: NSView {
    let fixture: RPGUIHarnessFixture
    let highContrast: Bool
    private var accessibilityPublished = false

    init(frame: NSRect, fixture: RPGUIHarnessFixture, highContrast: Bool) {
        self.fixture = fixture
        self.highContrast = highContrast
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("RPG UI fixture")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !accessibilityPublished else { return }
        accessibilityPublished = true
        setAccessibilityChildren(accessibilityElements())
        NSAccessibility.post(element: self, notification: .layoutChanged)
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: fixture.model.authority.voiceOverAnnouncement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = highContrast ? NSColor.white : NSColor(calibratedWhite: 0.10, alpha: 1)
        background.setFill()
        bounds.fill()

        let model = fixture.model
        let panel = rect(model.panelFrame)
        (highContrast ? NSColor.white : NSColor(calibratedWhite: 0.92, alpha: 1)).setFill()
        panel.fill()
        (highContrast ? NSColor.black : NSColor(calibratedWhite: 0.35, alpha: 1)).setStroke()
        NSBezierPath(rect: panel).stroke()

        let header = rect(model.layout.headerFrame)
        let authorityFrame = rect(model.layout.authorityChipFrame)
        drawAuthorityIcon(model.authority.proceduralIconID,
                          in: NSRect(x: authorityFrame.minX + 2, y: authorityFrame.minY,
                                     width: 18, height: 18))
        drawText(model.headerText, at: NSPoint(x: header.minX + 4, y: header.minY + 4),
                 size: 15, color: .black, bold: true)
        drawText(model.authority.visibleTitle,
                 at: NSPoint(x: authorityFrame.minX + 24, y: authorityFrame.minY + 3),
                 size: 11, color: highContrast ? .black : NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.13, alpha: 1))
        drawText(model.authority.proceduralIconID,
                 at: NSPoint(x: panel.maxX - 130, y: panel.minY + 10),
                 size: 8, color: .darkGray)
        if let statusDescriptor = model.descriptors.first(where: {
            $0.id.rawValue == "status:current"
        }) {
            let frame = rect(statusDescriptor.frame)
            if let status = model.status {
                drawStatusIcon(status.kind,
                    in: NSRect(x: frame.minX + 4, y: frame.minY + 2,
                               width: 16, height: 16))
            }
            drawText("Status", at: NSPoint(x: frame.minX + 26, y: frame.minY + 2),
                     size: 9, color: highContrast ? .black : .darkGray)
        }
        if let detailFrame = model.layout.contextualDetailFrame {
            let frame = rect(detailFrame)
            for (index, line) in model.contextualDetailLines.enumerated() {
                drawText(line, at: NSPoint(x: frame.minX + 4,
                                           y: frame.minY + 2 + Double(index) * 12),
                         size: 9, color: highContrast ? .black : .darkGray)
            }
        }

        for descriptor in model.visibleDescriptors {
            if descriptor.id.rawValue == "authority:phase" ||
                descriptor.id.rawValue == "status:current" ||
                descriptor.id.rawValue == "contextual-detail" { continue }
            drawDescriptor(descriptor, focusedID: model.focusedID)
        }
        if model.focusedID?.rawValue == "status:current",
           let statusDescriptor = model.descriptors.first(where: {
               $0.id.rawValue == "status:current"
           }) {
            drawFocusRing(frame: statusDescriptor.frame)
        }
        if model.focusedID?.rawValue == "authority:phase",
           let authorityDescriptor = model.descriptors.first(where: {
               $0.id.rawValue == "authority:phase"
           }) {
            drawFocusRing(frame: authorityDescriptor.frame)
        }
        drawText(model.footerText,
                 in: rect(model.layout.footerHelpFrame),
                 size: 9, color: .darkGray)
    }

    private func drawDescriptor(_ descriptor: RPGSemanticDescriptor,
                                focusedID: RPGUIElementID?) {
        guard let visible = descriptor.visibleFrame else { return }
        guard rpgDescriptorVisualLinesFit(
            frame: descriptor.frame, iconAssetID: descriptor.iconAssetID,
            visualLines: descriptor.visualLines) else { return }
        let frame = rect(visible)
        let highlighted = descriptor.selected || descriptor.prepared || descriptor.slotted
        let fill: NSColor
        if descriptor.locked || !descriptor.enabled {
            fill = highContrast ? NSColor(calibratedWhite: 0.82, alpha: 1) :
                NSColor(calibratedWhite: 0.67, alpha: 1)
        } else if highlighted {
            fill = highContrast ? .white :
                NSColor(calibratedRed: 0.85, green: 0.93, blue: 0.77, alpha: 1)
        } else {
            fill = highContrast ? .white : NSColor(calibratedWhite: 0.85, alpha: 1)
        }
        fill.setFill()
        frame.fill()
        (highContrast ? NSColor.black : NSColor.gray).setStroke()
        let outline = NSBezierPath(rect: frame)
        outline.lineWidth = 1
        outline.stroke()
        if descriptor.adornment == .selectedCheckDoubleBorder {
            let inner = NSBezierPath(rect: frame.insetBy(dx: 2, dy: 2))
            inner.lineWidth = 1
            inner.stroke()
            drawText("✓", at: NSPoint(x: frame.maxX - 14, y: frame.minY + 3),
                     size: 9, color: .black)
        } else if descriptor.adornment == .moveLeft || descriptor.adornment == .moveRight {
            let path = NSBezierPath()
            let x = descriptor.adornment == .moveLeft ? frame.minX + 3 : frame.maxX - 3
            let direction = descriptor.adornment == .moveLeft ? 1.0 : -1.0
            path.move(to: NSPoint(x: x, y: frame.midY))
            path.line(to: NSPoint(x: x + direction * 6, y: frame.midY - 4))
            path.move(to: NSPoint(x: x, y: frame.midY))
            path.line(to: NSPoint(x: x + direction * 6, y: frame.midY + 4))
            path.lineWidth = 1
            path.stroke()
        }
        var textX = frame.minX + 4
        if let icon = descriptor.iconAssetID {
            drawRPGIconPixels(icon, in: NSRect(x: frame.minX + 4,
                                               y: frame.minY + 4,
                                               width: 24, height: 24))
            textX += 28
        }
        for (index, line) in descriptor.visualLines.enumerated() {
            let y = frame.minY + 3 + Double(index) * 9
            drawText(line, at: NSPoint(x: textX, y: y),
                     size: index == 0 ? 9 : 7.5,
                     color: index == 0 && !descriptor.locked ? .black : .darkGray)
        }
        if descriptor.id == focusedID {
            drawFocusRing(frame: visible)
        }
    }

    private func drawFocusRing(frame: RPGLogicalRect) {
        let token = rpgFocusRingToken(highContrast: highContrast)
        guard let geometry = rpgFocusRingGeometry(frame: frame, token: token) else { return }
        NSColor.white.setStroke()
        let outer = NSBezierPath(rect: rect(geometry.lightOuterFrame))
        outer.lineWidth = token.lightOuterWidth
        outer.stroke()
        NSColor.black.setStroke()
        let inner = NSBezierPath(rect: rect(geometry.darkSeparationFrame))
        inner.lineWidth = token.darkSeparationWidth
        inner.stroke()
    }

    private func drawRPGIconPixels(_ assetID: String, in frame: NSRect) {
        guard let pixels = rpgIconPixels(assetID: assetID), pixels.count == 16 * 16 * 4 else { return }
        let sx = frame.width / 16, sy = frame.height / 16
        for y in 0..<16 {
            for x in 0..<16 {
                let offset = (y * 16 + x) * 4
                let alpha = CGFloat(pixels[offset + 3]) / 255
                guard alpha > 0 else { continue }
                NSColor(calibratedRed: CGFloat(pixels[offset]) / 255,
                        green: CGFloat(pixels[offset + 1]) / 255,
                        blue: CGFloat(pixels[offset + 2]) / 255,
                        alpha: alpha).setFill()
                NSRect(x: frame.minX + Double(x) * sx,
                       y: frame.minY + Double(y) * sy,
                       width: sx, height: sy).fill()
            }
        }
    }

    private func drawSharedWrappedText(_ text: String, at origin: NSPoint,
                                       width: Double, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ]
        for (index, line) in rpgWrappedPresentationLines(text, width: width).enumerated() {
            (line as NSString).draw(
                at: NSPoint(x: origin.x, y: origin.y + Double(index) * 12),
                withAttributes: attributes)
        }
    }

    private func drawAuthorityIcon(_ identifier: String, in frame: NSRect) {
        NSColor.black.setStroke()
        let path = NSBezierPath()
        switch identifier {
        case "authority.ready":
            path.move(to: NSPoint(x: frame.minX + 2, y: frame.midY))
            path.line(to: NSPoint(x: frame.midX - 1, y: frame.maxY - 3))
            path.line(to: NSPoint(x: frame.maxX - 2, y: frame.minY + 3))
        case "authority.awaitingHost":
            path.appendRect(frame.insetBy(dx: 3, dy: 2))
            path.move(to: NSPoint(x: frame.minX + 4, y: frame.minY + 3))
            path.line(to: NSPoint(x: frame.maxX - 4, y: frame.maxY - 3))
            path.move(to: NSPoint(x: frame.maxX - 4, y: frame.minY + 3))
            path.line(to: NSPoint(x: frame.minX + 4, y: frame.maxY - 3))
        case "authority.savingAccepted", "authority.savingRejected":
            path.appendRect(frame.insetBy(dx: 2, dy: 2))
            path.appendRect(NSRect(x: frame.minX + 5, y: frame.minY + 3,
                                   width: frame.width - 10, height: 5))
            if identifier == "authority.savingAccepted" {
                path.move(to: NSPoint(x: frame.minX + 4, y: frame.midY + 2))
                path.line(to: NSPoint(x: frame.midX - 1, y: frame.maxY - 4))
                path.line(to: NSPoint(x: frame.maxX - 3, y: frame.midY - 1))
            } else {
                path.move(to: NSPoint(x: frame.minX + 4, y: frame.midY))
                path.line(to: NSPoint(x: frame.maxX - 4, y: frame.maxY - 3))
                path.move(to: NSPoint(x: frame.maxX - 4, y: frame.midY))
                path.line(to: NSPoint(x: frame.minX + 4, y: frame.maxY - 3))
            }
        case "authority.reconnecting":
            path.appendArc(withCenter: NSPoint(x: frame.midX, y: frame.midY),
                           radius: frame.width / 2 - 3, startAngle: 25, endAngle: 165)
            path.appendArc(withCenter: NSPoint(x: frame.midX, y: frame.midY),
                           radius: frame.width / 2 - 3, startAngle: 205, endAngle: 345)
            path.move(to: NSPoint(x: frame.minX + 2, y: frame.midY - 1))
            path.line(to: NSPoint(x: frame.minX + 7, y: frame.midY - 4))
            path.move(to: NSPoint(x: frame.maxX - 2, y: frame.midY + 1))
            path.line(to: NSPoint(x: frame.maxX - 7, y: frame.midY + 4))
        case "authority.finalizing":
            path.move(to: NSPoint(x: frame.minX + 2, y: frame.minY + 6))
            path.line(to: NSPoint(x: frame.minX + 5, y: frame.maxY - 3))
            path.line(to: NSPoint(x: frame.maxX - 5, y: frame.maxY - 3))
            path.line(to: NSPoint(x: frame.maxX - 2, y: frame.minY + 6))
            path.close()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.midX - 2, y: frame.midY,
                                        width: 4, height: 4)).fill()
        case "authority.exhausted":
            let inset = frame.insetBy(dx: 2, dy: 2)
            let cut = 4.0
            path.move(to: NSPoint(x: inset.minX + cut, y: inset.minY))
            path.line(to: NSPoint(x: inset.maxX - cut, y: inset.minY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.minY + cut))
            path.line(to: NSPoint(x: inset.maxX, y: inset.maxY - cut))
            path.line(to: NSPoint(x: inset.maxX - cut, y: inset.maxY))
            path.line(to: NSPoint(x: inset.minX + cut, y: inset.maxY))
            path.line(to: NSPoint(x: inset.minX, y: inset.maxY - cut))
            path.line(to: NSPoint(x: inset.minX, y: inset.minY + cut))
            path.close()
        case "authority.unavailable":
            path.appendRect(NSRect(x: frame.minX + 3, y: frame.midY,
                                   width: frame.width - 6, height: frame.height / 2 - 2))
            path.appendArc(withCenter: NSPoint(x: frame.midX, y: frame.midY),
                           radius: frame.width / 4, startAngle: 180, endAngle: 360)
        default:
            path.move(to: NSPoint(x: frame.minX + 4, y: frame.maxY - 4))
            path.line(to: NSPoint(x: frame.maxX - 4, y: frame.minY + 4))
        }
        path.lineWidth = highContrast ? 3 : 1.5
        path.stroke()
    }

    private func drawStatusIcon(_ kind: RPGStatusKind, in frame: NSRect) {
        NSColor.black.setStroke()
        let path = NSBezierPath()
        switch kind {
        case .success:
            path.move(to: NSPoint(x: frame.minX + 1, y: frame.midY))
            path.line(to: NSPoint(x: frame.midX - 1, y: frame.maxY - 2))
            path.line(to: NSPoint(x: frame.maxX - 1, y: frame.minY + 2))
        case .pending:
            path.appendRect(frame.insetBy(dx: 2, dy: 1))
            path.move(to: NSPoint(x: frame.minX + 3, y: frame.minY + 2))
            path.line(to: NSPoint(x: frame.maxX - 3, y: frame.maxY - 2))
            path.move(to: NSPoint(x: frame.maxX - 3, y: frame.minY + 2))
            path.line(to: NSPoint(x: frame.minX + 3, y: frame.maxY - 2))
        case .rejection:
            path.move(to: NSPoint(x: frame.minX + 2, y: frame.minY + 2))
            path.line(to: NSPoint(x: frame.maxX - 2, y: frame.maxY - 2))
            path.move(to: NSPoint(x: frame.maxX - 2, y: frame.minY + 2))
            path.line(to: NSPoint(x: frame.minX + 2, y: frame.maxY - 2))
        case .cooldown:
            path.appendOval(in: frame.insetBy(dx: 1, dy: 1))
            path.move(to: NSPoint(x: frame.midX, y: frame.midY))
            path.line(to: NSPoint(x: frame.midX, y: frame.minY + 3))
            path.move(to: NSPoint(x: frame.midX, y: frame.midY))
            path.line(to: NSPoint(x: frame.maxX - 3, y: frame.midY))
        case .fatigue:
            path.move(to: NSPoint(x: frame.minX + 2, y: frame.maxY - 2))
            path.line(to: NSPoint(x: frame.midX, y: frame.minY + 1))
            path.line(to: NSPoint(x: frame.midX - 1, y: frame.midY))
            path.line(to: NSPoint(x: frame.maxX - 2, y: frame.midY - 1))
        case .missingFocus:
            path.appendOval(in: frame.insetBy(dx: 2, dy: 2))
            path.move(to: NSPoint(x: frame.midX, y: frame.minY))
            path.line(to: NSPoint(x: frame.midX, y: frame.maxY))
            path.move(to: NSPoint(x: frame.minX, y: frame.midY))
            path.line(to: NSPoint(x: frame.maxX, y: frame.midY))
        case .missingEquipment:
            path.appendRect(frame.insetBy(dx: 3, dy: 1))
            path.move(to: NSPoint(x: frame.minX + 3, y: frame.midY))
            path.line(to: NSPoint(x: frame.maxX - 3, y: frame.midY))
        case .permissionDenied:
            path.appendRect(NSRect(x: frame.minX + 2, y: frame.midY,
                                   width: frame.width - 4, height: frame.height / 2 - 1))
            path.appendArc(withCenter: NSPoint(x: frame.midX, y: frame.midY),
                           radius: frame.width / 4, startAngle: 180, endAngle: 360)
        case .persistenceFailure:
            path.appendRect(frame.insetBy(dx: 1, dy: 1))
            path.appendRect(NSRect(x: frame.minX + 4, y: frame.minY + 2,
                                   width: frame.width - 8, height: 4))
            path.move(to: NSPoint(x: frame.minX + 3, y: frame.maxY - 3))
            path.line(to: NSPoint(x: frame.maxX - 3, y: frame.midY))
        case .authorityExhausted:
            path.appendOval(in: frame.insetBy(dx: 1, dy: 1))
            path.move(to: NSPoint(x: frame.minX + 3, y: frame.midY))
            path.line(to: NSPoint(x: frame.maxX - 3, y: frame.midY))
        }
        path.lineWidth = highContrast ? 3 : 1.5
        path.stroke()
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat,
                          color: NSColor, bold: Bool = false) {
        drawText(text, in: NSRect(x: point.x, y: point.y,
                                  width: max(1, bounds.maxX - point.x - 6), height: size + 4),
                 size: size, color: color, bold: bold)
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat,
                          color: NSColor, bold: Bool = false) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                attributes: [.font: font, .foregroundColor: color,
                                             .paragraphStyle: paragraph])
    }

    private func rect(_ logical: RPGLogicalRect) -> NSRect {
        NSRect(x: logical.x, y: logical.y, width: logical.width, height: logical.height)
    }

    private func accessibilityElements() -> [RPGUIHarnessAccessibilityElement] {
        fixture.model.descriptors.prefix(512).map { descriptor in
            RPGUIHarnessAccessibilityElement(
                role: Self.accessibilityRole(descriptor.role),
                label: descriptor.label, value: Self.accessibilityValue(descriptor),
                help: descriptor.help.isEmpty ? nil : descriptor.help,
                enabled: descriptor.enabled && !descriptor.locked,
                selected: descriptor.selected,
                frame: accessibilityScreenFrame(rect(descriptor.frame)), parent: self)
        }
    }

    private static func accessibilityRole(_ role: RPGSemanticRole) -> NSAccessibility.Role {
        switch role {
        case .button: return .button
        case .staticText: return .staticText
        case .tab: return .radioButton
        case .group: return .group
        case .row: return .row
        case .scrollArea: return .scrollArea
        case .rankCell: return .cell
        }
    }

    private static func accessibilityValue(_ descriptor: RPGSemanticDescriptor) -> String {
        if descriptor.id.rawValue == "authority:phase" ||
            descriptor.id.rawValue == "status:current" {
            return descriptor.value
        }
        var values: [String] = []
        if !descriptor.value.isEmpty { values.append(descriptor.value) }
        if descriptor.role == .rankCell,
           let rank = descriptor.id.rawValue.components(separatedBy: ":rank:").last,
           Int(rank) != nil { values.append("Rank " + rank) }
        if descriptor.selected { values.append("Selected") }
        if descriptor.prepared { values.append("Prepared") }
        if descriptor.slotted { values.append("Slotted") }
        values.append(descriptor.locked ? "Locked" : descriptor.enabled ? "Enabled" : "Disabled")
        return values.joined(separator: ", ")
    }

    private func accessibilityScreenFrame(_ viewRect: NSRect) -> NSRect {
        guard let window, viewRect.width.isFinite, viewRect.height.isFinite,
              viewRect.origin.x.isFinite, viewRect.origin.y.isFinite,
              viewRect.width > 0, viewRect.height > 0,
              viewRect.width <= 1_000_000, viewRect.height <= 1_000_000 else { return .zero }
        let windowRect = convert(viewRect, to: nil)
        let screenOrigin = window.convertPoint(toScreen: windowRect.origin)
        guard screenOrigin.x.isFinite, screenOrigin.y.isFinite,
              abs(screenOrigin.x) <= 10_000_000, abs(screenOrigin.y) <= 10_000_000 else {
            return .zero
        }
        return NSRect(origin: screenOrigin, size: windowRect.size)
    }
}

private final class RPGUIHarnessReservedOutput: @unchecked Sendable {
    private var descriptor: Int32
    private var directoryDescriptor: Int32
    private let basename: String
    let path: String

    private init(descriptor: Int32, directoryDescriptor: Int32,
                 basename: String, path: String) {
        self.descriptor = descriptor
        self.directoryDescriptor = directoryDescriptor
        self.basename = basename
        self.path = path
    }

    deinit { abandon() }

    static func reserve(_ shot: RPGUIHarnessShotSpec) throws -> RPGUIHarnessReservedOutput {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let temporaryDescriptor = Darwin.open(
            temporary.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard temporaryDescriptor >= 0 else { throw RPGUIHarnessRuntimeError.unsafeOutput }
        defer { _ = Darwin.close(temporaryDescriptor) }
        let directoryName = "PebbleRPGUIHarness-v1"
        if mkdirat(temporaryDescriptor, directoryName, S_IRWXU) != 0, errno != EEXIST {
            throw RPGUIHarnessRuntimeError.unsafeOutput
        }
        let directoryDescriptor = openat(
            temporaryDescriptor, directoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw RPGUIHarnessRuntimeError.unsafeOutput
        }
        var information = stat()
        guard fstat(directoryDescriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(),
              information.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            _ = Darwin.close(directoryDescriptor)
            throw RPGUIHarnessRuntimeError.unsafeOutput
        }
        let descriptor = openat(directoryDescriptor, shot.basename,
                                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                                S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            _ = Darwin.close(directoryDescriptor)
            throw RPGUIHarnessRuntimeError.unsafeOutput
        }
        let output = temporary.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(shot.basename, isDirectory: false).path
        return RPGUIHarnessReservedOutput(descriptor: descriptor,
            directoryDescriptor: directoryDescriptor, basename: shot.basename, path: output)
    }

    func write(_ data: Data) throws {
        var writeError = false
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count <= 0 {
                    writeError = true
                    break
                }
                offset += count
            }
        }
        guard !writeError, fsync(descriptor) == 0, Darwin.close(descriptor) == 0 else {
            _ = Darwin.close(descriptor)
            descriptor = -1
            _ = unlinkat(directoryDescriptor, basename, 0)
            closeDirectory()
            throw RPGUIHarnessRuntimeError.outputFailed
        }
        descriptor = -1
        closeDirectory()
    }

    func abandon() {
        guard descriptor >= 0 else {
            closeDirectory()
            return
        }
        _ = Darwin.close(descriptor)
        descriptor = -1
        _ = unlinkat(directoryDescriptor, basename, 0)
        closeDirectory()
    }

    private func closeDirectory() {
        guard directoryDescriptor >= 0 else { return }
        _ = Darwin.close(directoryDescriptor)
        directoryDescriptor = -1
    }
}

@MainActor
func runRPGUIHarness(_ bootstrap: RPGUIHarnessBootstrap) {
    guard let fixture = RPGUIHarnessFixture.build(bootstrap) else {
        rpgUIHarnessExit("RPG UI harness failed: invalid fixture")
    }
    let reserved: RPGUIHarnessReservedOutput?
    do {
        reserved = try bootstrap.shot.map(RPGUIHarnessReservedOutput.reserve)
    } catch {
        rpgUIHarnessExit("RPG UI harness failed: unsafe screenshot output")
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let size = bootstrap.viewport.size
    let view = RPGUIHarnessView(
        frame: NSRect(x: 0, y: 0, width: size.0, height: size.1),
        fixture: fixture, highContrast: bootstrap.appearance.highContrast)
    let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
    window.title = "Pebble RPG UI Harness"
    window.contentView = view
    let delegate = RPGUIHarnessApplicationDelegate(window: window) {
        reserved?.abandon()
    }
    window.delegate = delegate
    application.delegate = delegate

    if bootstrap.semanticSummaryRequested {
        print(fixture.summary)
        fflush(stdout)
    }
    if let reserved, let shot = bootstrap.shot {
        var frames = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            frames += 1
            guard frames >= shot.frames else { return }
            timer.invalidate()
            view.display()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                reserved.abandon()
                rpgUIHarnessExit("RPG UI harness failed: screenshot render")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                reserved.abandon()
                rpgUIHarnessExit("RPG UI harness failed: screenshot encode")
            }
            do {
                try reserved.write(data)
                print("[rpg-ui-harness] screenshot=" + reserved.path)
                fflush(stdout)
                application.terminate(nil)
            } catch {
                rpgUIHarnessExit("RPG UI harness failed: screenshot write")
            }
        }
    } else if bootstrap.semanticSummaryRequested {
        DispatchQueue.main.async { application.terminate(nil) }
    }
    application.run()
}

private func rpgUIHarnessExit(_ message: String) -> Never {
    let bounded = String(message.prefix(256)) + "\n"
    FileHandle.standardError.write(Data(bounded.utf8))
    Darwin.exit(64)
}

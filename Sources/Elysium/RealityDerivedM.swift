import AppKit
import ElysiumCore
import Foundation
import WebKit

struct RealityDerivedGenerationOptions {
    let worldName: String
    let seedText: String
    let gameMode: Int
    let difficulty: Int
    let rpgClassesEnabled: Bool
    let mapSize: WorldMapSize
}

enum RealityDerivedRequestValidation {
    static func helperBuildingArgument(includeBuildings: Bool) -> String {
        "--include-buildings=\(includeBuildings ? "true" : "false")"
    }

    static func canonicalBBox(_ text: String, scale: Double = 1,
                              mapSize: WorldMapSize = .small) -> String? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
        guard parts.count == 4,
              let minLat = Double(parts[0]), let minLon = Double(parts[1]),
              let maxLat = Double(parts[2]), let maxLon = Double(parts[3]),
              [minLat, minLon, maxLat, maxLon].allSatisfy(\.isFinite),
              minLat >= -90, maxLat <= 90, minLon >= -180, maxLon <= 180,
              minLat < maxLat, minLon < maxLon else { return nil }
        let middleLatitude = (minLat + maxLat) * 0.5 * .pi / 180
        let height = (maxLat - minLat) * 111_320
        let width = (maxLon - minLon) * 111_320 * max(0.01, cos(middleLatitude))
        let projectedWidth = width * scale
        let projectedHeight = height * scale
        let chunksWide = ceil(projectedWidth / 16)
        let chunksDeep = ceil(projectedHeight / 16)
        let estimatedChunks = chunksWide * chunksDeep
        let estimatedTransitionChunks = 8 * (chunksWide + chunksDeep) + 64
        guard scale.isFinite, scale >= 0.5, scale <= 3,
              width * height <= REALITY_DERIVED_MAX_PHYSICAL_AREA_SQUARE_METRES,
              projectedWidth <= Double(mapSize.sideBlocks),
              projectedHeight <= Double(mapSize.sideBlocks),
              projectedHeight * projectedWidth <= mapSize.maximumAreaSquareMetres,
              projectedHeight * projectedWidth <= REALITY_DERIVED_MAX_PROJECTED_BLOCK_COLUMNS,
              estimatedChunks <= Double(REALITY_DERIVED_MAX_IMPORTED_CHUNKS),
              estimatedChunks + estimatedTransitionChunks <= Double(REALITY_DERIVED_MAX_TOTAL_CHUNKS) else {
            return nil
        }
        return [minLat, minLon, maxLat, maxLon]
            .map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) }
            .joined(separator: ",")
    }
}

final class RealityDerivedCoordinator: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    private weak var owner: AppDelegate?
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var bboxLabel: NSTextField?
    private var buildingsCheckbox: NSButton?
    private var scaleSlider: NSSlider?
    private var scaleLabel: NSTextField?
    private var generateButton: NSButton?
    private var cancelButton: NSButton?
    private var progressLabel: NSTextField?
    private var bboxText = ""
    private var options: RealityDerivedGenerationOptions?
    private var completion: ((WorldRecord) -> Void)?
    private var cancellation: (() -> Void)?
    private var activeProcess: Process?
    private var activeProcessStarted = false
    private let processLock = NSLock()
    private var cancelled = false
    private var pulseTimer: Timer?
    private var pulse = 0

    init(owner: AppDelegate) {
        self.owner = owner
        super.init()
    }

    func present(options: RealityDerivedGenerationOptions,
                 completion: @escaping (WorldRecord) -> Void,
                 cancellation: @escaping () -> Void) {
        guard panel == nil, let parent = owner?.window else { return }
        self.options = options
        self.completion = completion
        self.cancellation = cancellation
        processLock.lock()
        cancelled = false
        processLock.unlock()
        bboxText = ""

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "elysiumReality")
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener('message', function(event) {
              if (event.data && typeof event.data.bboxText === 'string') {
                window.webkit.messageHandlers.elysiumReality.postMessage({bboxText:event.data.bboxText});
              }
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = controller

        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sheet.title = "Reality Derived Map — powered by Arnis"
        sheet.minSize = NSSize(width: 760, height: 600)
        sheet.delegate = self
        let content = NSView(frame: sheet.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        sheet.contentView = content

        let map = WKWebView(frame: NSRect(x: 16, y: 128, width: 968, height: 616), configuration: configuration)
        map.autoresizingMask = [.width, .height]
        map.customUserAgent = "Elysium/1.1 RealityDerived (contact: github.com/mweingartner/elysium)"
        content.addSubview(map)
        webView = map

        let bbox = NSTextField(labelWithString: "Search for a place, then draw or resize a rectangle on the map.")
        bbox.frame = NSRect(x: 16, y: 94, width: 600, height: 22)
        bbox.autoresizingMask = [.width, .minYMargin]
        bbox.lineBreakMode = .byTruncatingMiddle
        content.addSubview(bbox)
        bboxLabel = bbox
        bbox.toolTip = "Selected size: \(options.mapSize.displayName), up to \(options.mapSize.sideBlocks) m per side at 1× scale."

        let buildings = NSButton(checkboxWithTitle: "Include buildings", target: nil, action: nil)
        buildings.frame = NSRect(x: 16, y: 52, width: 220, height: 28)
        buildings.state = .on
        buildings.toolTip = "Include OpenStreetMap buildings. Real terrain is generated either way."
        content.addSubview(buildings)
        buildingsCheckbox = buildings

        let scaleTitle = NSTextField(labelWithString: "Scale: 1.00×")
        scaleTitle.frame = NSRect(x: 252, y: 57, width: 100, height: 20)
        content.addSubview(scaleTitle)
        scaleLabel = scaleTitle
        let scale = NSSlider(value: 1, minValue: 0.5, maxValue: 3, target: self,
                             action: #selector(scaleChanged(_:)))
        scale.frame = NSRect(x: 352, y: 53, width: 180, height: 24)
        content.addSubview(scale)
        scaleSlider = scale

        let initialStatus = options.mapSize == .large || options.mapSize == .extraLarge || options.mapSize == .max
            ? "Large maps can take hours and substantial disk space · Map data © OpenStreetMap contributors"
            : "Map data © OpenStreetMap contributors · Arnis is Apache-2.0 licensed"
        let progress = NSTextField(labelWithString: initialStatus)
        progress.frame = NSRect(x: 16, y: 17, width: 610, height: 22)
        progress.autoresizingMask = [.width, .maxXMargin]
        progress.lineBreakMode = .byTruncatingTail
        content.addSubview(progress)
        progressLabel = progress

        let generate = NSButton(title: "Generate Map", target: self, action: #selector(generate(_:)))
        generate.frame = NSRect(x: 756, y: 50, width: 120, height: 32)
        generate.autoresizingMask = [.minXMargin]
        generate.isEnabled = false
        generate.keyEquivalent = "\r"
        content.addSubview(generate)
        generateButton = generate
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 884, y: 50, width: 100, height: 32)
        cancel.autoresizingMask = [.minXMargin]
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        cancelButton = cancel

        guard let mapURL = arnisMapURL() else {
            progress.stringValue = "Arnis map resources are missing from this Elysium build."
            generate.isEnabled = false
            panel = sheet
            parent.beginSheet(sheet)
            return
        }
        map.loadFileURL(mapURL, allowingReadAccessTo: mapURL.deletingLastPathComponent())
        panel = sheet
        parent.beginSheet(sheet)
    }

    private func arnisMapURL() -> URL? {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("ArnisUI/maps.html"),
           FileManager.default.fileExists(atPath: resource.path) { return resource }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let development = sourceRoot.appendingPathComponent("Vendor/Arnis/src/gui/maps.html")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["bboxText"] as? String else { return }
        Task { @MainActor [weak self] in self?.acceptBBox(text) }
    }

    private func acceptBBox(_ text: String) {
        bboxText = text
        if let canonical = RealityDerivedRequestValidation.canonicalBBox(
            text, scale: scaleSlider?.doubleValue ?? 1,
            mapSize: options?.mapSize ?? .small) {
            bboxLabel?.stringValue = "\(options?.mapSize.displayName ?? "Small") map · Selected: \(canonical)"
            processLock.lock()
            let idle = activeProcess == nil
            processLock.unlock()
            generateButton?.isEnabled = idle
        } else {
            let size = options?.mapSize.displayName ?? "selected"
            bboxLabel?.stringValue = "Selection exceeds the \(size) map at this scale; draw a smaller rectangle."
            generateButton?.isEnabled = false
        }
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        scaleLabel?.stringValue = String(format: "Scale: %.2f×", sender.doubleValue)
        acceptBBox(bboxText)
    }

    @objc private func generate(_ sender: NSButton) {
        let scale = scaleSlider?.doubleValue ?? 1
        guard let bbox = RealityDerivedRequestValidation.canonicalBBox(
            bboxText, scale: scale, mapSize: options?.mapSize ?? .small),
              let options, let owner else { return }
        guard let helper = helperURL() else {
            progressLabel?.stringValue = "The signed Arnis generator helper is missing. Reinstall Elysium."
            return
        }
        let worldID = makeRealityDerivedWorldIdentifier()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Elysium-Reality-\(UUID().uuidString)", isDirectory: true)
        let includeBuildings = buildingsCheckbox?.state == .on
        setGenerating(true)
        progressLabel?.stringValue = "Arnis is downloading map and elevation data…"
        startPulse()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak owner] in
            guard let self, let owner else { return }
            do {
                try self.runHelper(
                    helper: helper, output: output, bbox: bbox,
                    includeBuildings: includeBuildings, scale: scale)
                let plan = try makeRealityDerivedImportPlan(at: output, worldID: worldID)
                DispatchQueue.main.async { [weak self] in
                    self?.stopPulse()
                    self?.progressLabel?.stringValue = "Importing \(plan.totalChunkCount.formatted()) chunks…"
                }
                let record = try owner.game.persistRealityDerivedWorld(
                    id: worldID, name: options.worldName, seedText: options.seedText,
                    mode: options.gameMode,
                    difficulty: options.difficulty,
                    rpgClassesEnabled: options.rpgClassesEnabled, mapSize: options.mapSize,
                    plan: plan,
                    progress: { [weak self] completed, total in
                        DispatchQueue.main.async {
                            self?.progressLabel?.stringValue = "Importing terrain: \(completed.formatted()) / \(total.formatted()) chunks"
                        }
                    },
                    cancelled: { [weak self] in self?.isCancelled() ?? true })
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async { [weak self, weak owner] in
                    guard let self, let owner, !self.isCancelled() else { return }
                    self.stopPulse()
                    let completion = self.completion
                    self.completion = nil
                    self.cancellation = nil
                    self.closeSheet()
                    owner.game.enterPersistedRealityDerivedWorld(record)
                    completion?(record)
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isCancelled() else { return }
                    self.stopPulse()
                    self.setGenerating(false)
                    self.progressLabel?.stringValue = (error as? LocalizedError)?.errorDescription
                        ?? "Reality Derived generation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func helperURL() -> URL? {
        let helper = Bundle.main.resourceURL?.appendingPathComponent("Helpers/arnis-elysium")
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path),
              (try? helper.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return helper
    }

    private func runHelper(helper: URL, output: URL, bbox: String,
                           includeBuildings: Bool, scale: Double) throws {
        let process = Process()
        let pipe = Pipe()
        let lock = NSLock()
        var captured = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            if captured.count < 1_048_576 {
                captured.append(data.prefix(1_048_576 - captured.count))
            }
            lock.unlock()
        }
        process.executableURL = helper
        process.arguments = [
            "--elysium", "--output-dir", output.path, "--bbox", bbox,
            "--scale", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), scale),
            "--mode", "geo-terrain",
            RealityDerivedRequestValidation.helperBuildingArgument(includeBuildings: includeBuildings),
            "--no-3d", "--map-item=false",
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        processLock.lock()
        activeProcess = process
        let shouldCancel = cancelled
        processLock.unlock()
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            processLock.lock()
            if activeProcess === process {
                activeProcess = nil
                activeProcessStarted = false
            }
            processLock.unlock()
        }
        if shouldCancel { throw CancellationError() }
        try process.run()
        processLock.lock()
        activeProcessStarted = true
        let cancelAfterStart = cancelled
        processLock.unlock()
        if cancelAfterStart { process.terminate() }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            lock.lock()
            let text = String(data: captured.suffix(4_096), encoding: .utf8) ?? "generator exited with status \(process.terminationStatus)"
            lock.unlock()
            throw NSError(domain: "Elysium.RealityDerived", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    private func setGenerating(_ generating: Bool) {
        generateButton?.isEnabled = !generating && RealityDerivedRequestValidation.canonicalBBox(
            bboxText, scale: scaleSlider?.doubleValue ?? 1,
            mapSize: options?.mapSize ?? .small) != nil
        buildingsCheckbox?.isEnabled = !generating
        scaleSlider?.isEnabled = !generating
        cancelButton?.title = generating ? "Stop" : "Cancel"
    }

    private func startPulse() {
        pulse = 0
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulse = (self.pulse + 1) % 4
            self.progressLabel?.stringValue = "Arnis is downloading and building the map\(String(repeating: ".", count: self.pulse))"
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    @objc private func cancel(_ sender: NSButton) {
        processLock.lock()
        cancelled = true
        let process = activeProcess
        let processStarted = activeProcessStarted
        processLock.unlock()
        if processStarted { process?.terminate() }
        stopPulse()
        let cancellation = cancellation
        self.completion = nil
        self.cancellation = nil
        closeSheet()
        cancellation?()
    }

    private func isCancelled() -> Bool {
        processLock.lock(); defer { processLock.unlock() }
        return cancelled
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(NSButton())
        return false
    }

    private func closeSheet() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "elysiumReality")
        self.panel = nil
        webView = nil
        options = nil
        processLock.lock()
        activeProcess = nil
        activeProcessStarted = false
        processLock.unlock()
    }
}

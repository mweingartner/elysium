import Foundation
import PebbleCore

struct LANHostLaunchRequest {
    let joinCode: String?
    let port: UInt16?
}

final class LANLobbyScreen: Screen {
    private let manager = LANMultiplayerManager.shared
    private let playerNameField = TextField(0, 0, 130, 16, "Player",
                                            id: "lan.player", accessibilityLabel: "Player")
    private let hostCodeField = TextField(0, 0, 70, 16, "Join code",
                                          id: "lan.hostCode", accessibilityLabel: "Host Join Code")
    private let hostPortField = TextField(0, 0, 58, 16, "Port",
                                          id: "lan.hostPort", accessibilityLabel: "Host Port")
    private let joinHostField = TextField(0, 0, 130, 16, "Host",
                                          id: "lan.joinHost", accessibilityLabel: "Manual Host")
    private let joinPortField = TextField(0, 0, 58, 16, "Port",
                                          id: "lan.joinPort", accessibilityLabel: "Join Port")
    private let joinCodeField = TextField(0, 0, 70, 16, "Code",
                                          id: "lan.joinCode", accessibilityLabel: "Join Code")
    private var selectedHost = -1
    private var scroll = 0.0

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        let panelW = min(356.0, ui.width - 24)
        let left = cx - panelW / 2
        var y = 34.0

        playerNameField.x = left + 10
        playerNameField.y = y
        playerNameField.w = 148
        playerNameField.maxLength = LAN_MULTIPLAYER_MAX_PLAYER_NAME_CHARS
        if playerNameField.text.isEmpty {
            playerNameField.text = sanitizedLANPlayerName(NSFullUserName())
            playerNameField.caret = playerNameField.text.count
        }
        fields.append(playerNameField)

        hostCodeField.x = left + 166
        hostCodeField.y = y
        hostCodeField.w = 70
        hostCodeField.maxLength = 8
        hostPortField.x = left + 244
        hostPortField.y = y
        hostPortField.w = 58
        hostPortField.maxLength = 5
        if hostPortField.text.isEmpty {
            hostPortField.text = String(LAN_MULTIPLAYER_DEFAULT_PORT)
            hostPortField.caret = hostPortField.text.count
        }
        fields.append(hostCodeField)
        fields.append(hostPortField)

        y += 24
        let hostButton = Button(left + 10, y, 112, 18, "Host World", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            let code = self.hostCodeField.text.isEmpty ? nil : normalizedLANJoinCode(self.hostCodeField.text)
            if let code, !isValidLANJoinCode(code) {
                pushChat("§c" + LANTransportError.invalidJoinCode.description)
                return
            }
            let port = UInt16(self.hostPortField.text)
            if !self.hostPortField.text.isEmpty && port == nil {
                pushChat("§c" + LANTransportError.invalidPort.description)
                return
            }
            if !game.hasWorld() {
                ui.open(WorldSelectScreen(lanHostRequest: LANHostLaunchRequest(joinCode: code, port: port)), game)
                return
            }
            do {
                try self.manager.startHost(game: game, requestedJoinCode: code, requestedPort: port)
                if let code {
                    self.hostCodeField.text = code
                    self.hostCodeField.caret = code.count
                }
            } catch let error as LANTransportError {
                pushChat("§c" + error.description)
            } catch {
                pushChat("§cLAN host failed: \(error)")
            }
        })
        buttons.append(hostButton)
        buttons.append(Button(left + 130, y, 92, 18, "Browse LAN", { [weak self] in
            self?.manager.startBrowsing()
        }))
        buttons.append(Button(left + 230, y, 72, 18, "Stop", { [weak self] in
            self?.manager.stop()
        }))

        y += 104
        joinHostField.x = left + 10
        joinHostField.y = y
        joinHostField.w = 148
        joinHostField.maxLength = 253
        joinPortField.x = left + 166
        joinPortField.y = y
        joinPortField.w = 58
        joinPortField.maxLength = 5
        joinCodeField.x = left + 232
        joinCodeField.y = y
        joinCodeField.w = 70
        joinCodeField.maxLength = 8
        if joinPortField.text.isEmpty {
            joinPortField.text = String(LAN_MULTIPLAYER_DEFAULT_PORT)
            joinPortField.caret = joinPortField.text.count
        }
        fields.append(joinHostField)
        fields.append(joinPortField)
        fields.append(joinCodeField)

        y += 24
        buttons.append(Button(left + 10, y, panelW - 20, 18, "Join World", { [weak self, weak game] in
            guard let self, let game else { return }
            self.joinWorld(game)
        }))

        buttons.append(Button(cx - 100, ui.height - 30, 200, 20, "Back", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        if game.hasWorld() {
            ui.drawDarkBg(0.7)
        } else {
            ui.drawDirtBg()
        }
        let cv = ui.cv
        let cx = (ui.width / 2).rounded(.down)
        let panelW = min(356.0, ui.width - 24)
        let left = cx - panelW / 2
        let top = 18.0
        let bottom = ui.height - 40
        ui.drawPanel(left, top, panelW, bottom - top)
        cv.drawTextCentered("Multiplayer", cx, top + 8, 1)

        cv.drawText("Player", playerNameField.x, playerNameField.y - 9, 1, "#606060", shadow: false)
        cv.drawText("Code", hostCodeField.x, hostCodeField.y - 9, 1, "#606060", shadow: false)
        cv.drawText("Port", hostPortField.x, hostPortField.y - 9, 1, "#606060", shadow: false)

        let listTop = top + 66
        let listH = 60.0
        cv.setFill("#1c1c1c")
        cv.fillRect(left + 10, listTop, panelW - 20, listH)
        cv.setStroke("#606060")
        cv.strokeRect(left + 10, listTop, panelW - 20, listH)
        drawDiscoveredHosts(ui, x: left + 12, y: listTop + 2, w: panelW - 24, h: listH - 4)

        cv.drawText("Manual Host", joinHostField.x, joinHostField.y - 9, 1, "#606060", shadow: false)
        cv.drawText("Port", joinPortField.x, joinPortField.y - 9, 1, "#606060", shadow: false)
        cv.drawText("Code", joinCodeField.x, joinCodeField.y - 9, 1, "#606060", shadow: false)

        let statusY = joinCodeField.y + 48
        let statusLines = Array(manager.statusSummary().suffix(4))
        for (i, line) in statusLines.enumerated() {
            cv.drawText(clipped(line, maxChars: 54), left + 12, statusY + Double(i) * 10, 1, "#606060", shadow: false)
        }
        ui.drawButtons(self)
    }

    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        scroll = max(0, scroll + dy * 14)
        return true
    }

    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if joinHostField.contains(mx, my) || joinPortField.contains(mx, my) {
            selectedHost = -1
        }
        if super.onMouseDown(ui, game, mx, my, btn) { return true }
        let cx = (ui.width / 2).rounded(.down)
        let panelW = min(356.0, ui.width - 24)
        let left = cx - panelW / 2
        let listTop = 84.0
        let listX = left + 12
        let listW = panelW - 24
        let listH = 56.0
        guard mx >= listX, mx < listX + listW, my >= listTop, my < listTop + listH else { return false }
        let index = Int(((my - listTop) + scroll) / 18)
        if index >= 0, index < manager.discoveredHosts.count {
            selectedHost = index
            return true
        }
        return false
    }

    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if key == "Enter" {
            if joinHostField.focused || joinPortField.focused || joinCodeField.focused || playerNameField.focused {
                joinWorld(game)
                return true
            }
        }
        return super.onKey(ui, game, key)
    }

    private func joinWorld(_ game: GameCore) {
        manager.attachGame(game)
        do {
            if selectedHost >= 0, selectedHost < manager.discoveredHosts.count {
                let host = manager.discoveredHosts[selectedHost]
                try manager.connectToDiscovered(
                    host,
                    playerName: playerNameField.text,
                    joinCode: joinCodeField.text
                )
                pushChat("§7Joining LAN world \(host.displayName).")
                return
            }
            let manualHost = joinHostField.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !manualHost.isEmpty else {
                pushChat("§cSelect a discovered LAN world or enter a manual host address.")
                return
            }
            try manager.directConnect(
                host: manualHost,
                port: joinPortField.text,
                joinCode: joinCodeField.text,
                playerName: playerNameField.text
            )
            pushChat("§7Connecting to \(manualHost):\(joinPortField.text).")
        } catch let error as LANTransportError {
            pushChat("§c" + error.description)
        } catch {
            pushChat("§cLAN join failed: \(error)")
        }
    }

    private func drawDiscoveredHosts(_ ui: UIManager, x: Double, y: Double, w: Double, h: Double) {
        let cv = ui.cv
        let hosts = manager.discoveredHosts
        if hosts.isEmpty {
            cv.drawText("No LAN worlds found", x + 2, y + 4, 1, "#909090", shadow: false)
            return
        }
        scroll = min(scroll, max(0, Double(hosts.count) * 18 - h))
        for (i, host) in hosts.enumerated() {
            let rowY = y + Double(i) * 18 - scroll
            if rowY + 16 < y || rowY > y + h { continue }
            let selected = i == selectedHost
            cv.setFill(selected ? "rgba(255,255,255,0.24)" : "rgba(255,255,255,0.08)")
            cv.fillRect(x, rowY, w, 16)
            cv.drawText(clipped("[\(i)] \(host.displayName)", maxChars: 40), x + 3, rowY + 4, 1, selected ? "#ffffff" : "#d0d0d0", shadow: false)
        }
    }

    private func clipped(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        return String(text.prefix(max(0, maxChars - 3))) + "..."
    }
}

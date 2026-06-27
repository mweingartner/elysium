// Local Ollama HTTP transport for Pebble's in-game AI agent. The core AI action
// executor is in PebbleCore; LAN multiplayer uses its own Network.framework
// adapter in LANTransport.swift.

import Foundation
import PebbleCore

let pebbleOllamaAgent = OllamaAgentService()

final class OllamaAgentService {
    private let baseURL = URL(string: "http://localhost:11434")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: config)
    }

    func run(prompt userPrompt: String, game: GameCore) {
        guard game.hasWorld(), let player = game.player else {
            pushChat("§cThe AI agent needs an active world.")
            return
        }
        let cursor = game.crosshairBlock()
        if let directAction = inferDirectAIAgentAction(from: userPrompt) {
            execute(action: directAction, game: game, player: player, cursor: cursor)
            return
        }

        let model = sanitizedOllamaModelName(game.settings.aiOllamaModel)
        guard !model.isEmpty else {
            pushChat("§cChoose a local Ollama model in Options > AI before using /ai.")
            return
        }
        guard isAllowedLocalOllamaModelName(model) else {
            pushChat("§cPebble AI requires a local Ollama model; cloud-tagged models are not allowed.")
            return
        }

        let savedTemplates = loadSavedTemplates(for: game)
        let prompt = buildAIAgentPrompt(userRequest: userPrompt, world: game.world, player: player,
                                        cursor: cursor, savedTemplates: savedTemplates)
        pushChat("§7<Pebble AI> thinking with \(model)...")

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: generateBody(model: model, prompt: prompt))
        } catch {
            pushChat("§cPebble AI request could not be encoded.")
            return
        }

        session.dataTask(with: request) { [weak self, weak game] data, response, error in
            if let error {
                DispatchQueue.main.async {
                    pushChat("§cPebble AI could not reach local Ollama: \(error.localizedDescription)")
                }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                DispatchQueue.main.async {
                    pushChat("§cPebble AI Ollama request failed with HTTP \(http.statusCode).")
                }
                return
            }
            guard let data else {
                DispatchQueue.main.async { pushChat("§cPebble AI got an empty Ollama response.") }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
                if let error = decoded.error, !error.isEmpty {
                    throw OllamaAgentTransportError.ollama(error)
                }
                guard let response = decoded.response else {
                    throw OllamaAgentTransportError.empty
                }
                let action = try parseAIAgentAction(from: response)
                DispatchQueue.main.async {
                    guard let game, game.hasWorld(), let player = game.player else {
                        pushChat("§cPebble AI response arrived after the world closed.")
                        return
                    }
                    self?.execute(action: action, game: game, player: player, cursor: cursor)
                }
            } catch {
                DispatchQueue.main.async {
                    pushChat("§cPebble AI returned an invalid response: \(error)")
                }
            }
        }.resume()
    }

    private func loadSavedTemplates(for game: GameCore) -> [ObjectTemplate] {
        game.db.listTemplates().prefix(32).compactMap { name in
            try? game.db.getTemplate(named: name)
        }
    }

    private func execute(action: AIAgentAction, game: GameCore, player: Player, cursor: RaycastHit?) {
        do {
            let result: AIAgentExecutionResult
            if isAIAgentTemplateAction(action) {
                result = try executeAIAgentTemplateAction(
                    action,
                    loadTemplate: { try game.db.getTemplate(named: $0) },
                    saveTemplate: { try game.db.putTemplate($0) })
            } else {
                result = try executeAIAgentAction(action, world: game.world, player: player, cursor: cursor)
            }
            pushChat("§d<Pebble AI> §r\(result.message)")
        } catch {
            pushChat("§cPebble AI rejected action: \(error)")
        }
    }

    func fetchModels(_ completion: @escaping (Result<[String], Error>) -> Void) {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"), timeoutInterval: 8)
        session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                DispatchQueue.main.async { completion(.failure(OllamaAgentTransportError.http(http.statusCode))) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                let names = decoded.models
                    .filter { ($0.remoteHost ?? "").isEmpty }
                    .map(\.name)
                    .map(sanitizedOllamaModelName)
                    .filter(isAllowedLocalOllamaModelName)
                    .sorted()
                DispatchQueue.main.async { completion(.success(names)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private func generateBody(model: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "format": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["say", "give_item", "place_block", "fill_hole", "replace_template_blocks", "create_template"],
                    ],
                    "item": ["type": "string"],
                    "block": ["type": "string"],
                    "count": ["type": "integer", "minimum": 1, "maximum": AIAgentMaxGiveCount],
                    "target": ["type": "string", "enum": ["cursor", "front"]],
                    "message": ["type": "string"],
                    "template": ["type": "string"],
                    "name": ["type": "string"],
                    "from_block": ["type": "string"],
                    "to_block": ["type": "string"],
                    "kind": ["type": "string", "enum": ["pirate_ship", "ship", "boat"]],
                    "length": ["type": "integer", "minimum": 16, "maximum": OBJECT_TEMPLATE_MAX_SPAN],
                    "style": ["type": "string"],
                ],
                "required": ["action"],
            ],
        ]
    }
}

private struct OllamaGenerateResponse: Decodable {
    let response: String?
    let error: String?
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
    let remoteHost: String?

    enum CodingKeys: String, CodingKey {
        case name
        case remoteHost = "remote_host"
    }
}

private enum OllamaAgentTransportError: Error, CustomStringConvertible {
    case http(Int)
    case ollama(String)
    case empty

    var description: String {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .ollama(let message): return message
        case .empty: return "empty response"
        }
    }
}

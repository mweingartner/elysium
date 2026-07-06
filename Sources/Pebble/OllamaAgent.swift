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
        do {
            if let stubAction = try aiTestStubActionFromEnvironment() {
                execute(action: stubAction, game: game, player: player, cursor: cursor)
                return
            }
        } catch {
            pushChat("§cPebble AI test stub was invalid: \(error)")
            return
        }
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

        let savedTemplateSummaries = loadSavedTemplateSummaries(for: game)
        let prompt = buildAIAgentPrompt(userRequest: userPrompt, world: game.world, player: player,
                                        cursor: cursor, savedTemplateSummaries: savedTemplateSummaries)
        pushChat("§7<Pebble AI> thinking with \(model)...")

        requestAction(model: model, prompt: prompt) { [weak self, weak game] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let action):
                    guard let game, game.hasWorld(), let player = game.player else {
                        pushChat("§cPebble AI response arrived after the world closed.")
                        return
                    }
                    self?.execute(action: action, game: game, player: player, cursor: cursor)
                case .failure(let error):
                    pushChat("§cPebble AI returned an invalid response: \(error)")
                }
            }
        }
    }

    private func loadSavedTemplateSummaries(for game: GameCore) -> [ObjectTemplateSummary] {
        Array(game.db.listTemplateSummaries().prefix(32))
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
                result = try executeAIAgentAction(
                    action,
                    world: game.world,
                    player: player,
                    cursor: cursor,
                    openScreen: { [weak game] kind, data in game?.openScreen(kind, data) },
                    advance: { [weak game] id in game?.advance(id) },
                    persistPlayerState: { [weak game] in game?.saveAndFlush(synchronous: true) },
                    setDifficulty: { [weak game] difficulty in game?.setDifficulty(difficulty) },
                    setGameRule: { [weak game] rule, value in game?.setGameRule(rule, value) })
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

    private func requestAction(model: String, prompt: String,
                               completion: @escaping (Result<AIAgentAction, Error>) -> Void) {
        let request: URLRequest
        do {
            request = try encodedRequest(path: "api/chat", body: chatBody(model: model, prompt: prompt))
        } catch {
            completion(.failure(error))
            return
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.requestGeneratedAction(model: model, prompt: prompt, completion: completion)
                return
            }
            guard let data else {
                self.requestGeneratedAction(model: model, prompt: prompt, completion: completion)
                return
            }
            do {
                let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                if let error = decoded.error, !error.isEmpty {
                    throw OllamaAgentTransportError.ollama(error)
                }
                if let toolCall = decoded.message?.toolCalls?.first {
                    let argsData: Data
                    switch toolCall.function.arguments {
                    case .object(let object):
                        let args = object.mapValues(\.jsonObject)
                        guard JSONSerialization.isValidJSONObject(args) else {
                            throw OllamaAgentTransportError.invalidToolResponse
                        }
                        argsData = try JSONSerialization.data(withJSONObject: args)
                    case .string(let raw):
                        guard let data = raw.data(using: .utf8) else {
                            throw OllamaAgentTransportError.invalidToolResponse
                        }
                        argsData = data
                    case .none:
                        argsData = Data("{}".utf8)
                    default:
                        throw OllamaAgentTransportError.invalidToolResponse
                    }
                    let action = try parseAIAgentAction(
                        fromToolCallName: toolCall.function.name,
                        argumentsJSONData: argsData)
                    completion(.success(action))
                    return
                }
                if let content = decoded.message?.content,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(.success(try parseAIAgentAction(from: content)))
                    return
                }
                throw OllamaAgentTransportError.empty
            } catch {
                self.requestGeneratedAction(model: model, prompt: prompt, completion: completion)
            }
        }.resume()
    }

    private func requestGeneratedAction(model: String, prompt: String,
                                        completion: @escaping (Result<AIAgentAction, Error>) -> Void) {
        let request: URLRequest
        do {
            request = try encodedRequest(path: "api/generate", body: generateBody(model: model, prompt: prompt))
        } catch {
            completion(.failure(error))
            return
        }
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(OllamaAgentTransportError.http(http.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(OllamaAgentTransportError.empty))
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
                completion(.success(try parseAIAgentAction(from: response)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func encodedRequest(path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // Installed-app proof hook: still routes through the same parser and executor.
    private func aiTestStubActionFromEnvironment() throws -> AIAgentAction? {
        let env = ProcessInfo.processInfo.environment
        if let name = env["PEBBLE_AI_TOOL_STUB_NAME"],
           let args = env["PEBBLE_AI_TOOL_STUB_ARGS"],
           let data = args.data(using: .utf8) {
            return try parseAIAgentAction(fromToolCallName: name, argumentsJSONData: data)
        }
        if let raw = env["PEBBLE_AI_ACTION_STUB"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try parseAIAgentAction(from: raw)
        }
        return nil
    }

    private func generateBody(model: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "format": actionSchema(),
        ]
    }

    private func chatBody(model: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "Call exactly one Pebble tool for world/player mutations. If no mutation is needed, call say. Never invent coordinates.",
                ],
                ["role": "user", "content": prompt],
            ],
            "tools": toolDefinitions(),
            "stream": false,
        ]
    }

    private func actionSchema() -> [String: Any] {
        var properties = commonActionProperties()
        properties["action"] = ["type": "string", "enum": aiAgentSkillActionNames]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": ["action"],
        ]
    }

    private func toolDefinitions() -> [[String: Any]] {
        allAIAgentSkills.map { skill in
            var properties: [String: Any] = [:]
            for parameter in skill.parameters {
                properties[parameter.name] = schema(for: parameter)
            }
            return [
                "type": "function",
                "function": [
                    "name": skill.name,
                    "description": skill.summary,
                    "parameters": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": properties,
                        "required": skill.required,
                    ],
                ],
            ]
        }
    }

    private func commonActionProperties() -> [String: Any] {
        var properties: [String: Any] = [:]
        for skill in allAIAgentSkills {
            for parameter in skill.parameters where properties[parameter.name] == nil {
                properties[parameter.name] = schema(for: parameter)
            }
        }
        properties["name"] = ["type": "string", "description": "Legacy alias for template or entity name."]
        properties["time"] = ["type": "string", "description": "Legacy alias for time value."]
        return properties
    }

    private func schema(for parameter: AIAgentSkillParameter) -> [String: Any] {
        var schema: [String: Any] = [
            "type": parameter.type,
            "description": parameter.summary,
        ]
        if let enumValues = parameter.enumValues {
            schema["enum"] = enumValues
        }
        if let minimum = parameter.minimum {
            schema["minimum"] = minimum
        }
        if let maximum = parameter.maximum {
            schema["maximum"] = maximum
        }
        return schema
    }
}

private struct OllamaGenerateResponse: Decodable {
    let response: String?
    let error: String?
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatMessage?
    let error: String?
}

private struct OllamaChatMessage: Decodable {
    let role: String?
    let content: String?
    let toolCalls: [OllamaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

private struct OllamaToolCall: Decodable {
    let function: OllamaToolFunction
}

private struct OllamaToolFunction: Decodable {
    let name: String
    let arguments: OllamaJSONValue?
}

private enum OllamaJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OllamaJSONValue])
    case array([OllamaJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OllamaJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OllamaJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return Int(value)
            }
            return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.jsonObject)
        case .array(let value): return value.map(\.jsonObject)
        case .null: return NSNull()
        }
    }
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
    case invalidToolResponse

    var description: String {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .ollama(let message): return message
        case .empty: return "empty response"
        case .invalidToolResponse: return "invalid tool response"
        }
    }
}

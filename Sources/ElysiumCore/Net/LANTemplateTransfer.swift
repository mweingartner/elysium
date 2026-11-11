import Foundation
import ElysiumTextInput

// A LAN guest's object-template paste and undo.
//
// Each player keeps their own template library. A guest's paste therefore carries the template
// itself: the host never reads or writes its own library on a guest's behalf, and the only thing a
// guest's bytes reach on the host is the bounded template decoder. A guest's copy stays on the
// guest, because it only reads.

/// The largest template, as `PBT2` bytes, that a guest may send with one place intent. As
/// base64 it is 960,000 characters, which leaves room for the rest of the message inside
/// `LAN_MULTIPLAYER_MAX_FRAME_BYTES`.
public let LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES = 720_000
/// What the payload limit means to a player, in blocks.
public let LAN_MULTIPLAYER_TEMPLATE_GUEST_BLOCK_GUIDE =
    LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES / OBJECT_TEMPLATE_BINARY_BYTES_PER_BLOCK
/// Blocks of slack on the host's reach rule: the guest rounds the object's origin down to whole
/// blocks, and it may have moved since the last position the host heard.
public let LAN_MULTIPLAYER_TEMPLATE_REACH_SLACK = 6.0
/// The host reports a running job's progress to its guest once every this many steps.
public let LAN_MULTIPLAYER_TEMPLATE_PROGRESS_REPORT_STEPS = 30
/// How long a guest waits for the host's answer before it lets the player try again. The host
/// drops a rate-limited intent without answering.
public let LAN_CLIENT_TEMPLATE_ANSWER_TIMEOUT_TICKS = 100

private let LAN_TEMPLATE_INTENT_MAX_COORDINATE = 30_000_000

public struct LANTemplateIntent: Codable, Equatable {
    public enum Action: String, Codable, Equatable {
        case placeTemplate
        case undoPlacement
    }

    private enum CodingKeys: String, CodingKey {
        case action, templateName, x, y, z, rotation, templateData, appliedGrantID
    }

    public var action: Action
    /// For the host's log only. The host takes a placed object's name from the template itself.
    public var templateName: String
    public var x: Int
    public var y: Int
    public var z: Int
    public var rotation: Int
    /// `.placeTemplate` only: the guest's own template as `PBT2` bytes, unrotated. Nil when the
    /// caller gave none or gave more than `LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES`.
    public private(set) var templateData: Data?
    /// The last inventory grant the guest had applied when it sent this. The host charges for a
    /// paste from its copy of the guest's inventory, and that copy is only right once the guest
    /// has removed what the previous paste cost.
    public var appliedGrantID: Int

    public init(action: Action, templateName: String, x: Int, y: Int, z: Int, rotation: Int,
                templateData: Data? = nil, appliedGrantID: Int = 0) {
        let limit = LAN_TEMPLATE_INTENT_MAX_COORDINATE
        self.action = action
        self.appliedGrantID = max(0, appliedGrantID)
        self.templateName = sanitizedLANTemplateName(templateName)
        self.x = max(-limit, min(limit, x))
        self.y = max(-limit, min(limit, y))
        self.z = max(-limit, min(limit, z))
        self.rotation = normalizedTemplateRotation(rotation)
        if action == .placeTemplate, let templateData,
           templateData.count <= LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES {
            self.templateData = templateData
        } else {
            self.templateData = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            action: try c.decode(Action.self, forKey: .action),
            templateName: try c.decodeIfPresent(String.self, forKey: .templateName) ?? "",
            x: try c.decode(Int.self, forKey: .x),
            y: try c.decode(Int.self, forKey: .y),
            z: try c.decode(Int.self, forKey: .z),
            rotation: try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0,
            templateData: (try c.decodeIfPresent(String.self, forKey: .templateData))
                .flatMap(lanTemplateData(fromWireText:)),
            appliedGrantID: try c.decodeIfPresent(Int.self, forKey: .appliedGrantID) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(templateName, forKey: .templateName)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(z, forKey: .z)
        try c.encode(rotation, forKey: .rotation)
        try c.encodeIfPresent(templateData.map(lanTemplateWireText), forKey: .templateData)
        try c.encode(appliedGrantID, forKey: .appliedGrantID)
    }
}

/// Template bytes as JSON text. The URL-safe base64 alphabet is used because `JSONEncoder`
/// writes `/` as two characters, which would make the size of a frame depend on its content.
func lanTemplateWireText(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
}

func lanTemplateData(fromWireText text: String) -> Data? {
    guard text.utf8.count <= (LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES + 2) / 3 * 4 else { return nil }
    return Data(base64Encoded: text
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/"))
}

/// What the host tells a guest whose template request it refuses. These reach the guest's chat,
/// so they are sentences for a player.
public enum LANTemplateRefusal {
    public static let notAllowed = "The host has not allowed you to place objects."
    public static let cannotBuild = "The host has not allowed you to build."
    public static let dead = "You cannot place objects while dead."
    public static let unavailable = "The host could not find your player. Try again in a moment."
    public static let busy = "Your last object is still being placed or undone."
    public static let otherDimension = "Objects can only be placed in the dimension the host is in."
    public static let missingTemplate = "The host received no object to place."
    public static let outOfReach = "That spot is too far away. Move closer or pull the object toward you."
    public static let nothingToUndo = "No object placement to undo."
    public static let undoOtherDimension = "The host is in another dimension than the object, so it cannot be undone now."
    public static let undoNotLoaded = "Move closer to the object to undo it."
    public static let paymentPending = "Your last object is still being paid for. Try again in a moment."

    /// The player-facing sentence for a refusal from `LANMultiplayerHostSession.authorize`.
    static func authorization(_ result: LANAuthorizationResult, for permission: LANGameplayPermission) -> String? {
        guard case .rejected(let reason) = result else { return nil }
        if reason == "player is dead" { return dead }
        if reason.hasPrefix("permission denied") { return permission == .build ? cannotBuild : notAllowed }
        return unavailable
    }
}

/// The bytes a guest sends for `template`, or the reason it cannot be sent.
public func lanGuestTemplatePayload(for template: ObjectTemplate) throws -> Data {
    let data = try encodeObjectTemplate(template)
    guard data.count <= LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES else {
        throw TemplateError.tooLargeForLANGuest(template.blocks.count)
    }
    return data
}

/// Decodes a template a guest sent. The result has passed the same validation as a template read
/// from the host's own library, and the host does not take the guest's word for a single block
/// entity: every block arrives as placing it by hand would leave it (`templateAsPlacedByHand`).
public func lanHostTemplate(fromGuestPayload payload: Data) throws -> ObjectTemplate {
    let data = Data(payload) // the binary reader indexes from zero; a slice may not start there
    guard data.count <= LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES,
          data.prefix(OBJECT_TEMPLATE_BINARY_MAGIC.count) == OBJECT_TEMPLATE_BINARY_MAGIC else {
        throw TemplateError.corruptTemplate("not a template the host can read")
    }
    let template: ObjectTemplate
    do {
        template = try decodeObjectTemplate(data)
    } catch let error as TemplateError {
        throw error
    } catch {
        throw TemplateError.corruptTemplate("unreadable block entity data")
    }
    return templateAsPlacedByHand(template)
}

/// The host's reach rule for a guest's paste. The ordinary block reach cannot apply: the preview
/// sits a size-derived distance ahead of the player and the Up arrow pushes it further. The rule
/// is the furthest the guest's own preview can put the object's centre, plus slack.
/// `template` is validated and unrotated; the target is the rotated template's anchor.
public func isWithinLANTemplateReach(_ player: LANPlayerState, template: ObjectTemplate, rotationSteps: Int,
                                     targetX: Int, targetY: Int, targetZ: Int) -> Bool {
    let size = rotatedTemplateSize(template, rotationSteps: rotationSteps)
    let anchor = rotatedTemplateCoordinate(x: template.anchorX, y: template.anchorY, z: template.anchorZ,
                                           sizeX: template.sizeX, sizeZ: template.sizeZ,
                                           rotationSteps: rotationSteps)
    let dx = Double(targetX) - Double(anchor.x) + Double(size.x) * 0.5 - player.x
    let dy = Double(targetY) - Double(anchor.y) + Double(size.y) * 0.5 - (player.y + PLAYER_EYE)
    let dz = Double(targetZ) - Double(anchor.z) + Double(size.z) * 0.5 - player.z
    let limit = templatePlacementPreviewDistance(forValidated: template)
        + TemplatePlacementSession.maxExtraDistance + LAN_MULTIPLAYER_TEMPLATE_REACH_SLACK
    return dx * dx + dy * dy + dz * dz <= limit * limit
}

/// What a finished placement says, on the host's own screen and on a guest's.
public func templatePlacementCompletionText(name: String, blocks: Int, blockEntities: Int,
                                            cleared: Int, filled: Int, payment: String = "") -> String {
    var details = "\(blocks) blocks, \(blockEntities) block entities"
    if cleared > 0 || filled > 0 { details += ", cleared \(cleared), filled \(filled)" }
    return "Placed object \"\(name)\" - \(details)" + (payment.isEmpty ? "" : ". " + payment)
}

/// The short form of a completion text for the action bar (`Placed object "Name"`); chat has
/// the counts. A name cannot hold a quote, so the closing quote marks where the headline ends.
public func templateCompletionHeadline(_ completionText: String) -> String {
    completionText.range(of: "\" - ").map { String(completionText[..<$0.lowerBound]) + "\"" } ?? completionText
}

/// What a running placement or undo says, on the host's own screen and on a guest's.
public func templateProgressText(undo: Bool = false, name: String, percent: Int, phase: String) -> String {
    "\(undo ? "Undoing" : "Placing") \"\(name)\" \(percent)% - \(phase)"
}

/// What a finished undo says, on the host's own screen and on a guest's.
public func templateUndoCompletionText(name: String, restored: Int, refund: String = "") -> String {
    "Undid object placement \"\(name)\" - restored \(restored) cells" + (refund.isEmpty ? "" : ". " + refund)
}

/// The event the host sends its guest for one template result. A guest acts on the kind and
/// shows the message.
public func lanTemplateGameplayEvent(for result: LANTemplateIntentResult, playerID: String,
                                     tick: Int) -> LANGameplayEvent {
    let kind: LANGameplayEventKind
    let message: String
    switch result {
    case .accepted(let action, let name):
        kind = action == .undoPlacement ? .templateUndoAccepted : .templatePlaceAccepted
        message = action == .undoPlacement ? "Undoing \"\(name)\"" : "Placing \"\(name)\""
    case .progress(let action, let name, let percent, let phase):
        kind = .templateProgress
        message = templateProgressText(undo: action == .undoPlacement, name: name, percent: percent, phase: phase)
    case .placed(let name, let blocks, let blockEntities, let cleared, let filled, let payment):
        kind = .templateCompleted
        message = templatePlacementCompletionText(name: name, blocks: blocks, blockEntities: blockEntities,
                                                  cleared: cleared, filled: filled, payment: payment)
    case .undone(let name, let restored, let refund):
        kind = .templateCompleted
        message = templateUndoCompletionText(name: name, restored: restored, refund: refund)
    case .rejected(let reason):
        kind = .templateRefused
        message = reason
    }
    return LANGameplayEvent(playerID: playerID, kind: kind, message: message, tick: tick)
}

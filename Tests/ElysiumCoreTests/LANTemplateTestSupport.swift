import Foundation
@testable import ElysiumCore

extension LANMultiplayerHostSession {
    /// The suites that use this are about where and how a guest's object is placed, not about
    /// what it costs. Their guest pastes in creative mode the host has granted, which is free
    /// (`lanTemplatePasteIsFree`). What a survival guest pays has its own suite,
    /// `LANTemplatePaymentTests`.
    func letPasteForFree(_ playerID: String) {
        guard var peer = peers[playerID] else { return }
        peer.permissions.canUseCreative = true
        peer.playerState?.gameMode = GameMode.creative
        peers[playerID] = peer
    }

    /// A guest's place intent carries the template itself. Many host tests name a template and
    /// keep it in a dictionary; here that dictionary plays the guest's own library, and the
    /// payload is attached the way the guest's client attaches it. `saveTemplate` is unused: the
    /// host never writes a library for a guest.
    func applyTemplateIntent(
        _ intent: LANTemplateIntent,
        from playerID: String,
        world: World,
        loadTemplate: (String) throws -> ObjectTemplate?,
        saveTemplate: (ObjectTemplate) throws -> Bool
    ) -> LANTemplateIntentResult {
        letPasteForFree(playerID)
        guard intent.action == .placeTemplate, intent.templateData == nil,
              let template = try? loadTemplate(intent.templateName),
              let payload = try? lanGuestTemplatePayload(for: template) else {
            return applyTemplateIntent(intent, from: playerID, world: world)
        }
        return applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: intent.templateName,
                              x: intent.x, y: intent.y, z: intent.z, rotation: intent.rotation,
                              templateData: payload),
            from: playerID, world: world)
    }
}

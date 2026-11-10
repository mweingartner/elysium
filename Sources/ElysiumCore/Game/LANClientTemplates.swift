import Foundation

// A LAN guest's side of object-template paste and undo.
//
// The host owns the world, so a guest never runs a placement or an undo against its own mirror of
// it. The guest sends a `LANTemplateIntent` carrying the template from its own library, and shows
// what the host answers: accepted, progress, completed or refused. The blocks themselves arrive
// through ordinary replication, like every other change to the world.

/// What a LAN guest remembers about its own template requests to the host.
struct LANClientTemplateState {
    /// The armed template as the bytes a place intent carries (unrotated).
    var payload: Data?
    /// Counts the previews armed in this world, and the preview the last place request was sent
    /// from. An accept that arrives after the guest stopped waiting must not take away a preview
    /// the player has armed since.
    var armSerial = 0
    var placeRequestArm: Int?
    /// The request the host has not answered yet, and the ticks left before the guest stops
    /// waiting. One request at a time: an answer always belongs to this request.
    var awaiting: (action: LANTemplateIntent.Action, ticksLeft: Int)?
}

extension GameCore {
    /// A guest arms a template for placement: it must fit in one place intent, and the player
    /// hears so now, before aiming, when it does not.
    func armLANClientTemplate(_ session: TemplatePlacementSession) throws {
        lanClientTemplates.payload = try lanGuestTemplatePayload(for: session.baseTemplate)
        lanClientTemplates.armSerial += 1
    }

    /// The guest's click on the placement preview: asks the host to place the object. The
    /// preview stays armed until the host accepts, so a refusal ("too far away") can be put right
    /// and tried again without opening the browser a second time.
    func commitLANClientTemplatePlacement() throws -> TemplatePlacementResult? {
        guard let session = templatePlacement, lanClientTemplateRequestMayStart() else { return nil }
        guard let handler = lanTemplateIntentHandler, let payload = lanClientTemplates.payload else {
            showLANClientTemplateProblem("No active LAN connection.")
            return nil
        }
        guard let target = templatePlacementTarget() else { throw TemplateError.missingTarget }
        handler(LANTemplateIntent(
            action: .placeTemplate, templateName: session.name,
            x: target.targetX, y: target.targetY, z: target.targetZ,
            rotation: session.rotationSteps, templateData: payload))
        lanClientTemplates.awaiting = (.placeTemplate, LAN_CLIENT_TEMPLATE_ANSWER_TIMEOUT_TICKS)
        lanClientTemplates.placeRequestArm = lanClientTemplates.armSerial
        host?.showActionBar("Asking the host to place \"\(session.name)\"", 60)
        return nil
    }

    /// The guest's Command-Z: asks the host to undo this guest's most recent placement. The host
    /// keeps the undo record, so the guest sends no name and no position. Returns whether the
    /// request went out.
    func requestLANClientTemplateUndo() -> Bool {
        guard lanClientTemplateRequestMayStart() else { return false }
        guard let handler = lanTemplateIntentHandler else {
            showLANClientTemplateProblem("No active LAN connection.")
            return false
        }
        handler(LANTemplateIntent(action: .undoPlacement, templateName: "", x: 0, y: 0, z: 0, rotation: 0))
        lanClientTemplates.awaiting = (.undoPlacement, LAN_CLIENT_TEMPLATE_ANSWER_TIMEOUT_TICKS)
        host?.showActionBar("Asking the host to undo your last object", 60)
        return true
    }

    /// Shows the host's answer to this guest's template request. Called by the LAN transport for
    /// the `template*` gameplay-event kinds addressed to this player.
    public func applyLANTemplateEvent(_ event: LANGameplayEvent) {
        guard isLANClientWorld else { return }
        switch event.kind {
        case .templatePlaceAccepted:
            lanClientTemplates.awaiting = nil
            if lanClientTemplates.placeRequestArm == lanClientTemplates.armSerial {
                lanClientTemplates.payload = nil
                cancelTemplatePlacement(showMessage: false)
            }
            lanClientTemplates.placeRequestArm = nil
            host?.showActionBar(event.message, 60)
        case .templateUndoAccepted:
            lanClientTemplates.awaiting = nil
            host?.showActionBar(event.message, 60)
        case .templateProgress:
            host?.showActionBar(event.message, 25)
        case .templateCompleted:
            host?.pushChat("§7" + event.message)
            host?.showActionBar(templateCompletionHeadline(event.message), 60)
        case .templateRefused:
            lanClientTemplates.awaiting = nil
            showLANClientTemplateProblem(event.message)
        default:
            break
        }
    }

    /// One client tick: gives up on a request the host never answered. The host drops an intent
    /// over its rate limit without a reply, and the player must not be left unable to try again.
    func tickLANClientTemplates() {
        guard var awaiting = lanClientTemplates.awaiting else { return }
        awaiting.ticksLeft -= 1
        guard awaiting.ticksLeft <= 0 else {
            lanClientTemplates.awaiting = awaiting
            return
        }
        lanClientTemplates.awaiting = nil
        showLANClientTemplateProblem("The host did not answer. Try again.")
    }

    private func lanClientTemplateRequestMayStart() -> Bool {
        guard lanClientTemplates.awaiting == nil else {
            host?.showActionBar("Waiting for the host to answer", 40)
            return false
        }
        return true
    }

    private func showLANClientTemplateProblem(_ text: String) {
        host?.pushChat("§c" + text)
        host?.showActionBar(text, 70)
    }
}

import Foundation

// The LAN host's side of a guest's object-template paste and undo: admission, the tick-sliced
// jobs, their completion, and the settle when the host quits. The session's stored state
// (`peers`, `templateJobs`, `pendingTemplateResponses`) stays in LANReplication.swift.

extension LANMultiplayerHostSession {
    /// Admits a guest's template place or undo. The guest sends the template itself
    /// (`LANTemplateTransfer.swift`); the host's own library is never read or written here.
    /// Permission, dimension and reach are checked once, at admission, before any world change.
    public func applyTemplateIntent(
        _ intent: LANTemplateIntent,
        from rawPlayerID: String,
        world: World
    ) -> LANTemplateIntentResult {
        let playerID = String(rawPlayerID.prefix(128))
        if let refusal = LANTemplateRefusal.authorization(authorize(.template, from: playerID), for: .template) {
            return .rejected(refusal)
        }
        switch intent.action {
        case .placeTemplate:
            if let refusal = LANTemplateRefusal.authorization(authorize(.build, from: playerID), for: .build) {
                return .rejected(refusal)
            }
            guard let peer = peers[playerID], let playerState = peer.playerState else {
                return .rejected(LANTemplateRefusal.unavailable)
            }
            guard playerState.dimension == world.dim.rawValue else {
                return .rejected(LANTemplateRefusal.otherDimension)
            }
            // Busy is answered before the payload is decoded, so a peer with a job in flight
            // cannot make the host decode a template for every further intent.
            guard templateJobs[playerID] == nil else { return .rejected(LANTemplateRefusal.busy) }
            guard let payload = intent.templateData else {
                return .rejected(LANTemplateRefusal.missingTemplate)
            }
            do {
                let rawTemplate = try lanHostTemplate(fromGuestPayload: payload)
                guard isWithinLANTemplateReach(playerState, template: rawTemplate, rotationSteps: intent.rotation,
                                               targetX: intent.x, targetY: intent.y, targetZ: intent.z) else {
                    return .rejected(LANTemplateRefusal.outOfReach)
                }
                // The job's throwing init does the rotate + preparation plan + destination
                // validation, all synchronously and all-or-nothing; pass the raw template +
                // rotationSteps directly rather than pre-rotating, since the init rotates
                // internally and pre-rotating would double-rotate.
                let job = try ObjectTemplatePlacementJob(
                    rawTemplate: rawTemplate,
                    in: world,
                    targetX: intent.x,
                    targetY: intent.y,
                    targetZ: intent.z,
                    rotationSteps: intent.rotation,
                    options: TemplatePlacementOptions(prepareTerrain: true)
                )
                // No dirty-section marking and no manual change-log loop here: the
                // `onWorldBlockChanged` hook streams every write as the job steps, and
                // `recordDirtyChunkSections` runs once at completion (finishTemplateJob) as the
                // eviction backstop, exactly like local completion. The undo snapshot is not
                // stored on `peers[playerID].lastTemplateUndo` until completion either.
                templateJobs[playerID] = TemplateJobEntry(
                    job: .place(job),
                    action: .placeTemplate,
                    templateName: job.undoSnapshot.templateName,
                    dimension: world.dim.rawValue
                )
                return .accepted(action: .placeTemplate, name: job.undoSnapshot.templateName)
            } catch {
                return .rejected(String(describing: error))
            }
        case .undoPlacement:
            guard let peer = peers[playerID], let undo = peer.lastTemplateUndo else {
                return .rejected(LANTemplateRefusal.nothingToUndo)
            }
            guard undo.dimension == world.dim.rawValue else {
                return .rejected(LANTemplateRefusal.undoOtherDimension)
            }
            guard templateUndoSnapshotFullyLoaded(undo, in: world) else {
                return .rejected(LANTemplateRefusal.undoNotLoaded)
            }
            guard templateJobs[playerID] == nil else { return .rejected(LANTemplateRefusal.busy) }
            // `lastTemplateUndo` is deliberately NOT cleared here — only at undo-completion
            // (finishTemplateJob). The busy guard above already prevents a second undo from
            // starting while this one is in flight, so early-clearing is unnecessary and would
            // lose the snapshot if the peer disconnects mid-undo.
            let job = ObjectTemplateUndoRestoreJob(snapshot: undo, in: world)
            templateJobs[playerID] = TemplateJobEntry(
                job: .undo(job),
                action: .undoPlacement,
                templateName: undo.templateName,
                dimension: undo.dimension
            )
            return .accepted(action: .undoPlacement, name: undo.templateName)
        }
    }

    /// Steps every peer's in-flight template job by up to `budgetPerPeer` operations, in
    /// ascending `joinedOrdinal` order (never dictionary order, per the engine's determinism
    /// contract). A job whose stored dimension doesn't match `world`'s current dimension is
    /// paused (skipped, not aborted or dropped) until the host returns to that dimension. Jobs
    /// that finish this call are completed via `finishTemplateJob`, which enqueues a drainable
    /// response and updates the peer's undo-snapshot bookkeeping exactly once.
    public func stepTemplateJobs(in world: World, budgetPerPeer: Int = LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET) {
        guard !templateJobs.isEmpty else { return }
        let ordered = peers.values.sorted { $0.joinedOrdinal < $1.joinedOrdinal }.map { $0.playerID }
        for playerID in ordered {
            guard let entry = templateJobs[playerID] else { continue }
            guard entry.dimension == world.dim.rawValue else { continue }
            let done: Bool
            switch entry.job {
            case .place(let job): done = job.step(maxOperations: budgetPerPeer)
            case .undo(let job): done = job.step(maxOperations: budgetPerPeer)
            }
            if done {
                finishTemplateJob(playerID: playerID, in: world)
            } else {
                noteTemplateJobStep(playerID: playerID)
            }
        }
    }

    /// Queues a progress report for a job still running, once every
    /// `LAN_MULTIPLAYER_TEMPLATE_PROGRESS_REPORT_STEPS` steps, so the guest sees it advance.
    private func noteTemplateJobStep(playerID: String) {
        guard var entry = templateJobs[playerID] else { return }
        entry.stepsSinceReport += 1
        if entry.stepsSinceReport >= LAN_MULTIPLAYER_TEMPLATE_PROGRESS_REPORT_STEPS {
            entry.stepsSinceReport = 0
            let progress: TemplatePlacementProgress
            switch entry.job {
            case .place(let job): progress = job.progress
            case .undo(let job): progress = job.progress
            }
            pendingTemplateResponses.append((playerID, .progress(
                action: entry.action, name: entry.templateName, percent: progress.percent, phase: progress.phase)))
        }
        templateJobs[playerID] = entry
    }

    /// Single completion path for a `.done` template job, shared by `stepTemplateJobs` and
    /// `settleAllTemplateJobs`. Marks dirty chunk sections from the undo snapshot exactly as
    /// local completion does (`onTemplatePlacementCommitted`), writes/clears the peer's
    /// `lastTemplateUndo` exactly once, and enqueues the drainable completion response. Does
    /// NOT re-emit per-block change-log entries — the `onWorldBlockChanged` hook is
    /// authoritative for per-block deltas fired during stepping.
    private func finishTemplateJob(playerID: String, in world: World) {
        guard let entry = templateJobs.removeValue(forKey: playerID) else { return }
        switch entry.job {
        case .place(let job):
            guard let result = job.result else {
                print("[lan] template job for \(playerID) finished without a result; dropping without completion")
                return
            }
            let undo = job.undoSnapshot
            recordDirtyChunkSections(from: undo, in: world)
            if var peer = peers[playerID] {
                peer.lastTemplateUndo = undo
                peers[playerID] = peer
            }
            pendingTemplateResponses.append((playerID, .placed(
                name: undo.templateName,
                blocks: result.blocksPlaced,
                blockEntities: result.blockEntitiesPlaced,
                cleared: result.blocksCleared,
                filled: result.supportBlocksFilled
            )))
        case .undo(let job):
            let undo = job.undoSnapshot
            recordDirtyChunkSections(from: undo, in: world)
            if var peer = peers[playerID] {
                peer.lastTemplateUndo = nil
                peers[playerID] = peer
            }
            pendingTemplateResponses.append((playerID, .undone(name: undo.templateName, restored: job.restored)))
        }
    }

    /// Drains queued template-job completion responses in completion order.
    public func drainTemplateIntentResponses() -> [(playerID: String, result: LANTemplateIntentResult)] {
        let out = pendingTemplateResponses
        pendingTemplateResponses.removeAll()
        return out
    }

    /// Test/diagnostic helper — true while `playerID` has an in-flight template job.
    public func hasActiveTemplateJob(playerID: String) -> Bool {
        templateJobs[String(playerID.prefix(128))] != nil
    }

    /// Guards the `unowned world` contract on every held job: drops all in-flight template jobs
    /// without settling them. Intended for world-teardown paths that do not already replace the
    /// whole session (session replacement at `startHost`/`stop` already drops jobs implicitly);
    /// callers that must persist partial work before teardown should call
    /// `settleAllTemplateJobs(in:)` first.
    public func cancelAllTemplateJobs() {
        templateJobs.removeAll()
        pendingTemplateResponses.removeAll()
    }

    /// Drives every in-flight template job to completion, in ascending `joinedOrdinal` order,
    /// so a graceful host quit never persists a half-placed or half-undone guest object. Mirrors
    /// `GameCore.settleInFlightTemplatePlacementJobs`'s fail-toward-saving contract: each job is
    /// bounded by its own operation caps plus a hard per-job iteration ceiling, and a job that
    /// somehow fails to converge is abandoned (dropped, logged) rather than blocking the flush.
    /// Each settled job goes through `finishTemplateJob` exactly as a normal per-tick completion
    /// would — undo-store write/clear and dirty-section marking happen identically — except no
    /// completion response is meaningful at quit time (there is no live connection to receive
    /// it), so the drained responses are discarded by the caller.
    ///
    /// Settlement is exhaustive rather than current-dimension-filtered: unlike `stepTemplateJobs`,
    /// every job is settled against its own admitted world regardless of the dimension the host
    /// happens to be standing in when quitting, since each job already owns a bound reference to
    /// the world it was constructed against.
    ///
    /// - Parameter worldForDimension: resolves the `World` a given entry's stored dimension maps
    ///   to. This is the world the job steps against and the world `recordDirtyChunkSections`
    ///   marks on completion.
    /// - Returns: the number of jobs actually driven to completion (an abandoned or
    ///   unresolvable-dimension job is dropped but does not count toward this total).
    @discardableResult
    public func settleAllTemplateJobs(worldForDimension: (Int) -> World?) -> Int {
        guard !templateJobs.isEmpty else { return 0 }
        let ordered = peers.values.sorted { $0.joinedOrdinal < $1.joinedOrdinal }.map { $0.playerID }
        let maxOperations = LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET
        var settled = 0
        for playerID in ordered {
            guard let entry = templateJobs[playerID] else { continue }
            guard let world = worldForDimension(entry.dimension) else {
                templateJobs.removeValue(forKey: playerID)
                continue
            }
            let totalOperations: Int
            switch entry.job {
            case .place(let job): totalOperations = job.progress.totalOperations
            case .undo(let job): totalOperations = job.progress.totalOperations
            }
            let ceiling = (totalOperations + maxOperations - 1) / maxOperations + 2
            var iterations = 0
            var isDone: Bool
            switch entry.job {
            case .place(let job): isDone = job.isDone
            case .undo(let job): isDone = job.isDone
            }
            while !isDone {
                guard iterations < ceiling else {
                    templateJobs.removeValue(forKey: playerID)
                    print("[templates] settleAllTemplateJobs: abandoned peer \(playerID)'s job after \(iterations) iterations — could not finish before quit; the partial object was left in place.")
                    break
                }
                switch entry.job {
                case .place(let job): isDone = job.step(maxOperations: maxOperations)
                case .undo(let job): isDone = job.step(maxOperations: maxOperations)
                }
                iterations += 1
            }
            guard isDone else { continue }
            finishTemplateJob(playerID: playerID, in: world)
            settled += 1
        }
        return settled
    }
}

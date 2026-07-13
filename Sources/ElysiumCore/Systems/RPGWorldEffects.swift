import Foundation

public let RPG_MAX_TEMPORARY_EFFECTS_PER_WORLD = 32
public let RPG_MAX_TEMPORARY_EFFECTS_PER_OWNER_KIND = 2

public enum RPGTemporaryEffectKind: String, CaseIterable, Equatable, Hashable {
    case fortifiedBlock
    case gravelTrap
    case decoy
    case safeHaven
    case mageLight
    case ward
    case stoneWard
    case servant
    case sanctuary
    case controlledCharge

    var ownerLimit: Int { self == .servant ? 1 : RPG_MAX_TEMPORARY_EFFECTS_PER_OWNER_KIND }
}

public struct RPGTemporaryEffectKey: Hashable, Equatable {
    public var ownerAuthorityID: String
    public var ownerSequence: Int
    public var kind: RPGTemporaryEffectKind

    public init(ownerAuthorityID: String, ownerSequence: Int, kind: RPGTemporaryEffectKind) {
        self.ownerAuthorityID = ownerAuthorityID
        self.ownerSequence = ownerSequence
        self.kind = kind
    }
}

public struct RPGGuardedTemporaryBlock: Equatable {
    public var position: RPGBlockPosition
    public var originalCell: Int
    public var temporaryCell: Int

    public init(position: RPGBlockPosition, originalCell: Int, temporaryCell: Int) {
        self.position = position
        self.originalCell = originalCell
        self.temporaryCell = temporaryCell
    }
}

public struct RPGTemporaryEffectDraft: Equatable {
    public var kind: RPGTemporaryEffectKind
    public var ownerAuthorityID: String
    public var ownerEntityID: Int?
    public var ownerSequence: Int
    public var center: RPGBlockPosition
    public var radius: Double
    public var durationTicks: Int
    public var remainingCharges: Int
    public var guardedBlock: RPGGuardedTemporaryBlock?
    public var magnitude: Double

    public init(kind: RPGTemporaryEffectKind,
                ownerAuthorityID: String,
                ownerEntityID: Int?,
                ownerSequence: Int,
                center: RPGBlockPosition,
                radius: Double = 0,
                durationTicks: Int,
                remainingCharges: Int = 0,
                guardedBlock: RPGGuardedTemporaryBlock? = nil,
                magnitude: Double = 0) {
        self.kind = kind
        self.ownerAuthorityID = ownerAuthorityID
        self.ownerEntityID = ownerEntityID
        self.ownerSequence = max(0, min(RPG_MAX_COUNTER, ownerSequence))
        self.center = center
        self.radius = max(0, min(32, radius.isFinite ? radius : 0))
        self.durationTicks = max(1, min(RPG_MAX_EFFECT_TICKS, durationTicks))
        self.remainingCharges = max(0, min(64, remainingCharges))
        self.guardedBlock = guardedBlock
        self.magnitude = magnitude.isFinite ? magnitude : 0
    }

    public var key: RPGTemporaryEffectKey {
        RPGTemporaryEffectKey(ownerAuthorityID: ownerAuthorityID,
                              ownerSequence: ownerSequence,
                              kind: kind)
    }
}

public struct RPGTemporaryEffect: Equatable {
    public var draft: RPGTemporaryEffectDraft
    public var dimension: Int
    public var createdTick: Int
    public var expiryTick: Int
    public var entityID: Int?

    public var key: RPGTemporaryEffectKey { draft.key }
}

public extension World {
    /// Immutable persistence overlay: guarded temporary cells are represented by
    /// their originals without changing the live chunk or effect registry.
    func rpgBlocksForPersistence(in chunk: Chunk) -> [UInt16] {
        var blocks = chunk.blocks
        for effect in rpgTemporaryEffects where effect.dimension == dim.rawValue {
            guard let guarded = effect.draft.guardedBlock,
                  floorDiv(guarded.position.x, CHUNK_W) == chunk.cx,
                  floorDiv(guarded.position.z, CHUNK_W) == chunk.cz,
                  chunk.inYRange(guarded.position.y) else { continue }
            let index = chunk.index(posMod(guarded.position.x, CHUNK_W), guarded.position.y,
                                    posMod(guarded.position.z, CHUNK_W))
            guard let temporary = UInt16(exactly: guarded.temporaryCell),
                  let original = UInt16(exactly: guarded.originalCell) else { continue }
            if blocks[index] == temporary {
                blocks[index] = original
            }
        }
        return blocks
    }

    func rpgTemporaryEntityIDsForPersistence() -> Set<Int> {
        Set(rpgTemporaryEffects.compactMap(\.entityID))
    }

    func finalizeRPGTransientState() {
        for living in entities.compactMap({ $0 as? LivingEntity }) {
            if let player = living as? Player { player.clearRPGTerminalUpkeeps() }
            living.clearRPGCausalProgressionState()
        }
        cancelAllRPGTemporaryEffects()
    }

    func canRegisterRPGTemporaryEffect(ownerID: String, kind: RPGTemporaryEffectKind) -> Bool {
        let cleanOwner = ownerID
        guard rpgIsBoundedID(cleanOwner), rpgTemporaryEffects.count < RPG_MAX_TEMPORARY_EFFECTS_PER_WORLD else { return false }
        return rpgTemporaryEffects.filter {
            $0.draft.ownerAuthorityID == cleanOwner && $0.draft.kind == kind
        }.count < kind.ownerLimit
    }

    private func isViableRPGTemporaryDraft(_ draft: RPGTemporaryEffectDraft) -> Bool {
        guard rule(RPG_CLASSES_GAME_RULE), rpgIsBoundedID(draft.ownerAuthorityID),
              draft.ownerSequence > 0,
              isLoadedAt(draft.center.x, draft.center.z),
              draft.center.y >= info.minY, draft.center.y < info.minY + info.height else { return false }
        if let guarded = draft.guardedBlock {
            guard isLoadedAt(guarded.position.x, guarded.position.z),
                  guarded.position.y >= info.minY,
                  guarded.position.y < info.minY + info.height,
                  UInt16(exactly: guarded.originalCell) != nil,
                  UInt16(exactly: guarded.temporaryCell) != nil else { return false }
            let current = getBlock(guarded.position.x, guarded.position.y, guarded.position.z)
            guard current == guarded.originalCell || current == guarded.temporaryCell else { return false }
        }
        return true
    }

    /// Pure cumulative reservation check over complete drafts.
    func canReserveRPGTemporaryEffects(_ drafts: [RPGTemporaryEffectDraft]) -> Bool {
        guard !drafts.isEmpty,
              rpgTemporaryEffects.count + drafts.count <= RPG_MAX_TEMPORARY_EFFECTS_PER_WORLD else {
            return false
        }
        var keys = Set(rpgTemporaryEffects.map(\.key))
        var ownerKindCounts: [RPGTemporaryEffectKey: Int] = [:]
        for effect in rpgTemporaryEffects {
            let countKey = RPGTemporaryEffectKey(ownerAuthorityID: effect.draft.ownerAuthorityID,
                                                 ownerSequence: 0, kind: effect.draft.kind)
            ownerKindCounts[countKey, default: 0] += 1
        }
        for draft in drafts {
            guard isViableRPGTemporaryDraft(draft), keys.insert(draft.key).inserted else { return false }
            let countKey = RPGTemporaryEffectKey(ownerAuthorityID: draft.ownerAuthorityID,
                                                 ownerSequence: 0, kind: draft.kind)
            ownerKindCounts[countKey, default: 0] += 1
            guard ownerKindCounts[countKey, default: 0] <= draft.kind.ownerLimit else { return false }
        }
        return true
    }

    /// Atomically appends every reservation or none. Callers publish action cost
    /// only after this succeeds.
    @discardableResult
    func reserveRPGTemporaryEffects(_ drafts: [RPGTemporaryEffectDraft]) -> Bool {
        guard canReserveRPGTemporaryEffects(drafts) else { return false }
        let created = max(0, min(RPG_MAX_COUNTER, rpgSimulationTick))
        let records = drafts.map {
            RPGTemporaryEffect(draft: $0, dimension: dim.rawValue, createdTick: created,
                               expiryTick: rpgSaturatedAdd(created, $0.durationTicks), entityID: nil)
        }
        rpgTemporaryEffects.append(contentsOf: records)
        return true
    }

    func rollbackRPGTemporaryReservations(_ keys: Set<RPGTemporaryEffectKey>) {
        rpgTemporaryEffects.removeAll { keys.contains($0.key) }
    }

    @discardableResult
    func attachRPGTemporaryEntity(_ entityID: Int, to key: RPGTemporaryEffectKey) -> Bool {
        guard entityById[entityID] != nil,
              let index = rpgTemporaryEffects.firstIndex(where: { $0.key == key && $0.entityID == nil }) else {
            return false
        }
        rpgTemporaryEffects[index].entityID = entityID
        return true
    }

    @discardableResult
    func registerRPGTemporaryEffect(_ draft: RPGTemporaryEffectDraft, entityID: Int? = nil) -> Bool {
        guard reserveRPGTemporaryEffects([draft]) else { return false }
        if let entityID, !attachRPGTemporaryEntity(entityID, to: draft.key) {
            rollbackRPGTemporaryReservations([draft.key])
            return false
        }
        return true
    }

    func rpgTemporaryEffect(for key: RPGTemporaryEffectKey) -> RPGTemporaryEffect? {
        rpgTemporaryEffects.first { $0.key == key }
    }

    func nearestOwnedRPGCharge(ownerID: String,
                               x: Double, eyeY: Double, y: Double, z: Double,
                               radius: Double) -> RPGTemporaryEffect? {
        let r2 = max(0, radius) * max(0, radius)
        return rpgTemporaryEffects
            .filter { effect in
                guard effect.draft.kind == .controlledCharge,
                      effect.draft.ownerAuthorityID == ownerID,
                      effect.dimension == dim.rawValue,
                      let guardBlock = effect.draft.guardedBlock,
                      getBlock(guardBlock.position.x, guardBlock.position.y, guardBlock.position.z) == guardBlock.temporaryCell,
                      hasRPGLineOfSightToCharge(guardBlock.position, x: x, eyeY: eyeY, z: z)
                else { return false }
                let dx = Double(guardBlock.position.x) + 0.5 - x
                let dy = Double(guardBlock.position.y) + 0.5 - y
                let dz = Double(guardBlock.position.z) + 0.5 - z
                return dx * dx + dy * dy + dz * dz <= r2
            }
            .sorted { lhs, rhs in
                let lp = lhs.draft.guardedBlock!.position
                let rp = rhs.draft.guardedBlock!.position
                let ld = distanceSquared(lp, x, y, z)
                let rd = distanceSquared(rp, x, y, z)
                if ld != rd { return ld < rd }
                if lp.y != rp.y { return lp.y < rp.y }
                if lp.z != rp.z { return lp.z < rp.z }
                if lp.x != rp.x { return lp.x < rp.x }
                return lhs.draft.ownerSequence < rhs.draft.ownerSequence
            }
            .first
    }

    private func hasRPGLineOfSightToCharge(_ position: RPGBlockPosition,
                                           x: Double, eyeY: Double, z: Double) -> Bool {
        let tx = Double(position.x) + 0.5, ty = Double(position.y) + 0.5
        let tz = Double(position.z) + 0.5
        let dx = tx - x, dy = ty - eyeY, dz = tz - z
        let distance = detHyp3(dx, dy, dz)
        guard distance > 0.001,
              let hit = raycast(x, eyeY, z, dx / distance, dy / distance, dz / distance,
                                distance + 0.75) else { return false }
        return hit.x == position.x && hit.y == position.y && hit.z == position.z
    }

    @discardableResult
    func transferRPGControlledCharge(at position: RPGBlockPosition, to tnt: TNTEntity) -> Bool {
        guard let effect = rpgTemporaryEffects.first(where: {
            $0.draft.kind == .controlledCharge && $0.draft.guardedBlock?.position == position
        }) else { return false }
        tnt.rpgControlledChargeOwnerEntityID = effect.draft.ownerEntityID
        tnt.rpgControlledChargeOwnerAuthorityID = effect.draft.ownerAuthorityID
        return removeRPGTemporaryEffect(effect.key, restoreGuardedBlock: false)
    }

    @discardableResult
    func removeRPGTemporaryEffect(_ key: RPGTemporaryEffectKey, restoreGuardedBlock: Bool) -> Bool {
        guard let index = rpgTemporaryEffects.firstIndex(where: { $0.key == key }) else { return false }
        let effect = rpgTemporaryEffects.remove(at: index)
        cleanupRPGTemporaryEffect(effect, restoreGuardedBlock: restoreGuardedBlock)
        return true
    }

    func cancelRPGTemporaryEffects(ownerID: String) {
        cancelRPGTemporaryEffects { $0.draft.ownerAuthorityID == ownerID }
    }

    /// Terminal owner cleanup. Unlike ordinary guarded cancellation, an
    /// unloaded guarded record is safe to drop: chunk persistence overlays its
    /// original cell and unload itself cancels while the chunk is still live.
    /// Loaded cells still receive the normal equality-guarded restoration.
    @discardableResult
    func terminateRPGTemporaryEffects(ownerID: String) -> Int {
        guard rpgIsBoundedID(ownerID) else { return 0 }
        let removed = rpgTemporaryEffects.filter { $0.draft.ownerAuthorityID == ownerID }
        guard !removed.isEmpty else { return 0 }
        let removedKeys = Set(removed.map(\.key))
        rpgTemporaryEffects.removeAll { removedKeys.contains($0.key) }
        for effect in removed { cleanupRPGTemporaryEffect(effect, restoreGuardedBlock: true) }
        return removed.count
    }

    /// Removes Warden award provenance owned by one authority from every live
    /// recipient while preserving the already-granted absorption itself.
    @discardableResult
    func removeRPGWardenMitigationLayers(ownerAuthorityID: String) -> Int {
        guard rpgIsBoundedID(ownerAuthorityID) else { return 0 }
        var removed = 0
        for living in entities.compactMap({ $0 as? LivingEntity }).sorted(by: { $0.id < $1.id }) {
            removed += living.removeRPGWardenMitigationLayers(ownerAuthorityID: ownerAuthorityID)
        }
        return removed
    }

    func cancelRPGTemporaryEffects(inChunkX cx: Int, z cz: Int) {
        cancelRPGTemporaryEffects { effect in
            let position = effect.draft.guardedBlock?.position ?? effect.draft.center
            return floorDiv(position.x, CHUNK_W) == cx && floorDiv(position.z, CHUNK_W) == cz
        }
    }

    func cancelAllRPGTemporaryEffects() {
        cancelRPGTemporaryEffects { _ in true }
    }

    private func cancelRPGTemporaryEffects(where predicate: (RPGTemporaryEffect) -> Bool) {
        let removed = rpgTemporaryEffects.filter { effect in
            guard predicate(effect) else { return false }
            if let guarded = effect.draft.guardedBlock {
                return isLoadedAt(guarded.position.x, guarded.position.z)
            }
            return true
        }
        let removedKeys = Set(removed.map(\.key))
        rpgTemporaryEffects.removeAll { removedKeys.contains($0.key) }
        for effect in removed { cleanupRPGTemporaryEffect(effect, restoreGuardedBlock: true) }
    }

    private func cleanupRPGTemporaryEffect(_ effect: RPGTemporaryEffect, restoreGuardedBlock: Bool) {
        if let entityID = effect.entityID, let entity = entityById[entityID] {
            if let concrete = entity as? Entity { concrete.remove() }
            removeEntity(entity)
        }
        guard restoreGuardedBlock, let guardBlock = effect.draft.guardedBlock,
              isLoadedAt(guardBlock.position.x, guardBlock.position.z),
              getBlock(guardBlock.position.x, guardBlock.position.y, guardBlock.position.z) == guardBlock.temporaryCell
        else { return }
        setBlock(guardBlock.position.x, guardBlock.position.y, guardBlock.position.z, guardBlock.originalCell)
    }

    func tickRPGTemporaryEffects() {
        if !rule(RPG_CLASSES_GAME_RULE) {
            finalizeRPGTransientState()
            return
        }
        for living in entities.compactMap({ $0 as? LivingEntity }).sorted(by: { $0.id < $1.id }) {
            living.pruneInvalidRPGWardenMitigationLayers()
        }
        var kept: [RPGTemporaryEffect] = []
        kept.reserveCapacity(rpgTemporaryEffects.count)
        for effect in rpgTemporaryEffects {
            if let guardBlock = effect.draft.guardedBlock,
               isLoadedAt(guardBlock.position.x, guardBlock.position.z),
               getBlock(guardBlock.position.x, guardBlock.position.y, guardBlock.position.z) != guardBlock.temporaryCell {
                continue
            }
            if let entityID = effect.entityID, entityById[entityID] == nil { continue }
            if rpgSimulationTick >= effect.expiryTick {
                if let guardBlock = effect.draft.guardedBlock,
                   !isLoadedAt(guardBlock.position.x, guardBlock.position.z) {
                    kept.append(effect)
                } else {
                    cleanupRPGTemporaryEffect(effect, restoreGuardedBlock: true)
                }
                continue
            }
            if rpgSimulationTick % 20 == 0 { pulseRPGTemporaryEffect(effect) }
            kept.append(effect)
        }
        rpgTemporaryEffects = kept
    }

    private func pulseRPGTemporaryEffect(_ effect: RPGTemporaryEffect) {
        let center = effect.draft.center
        let x = Double(center.x) + 0.5
        let y = Double(center.y) + 0.5
        let z = Double(center.z) + 0.5
        switch effect.draft.kind {
        case .decoy:
            for entity in rpgHostilesNear(x: x, y: y, z: z, radius: effect.draft.radius) {
                entity.addEffect("slowness", 40, 0)
                entity.addEffect("glowing", 40, 0)
            }
            hooks.addParticles("enchant", x, y, z, 8, effect.draft.radius, 0)
        case .safeHaven:
            let recipients = getEntitiesNear(x, y, z, effect.draft.radius)
                .compactMap { $0 as? LivingEntity }
                .filter { !$0.dead && ($0.id == effect.draft.ownerEntityID
                    || (!$0.isPlayer && !rpgIsHostileTarget($0))) }
                .sorted {
                    let adx = $0.x - x, ady = $0.y - y, adz = $0.z - z
                    let bdx = $1.x - x, bdy = $1.y - y, bdz = $1.z - z
                    let ad = adx * adx + ady * ady + adz * adz
                    let bd = bdx * bdx + bdy * bdy + bdz * bdz
                    return ad == bd ? $0.id < $1.id : ad < bd
                }.prefix(32)
            for entity in recipients {
                entity.addEffect("regeneration", 40, 0)
            }
            hooks.addParticles("happy_villager", x, y, z, 8, effect.draft.radius, 0)
        case .sanctuary:
            for entity in rpgHostilesNear(x: x, y: y, z: z, radius: effect.draft.radius) {
                entity.addEffect("weakness", 40, 0)
                let dx = entity.x - x
                let dz = entity.z - z
                let distance = max(0.001, detHyp(dx, dz))
                entity.vx += dx / distance * 0.35
                entity.vz += dz / distance * 0.35
            }
            hooks.addParticles("totem", x, y, z, 12, effect.draft.radius, 0)
        default:
            break
        }
    }

    @discardableResult
    func consumeRPGExplosionProtection(at position: RPGBlockPosition) -> Bool {
        let candidates = rpgTemporaryEffects.enumerated().filter { _, effect in
            guard effect.draft.remainingCharges > 0,
                  effect.dimension == dim.rawValue,
                  effect.draft.kind == .fortifiedBlock || effect.draft.kind == .ward || effect.draft.kind == .stoneWard
            else { return false }
            let dx = Double(position.x - effect.draft.center.x)
            let dy = Double(position.y - effect.draft.center.y)
            let dz = Double(position.z - effect.draft.center.z)
            return dx * dx + dy * dy + dz * dz <= effect.draft.radius * effect.draft.radius
        }.sorted { lhs, rhs in
            let le = lhs.element
            let re = rhs.element
            if le.draft.radius != re.draft.radius { return le.draft.radius < re.draft.radius }
            if le.createdTick != re.createdTick { return le.createdTick < re.createdTick }
            if le.draft.ownerAuthorityID != re.draft.ownerAuthorityID {
                return le.draft.ownerAuthorityID < re.draft.ownerAuthorityID
            }
            return le.draft.ownerSequence < re.draft.ownerSequence
        }
        guard let selected = candidates.first else { return false }
        let key = selected.element.key
        guard let index = rpgTemporaryEffects.firstIndex(where: { $0.key == key }) else { return false }
        rpgTemporaryEffects[index].draft.remainingCharges -= 1
        if rpgTemporaryEffects[index].draft.remainingCharges <= 0 {
            rpgTemporaryEffects.remove(at: index)
        }
        return true
    }

    private func rpgHostilesNear(x: Double, y: Double, z: Double, radius: Double) -> [LivingEntity] {
        getEntitiesNear(x, y, z, radius)
            .compactMap { $0 as? LivingEntity }
            .filter { !$0.dead && rpgIsHostileTarget($0) }
            .sorted {
                let adx = $0.x - x, ady = $0.y - y, adz = $0.z - z
                let bdx = $1.x - x, bdy = $1.y - y, bdz = $1.z - z
                let ad = adx * adx + ady * ady + adz * adz
                let bd = bdx * bdx + bdy * bdy + bdz * bdz
                return ad == bd ? $0.id < $1.id : ad < bd
            }.prefix(32).map { $0 }
    }
}

private func distanceSquared(_ position: RPGBlockPosition,
                             _ x: Double, _ y: Double, _ z: Double) -> Double {
    let dx = Double(position.x) + 0.5 - x
    let dy = Double(position.y) + 0.5 - y
    let dz = Double(position.z) + 0.5 - z
    return dx * dx + dy * dy + dz * dz
}

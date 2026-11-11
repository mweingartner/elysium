import Foundation

// A LAN guest's open container.
//
// A guest changes a container on its own side first and then tells the host with a container
// edit, which also carries the guest's inventory. Between the change and the edit the guest is
// ahead of the host, and two things must not happen in that time:
//
// - The guest's ordinary inventory publish must not go out. It would tell the host that items
//   left (or entered) the inventory before the edit says where they went; the host would then
//   see the edit create or destroy items and refuse it. So while a container is open, the
//   inventory travels with the container edits only (`publishLANInventoryIfChanged`).
// - A snapshot of that container from the host must not be written over the guest's change.
//   The host sends every container near a player twice a second. Written over the change, it
//   would silently undo it, or put a stack the guest holds on its cursor back into the chest.
//   The guest keeps its change, and its edit names the container as the host last sent it
//   (`lanOpenContainerRevision`), so the host still refuses the edit when someone else changed
//   the container in the meantime, and hands the guest's move back.

extension GameCore {
    /// The open container as this guest holds it now.
    private var lanOpenContainerSnapshots: [LANBlockEntitySnapshot] {
        lanOpenContainerPositions.compactMap { position -> LANBlockEntitySnapshot? in
            guard position.dimension == dim.rawValue,
                  let be = world.getBlockEntity(position.x, position.y, position.z)
            else { return nil }
            return makeLANBlockEntitySnapshot(be, dimension: position.dimension)
        }
    }

    /// Whether this guest has changed its open container and not yet told the host: what it
    /// holds differs from what the host last sent and from what the guest last sent.
    var lanHasUnsentContainerEdit: Bool {
        guard isLANClientWorld, hasWorld(), !lanOpenContainerPositions.isEmpty else { return false }
        let held = lanOpenContainerSnapshots
        return !held.isEmpty && lanBlockEntityRevision(held) != lanOpenContainerRevision
    }

    /// A batch from the host as this guest applies it: while the guest has an unsent change to
    /// its open container, without the host's snapshot of that container.
    func lanBatchKeepingUnsentContainerEdit(_ batch: LANReplicationBatch) -> LANReplicationBatch {
        guard !batch.blockEntities.isEmpty, lanHasUnsentContainerEdit else { return batch }
        let open = Set(lanOpenContainerPositions)
        var kept = batch
        kept.blockEntities = batch.blockEntities.filter {
            !open.contains(LANBlockPosition(dimension: $0.dimension, x: $0.x, y: $0.y, z: $0.z))
        }
        return kept
    }

    /// The host's snapshot of the open container was applied: that is the container the
    /// guest's next edit starts from.
    func lanNoteOpenContainerApplied(from batch: LANReplicationBatch) {
        guard !lanOpenContainerPositions.isEmpty else { return }
        let open = Set(lanOpenContainerPositions)
        guard batch.blockEntities.contains(where: {
            open.contains(LANBlockPosition(dimension: $0.dimension, x: $0.x, y: $0.y, z: $0.z))
        }) else { return }
        let held = lanOpenContainerSnapshots
        if !held.isEmpty { lanOpenContainerRevision = lanBlockEntityRevision(held) }
    }
}

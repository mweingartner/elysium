import ElysiumStorage

struct ForbiddenSlotOnlyCheckpointWrapper {
    let storage: ElysiumClientAuthorityCheckpointV6Storage
    func writeOnlyOwner(_ row: ElysiumLANClientOwnerCheckpointStorageRow) {
        _ = row
    }
}

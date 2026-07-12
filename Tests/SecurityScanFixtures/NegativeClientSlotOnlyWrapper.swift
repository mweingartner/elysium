import PebbleStorage

struct ForbiddenSlotOnlyCheckpointWrapper {
    let storage: PebbleClientAuthorityCheckpointV6Storage
    func writeOnlyOwner(_ row: PebbleLANClientOwnerCheckpointStorageRow) {
        _ = row
    }
}

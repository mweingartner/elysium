import PebbleStorage

typealias ForbiddenStorageAlias<T> = Result<T, PebbleStorageError>
let forbiddenAlias: ForbiddenStorageAlias<PebbleRPGLocalPreferenceStorageRow>? = nil

import ElysiumStorage

typealias ForbiddenStorageAlias<T> = Result<T, ElysiumStorageError>
let forbiddenAlias: ForbiddenStorageAlias<ElysiumRPGLocalPreferenceStorageRow>? = nil

import Foundation

/// Persistence lock ordering. Lower ranks may enter higher ranks, never the reverse.
/// The checks are intentionally DEBUG-only; release builds retain only the wrapper shape.
enum ElysiumLockRank: Int {
    case migrationSource = 10
    case saveQueue = 11
    case saveDB = 12
    case publication = 20
}

#if DEBUG
private let elysiumLockRankKey: pthread_key_t = {
    var key = pthread_key_t()
    let result = pthread_key_create(&key, nil)
    precondition(result == 0, "unable to allocate Elysium lock-rank TLS")
    return key
}()

@inline(__always)
private func elysiumCurrentLockRankRaw() -> Int {
    guard let pointer = pthread_getspecific(elysiumLockRankKey) else { return 0 }
    return Int(bitPattern: pointer) - 1
}

@inline(__always)
func elysiumCurrentLockRank() -> Int {
    elysiumCurrentLockRankRaw()
}

@inline(__always)
func withElysiumLockRank<T>(_ rank: ElysiumLockRank, _ body: () throws -> T) rethrows -> T {
    let previous = elysiumCurrentLockRankRaw()
    precondition(previous < rank.rawValue,
                 "Elysium lock-rank inversion: \(previous) -> \(rank.rawValue)")
    let priorPointer = pthread_getspecific(elysiumLockRankKey)
    let nextPointer = UnsafeMutableRawPointer(bitPattern: rank.rawValue + 1)
    precondition(pthread_setspecific(elysiumLockRankKey, nextPointer) == 0,
                 "unable to set Elysium lock-rank TLS")
    defer {
        precondition(pthread_setspecific(elysiumLockRankKey, priorPointer) == 0,
                     "unable to restore Elysium lock-rank TLS")
    }
    return try body()
}

@inline(__always)
func preconditionElysiumLockRank(_ rank: ElysiumLockRank) {
    precondition(elysiumCurrentLockRankRaw() == rank.rawValue,
                 "Elysium lock rank \(rank.rawValue) is not held")
}
#else
@inline(__always)
func elysiumCurrentLockRank() -> Int { 0 }

@inline(__always)
func withElysiumLockRank<T>(_ rank: ElysiumLockRank, _ body: () throws -> T) rethrows -> T {
    _ = rank
    return try body()
}

@inline(__always)
func preconditionElysiumLockRank(_ rank: ElysiumLockRank) {
    _ = rank
}
#endif

import Foundation

/// Persistence lock ordering. Lower ranks may enter higher ranks, never the reverse.
/// The checks are intentionally DEBUG-only; release builds retain only the wrapper shape.
enum PebbleLockRank: Int {
    case migrationSource = 10
    case saveQueue = 11
    case saveDB = 12
    case publication = 20
}

#if DEBUG
private let pebbleLockRankKey: pthread_key_t = {
    var key = pthread_key_t()
    let result = pthread_key_create(&key, nil)
    precondition(result == 0, "unable to allocate Pebble lock-rank TLS")
    return key
}()

@inline(__always)
private func pebbleCurrentLockRankRaw() -> Int {
    guard let pointer = pthread_getspecific(pebbleLockRankKey) else { return 0 }
    return Int(bitPattern: pointer) - 1
}

@inline(__always)
func pebbleCurrentLockRank() -> Int {
    pebbleCurrentLockRankRaw()
}

@inline(__always)
func withPebbleLockRank<T>(_ rank: PebbleLockRank, _ body: () throws -> T) rethrows -> T {
    let previous = pebbleCurrentLockRankRaw()
    precondition(previous < rank.rawValue,
                 "Pebble lock-rank inversion: \(previous) -> \(rank.rawValue)")
    let priorPointer = pthread_getspecific(pebbleLockRankKey)
    let nextPointer = UnsafeMutableRawPointer(bitPattern: rank.rawValue + 1)
    precondition(pthread_setspecific(pebbleLockRankKey, nextPointer) == 0,
                 "unable to set Pebble lock-rank TLS")
    defer {
        precondition(pthread_setspecific(pebbleLockRankKey, priorPointer) == 0,
                     "unable to restore Pebble lock-rank TLS")
    }
    return try body()
}

@inline(__always)
func preconditionPebbleLockRank(_ rank: PebbleLockRank) {
    precondition(pebbleCurrentLockRankRaw() == rank.rawValue,
                 "Pebble lock rank \(rank.rawValue) is not held")
}
#else
@inline(__always)
func pebbleCurrentLockRank() -> Int { 0 }

@inline(__always)
func withPebbleLockRank<T>(_ rank: PebbleLockRank, _ body: () throws -> T) rethrows -> T {
    _ = rank
    return try body()
}

@inline(__always)
func preconditionPebbleLockRank(_ rank: PebbleLockRank) {
    _ = rank
}
#endif

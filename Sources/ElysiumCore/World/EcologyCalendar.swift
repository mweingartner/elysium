// The ecology calendar advances with simulated sunlight, not wall time or render frames.
// Setting the displayed clock is not a completed day; sleeping explicitly completes one.
import Foundation

public struct EcologyCalendar: Codable, Equatable {
    public static let maximumTick = Int.max / 4
    public private(set) var elapsedTicks: Int
    public private(set) var completedDawns: Int
    public private(set) var lastRespawnDawn: Int
    private var pendingDawn = false

    public init(elapsedTicks: Int = 0, completedDawns: Int = 0, lastRespawnDawn: Int = 0) {
        self.elapsedTicks = max(0, min(Self.maximumTick, elapsedTicks))
        self.completedDawns = max(0, min(Self.maximumTick, completedDawns))
        self.lastRespawnDawn = max(0, min(self.completedDawns, lastRespawnDawn))
    }

    private enum CodingKeys: String, CodingKey { case elapsedTicks, completedDawns, lastRespawnDawn }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(elapsedTicks: (try? c.decode(Int.self, forKey: .elapsedTicks)) ?? 0,
                  completedDawns: (try? c.decode(Int.self, forKey: .completedDawns)) ?? 0,
                  lastRespawnDawn: (try? c.decode(Int.self, forKey: .lastRespawnDawn)) ?? 0)
    }

    public mutating func advance(ticks: Int, dawn: Bool = false) {
        elapsedTicks += min(max(0, ticks), Self.maximumTick - elapsedTicks)
        if dawn {
            completedDawns += min(1, Self.maximumTick - completedDawns)
            pendingDawn = true
        }
    }

    /// A dawn is consumed even when spawning is disabled or the habitat is full. No backlog.
    public mutating func consumeRespawnDawn(frequency: CreatureRespawnFrequency) -> Bool {
        guard pendingDawn else { return false }
        pendingDawn = false
        guard completedDawns - lastRespawnDawn >= frequency.dayCount else { return false }
        lastRespawnDawn = completedDawns
        return true
    }
}

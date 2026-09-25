import Foundation

/// Keeps the frozen seven-word mesher ABI while giving water its own optical pass.
/// Glass, portals and lava must never accidentally sample the water refraction path.
struct WaterMeshIndices {
    let water: [UInt32]
    let other: [UInt32]

    init(words: [UInt32], indices: [UInt32]) {
        var water: [UInt32] = [], other: [UInt32] = []
        water.reserveCapacity(indices.count)
        other.reserveCapacity(indices.count)
        let vertexCount = words.count / 7
        for start in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let triangle = [indices[start], indices[start + 1], indices[start + 2]]
            guard triangle.allSatisfy({ UInt64($0) < UInt64(vertexCount) }) else { continue }
            if triangle.allSatisfy({ ((words[Int($0) * 7 + 6] >> 24) & 7) == 1 }) {
                water.append(contentsOf: triangle)
            } else {
                other.append(contentsOf: triangle)
            }
        }
        self.water = water
        self.other = other
    }
}

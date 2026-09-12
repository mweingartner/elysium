// Native held props whose 3D orientation cannot be recovered from a diagonal
// inventory icon. Both share the authored hand grip at (0,0,0), with +Y through
// the fist; the crossbow aims down -Z into the world, never toward the player.
import simd

extension ViewmodelMesh {
    private static func specialColor(_ rgb: UInt32) -> SIMD4<Float> {
        viewmodelLinearColor(SIMD4(Float((rgb >> 16) & 255)/255,
                                  Float((rgb >> 8) & 255)/255,Float(rgb & 255)/255,1))
    }

    private mutating func specialBox(_ low: SIMD3<Float>, _ high: SIMD3<Float>, _ rgb: UInt32) {
        box(min: low, max: high, color: Self.specialColor(rgb))
    }

    /// A real solid rectangular beam. Rotation applies to the complete mesh,
    /// including normals; string and limb segments therefore have thickness
    /// from either hand's viewing direction rather than becoming sprite cards.
    private mutating func specialBeam(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                      width: Float, color: UInt32) {
        let delta = b-a, length = simd_length(delta)
        guard length > 0.00001 else { return }
        let rotation = simd_quatf(from: SIMD3<Float>(0,1,0), to: delta/length)
        var segment = Self()
        segment.specialBox(SIMD3(-width/2,0,-width/2), SIMD3(width/2,length,width/2), color)
        for i in segment.vertices.indices {
            let p = segment.vertices[i].position, n = segment.vertices[i].normal
            segment.vertices[i].position = SIMD4(rotation.act(SIMD3(p.x,p.y,p.z))+a,1)
            segment.vertices[i].normal = SIMD4(rotation.act(SIMD3(n.x,n.y,n.z)),0)
        }
        vertices.append(contentsOf: segment.vertices)
    }

    static func crossbow() -> Self {
        var mesh = Self()
        let grain: [UInt32] = [0x704521,0x966132,0x845329,0xa16c3c]

        // Vertical pistol grip fits the ordinary rectangular fist. Narrow wood
        // strips are contiguous solids, not a second painted hilt on the hand.
        for strip in 0..<5 {
            let x = -Float(0.035)+Float(strip)*0.014
            mesh.specialBox(SIMD3(x,-0.115,-0.0275),SIMD3(x+0.014,0.115,0.0275),grain[strip%4])
        }
        mesh.specialBox(SIMD3(-0.04,-0.13,-0.032),SIMD3(0.04,-0.105,0.032),0x505b63)

        // A long, legible stock with a split upper rail and an iron nose.
        // Its rear (+Z) sits toward the wrist; its muzzle (-Z) points outward.
        for strip in 0..<5 {
            let x = -Float(0.055)+Float(strip)*0.022
            mesh.specialBox(SIMD3(x,0.105,-0.52),SIMD3(x+0.022,0.165,0.27),grain[(strip+1)%4])
        }
        mesh.specialBox(SIMD3(-0.065,0.09,0.22),SIMD3(0.065,0.18,0.285),0x48515a)
        mesh.specialBox(SIMD3(-0.06,0.115,-0.55),SIMD3(0.06,0.185,-0.47),0x88969e)
        mesh.specialBox(SIMD3(-0.044,0.165,-0.46),SIMD3(-0.018,0.192,0.17),0x5c3920)
        mesh.specialBox(SIMD3(0.018,0.165,-0.46),SIMD3(0.044,0.192,0.17),0x9d7544)
        mesh.specialBox(SIMD3(-0.045,0.16,0.03),SIMD3(0.045,0.203,0.09),0x53616b)
        mesh.specialBox(SIMD3(-0.014,0.203,0.044),SIMD3(0.014,0.218,0.073),0xb7c0c4)

        // Symmetrical laminated limbs curve back toward the wearer; each tip
        // connects physically to a drawn string seated at the stock's catch.
        for sign: Float in [-1,1] {
            let root = SIMD3<Float>(sign*0.035,0.147,-0.40)
            let elbow = SIMD3<Float>(sign*0.225,0.147,-0.34)
            let tip = SIMD3<Float>(sign*0.355,0.147,-0.22)
            mesh.specialBeam(from: root,to: elbow,width:0.057,color:0x966535)
            mesh.specialBeam(from: elbow,to: tip,width:0.047,color:0x694321)
            mesh.specialBeam(from: root+SIMD3(0,0.019,0),to: elbow+SIMD3(0,0.019,0),
                             width:0.022,color:0xc39a5b)
            mesh.specialBeam(from: tip-SIMD3(sign*0.022,0,-0.02),to: tip,
                             width:0.054,color:0x89959c)
            mesh.specialBeam(from: tip+SIMD3(0,0.024,0),to: SIMD3(0,0.19,0.055),
                             width:0.010,color:0xc5baa3)
        }
        // Steel bow fastening band is attached to the wood stock, not a floating decal.
        mesh.specialBox(SIMD3(-0.073,0.091,-0.423),SIMD3(0.073,0.111,-0.375),0x596772)
        return mesh
    }

    static func flyingWand() -> Self {
        var mesh = Self()
        let grain: [UInt32] = [0x8d5a2c,0xb7803b,0x72441d,0xa16a30]
        // Straight +Y staff: no sprite-derived 45-degree bend at the fingers.
        // The flattened cross-section shares the measured normal-tool grip.
        for strip in 0..<4 {
            let x = -Float(0.035)+Float(strip)*0.0175
            mesh.specialBox(SIMD3(x,-0.13,-0.024),SIMD3(x+0.0175,0.50,0.024),grain[strip])
        }
        for y: Float in [-0.13,0.105,0.405] {
            mesh.specialBox(SIMD3(-0.042,y,-0.031),SIMD3(0.042,y+0.025,0.031),0x80581e)
        }
        // Supported golden cage and stepped amber crown preserve the existing
        // blaze/torch material identity without a flat flame pasted to a stick.
        mesh.specialBox(SIMD3(-0.060,0.475,-0.048),SIMD3(0.060,0.51,0.048),0xb68225)
        mesh.specialBox(SIMD3(-0.045,0.51,-0.035),SIMD3(0.045,0.59,0.035),0xe8a633)
        mesh.specialBox(SIMD3(-0.033,0.59,-0.027),SIMD3(0.033,0.635,0.027),0xffcd64)
        mesh.specialBox(SIMD3(-0.019,0.635,-0.016),SIMD3(0.019,0.665,0.016),0xffe3a1)
        for x: Float in [-0.051,0.051] {
            for z: Float in [-0.039,0.039] {
                mesh.specialBox(SIMD3(x-0.01,0.505,z-0.009),SIMD3(x+0.01,0.568,z+0.009),0xd4a54a)
            }
        }
        return mesh
    }
}

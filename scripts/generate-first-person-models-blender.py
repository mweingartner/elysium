#!/usr/bin/env python3
"""Author and export Elysium's real first-person meshes with Blender.

Run in an isolated background process; never clears the user's open Blender scene:
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
    --python-exit-code 1 --python scripts/generate-first-person-models-blender.py

Coordinates are runtime coordinates: +Y along the haft, +Z toward the player.
Every object shares one grip origin. No painted or duplicate handle is in the hand.
The exported stream is position xyz, flat normal xyz, linear RGBA Float32.
"""

import base64
import bpy
import collections
import hashlib
import json
import math
import pathlib
import struct
from mathutils import Matrix, Vector

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "Assets/Elysium/FirstPerson3D"
SWIFT = ROOT / "Sources/Elysium/FirstPersonModelAssets.swift"
SOURCE = ROOT / "Assets/Meshy/IronPickaxe/tfwa_pickaxe_cc0_source.glb"
SOURCE_HASH = "3d3c188a832b80518f405f7ab95c7982d88cd482ac81fe9be4eb535e39269f1d"
STEP = .01
ARM_LOWER_Y = -1.28


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def linear(rgb):
    return tuple((x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4)
                 for x in (v / 255 for v in rgb)) + (1.0,)


SKIN = [linear(c) for c in ((186, 132, 94), (194, 141, 102), (178, 122, 86), (203, 151, 111))]
SLEEVE = [linear(c) for c in ((50, 86, 107), (53, 91, 112), (43, 75, 95), (65, 102, 120))]
CUFF = [linear(c) for c in ((37, 60, 76), (45, 71, 86))]
WOOD = [linear(c) for c in ((122, 87, 48), (139, 102, 61), (109, 77, 43), (157, 117, 71))]
IRON = [linear(c) for c in ((109, 120, 123), (148, 157, 157), (82, 94, 100))]
LEATHER = linear((86, 55, 33))


def add_face(vertices, faces, colors, corners, color):
    start = len(vertices)
    vertices.extend(corners)
    faces.append(tuple(range(start, start + 4)))
    colors.append(color)


def mesh_object(name, vertices, faces, colors):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    attr = mesh.color_attributes.new(name="ViewmodelColor", type="FLOAT_COLOR", domain="CORNER")
    for poly, color in zip(mesh.polygons, colors):
        for loop_index in poly.loop_indices:
            attr.data[loop_index].color = color
    material = bpy.data.materials.get("ViewmodelVertexColor")
    if material is None:
        material = bpy.data.materials.new("ViewmodelVertexColor")
        material.use_nodes = True
        nodes = material.node_tree.nodes
        vertex = nodes.new("ShaderNodeVertexColor")
        vertex.layer_name = "ViewmodelColor"
        shader = nodes.get("Principled BSDF")
        shader.inputs["Roughness"].default_value = .84
        material.node_tree.links.new(vertex.outputs["Color"], shader.inputs["Base Color"])
    mesh.materials.append(material)
    return obj


# Quad corners are counter-clockwise when seen from outside each occupied cell.
SIDES = (
    ((1, 0, 0), ((1,0,0),(1,1,0),(1,1,1),(1,0,1))),
    ((-1,0,0), ((0,0,1),(0,1,1),(0,1,0),(0,0,0))),
    ((0,1,0), ((0,1,1),(1,1,1),(1,1,0),(0,1,0))),
    ((0,-1,0), ((0,0,0),(1,0,0),(1,0,1),(0,0,1))),
    ((0,0,1), ((1,0,1),(1,1,1),(0,1,1),(0,0,1))),
    ((0,0,-1), ((0,0,0),(0,1,0),(1,1,0),(1,0,0))),
)


def voxel_mesh(name, predicate, bounds, shade):
    occupied = set()
    for x in range(bounds[0][0], bounds[0][1]):
        for y in range(bounds[1][0], bounds[1][1]):
            for z in range(bounds[2][0], bounds[2][1]):
                if predicate((x+.5)*STEP, (y+.5)*STEP, (z+.5)*STEP):
                    occupied.add((x,y,z))
    # Connectivity is an explicit acceptance check: detail cannot float off the arm.
    seen = set()
    todo = [min(occupied)]
    while todo:
        cell = todo.pop()
        if cell in seen:
            continue
        seen.add(cell)
        for direction, _ in SIDES:
            neighbour = tuple(cell[i] + direction[i] for i in range(3))
            if neighbour in occupied and neighbour not in seen:
                todo.append(neighbour)
    if seen != occupied:
        raise RuntimeError(f"{name}: detached voxel component")
    verts, faces, colors = [], [], []
    # Greedy-merge equal-color coplanar face cells; voxel shape is unchanged,
    # but large flat boards do not need a triangle for every source texel.
    planes = collections.defaultdict(set)
    for cell in sorted(occupied):
        for side, (direction, corners) in enumerate(SIDES):
            neighbour = tuple(cell[i]+direction[i] for i in range(3))
            if neighbour in occupied:
                continue
            axis = next(i for i in range(3) if direction[i])
            uv = [i for i in range(3) if i != axis]
            planes[(side,cell[axis],shade(cell,side))].add((cell[uv[0]],cell[uv[1]]))
    for (side,plane,color),cells in sorted(planes.items()):
        direction,corners = SIDES[side]
        axis = next(i for i in range(3) if direction[i])
        uv = [i for i in range(3) if i != axis]
        while cells:
            u,v = min(cells)
            width = 1
            while (u+width,v) in cells:
                width += 1
            height = 1
            while all((u+du,v+height) in cells for du in range(width)):
                height += 1
            for du in range(width):
                for dv in range(height):
                    cells.remove((u+du,v+dv))
            points = []
            for corner in corners:
                p = [0.0]*3
                p[axis] = (plane+corner[axis])*STEP
                p[uv[0]] = (u+corner[uv[0]]*width)*STEP
                p[uv[1]] = (v+corner[uv[1]]*height)*STEP
                points.append(tuple(p))
            add_face(verts,faces,colors,points,color)
    return mesh_object(name, verts, faces, colors)


def make_arm():
    def shade(cell, side):
        x,y,z = cell
        if y < -32:
            palette = SLEEVE
        elif y < -29:
            palette = CUFF
        else:
            palette = SKIN
        # Broad pixel patches, not noisy per-pixel surface fragments.
        index = ((x//3)*13 + (y//4)*7 + (z//3)*3) % 17
        return palette[(index % len(palette)) if index < 3 else 0]
    def section(y):
        # Preserve the reviewed wrist and forearm exactly through Y=-.68.
        # Continue its shoulder direction beyond that point without widening:
        # the lower cap must stay offscreen during the maximum forward stroke.
        t = max(0,(-y-.10)/.58)
        width_t = min(1,t)
        center_z = -.01 + t*.19
        hx = .075+.015*width_t
        hz = .070+.015*width_t
        return [Vector((x,y,z)) for x,z in
                ((-hx,center_z-hz),(hx,center_z-hz),(hx,center_z+hz),(-hx,center_z+hz))]
    ys = sorted(set([round(-.68+i*.03,6) for i in range(21)]
                    + [round(ARM_LOWER_Y+i*.03,6) for i in range(21)]
                    + [-.32,-.29,-.08]))
    verts,faces,colors = [],[],[]
    for y0,y1 in zip(ys,ys[1:]):
        low,high = section(y0),section(y1)
        for side in range(4):
            next_side = (side+1)%4
            for stripe in range(5):
                t0,t1 = stripe/5,(stripe+1)/5
                corners = [low[side].lerp(low[next_side],t0),high[side].lerp(high[next_side],t0),
                           high[side].lerp(high[next_side],t1),low[side].lerp(low[next_side],t1)]
                midpoint = sum(corners,Vector())/4
                cell = tuple(math.floor(c/STEP) for c in midpoint)
                add_face(verts,faces,colors,corners,shade(cell,side))
    add_face(verts,faces,colors,section(ys[0]),SLEEVE[0])
    add_face(verts,faces,colors,list(reversed(section(ys[-1]))),SKIN[0])
    return mesh_object("arm",verts,faces,colors)


def make_arm_segment(name, length, top, bottom, is_forearm):
    """Separate rigid bones for wrist->elbow->shoulder attachment.

    The visible wrist footprint matches the existing hand, but the segment has
    no baked shoulder lean. Small planar bevels make the eight faceted sides
    readable under the real renderer's lighting without rounding the voxel style.
    """
    def section(y):
        t = max(0,min(1,-y/length))
        if is_forearm:
            hx,hz,center_z,bevel = .075+.007*t,.070+.008*t,-.01*(1-t),.006
        else:
            hx,hz,center_z,bevel = .084+.014*t,.079+.014*t,0,.009
        lo,hi = center_z-hz,center_z+hz
        return [Vector((x,y,z)) for x,z in
                ((-hx+bevel,lo),(hx-bevel,lo),(hx,lo+bevel),(hx,hi-bevel),
                 (hx-bevel,hi),(-hx+bevel,hi),(-hx,hi-bevel),(-hx,lo+bevel))]
    skin = [SKIN[0],linear((190,138,101)),linear((180,127,91)),linear((194,143,104))]
    def shade(midpoint,side):
        x,y,z = midpoint
        if is_forearm and y > -.315:
            if y > -.07:
                return skin[0]  # skin tone and joining surface stay continuous at wrist
            ix,iy,iz = (math.floor(v/.025) for v in (x,y,z))
            patch = (ix*11+iy*5+iz*3)%31
            return skin[patch] if patch < 4 else skin[0]
        if is_forearm and y > -.34:
            return CUFF[0 if side%2 else 1]
        ix,iy,iz = (math.floor(v/.025) for v in (x,y,z))
        patch = (ix*11+iy*7+iz*3)%29
        return SLEEVE[patch] if patch < 4 else SLEEVE[0]
    ys = sorted(set([top,bottom,0,-length]+[round(-i*.025,6) for i in range(1,math.ceil(-bottom/.025))]
                    + ([-.315,-.34] if is_forearm else [])))
    verts,faces,colors = [],[],[]
    for y0,y1 in zip(ys,ys[1:]):
        low,high = section(y0),section(y1)
        for side in range(8):
            next_side = (side+1)%8
            columns = 5 if side%2 == 0 else 1
            for stripe in range(columns):
                t0,t1 = stripe/columns,(stripe+1)/columns
                corners = [low[side].lerp(low[next_side],t0),high[side].lerp(high[next_side],t0),
                           high[side].lerp(high[next_side],t1),low[side].lerp(low[next_side],t1)]
                add_face(verts,faces,colors,corners,shade(sum(corners,Vector())/4,side))
    for corners,color in ((section(bottom),SLEEVE[0]),
                          (list(reversed(section(top))),skin[0] if is_forearm else SLEEVE[0])):
        start = len(verts)
        verts.extend(corners)
        faces.append(tuple(range(start,start+len(corners))))
        colors.append(color)
    return mesh_object(name,verts,faces,colors)


def make_hand(name="hand", bore_x=.064, bore_z=.064):
    def body(x,y,z):
        # Curled fingers form a closed lateral loop around the shaft. Only its
        # top/bottom are open: a side slit would reveal a floating brown patch
        # of the real handle between the thumb and wrist during a strike.
        palm = abs(x) <= .095 and -.10 <= y <= .08 and -.105 <= z <= -bore_z
        outer = bore_x <= x <= .10 and -.08 <= y <= .08 and -.085 <= z <= .10
        fingers = -.045 <= x <= .08 and -.08 <= y <= .075 and bore_z <= z <= .10
        thumb = -.095 <= x <= -bore_x and -.08 <= y <= .08 and -.085 <= z <= .075
        thumb_tip = -.085 <= x <= -.025 and .035 <= y <= .08 and bore_z <= z <= .095
        wrist = abs(x) <= .075 and -.12 <= y <= -.08 and -.09 <= z <= .035
        return palm or outer or fingers or thumb or thumb_tip or wrist
    def shade(cell, side):
        x,y,z = cell
        # Finger joints are face colors on a closed surface, never floating cards.
        if z >= 9 and y in (-5,-1,3):
            return SKIN[2]
        if z >= 8 and x >= 5:
            return SKIN[3]
        return SKIN[1] if (x//3+y//4+z//3)%9 == 0 else SKIN[0]
    obj = voxel_mesh(name,body,((-10,10),(-12,8),(-11,10)),shade)
    if name == "hand":
        # Voxel occupancy finds the same closed loop, then shift its inner
        # boundary from the .01 grid to the measured .064 clearance exactly.
        # Outer palm/wrist dimensions and the narrow grip remain unchanged.
        for vertex in obj.data.vertices:
            for axis in (0,2):
                if abs(abs(vertex.co[axis])-.06) < .000001:
                    vertex.co[axis] = math.copysign(.064,vertex.co[axis])
        obj.data.update()
    elif name in ("handShield", "handRound"):
        # A .01 occupancy grid gives both dedicated grips a .03 inner plane.
        # Fit that shared plane to the actual shaft clearance, without scaling
        # the palm or moving the wrist joint/shoulder-facing joining footprint.
        # Mapping shared positions identically preserves the closed union.
        for vertex in obj.data.vertices:
            if vertex.co.y < -.080001:
                continue
            for axis, bore in ((0,bore_x),(2,bore_z)):
                if abs(abs(vertex.co[axis])-.03) < .000001:
                    vertex.co[axis] = math.copysign(bore,vertex.co[axis])
        obj.data.update()
    return obj


def make_wrist_joint():
    """A closed faceted swivel fills the gap between independently posed bones.

    This is an intentionally broad, single-segment bevel, not smooth skin or
    detached overlay cards. Its .082 outer planes differ from existing collars
    so the overlapping closed surfaces do not share coplanar exposed faces.
    """
    bpy.ops.mesh.primitive_cube_add(size=.164)
    source = bpy.context.object
    bevel = source.modifiers.new(name="VoxelWristBevel",type="BEVEL")
    bevel.width = .018
    bevel.segments = 1
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    verts = [tuple(vertex.co) for vertex in source.data.vertices]
    faces = [tuple(polygon.vertices) for polygon in source.data.polygons]
    colors = [SKIN[0]]*len(faces)
    bpy.data.objects.remove(source,do_unlink=True)
    return mesh_object("wristJoint",verts,faces,colors)


def make_draw_hand():
    """Split-finger archery hook, not a smaller hollow tool grip.

    Local X crosses index/middle/ring pads. The nock sits in the index-middle
    gap at (.025,.040,-.0415); a .007 string touches the Z=-.045 hooked pads.
    All finger segments are part of the same closed voxel union as the palm.
    """
    def body(x,y,z):
        wrist = abs(x) <= .075 and -.12 <= y <= -.08 and -.09 <= z <= .035
        palm = abs(x) < .076 and -.089 <= y <= .016 and -.021 <= z <= .046
        finger_x = (-.079 < x < -.041 or -.029 < x < .011 or .039 < x < .079)
        proximal = finger_x and -.011 <= y <= .061 and -.021 <= z <= .041
        curled = finger_x and .051 <= y <= .081 and -.071 <= z <= .021
        tips = finger_x and .029 <= y <= .061 and -.071 <= z <= -.041
        # Thumb lies relaxed down the outside of the palm, not closing a bore.
        thumb = .059 <= x <= .081 and -.061 <= y <= .021 and -.041 <= z <= .021
        thumb_tip = .059 <= x <= .081 and .009 <= y <= .031 and -.041 <= z <= .001
        return wrist or palm or proximal or curled or tips or thumb or thumb_tip
    def shade(cell,side):
        x,y,z = cell
        if y in (4,5) and z >= 3:
            return SKIN[2]
        if y >= 6 and side in (0,4):
            return SKIN[3]
        return SKIN[1] if (x//3+y//4+z//3)%13 == 0 else SKIN[0]
    obj = voxel_mesh("handDraw",body,((-8,9),(-12,9),(-9,6)),shade)
    # Fit the inner pads between grid planes while preserving welded positions.
    for vertex in obj.data.vertices:
        if abs(vertex.co.z+.04) < .000001:
            vertex.co.z = -.045
    obj.data.update()
    return obj


def make_pickaxe():
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(SOURCE))
    source = next(obj for obj in set(bpy.data.objects)-before if obj.type == "MESH")
    image = next(node.image for node in source.data.materials[0].node_tree.nodes if node.type == "TEX_IMAGE")
    pixels = list(image.pixels[:])
    width, height = image.size
    uv = source.data.uv_layers.active.data
    mesh = source.data
    verts, faces, colors = [], [], []
    # Rotation (x,y,z)->(x,z,-y) is proper/right-handed; scale is uniform.
    # The source handle center is (x=.05,y=-.15); grip is z=.60 (15%height).
    for poly in mesh.polygons:
        points = []
        for vertex_index in poly.vertices:
            p = source.matrix_world @ mesh.vertices[vertex_index].co
            points.append(((p.x-.05)*.2125,(p.z-.60)*.2125,-(p.y+.15)*.2125))
        center_uv = sum((uv[i].uv for i in poly.loop_indices),Vector((0,0)))/len(poly.loop_indices)
        pixel_x = min(width-1,max(0,int(center_uv.x*width)))
        pixel_y = min(height-1,max(0,int(center_uv.y*height)))
        rgba = pixels[(pixel_y*width+pixel_x)*4:(pixel_y*width+pixel_x)*4+4]
        # The palette contains authored sRGB steps; export linear values so
        # the Metal sRGB target and Blender preview agree under real lighting.
        rgba = linear(tuple(round(channel*255) for channel in rgba[:3]))
        start = len(verts)
        verts.extend(points)
        faces.append(tuple(range(start,start+len(points))))
        colors.append(rgba)
    bpy.data.objects.remove(source,do_unlink=True)
    return mesh_object("pickaxe",verts,faces,colors)


def make_shield():
    def board(x,y,z):
        # Classic tall board, clipped lower corners, substantial rim/backside.
        half_width = .25 if y >= -.27 else .25-(-.27-y)*.70
        # Leave 0.03 clear between the board's rear and the palm's farthest
        # -Z surface. The board must not pass through the back of the hand.
        panel = abs(x) <= half_width and -.42 <= y <= .38 and -.19 <= z <= -.14
        # Integral rear brackets and handle. Fist is on the +Z (player) side.
        brackets = abs(x) <= .055 and (abs(y-.11)<.025 or abs(y+.11)<.025) and -.14 <= z <= .025
        handle = abs(x) <= .027 and abs(y) <= .11 and -.027 <= z <= .027
        return panel or brackets or handle
    def shade(cell,side):
        x,y,z = cell
        if z >= -14:
            return LEATHER if abs(y)<9 else IRON[2]
        half = 25 if y >= -27 else 25-(-27-y)*.70
        rim = abs(x)+2 >= half or y >= 35 or y <= -40
        if rim:
            return IRON[1 if (x+y)%7==0 else 0]
        # End-grain planks and routed grooves are geometry-face palette work.
        if x % 10 in (0,9):
            return WOOD[2]
        return WOOD[(x//10+2)%4] if (y//3+x//3)%11 else WOOD[3]
    return voxel_mesh("shield",board,((-25,25),(-42,38),(-19,3)),shade)


def triangle_stream(obj):
    mesh = obj.data
    mesh.calc_loop_triangles()
    color = mesh.color_attributes["ViewmodelColor"].data
    data = []
    for tri in mesh.loop_triangles:
        normal = tri.normal.normalized()
        if normal.length < .999:
            raise RuntimeError(f"{obj.name}: degenerate face")
        for vertex_index,loop_index in zip(tri.vertices,tri.loops):
            p = mesh.vertices[vertex_index].co
            values = (*p,*normal,*color[loop_index].color)
            if not all(math.isfinite(value) for value in values):
                raise RuntimeError(f"{obj.name}: non-finite vertex")
            data.extend(values)
    return struct.pack(f"<{len(data)}f",*data)


def camera(name, location, target, scale):
    data = bpy.data.cameras.new(name)
    obj = bpy.data.objects.new(name,data)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    forward = (Vector(target)-obj.location).normalized()
    right = forward.cross(Vector((0,1,0))).normalized()
    up = right.cross(forward).normalized()
    obj.rotation_euler = Matrix((right,up,-forward)).transposed().to_euler()
    data.type = "ORTHO"
    data.ortho_scale = scale
    bpy.context.scene.camera = obj
    return obj


def previews(objects):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.world.color = (.13,.15,.19)
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    # Runtime gives this preserved .85-high source its explicit .98 presentation
    # length. Apply the same inspection-only uniform scale after stream export.
    objects["pickaxe"].scale = (.98/.85,)*3
    objects["pickaxe"].location.y = .05
    # Match FirstPersonHandGrip.meshTransform: the authored curled fingers are
    # +Z, but the closed fist's dorsal side faces the wearer at runtime. Turn
    # the hand only, keeping its shaft bore, grip origin, and wrist invariant.
    # This is applied after export; the dedicated archery hook is not turned.
    for name in ("hand", "handNarrow", "handShield", "handRound"):
        objects[name].rotation_euler.y = math.pi
    # Inspection-only reference shaft proves the tighter bore without changing
    # the authored tool model or embedding another handle into the hand.
    verts,faces,colors = [],[],[]
    for _,corners in SIDES:
        points = [((x-.5)*.08,y*.65-.12,(z-.5)*.045) for x,y,z in corners]
        add_face(verts,faces,colors,points,WOOD[0])
    objects["inspectionShaft"] = mesh_object("inspectionShaft",verts,faces,colors)
    # A real-width string along the draw hand's authored contact direction.
    verts,faces,colors = [],[],[]
    for _,corners in SIDES:
        points = [(x*.34-.17,.040+(y-.5)*.007,-.0415+(z-.5)*.007) for x,y,z in corners]
        add_face(verts,faces,colors,points,linear((224,219,186)))
    objects["inspectionDrawString"] = mesh_object("inspectionDrawString",verts,faces,colors)
    # One inspectable two-bone pose, independent of the runtime's IK solver.
    # Neither segment is stretched; wrist and elbow share actual endpoints.
    wrist = Vector((0,-.10,0))
    objects["wristJoint"].location = wrist
    elbow = wrist+Vector((.20,-.30,.18)).normalized()*.40
    shoulder = elbow+Vector((.18,-.14,-.27)).normalized()*.45
    forearm = objects["forearm"]
    forearm.location = wrist
    forearm.rotation_mode = "QUATERNION"
    forearm.rotation_quaternion = Vector((0,-1,0)).rotation_difference(elbow-wrist)
    upper_arm = objects["upperArm"]
    upper_arm.location = elbow
    upper_arm.rotation_mode = "QUATERNION"
    upper_arm.rotation_quaternion = Vector((0,-1,0)).rotation_difference(shoulder-elbow)
    for name,position,energy,size in (("Key",(-2,3,5),450,4),("Fill",(3,1,2),160,3)):
        light = bpy.data.lights.new(name,"AREA")
        light.energy = energy
        light.shape = "DISK"
        light.size = size
        obj = bpy.data.objects.new(name,light)
        scene.collection.objects.link(obj)
        obj.location = position
        obj.rotation_euler = (-obj.location).to_track_quat("-Z","Y").to_euler()
    for name,visible,location,target,scale in (
        ("grip-three-quarter",("arm","hand","pickaxe"),(1.5,.65,3.0),(0,.00,0),1.90),
        ("grip-front",("arm","hand","pickaxe"),(0,0,3),(0,0,0),1.90),
        ("grip-narrow",("arm","handNarrow","inspectionShaft"),(1.5,.65,3.0),(0,-.10,0),1.60),
        ("bow-draw-hook",("handDraw","inspectionDrawString"),(1.7,.65,3.0),(0,-.005,-.01),.40),
        ("bow-draw-hook-side",("handDraw","inspectionDrawString"),(-3,.65,-1.5),(0,-.005,-.01),.40),
        ("segmented-arm-grip",("forearm","upperArm","wristJoint","hand","pickaxe"),(1.2,.30,3.0),(.12,-.06,0),2.0),
        ("shield-player-side",("arm","handShield","shield"),(1,.3,3),(0,-.1,0),1.25),
        ("shield-outward-face",("shield",),(1,.2,-3),(0,-.02,-.09),1.03),
    ):
        for key,obj in objects.items():
            obj.hide_render = key not in visible
        cam = camera(name,location,target,scale)
        scene.render.filepath = str(OUT/f"{name}.png")
        bpy.ops.render.render(write_still=True)
        bpy.data.objects.remove(cam,do_unlink=True)
    for obj in objects.values():
        obj.hide_render = False
    objects["shield"].hide_render = True
    objects["shield"].hide_set(True)
    for key in ("handNarrow","handShield","handRound","handDraw","inspectionShaft","inspectionDrawString","forearm","upperArm","wristJoint"):
        objects[key].hide_render = True
        objects[key].hide_set(True)
    camera("Inspect_Grip",(1.5,.65,3),(0,0,0),1.90)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/"first-person-models.blend"))


def main():
    if bpy.app.version[:2] != (5,1):
        raise RuntimeError(f"Expected Blender5.1, got{bpy.app.version_string}")
    if digest(SOURCE) != SOURCE_HASH:
        raise RuntimeError("Source pickaxe changed; review before regeneration")
    OUT.mkdir(parents=True,exist_ok=True)
    # Only this factory-startup background scene is cleared.
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    objects = {"pickaxe":make_pickaxe(),"arm":make_arm(),"hand":make_hand(),
               "handNarrow":make_hand("handNarrow",.045,.025),"shield":make_shield(),
               "handShield":make_hand("handShield",.032,.032),
               "handRound":make_hand("handRound",.028,.028),
               "forearm":make_arm_segment("forearm",.40,.025,-.425,True),
               "upperArm":make_arm_segment("upperArm",.45,.035,-.48,False),
               "wristJoint":make_wrist_joint(),"handDraw":make_draw_hand()}
    swift = ["// Generated by scripts/generate-first-person-models-blender.py. Do not hand-edit.",
             "// Real triangle meshes: +Y along handle; +Z toward player; shared grip=(0,0,0).",
             "import Foundation", "", "enum FirstPersonModelAssets {"]
    records = {}
    for name,obj in objects.items():
        encoded = triangle_stream(obj)
        (OUT/f"{name}.f32").write_bytes(encoded)
        b64 = base64.b64encode(encoded).decode("ascii")
        swift.extend([f"    static let {name}: [Float] = decode(\"\"\""]+
                     ["        "+b64[i:i+100] for i in range(0,len(b64),100)]+["        \"\"\")",""])
        points = [v.co for v in obj.data.vertices]
        records[name] = {
            "triangles":len(encoded)//120,"vertices":len(encoded)//40,
            "bounds":[[round(min(v[i] for v in points),6),round(max(v[i] for v in points),6)] for i in range(3)],
            "float32_sha256":hashlib.sha256(encoded).hexdigest(),
        }
    swift.extend([
        "    /// Split-finger nock contact; local X spans the three hooked finger pads.",
        "    static let handDrawStringContact = SIMD3<Float>(0.025, 0.040, -0.0415)",
        "    static let handDrawStringAxis = SIMD3<Float>(1, 0, 0)",
        "",
        "    /// Recolor only the source's neutral iron head; wood and its voxel detail are unchanged.",
        "    static func pickaxe(material: String) -> [Float] {",
        "        let shades: [[Float]]",
        "        switch material {",
        "        case \"wooden\": shades = [[139,88,38], [193,137,67]]",
        "        case \"stone\": shades = [[112,117,119], [166,171,172]]",
        "        case \"copper\": shades = [[184,89,52], [237,151,92]]",
        "        case \"golden\": shades = [[226,168,14], [255,231,91]]",
        "        case \"diamond\": shades = [[35,195,202], [159,247,244]]",
        "        case \"netherite\": shades = [[75,65,78], [119,103,121]]",
        "        default: shades = [[164,177,183], [232,239,241]]",
        "        }",
        "        let linear = shades.map { shade in shade.map { channel -> Float in",
        "            let c = channel / 255",
        "            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)",
        "        } }",
        "        var result = pickaxe",
        "        for offset in stride(from: 0, to: result.count, by: 10) {",
        "            let r = result[offset + 6], g = result[offset + 7], b = result[offset + 8]",
        "            guard abs(r - g) < 0.001 && abs(g - b) < 0.001 else { continue }",
        "            let color = linear[r < 0.20 ? 0 : 1]",
        "            for channel in 0..<3 { result[offset + 6 + channel] = color[channel] }",
        "        }",
        "        return result",
        "    }", "",
        "    private static func decode(_ encoded: String) -> [Float] {",
        "        guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {",
        "            preconditionFailure(\"Invalid generated viewmodel data\")",
        "        }",
        "        precondition(bytes.count % 40 == 0)",
        "        return bytes.withUnsafeBytes { source in",
        "            (0..<(source.count / 4)).map { index in",
        "                Float(bitPattern: UInt32(littleEndian: source.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))",
        "            }",
        "        }",
        "    }", "}", ""])
    SWIFT.write_text("\n".join(swift))
    manifest = {
        "generator":"Blender "+bpy.app.version_string+" real mesh triangle export",
        "format":"little-endian float32 position xyz, flat normal xyz, linear rgba; CCW outside",
        "geometry_source":str(SOURCE.relative_to(ROOT)),"geometry_source_sha256":SOURCE_HASH,
        "geometry_provider":"tfwa.games Voxel Tools","geometry_license":"CC0-1.0",
        "geometry_url":"https://tfwagames.itch.io/voxel-tools",
        "arm_hand_shield":"Original Elysium voxel geometry and face palettes; repository MIT license",
        "grip":{"origin":[0,0,0],"axis":[0,1,0],"pickaxe_handle_width":.10625,
                "runtime_closed_hand_rotation_degrees":[0,180,0],
                "hand_bore_half_width":.064,"handNarrow_bore_half_x":.045,"handNarrow_bore_half_z":.025,
                "handShield_bore_half_x":.032,"handShield_bore_half_z":.032,
                "handRound_bore_half_x":.028,"handRound_bore_half_z":.028,
                "handDraw_string_contact":[.025,.040,-.0415],"handDraw_string_axis":[1,0,0],
                "runtime_pickaxe_uniform_scale":.98/.85,"runtime_pickaxe_handle_width":.1225,
                "runtime_pickaxe_translation_after_scale":[0,.05,0]},
        "arm_joints":{"hand_to_wrist":[0,-.10,0],
                      "forearm":{"wrist":[0,0,0],"elbow":[0,-.40,0],"overlap_y":[-.425,.025]},
                      "upperArm":{"elbow":[0,0,0],"shoulder":[0,-.45,0],"overlap_y":[-.48,.035]},
                      "wristJoint":{"origin":[0,0,0],"half_extent":.082,"bevel":.018,
                                    "placement":"at solved wrist; same hand frame or forearm frame"},
                      "scaling":"rigid rotation/translation; never stretch the X/Z cross-section"},
        "source_axes_to_runtime":"(x-.05,z-.60,-y-.15)*.2125; uniform scale; preserved silhouette",
        "models":records,"generated_swift_sha256":digest(SWIFT),
    }
    (OUT/"manifest.json").write_text(json.dumps(manifest,indent=2,sort_keys=True)+"\n")
    previews(objects)
    print(json.dumps(manifest,indent=2))


main()

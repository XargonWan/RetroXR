"""Decimate every mesh in a GLB, in place-ish, via Blender's Collapse decimator.

    blender --background --python Tools/glb/decimate_glb.py -- \
        --in  RetroXR/imported-assets/consoles/atari_2600/atari_2600_console.glb \
        --out /tmp/atari_2600_console.glb --target 26000

Sketchfab shells arrive subdivided for renders, not for a Quest: the Atari 2600
console shipped 1.08 M triangles for a box with six switches. Every object gets
the same reduction ratio (total target / total source), floored at --min-tris so
a 5 mm switch lever does not collapse into nothing, and never raised above what
the object already had.

What has to survive, because the Godot models measure against it:
  * object names — the models resolve Switch_Power / Switch_GameReset by name;
  * node transforms and world placement — every seat, port and jack constant in
    atari_2600_model.gd is a hand-measured position in this file's space;
  * image names — Godot extracts embedded textures as <glb>_<image>.png, and the
    committed .import files are keyed to Image_0/1/2.
Verify all three with Tools/glb/glb_report.py before and after.
"""
import bpy
import bmesh
import sys


def argv():
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(args, flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default


## Weld coincident vertices, WITHOUT which nothing below is worth running.
##
## These shells export as unwelded triangle soup: the Atari console arrived as
## 230 787 disconnected islands, 227 391 of them 8 faces or fewer, and a median
## "part" of one lone triangle — 964 229 of its 1.96 M edges were boundaries.
## Collapse cannot reduce an isolated triangle, so the body floored at 54 k
## however low it was asked to go, and merging material slots changed nothing.
##
## One micron is four orders of magnitude under the smallest feature on a 33 cm
## console, so this is repairing float noise, not simplifying: it takes the
## boundary count to 5 161 and the decimator's floor with it.
def _weld(obj, dist):
    if dist <= 0.0:
        return
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    before = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bm.to_mesh(obj.data)
    obj.data.update()
    after = len(bm.verts)
    bm.free()
    if before != after:
        print("[dec] %-28s weld %d -> %d verts" % (obj.name, before, after))


## Rebuild shading from the decimated geometry.
##
## glTF normals import as CUSTOM SPLIT normals, authored against a million
## triangles. Carried through a 98% collapse they describe a surface that is no
## longer there, and large flat panels came out streaked with a starburst of
## facets. Dropping them and re-deriving from the angle between faces gives back
## crisp panels and rounded edges — 35 degrees keeps the console's chamfers smooth
## and its corners sharp.
def _reshade(obj, angle_deg):
    bpy.context.view_layer.objects.active = obj
    try:
        bpy.ops.mesh.customdata_custom_splitnormals_clear()
    except RuntimeError:
        pass
    import math
    limit = math.radians(angle_deg)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        e.smooth = len(e.link_faces) != 2 or e.calc_face_angle(0.0) <= limit
    bm.to_mesh(obj.data)
    obj.data.update()
    bm.free()


def main():
    args = argv()
    src = opt(args, "--in")
    dst = opt(args, "--out")
    target = int(opt(args, "--target", "25000"))
    min_tris = int(opt(args, "--min-tris", "150"))
    weld = float(opt(args, "--weld", "1e-6"))
    smooth_deg = float(opt(args, "--smooth-angle", "35"))
    if not src or not dst:
        raise SystemExit("need --in and --out")

    merge_mats = "--no-merge-materials" not in args

    bpy.ops.wm.read_factory_settings(use_empty=True)
    # merge_vertices welds the per-primitive vertex splits back together. Without
    # it the seams are disconnected geometry that Collapse cannot cross, which
    # both caps how far the mesh can go and leaves cracks where it stops.
    #
    # import_merge_material_slots does the same thing one level up. The Atari
    # shell carries four pure-black materials with matching roughness under four
    # names (Black_Rough / Vent_Rough / Control_Panel, then Black_Gloss /
    # Black_Dull) — 825 k triangles split across slots that render identically.
    # Merging them is a draw call saved AND a wall the decimator no longer has to
    # stop at; without it the body floors out at 54 k however low you aim.
    bpy.ops.import_scene.gltf(filepath=src, merge_vertices=True,
                              import_merge_material_slots=merge_mats,
                              import_shading="NORMALS")

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    total = sum(len(o.data.loop_triangles) if o.data.loop_triangles else 0 for o in meshes)
    if total == 0:
        for o in meshes:
            o.data.calc_loop_triangles()
        total = sum(len(o.data.loop_triangles) for o in meshes)
    ratio = float(target) / float(total)
    print("[dec] %d objects, %d tris -> target %d (ratio %.5f)" % (len(meshes), total, target, ratio))

    after = 0
    for o in meshes:
        _weld(o, weld)
        o.data.calc_loop_triangles()
        src_tris = len(o.data.loop_triangles)
        want = max(min_tris, int(round(src_tris * ratio)))
        if want >= src_tris:
            after += src_tris
            _reshade(o, smooth_deg)
            print("[dec] %-28s %7d -> kept" % (o.name, src_tris))
            continue
        bpy.context.view_layer.objects.active = o
        mod = o.modifiers.new(name="Decimate", type="DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = float(want) / float(src_tris)
        # Keep the outline of the part honest — a lever's silhouette IS the read.
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=mod.name)
        _reshade(o, smooth_deg)
        o.data.calc_loop_triangles()
        got = len(o.data.loop_triangles)
        after += got
        print("[dec] %-28s %7d -> %6d  (asked %d)" % (o.name, src_tris, got, want))

    print("[dec] TOTAL %d -> %d tris" % (total, after))

    bpy.ops.export_scene.gltf(
        filepath=dst,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_image_format="AUTO",
        export_extras=False,
        export_unused_images=False,
        export_unused_textures=False,
        use_selection=False,
    )
    print("[dec] wrote %s" % dst)


main()

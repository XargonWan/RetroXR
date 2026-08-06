"""Dump a GLB's node tree, per-node world AABB and triangle budget.

Used to prove a decimation round trip did not move, rescale or rename anything
the Godot models measure off. Reads the glTF JSON only — no Blender, no Godot.
"""
import json, struct, sys

def load(path):
    d = open(path, "rb").read()
    off, j, bin_ = 12, None, None
    while off < len(d):
        clen, ctype = struct.unpack_from("<II", d, off)
        if ctype == 0x4E4F534A:
            j = json.loads(d[off + 8:off + 8 + clen])
        off += 8 + clen
    return j

def mat_from_node(n):
    if "matrix" in n:
        m = n["matrix"]           # column-major
        return [[m[0], m[4], m[8], m[12]],
                [m[1], m[5], m[9], m[13]],
                [m[2], m[6], m[10], m[14]],
                [m[3], m[7], m[11], m[15]]]
    t = n.get("translation", [0, 0, 0])
    r = n.get("rotation", [0, 0, 0, 1])
    s = n.get("scale", [1, 1, 1])
    x, y, z, w = r
    rot = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
           [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
           [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[rot[i][k] * s[k] for k in range(3)] + [t[i]] for i in range(3)] + [[0, 0, 0, 1]]

def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

def xform(m, p):
    return [sum(m[i][k] * p[k] for k in range(3)) + m[i][3] for i in range(3)]

def report(path):
    j = load(path)
    acc = j["accessors"]
    out, total = [], [0, 0]

    def walk(idx, parent, depth):
        n = j["nodes"][idx]
        world = mul(parent, mat_from_node(n))
        name = n.get("name", "?")
        line = "  " * depth + name
        if "mesh" in n:
            m = j["meshes"][n["mesh"]]
            tris = verts = 0
            lo = [1e9] * 3
            hi = [-1e9] * 3
            for pr in m["primitives"]:
                pa = acc[pr["attributes"]["POSITION"]]
                verts += pa["count"]
                tris += acc[pr["indices"]]["count"] // 3 if "indices" in pr else pa["count"] // 3
                # AABB corners through the world matrix
                for cx in (pa["min"][0], pa["max"][0]):
                    for cy in (pa["min"][1], pa["max"][1]):
                        for cz in (pa["min"][2], pa["max"][2]):
                            w = xform(world, [cx, cy, cz])
                            lo = [min(lo[i], w[i]) for i in range(3)]
                            hi = [max(hi[i], w[i]) for i in range(3)]
            total[0] += tris
            total[1] += verts
            line += "  [mesh %s tris=%d prims=%d]" % (m.get("name", "?"), tris, len(m["primitives"]))
            line += "\n" + "  " * depth + "    world lo=(%.5f %.5f %.5f) hi=(%.5f %.5f %.5f)" % (*lo, *hi)
        out.append(line)
        for c in n.get("children", []):
            walk(c, world, depth + 1)

    ident = [[1 if i == k else 0 for k in range(4)] for i in range(4)]
    for root in j["scenes"][j.get("scene", 0)]["nodes"]:
        walk(root, ident, 0)
    print("\n".join(out))
    print("TOTAL tris=%d verts=%d  materials=%d  images=%s"
          % (total[0], total[1], len(j.get("materials", [])),
             [i.get("name", "?") for i in j.get("images", [])]))

if __name__ == "__main__":
    for p in sys.argv[1:]:
        print("=== %s" % p)
        report(p)

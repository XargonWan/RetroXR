"""Compare two GLBs' node trees: names, hierarchy, world AABBs, image names.

Proves a decimation round trip moved nothing the Godot models measure against.
"""
import sys, json, struct
sys.path.insert(0, __file__.rsplit("/", 1)[0].rsplit("\\", 1)[0])
from glb_report import load, mat_from_node, mul, xform


def tree(path):
    j = load(path)
    acc = j["accessors"]
    out = {}

    def walk(idx, parent, prefix):
        n = j["nodes"][idx]
        world = mul(parent, mat_from_node(n))
        name = prefix + "/" + n.get("name", "?")
        box = None
        if "mesh" in n:
            lo, hi = [1e9] * 3, [-1e9] * 3
            tris = 0
            for pr in j["meshes"][n["mesh"]]["primitives"]:
                pa = acc[pr["attributes"]["POSITION"]]
                tris += acc[pr["indices"]]["count"] // 3 if "indices" in pr else pa["count"] // 3
                for cx in (pa["min"][0], pa["max"][0]):
                    for cy in (pa["min"][1], pa["max"][1]):
                        for cz in (pa["min"][2], pa["max"][2]):
                            w = xform(world, [cx, cy, cz])
                            lo = [min(lo[i], w[i]) for i in range(3)]
                            hi = [max(hi[i], w[i]) for i in range(3)]
            box = (lo, hi, tris)
        out[name] = box
        for c in n.get("children", []):
            walk(c, world, name)

    ident = [[1 if i == k else 0 for k in range(4)] for i in range(4)]
    for r in j["scenes"][j.get("scene", 0)]["nodes"]:
        walk(r, ident, "")
    return out, [i.get("name", "?") for i in j.get("images", [])], len(j.get("materials", []))


def main(a, b, tol=0.0005):
    ta, ia, ma = tree(a)
    tb, ib, mb = tree(b)
    bad = 0
    for k in sorted(set(ta) | set(tb)):
        if k not in tb:
            print("  LOST   %s" % k); bad += 1; continue
        if k not in ta:
            print("  EXTRA  %s" % k); bad += 1; continue
        if (ta[k] is None) != (tb[k] is None):
            print("  MESH?  %s" % k); bad += 1; continue
        if ta[k] is None:
            continue
        d = max(max(abs(ta[k][0][i] - tb[k][0][i]), abs(ta[k][1][i] - tb[k][1][i]))
                for i in range(3))
        flag = "  DRIFT" if d > tol else "  ok   "
        if d > tol:
            bad += 1
        print("%s %-42s dmax=%.6f m   %7d -> %6d tris" % (flag, k, d, ta[k][2], tb[k][2]))
    if ia != ib:
        print("  IMAGES CHANGED %s -> %s" % (ia, ib)); bad += 1
    if ma != mb:
        print("  MATERIALS %d -> %d" % (ma, mb))
    print("  %s" % ("OK" if bad == 0 else "%d PROBLEM(S)" % bad))
    return bad


if __name__ == "__main__":
    sys.exit(1 if main(sys.argv[1], sys.argv[2]) else 0)

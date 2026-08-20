"""Draw the NES pad line art for the per-platform Controls remap diagram.

Same reasoning as gen_gamepad_art.py: the Quest art is baked from a real glTF
because a Touch controller's shape cannot be guessed, but this pad is a rounded
rectangle carrying a cross, two circles and two capsules. Drawing it outright is
simpler, and the anchors come out as coordinates chosen here rather than measured
off a render, so they can never drift from the art.

It is deliberately an NES *layout* — a cross on the left, two small capsules in
the middle, two round buttons on the right. No logo, no red-and-black inset
panel, no trade dress, nothing traced from a photo, so there is nothing to
license and nobody's mark to borrow.

Emits, into RetroXR/Textures/Controllers/:

    nes_pad_line.svg    white stroke, faint white body; alpha carries the drawing

White means the Control tints it with `modulate`, exactly like the Quest and
gamepad art, so the diagram follows the panel theme instead of baking a palette
into the asset.

Also prints the ANCHORS table for console_pad_art.gd, normalized to the viewBox
so the diagram can be laid out at any size, and the two row orders. Those are not
searched the way gen_gamepad_art.py's columns were — splitting by anchor height
and ordering each row by anchor x is enough. The leader-line intersection count
over a sweep of panel sizes is printed as a check on that, and must stay 0.

Usage:
    python Tools/gen_nes_pad_art.py [out_dir]
"""
import sys
from pathlib import Path

W, H = 1000, 430

STROKE = 5.0
BODY_FILL = 0.10        # interior wash, so the silhouette reads on a dark panel

# ── Feature positions ─────────────────────────────────────────────────────────
BODY = (24, 60, 952, 310)   # x, y, w, h
BODY_R = 18

DPAD = (198, 212)
DPAD_ARM = 78           # centre to tip
DPAD_HALF = 54 / 2      # arm half-width

# Select and Start sit below the centre line on the real hardware; A and B sit
# just above it. Keeping that offset is what stops the four reading as one row.
SMALL_Y = 262
SELECT = (430, SMALL_Y)
START = (556, SMALL_Y)
SMALL_HALF_W = 44
SMALL_HALF_H = 15

FACE_Y = 218
B = (742, FACE_Y)
A = (868, FACE_Y)
FACE_R = 38

# ── Diagram layout constants, mirrored from console_pad_diagram.gd ────────────
# The crossing count below is only meaningful if these match the widget.
#
# Rows run along the TOP and BOTTOM rather than down the sides, because this pad
# is 2.3:1. Side columns suit the Quest and Xbox art, which are roughly square;
# against a wide, short body every lead would run nearly horizontally across the
# whole picture to reach a column beside it. Both layouts can be ordered to zero
# crossings, so this is a legibility choice, not a topological one — the check
# below only guards against a future anchor move making it worse.
MAX_W = 1520.0
SLOT_W = 250.0
ROW_H = 50.0
ROW_PAD = 14.0
STUB = 18.0


def _stroke(extra=""):
    return ('fill="none" stroke="#ffffff" stroke-width="%.1f" '
            'stroke-linecap="round" stroke-linejoin="round" %s' % (STROKE, extra))


def _circle(cx, cy, r, extra=""):
    return '<circle cx="%.1f" cy="%.1f" r="%.1f" %s/>' % (cx, cy, r, _stroke(extra))


def _capsule(cx, cy, half_w, half_h):
    """Rounded bar — Select and Start."""
    return ('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" %s/>'
            % (cx - half_w, cy - half_h, half_w * 2, half_h * 2, half_h, _stroke()))


def _dpad(cx, cy, arm, half):
    """A plus sign as one closed path, so the inner corners stay square."""
    p = [
        (cx - half, cy - arm), (cx + half, cy - arm),
        (cx + half, cy - half), (cx + arm, cy - half),
        (cx + arm, cy + half), (cx + half, cy + half),
        (cx + half, cy + arm), (cx - half, cy + arm),
        (cx - half, cy + half), (cx - arm, cy + half),
        (cx - arm, cy - half), (cx - half, cy - half),
    ]
    d = "M %.1f %.1f " % p[0] + " ".join("L %.1f %.1f" % q for q in p[1:]) + " Z"
    return '<path d="%s" %s/>' % (d, _stroke())


def build() -> str:
    out = []
    out.append('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" '
               'width="%d" height="%d">' % (W, H, W, H))

    out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" '
               'fill="#ffffff" fill-opacity="%.2f" stroke="#ffffff" '
               'stroke-width="%.1f" stroke-linejoin="round"/>'
               % (BODY[0], BODY[1], BODY[2], BODY[3], BODY_R, BODY_FILL, STROKE))

    out.append(_dpad(DPAD[0], DPAD[1], DPAD_ARM, DPAD_HALF))
    out.append(_capsule(SELECT[0], SELECT[1], SMALL_HALF_W, SMALL_HALF_H))
    out.append(_capsule(START[0], START[1], SMALL_HALF_W, SMALL_HALF_H))
    out.append(_circle(B[0], B[1], FACE_R))
    out.append(_circle(A[0], A[1], FACE_R))

    out.append("</svg>")
    return "\n".join(out)


def anchors() -> dict:
    """Anchor per bindable control. Keys are GamepadBindings target strings, so
    the same table serves both the XR and the physical-pad sections."""
    return {
        "up": (DPAD[0], DPAD[1] - DPAD_ARM),
        "down": (DPAD[0], DPAD[1] + DPAD_ARM),
        "left": (DPAD[0] - DPAD_ARM, DPAD[1]),
        "right": (DPAD[0] + DPAD_ARM, DPAD[1]),
        "select": SELECT,
        "start": START,
        "b": B,
        "a": A,
    }


# ── Row order and slot placement ──────────────────────────────────────────────

def _seg_hit(p1, p2, p3, p4) -> bool:
    """Do segments p1p2 and p3p4 properly cross?

    Shared endpoints do not count. Every lead meets its own stub at a point, so
    without this test each one scores a crossing against itself and a perfectly
    clean layout reports two per panel size.
    """
    if len({p1, p2, p3, p4}) < 4:
        return False

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    d1, d2 = cross(p3, p4, p1), cross(p3, p4, p2)
    d3, d4 = cross(p1, p2, p3), cross(p1, p2, p4)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))


def slot_xs(order, art_x, art_w, w):
    """Slot centres for one row.

    Each slot starts directly under (or over) its own anchor, so its lead is as
    short and as vertical as it can be. Only where two would overlap are they
    pushed apart, order preserved.

    Spreading a row evenly across the art is also crossing-free, but this pad's
    d-pad anchors sit in its left fifth, so even spacing drags three leads back
    across the whole picture to reach them. Shorter leads, not fewer crossings,
    are what this buys.
    """
    a = anchors()
    xs = [art_x + a[k][0] / W * art_w for k in order]

    for i in range(1, len(xs)):
        if xs[i] - xs[i - 1] < SLOT_W:
            xs[i] = xs[i - 1] + SLOT_W
    # The forward pass can only push right, so it may run off the edge; walk back
    # and push left by the overflow, then clamp.
    over = xs[-1] - (w - SLOT_W * 0.5)
    if over > 0:
        xs = [x - over for x in xs]
        for i in range(len(xs) - 2, -1, -1):
            if xs[i + 1] - xs[i] < SLOT_W:
                xs[i] = xs[i + 1] - SLOT_W
    lo = SLOT_W * 0.5
    if xs[0] < lo:
        shift = lo - xs[0]
        xs = [x + shift for x in xs]
    return xs


def art_rect(w, h):
    """Where the picture sits, matching console_pad_diagram.gd."""
    band_w = min(w, MAX_W)
    art_h = h - 2.0 * (ROW_H + ROW_PAD)
    aspect = float(W) / float(H)
    art_w = art_h * aspect
    if art_w > band_w:
        art_w = band_w
        art_h = art_w / aspect
    return (w - art_w) * 0.5, (h - art_h) * 0.5, art_w, art_h


def _leads(top_order, bottom_order, w, h):
    """The leader segments the widget would draw at panel size w x h."""
    a = anchors()
    art_x, art_y, art_w, art_h = art_rect(w, h)

    segs = []
    for top, order in ((True, top_order), (False, bottom_order)):
        row_y = 0.0 if top else h - ROW_H
        xs = slot_xs(order, art_x, art_w, w)
        for i, key in enumerate(order):
            cx = xs[i]
            edge = (cx, row_y + (ROW_H if top else 0.0))
            stub = (cx, edge[1] + (STUB if top else -STUB))
            ax, ay = a[key]
            anchor = (art_x + ax / W * art_w, art_y + ay / H * art_h)
            segs.append((stub, anchor))
            segs.append((edge, stub))
    return segs


def _crossings(top_order, bottom_order) -> int:
    total = 0
    for w in range(900, 1701, 100):
        for h in range(440, 721, 40):
            segs = _leads(top_order, bottom_order, w, h)
            for i in range(len(segs)):
                for j in range(i + 1, len(segs)):
                    if _seg_hit(segs[i][0], segs[i][1], segs[j][0], segs[j][1]):
                        total += 1
    return total


def orders():
    """Which control sits in which row, and in what order.

    The split is by anchor height — the pad's upper controls reach up, the lower
    ones reach down — so no lead from one row has to cross the other's. Within a
    row the slots keep anchor-x order, and slot_xs() parks each one under its own
    anchor, so no two leads in a row can invert.

    `down` goes to the bottom row despite sharing the d-pad's x with `up`; from
    the top row its lead would run straight down through the cross.
    """
    a = anchors()
    top = ["left", "up", "right"]
    bottom = ["down", "select", "start", "b", "a"]
    top.sort(key=lambda k: a[k][0])
    bottom.sort(key=lambda k: a[k][0])
    return top, bottom


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parent.parent / "RetroXR" / "Textures" / "Controllers"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "nes_pad_line.svg"
    path.write_text(build(), encoding="utf-8")
    print("wrote %s" % path)

    print('\n\t\t"anchors": {')
    for name, (x, y) in anchors().items():
        print('\t\t\t"%s": Vector2(%.4f, %.4f),' % (name, x / W, y / H))
    print("\t\t},")

    top, bottom = orders()
    print('\t\t"top": %s,' % str(top).replace("'", '"'))
    print('\t\t"bottom": %s,' % str(bottom).replace("'", '"'))
    print("\nleader-line crossings over the size sweep: %d"
          % _crossings(top, bottom))


if __name__ == "__main__":
    main()

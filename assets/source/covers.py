"""Square covers (1254x1254) for the Vanilla Plus Megapack options whose mods had no code-drawn cover.

    python covers.py [out folder] [Slug ...]     (default: ../covers, every cover)

Same system as the Bingus Shared Loader, Mod Bindings Menu, Mod Options Menu and Sound Systems Rebalanced art:
artlib.py and style.py are byte-identical copies; each mod gets its own hero graphic drawn from what it does, in plain
words, with no counts or versions. Drawn in code (Pillow and NumPy); no image generator."""
import math
import sys
from pathlib import Path

import numpy as np

import style
from artlib import Canvas, cap_height, font, ink_x
from style import ROUND, TITLE, UI, UI_BOLD, UI_SEMI, Spec, key_label, ui_size

S, M = 1254, 88
CAPTION_CAP, CAPTION_PITCH, CAPTION_GAP = 22, 40, 48
COVERS: dict[str, Spec] = {}


# ------------------------------------------------------------------ title metrics

def title_rights(square, bar):
    """Right ink edge of each cream line, as style.cover sets them."""
    ratio = cap_height(font(TITLE, 1000)) / 1000
    over = 0.015
    widths = []
    for line in square:
        l, r = ink_x(line, TITLE, 1.0)
        widths.append((r - l) / ratio - ((line[0] in ROUND) + (line[-1] in ROUND)) * over)
    l, r = ink_x(bar, TITLE, 1.0)
    bar_w = (r - l) / ratio + 0.25 + 0.17 + 3 * 0.17 + 2 * 0.12 + 0.5 * 1.4
    ch = min((S - 2 * M) / w for w in widths + [bar_w])
    rights = []
    for line in square:
        l, r = ink_x(line, TITLE, ch / ratio)
        rights.append(M - (over * ch if line[0] in ROUND else 0) + r - l)
    return rights


def caption_width(lines):
    cv = Canvas(8, 8, ss=1)
    return max(cv.measure(t, UI, ui_size(CAPTION_CAP), UI_SEMI, tracking=0.08) for t in lines)


def fitting_line(square, bar, caption):
    """The cream line with the most room on its right, if the caption fits there; None when it does not."""
    rooms = [S - M - r for r in title_rights(square, bar)]
    best = rooms.index(max(rooms))
    return best if rooms[best] >= caption_width(caption) + CAPTION_GAP else None


def corner_caption(cv, r, lines, layout):
    """Where no title line leaves room: the caption in the hero's corner next to the title, right aligned."""
    size = ui_size(CAPTION_CAP)
    if layout == 'bottom':
        first = r.top + r.h - (len(lines) - 1) * CAPTION_PITCH
    else:
        first = r.top + CAPTION_CAP
    for i, line in enumerate(lines):
        cv.text('gray', S - M, first + i * CAPTION_PITCH, line, UI, size, UI_SEMI, tracking=0.08, anchor='right')


def cover(slug, square, bar, caption, layout):
    def register(fn):
        line = fitting_line(square, bar, caption)
        if line is None:
            def row(cv, r):
                fn(cv, r)
                corner_caption(cv, r, caption, layout)
            spec = Spec(wide=' '.join(square), bar=bar, square=square, menu=lambda cv, g: None, cover_row=row,
                        cover_layout=layout)
        else:
            spec = Spec(wide=' '.join(square), bar=bar, square=square, menu=lambda cv, g: None, cover_row=fn,
                        caption=caption, caption_line=line, cover_layout=layout)
        COVERS[slug] = spec
        return fn
    return register


# ------------------------------------------------------------------ drawing helpers

def frame(cv, x0, top, bottom, corner=30, right=None):
    """The game-menu panel of the covers: bleeds off the right edge, top left corner cut and marked yellow."""
    right = cv.width + 10 if right is None else right
    cv.poly('panel', [(x0 + corner, top), (right, top), (right, bottom), (x0, bottom), (x0, top + corner)])
    cv.polyline('edge', [(right, bottom), (x0, bottom), (x0, top + corner), (x0 + corner, top), (right, top)], 2)
    cv.line('yellow', x0, top + corner, x0 + corner, top, 3.5)


def label(cv, ink, x, base, text, cap=22, anchor='left', bold=False, fill=255):
    return cv.text(ink, x, base, text, UI, ui_size(cap), UI_BOLD if bold else UI_SEMI, tracking=0.08,
                   anchor=anchor, fill=fill)


def curve(fn, t0, t1, n=80):
    return [fn(t0 + (t1 - t0) * i / n) for i in range(n + 1)]


def bezier(p0, c, p1, n=80):
    return curve(lambda t: ((1 - t) ** 2 * p0[0] + 2 * t * (1 - t) * c[0] + t * t * p1[0],
                            (1 - t) ** 2 * p0[1] + 2 * t * (1 - t) * c[1] + t * t * p1[1]), 0, 1, n)


def stroke(cv, ink, pts, w):
    """A smooth line through the points: round joins and ends, so curves keep clean edges."""
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        if (ax, ay) != (bx, by):
            cv.line(ink, ax, ay, bx, by, w)
    for x, y in pts:
        cv.circle(ink, x, y, w / 2)


def dashed(cv, ink, pts, w, dash, gap):
    """A dashed stroke along a polyline (dash and gap measured along the path)."""
    on, left = True, dash
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        seg = math.hypot(bx - ax, by - ay)
        pos = 0.0
        while pos < seg - 1e-6:
            step = min(left, seg - pos)
            t0, t1 = pos / seg, (pos + step) / seg
            if on:
                stroke(cv, ink, [(ax + (bx - ax) * t0, ay + (by - ay) * t0), (ax + (bx - ax) * t1, ay + (by - ay) * t1)],
                       w)
            pos += step
            left -= step
            if left <= 1e-6:
                on = not on
                left = dash if on else gap


def heading(pts):
    (ax, ay), (bx, by) = pts[-4], pts[-1]
    return math.atan2(by - ay, bx - ax)


def arrowhead(cv, ink, x, y, angle, size, w):
    for side in (-1, 1):
        a = angle + math.pi - side * 0.5
        cv.line(ink, x, y, x + math.cos(a) * size, y + math.sin(a) * size, w)
    cv.rect(ink, x - w / 2, y - w / 2, x + w / 2, y + w / 2)


def arrow(cv, ink, x0, y0, x1, y1, w, head):
    cv.line(ink, x0, y0, x1, y1, w)
    arrowhead(cv, ink, x1, y1, math.atan2(y1 - y0, x1 - x0), head, w)


def ring_dashed(cv, ink, cx, cy, r, w, parts=24):
    for i in range(parts):
        a0, a1 = 2 * math.pi * i / parts, 2 * math.pi * (i + 0.55) / parts
        cv.polyline(ink, curve(lambda a: (cx + r * math.cos(a), cy + r * math.sin(a)), a0, a1, 8), w)


def ellipse_pts(cx, cy, rx, ry, n=120):
    return [(cx + rx * math.cos(a), cy + ry * math.sin(a)) for a in np.linspace(0, 2 * math.pi, n)]


def hellpod(cv, cx, cy, s, ink='cream'):
    """A hellpod falling nose down; (cx, cy) is the middle of its body, s its width."""
    cv.rrect(ink, cx - s / 2, cy - 1.1 * s, cx + s / 2, cy + 0.5 * s, s * 0.32)
    cv.poly(ink, [(cx - s / 2, cy + 0.3 * s), (cx + s / 2, cy + 0.3 * s), (cx, cy + 1.15 * s)])
    for d in (-1, 1):
        cv.poly(ink, [(cx + d * s * 0.5, cy - 1.0 * s), (cx + d * s * 0.85, cy - 1.25 * s),
                      (cx + d * s * 0.85, cy - 0.7 * s), (cx + d * s * 0.5, cy - 0.45 * s)])
    for y in (-0.6, 0.0):                               # panel seams
        cv.rect(ink, cx - s / 2 - 1, cy + (y - 0.035) * s, cx + s / 2 + 1, cy + (y + 0.035) * s, fill=0)


def lightning(cv, ink, x, y, h):
    """A lightning-bolt glyph, `h` tall, its top at (x, y)."""
    k = h / 100
    pts = [(14, 0), (46, 0), (32, 38), (54, 38), (8, 100), (20, 54), (0, 54)]
    cv.poly(ink, [(x + k * px, y + k * py) for px, py in pts])


def person(cv, ink, cx, feet, h):
    """A standing figure, side on, facing right: helmet, pack, body and legs in one silhouette."""
    k = h / 150
    cv.circle(ink, cx + 6 * k, feet - 132 * k, 17 * k)
    body = [(-14, -112), (24, -112), (22, -62), (16, -62), (24, 0), (8, 0), (2, -46), (-4, 0), (-20, 0), (-12, -62),
            (-16, -62)]
    cv.poly(ink, [(cx + k * x, feet + k * y) for x, y in body])
    cv.rrect(ink, cx - 32 * k, feet - 108 * k, cx - 10 * k, feet - 66 * k, 6 * k)
    cv.line(ink, cx + 20 * k, feet - 96 * k, cx + 46 * k, feet - 80 * k, 9 * k)


def bolt(cv, ink, x0, y0, x1, y1, w, jag, seed, steps=9):
    """A jagged electric arc between two points."""
    rng = np.random.default_rng(seed)
    nx, ny = -(y1 - y0), x1 - x0
    norm = math.hypot(nx, ny)
    nx, ny = nx / norm, ny / norm
    pts = [(x0, y0)]
    for i in range(1, steps):
        t = i / steps
        off = (rng.random() - 0.5) * 2 * jag * (1 if i % 2 else -1) * (0.5 + 0.5 * math.sin(math.pi * t))
        pts.append((x0 + (x1 - x0) * t + nx * off, y0 + (y1 - y0) * t + ny * off))
    pts.append((x1, y1))
    cv.polyline(ink, pts, w)
    return pts


# ------------------------------------------------------------------ heroes

@cover('BetterStratagemBounce', ['BETTER', 'STRATAGEM'], 'BOUNCE', ['STICKS ON MORE', 'SURFACES'], 'top')
def bounce(cv, r):
    """A stratagem ball lands on a rock's sloped top (well under the game's 45-degree limit) and stays, beam up;
    where it used to bounce off and roll away, in grey."""
    ground = S - 70
    a, b = (620, r.top + 340), (1020, r.top + 160)      # the rock's sloped top, about 24 degrees
    rock = [(520, S + 10), (540, ground), a, b, (S + 10, r.top + 150), (S + 10, S + 10)]
    cv.poly('dim', rock)
    stroke(cv, 'gray', rock[1:5], 4)
    cv.line('gray', -10, ground, 540, ground, 4)
    u = 0.55
    land = (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)
    fx, fy = b[0] - a[0], b[1] - a[1]
    fl = math.hypot(fx, fy)
    nx, ny = fy / fl, -fx / fl                          # outward normal, up and left
    ball = (land[0] + nx * 24, land[1] + ny * 24)
    throw = bezier((150, ground - 120), (420, r.top - 60), (ball[0] - 30, ball[1] - 14))
    dashed(cv, 'cream', throw, 6, 20, 14)
    cv.circle('gray', 150, ground - 120, 12)
    rest = (430, ground - 22)
    ghost = bezier((ball[0] - 20, ball[1] + 4), (520, ball[1] - 160), (rest[0] + 30, rest[1] - 6))
    dashed(cv, 'gray', ghost, 5, 14, 14)
    cv.ring('gray', rest[0], rest[1], 20, 5)
    label(cv, 'gray', rest[0] - 40, ground - 14, 'OLD BOUNCE', 20, anchor='right')
    cv.rect('yellow', ball[0] - 4, r.top + 30, ball[0] + 4, ball[1] - 22)
    cv.circle('yellow', ball[0], ball[1], 24)


@cover('HellpodSteeringUnlocked', ['HELLPOD', 'STEERING'], 'UNLOCKED', ['STEER TOWARD', 'HIGH GROUND'], 'bottom')
def steering(cv, r):
    """A hellpod steers over and down onto a rooftop; the old pod (grey) was pushed down to the low ground."""
    bottom = r.top + r.h - 10
    low, high = bottom - 60, bottom - 250
    cv.rect('dim', -10, low, S + 10, bottom)
    cv.line('gray', -10, low, 640, low, 4)
    cv.rect('dim', 640, high, S + 10, low)              # a building, its roof the high ground
    stroke(cv, 'gray', [(640, low), (640, high), (S + 10, high)], 4)
    for wy in (high + 46, high + 116):
        for wx in (700, 830, 960, 1090):
            cv.rect('dim', wx, wy, wx + 70, wy + 40, fill=0)
    px, py = 300, 150
    hellpod(cv, px, py, 76)
    for d in (-1, 1):
        for k in range(2):
            cx = px + d * (104 + 32 * k)
            cv.polyline('yellow', [(cx - d * 13, py - 40), (cx + d * 13, py - 10), (cx - d * 13, py + 20)], 8)
    dashed(cv, 'gray', [(px, py + 130), (px, low - 8)], 5, 16, 14)
    end = (930, high - 46)
    path = bezier((px + 14, py + 130), (900, py + 70), end)
    dashed(cv, 'yellow', path, 7, 22, 12)
    arrowhead(cv, 'yellow', end[0], end[1], heading(path), 26, 7)
    cv.rect('yellow', end[0] - 56, high - 6, end[0] + 56, high + 4)


@cover('ReinforcementBeaconsFixed', ['REINFORCEMENT', 'BEACONS'], 'FIXED', ['CENTERED OVER', 'YOUR BEACON'], 'top')
def beacons(cv, r):
    """Top-down: your queued reinforcement pod centred over the beacon; where it used to land (grey) pulled onto it."""
    cx, cy = 700, r.top + 400
    for k, rr in enumerate((250, 175)):
        ring_dashed(cv, 'cream', cx, cy, rr, 5, 32 - 6 * k)
    cv.ring('yellow', cx, cy, 70, 7)
    for a in (0, 90, 180, 270):
        t = math.radians(a)
        cv.line('yellow', cx + 88 * math.cos(t), cy + 88 * math.sin(t), cx + 122 * math.cos(t), cy + 122 * math.sin(t), 7)
    cv.circle('cream', cx, cy, 40)
    cv.ring('cream', cx, cy, 40, 6)
    cv.circle('cream', cx, cy, 15, fill=0)
    for gx, gy in [(250, r.top + 130)]:              # your pod's old landing spot
        ring_dashed(cv, 'gray', gx, gy, 40, 5, 14)
        dx, dy = cx - gx, cy - gy
        d = math.hypot(dx, dy)
        arrow(cv, 'gray', gx + dx / d * 60, gy + dy / d * 60, cx - dx / d * 140, cy - dy / d * 140, 5, 22)


@cover('ConsistentVaulting', ['CONSISTENT'], 'VAULTING', ['CLIMBS HIGHER', 'LEDGES'], 'bottom')
def vaulting(cv, r):
    """Side view: a climb onto each ledge of a rising row, every one taken."""
    floor = r.top + r.h - 150
    blocks = [(380, floor - 100), (620, floor - 210), (860, floor - 410)]
    outline = [(-10, floor)]
    for bx, top in blocks:
        outline += [(bx, outline[-1][1]), (bx, top)]
    outline += [(S + 10, blocks[-1][1])]
    cv.poly('dim', outline + [(S + 10, floor), (-10, floor)])
    cv.polyline('gray', outline, 4)
    cv.line('gray', -10, floor, S + 10, floor, 4)
    person(cv, 'cream', 170, floor, 150)
    starts = [(230, floor - 20)] + [(bx + 70, top - 20) for bx, top in blocks[:-1]]
    for (sx, sy), (bx, top) in zip(starts, blocks):
        end = (bx + 80, top - 18)
        path = bezier((sx, sy), (bx - 30, top - 170), end)
        dashed(cv, 'yellow', path, 7, 20, 12)
        arrowhead(cv, 'yellow', end[0], end[1], heading(path), 24, 7)


@cover('ShallowWaterDiving', ['SHALLOW', 'WATER'], 'DIVING', ['DIVE FROM', 'SHALLOW WATER'], 'top')
def diving(cv, r):
    """Side view: a Helldiver standing shin-deep in water dives forward onto the dry bank. The gauge beside them
    stands on the bottom: the water's height on it, and in yellow the deepest water a dive can start in."""
    bed = S - 50
    surface = bed - 56                                  # about lower-shin depth for a 230 px figure
    land = surface - 24
    bank_foot, bank_top = 560, 780
    shore = bank_foot + (bed - surface) * (bank_top - bank_foot) / (bed - land)     # where the water meets the bank
    wave = curve(lambda x: (x, surface + 5 * math.sin((x - shore) / 30)), -10, shore, 160)
    cv.poly('band', wave + [(bank_foot, bed), (-10, bed)])
    cv.poly('dim', [(-10, bed), (bank_foot, bed), (bank_top, land), (S + 10, land), (S + 10, S + 10), (-10, S + 10)])
    stroke(cv, 'gray', [(-10, bed), (bank_foot, bed), (bank_top, land), (S + 10, land)], 4)
    px = 330
    person(cv, 'cream', px, bed, 230)
    cv.rect('cream', px - 60, surface + 3, px + 60, bed + 2, fill=0)      # the shins under water
    stroke(cv, 'cream', wave, 7)
    dive = bezier((px + 50, bed - 180), (700, r.top + 70), (960, land - 26))
    dashed(cv, 'yellow', dive, 7, 22, 12)
    arrowhead(cv, 'yellow', dive[-1][0], dive[-1][1], heading(dive), 26, 7)
    gx = 150                                            # depth gauge standing on the bottom
    cv.line('gray', gx, bed, gx, bed - 140, 4)
    for k in range(8):
        y = bed - k * 20
        cv.line('gray', gx, y, gx + (30 if k % 2 == 0 else 18), y, 4)
    limit = bed - 80
    cv.line('yellow', gx - 26, limit, gx + 50, limit, 7)
    cv.poly('yellow', [(gx - 56, limit - 15), (gx - 30, limit), (gx - 56, limit + 15)])


@cover('SentryAimRetention', ['SENTRY', 'AIM'], 'RETENTION', ['KEEPS ITS AIM', 'BETWEEN TARGETS'], 'bottom')
def sentry(cv, r):
    """Top-down: a sentry on target, turning straight on to the next target instead of letting its aim go."""
    sx, sy = 250, r.top + 370
    reach = 560
    a0, a1 = math.radians(-31), math.radians(25)
    targets = [(sx + reach * math.cos(a0), sy + reach * math.sin(a0)), (sx + reach * math.cos(a1), sy + reach * math.sin(a1))]
    cv.poly('band', [(sx, sy)] + curve(lambda a: (sx + 900 * math.cos(a), sy + 900 * math.sin(a)), a0 - 0.1,
                                       a1 + 0.1, 30))
    for k in range(3):                                  # tripod legs
        t = a0 + math.pi + (k - 1) * 2 * math.pi / 3
        cv.line('gray', sx, sy, sx + 110 * math.cos(t), sy + 110 * math.sin(t), 14)
        cv.circle('gray', sx + 110 * math.cos(t), sy + 110 * math.sin(t), 14)
    ux, uy = math.cos(a0), math.sin(a0)
    for side in (-1, 1):                                # twin barrels
        ox, oy = -uy * 16 * side, ux * 16 * side
        cv.line('cream', sx + ox + ux * 30, sy + oy + uy * 30, sx + ox + ux * 190, sy + oy + uy * 190, 14)
    cv.poly('cream', [(sx + 64 * math.cos(a0 + t), sy + 64 * math.sin(a0 + t)) for t in np.linspace(0, 2 * math.pi, 7)])
    # The target it lost sight of: an outline, with the aim still held on it.
    dashed(cv, 'yellow', [(sx + ux * 200, sy + uy * 200), (targets[0][0] - ux * 50, targets[0][1] - uy * 50)], 4, 14, 10)
    tx, ty = targets[0]
    stroke(cv, 'yellow', [(tx, ty - 38), (tx + 38, ty), (tx, ty + 38), (tx - 38, ty), (tx, ty - 38)], 6)
    for i, (tx, ty) in enumerate(targets[1:], 1):
        cv.poly('cream' if i == 1 else 'gray', [(tx, ty - 38), (tx + 38, ty), (tx, ty + 38), (tx - 38, ty)])
    turn = curve(lambda a: (sx + reach * math.cos(a), sy + reach * math.sin(a)), a0 + 0.11, a1 - 0.1, 50)
    dashed(cv, 'yellow', turn, 7, 18, 10)
    arrowhead(cv, 'yellow', turn[-1][0], turn[-1][1], heading(turn), 24, 7)


@cover('EnemyCollisionSynchronized', ['ENEMY', 'COLLISION'], 'SYNCHRONIZED', ['COLLISION', 'MATCHES THE BODY'],
       'top')
def collision(cv, r):
    """A dead bug, legs up, with its collision drawn back onto the body (yellow); where it had drifted, in grey."""
    cy = r.top + 300
    parts = [(720, cy, 210, 94), (510, cy + 6, 100, 78), (392, cy + 18, 56, 48)]
    for px, py, rx, ry in parts:                        # one outline around the joined body
        cv.poly('dim', ellipse_pts(px, py, rx, ry))
        cv.poly('cream', ellipse_pts(px, py, rx + 5, ry + 5))
    for px, py, rx, ry in parts:
        cv.poly('cream', ellipse_pts(px, py, rx, ry), fill=0)
    for lx in (470, 545, 620):                          # legs up
        stroke(cv, 'cream', [(lx, cy - 72), (lx - 34, cy - 170), (lx + 14, cy - 240), (lx + 40, cy - 228)], 9)
        cv.circle('cream', lx - 34, cy - 170, 9)          # the knee joint
    for k in range(3):                                  # the abdomen's segments
        x = 650 + 70 * k
        half = 94 * math.sqrt(max(0.0, 1 - ((x - 720) / 210) ** 2))
        stroke(cv, 'cream', curve(lambda a: (x + 22 * math.cos(a), cy + half * math.sin(a)), -math.pi / 2,
                                  math.pi / 2, 24), 4)
    hx, hy, hrx, hry = 625, cy + 8, 320, 124
    dashed(cv, 'yellow', ellipse_pts(hx, hy, hrx, hry), 7, 22, 12)
    gx, gy = hx + 190, hy + 268                         # where the collision had drifted to
    dashed(cv, 'gray', ellipse_pts(gx, gy, hrx, hry), 5, 16, 14)
    arrow(cv, 'gray', gx - 40, gy - 30, hx + 70, hy + hry + 18, 6, 24)


@cover('ControllableHoverPack', ['CONTROLLABLE', 'HOVER'], 'PACK', ['LAND WHEN', 'YOU CHOOSE'], 'bottom')
def hover(cv, r):
    """Height over time: up, the hover, and a second press that brings you down early (yellow)."""
    ground = r.top + r.h - 40
    hover_y = r.top + 230
    cv.line('gray', -10, ground, S + 10, ground, 4)
    rise = curve(lambda t: (130 + 240 * t, ground - (ground - hover_y) * math.sin(t * math.pi / 2)), 0, 1)
    stroke(cv, 'cream', rise, 8)
    press_x = 600
    stroke(cv, 'cream', [rise[-1], (press_x, hover_y)], 8)
    late = bezier((1000, hover_y), (1120, hover_y), (1130, ground - 8))
    dashed(cv, 'gray', [(press_x, hover_y), (1000, hover_y)] + late[1:], 5, 16, 12)
    cv.rect('gray', 1130 - 40, ground - 5, 1130 + 40, ground + 5)
    land = curve(lambda t: (press_x + 250 * t, hover_y + (ground - hover_y) * (1 - math.cos(t * math.pi / 2))), 0, 1)
    stroke(cv, 'yellow', land, 9)
    person(cv, 'cream', 430, hover_y - 44, 120)        # a Helldiver hovering on the jump pack
    cv.circle('yellow', press_x, hover_y, 18)
    label(cv, 'cream', press_x, hover_y - 44, 'PRESS AGAIN', 26, anchor='center', bold=True)
    cv.rect('yellow', land[-1][0] - 60, ground - 5, land[-1][0] + 60, ground + 5)


@cover('KnowYourConstellation', ['KNOW YOUR'], 'CONSTELLATION', ['EVERY ENEMY', 'BEFORE YOU DROP'], 'top')
def constellation(cv, r):
    """The briefing panel as the mod lays it out: large enemies with a ten-tick spawn-rate meter, then the small and
    medium enemies as a list, most common first. Names, captions and the forecast are the mod's own: its roster.compute
    for a Terminid mission with standard forces at difficulty 7."""
    frame(cv, r.x0 - 24, r.top, S + 10)

    def section(y, left, right):
        label(cv, 'gray', r.x0, y, left, 22)
        label(cv, 'gray', r.x1, y, right, 22, anchor='right')
        cv.rect('gray', r.x0, y + 16, r.x1, y + 18)
    label(cv, 'cream', r.x0, r.top + 70, 'STANDARD FORCES', 32, bold=True)   # the mod's headline for this mission
    y = r.top + 126
    section(y, 'LARGE ENEMIES', 'SPAWN RATE')
    tick_w, tick_gap, tick_h = 22, 10, 40
    meter_x = r.x1 - 10 * tick_w - 9 * tick_gap
    y += 86
    for name, ticks in [('Brood Commanders', 8), ('Bile Titans', 7), ('Chargers', 6), ('Charger Behemoths', 6),
                        ('Impalers', 5), ('Spore Chargers', 4)]:
        ink = 'cream'
        label(cv, ink, r.x0, y, name, 34)
        for k in range(10):
            x = meter_x + k * (tick_w + tick_gap)
            cv.rect(ink if k < ticks else 'dim', x, y - 37, x + tick_w, y - 37 + tick_h)
        y += 78
    y += 14
    section(y, 'SMALL AND MEDIUM ENEMIES', 'MOST COMMON FIRST')
    y += 70
    names = ['Warriors', 'Scavengers', 'Hunters', 'Hive Guards']
    line = ''
    for i, name in enumerate(names):                     # wrapped by whole names, as the mod's list
        word = name + (',' if i < len(names) - 1 else '')
        trial = (line + ' ' + word).strip()
        if cv.measure(trial, UI, ui_size(34), UI_SEMI, tracking=0.08) > r.x1 - r.x0 and line:
            label(cv, 'cream', r.x0, y, line, 34)
            y += 62
            line = word
        else:
            line = trial
    label(cv, 'cream', r.x0, y, line, 34)


def armor_shape(cx, top, w, h):
    """Body armor seen from the front: shoulder pads, a narrower waist; (cx, top) is the middle of the neckline."""
    return [(cx - w * 0.16, top), (cx - w * 0.5, top + h * 0.1), (cx - w * 0.5, top + h * 0.34),
            (cx - w * 0.36, top + h * 0.34), (cx - w * 0.33, top + h), (cx + w * 0.33, top + h),
            (cx + w * 0.36, top + h * 0.34), (cx + w * 0.5, top + h * 0.34), (cx + w * 0.5, top + h * 0.1),
            (cx + w * 0.16, top), (cx, top + h * 0.16)]


def armor(cv, ink, cx, top, w, h):
    cv.poly(ink, armor_shape(cx, top, w, h))


def tile_icon(cv, ink, kind, mx, my, w, h):
    if kind == 0:                                       # helmet with a visor
        dome = curve(lambda a: (mx + w * 0.3 * math.cos(a), my + h * 0.12 - h * 0.36 * math.sin(a)), 0, math.pi, 30)
        cv.poly(ink, dome + [(mx - w * 0.3, my + h * 0.3), (mx + w * 0.3, my + h * 0.3)])
        cv.rect(ink, mx - w * 0.2, my - h * 0.02, mx + w * 0.2, my + h * 0.1, fill=0)
    elif kind == 1:                                     # body armor
        armor(cv, ink, mx, my - h * 0.36, w * 0.66, h * 0.7)
    elif kind == 2:                                     # a cape
        cv.poly(ink, [(mx - w * 0.18, my - h * 0.34), (mx + w * 0.18, my - h * 0.34), (mx + w * 0.3, my + h * 0.34),
                      (mx + w * 0.1, my + h * 0.26), (mx - w * 0.1, my + h * 0.34), (mx - w * 0.3, my + h * 0.26)])
    elif kind == 3:                                     # a rifle
        cv.rect(ink, mx - w * 0.4, my - h * 0.08, mx + w * 0.4, my + h * 0.04)
        cv.poly(ink, [(mx - w * 0.4, my - h * 0.08), (mx - w * 0.22, my - h * 0.08), (mx - w * 0.26, my + h * 0.2),
                      (mx - w * 0.4, my + h * 0.2)])
        cv.rect(ink, mx - w * 0.06, my, mx + w * 0.04, my + h * 0.26)
    else:                                               # a grenade
        cv.circle(ink, mx, my + h * 0.06, min(w, h) * 0.24)
        cv.rect(ink, mx - w * 0.06, my - h * 0.3, mx + w * 0.06, my - h * 0.14)


@cover('ArmoryPreviewCache', ['ARMORY', 'PREVIEW'], 'CACHE', ['FASTER', 'REPEAT VISITS'], 'bottom')
def cache(cv, r):
    """The Armory's item grid on a repeat visit, every thumbnail already drawn; one item picked. The bottom right is
    left for the caption."""
    bottom = r.top + r.h - 100
    frame(cv, r.x0 - 24, r.top + 60, bottom)
    cols, rows, gap = 6, 2, 18
    gx0, gy0 = r.x0 + 12, r.top + 112
    tw = (r.x1 - gx0 + gap) / cols - gap
    th = (bottom - 46 - gy0 + gap) / rows - gap
    for i in range(rows):
        for j in range(cols):
            x, y = gx0 + j * (tw + gap), gy0 + i * (th + gap)
            pick = (i, j) == (1, 1)
            cv.rrect('dim', x, y, x + tw, y + th, 10)
            if pick:
                cv.rrect_outline('yellow', x - 7, y - 7, x + tw + 7, y + th + 7, 15, 6)
            side = min(tw, th)
            tile_icon(cv, 'yellow' if pick else 'cream', (i * 2 + j) % 5, x + tw / 2, y + th / 2, side, side)


@cover('ClickableScrollbars', ['CLICKABLE'], 'SCROLLBARS', ['STILL DRAGS WITH', 'THE POINTER AWAY'], 'top')
def scrollbars(cv, r):
    """A list with its scrollbar: the pointer, well away from the track, still drags the thumb."""
    frame(cv, r.x0 - 24, r.top, S + 10, right=r.x1 + 24)
    track_x = r.x1 - 44
    y = r.top + 35
    while y < S:
        cv.rrect('dim', r.x0, y, track_x - 80, y + 60, 8)
        cv.rect('gray', r.x0 + 28, y + 25, r.x0 + 300, y + 35)
        y += 80
    cv.rrect('dim', track_x - 16, r.top + 40, track_x + 16, S + 10, 16)
    thumb = (r.top + 230, r.top + 430)
    mid = (thumb[0] + thumb[1]) / 2
    cv.rrect('yellow', track_x - 16, thumb[0], track_x + 16, thumb[1], 16)
    px, py = r.x0 + 430, mid + 10
    dashed(cv, 'yellow', [(px + 70, mid), (track_x - 34, mid)], 5, 16, 10)
    k = 1.7
    cursor = [(0, -40), (0, 12), (12, 0), (22, 22), (31, 18), (21, -4), (38, -4)]
    cv.poly('cream', [(px + k * x, py + k * y) for x, y in cursor])
    for d in (-1, 1):
        arrow(cv, 'yellow', px - 40, py - 30 + d * 40, px - 40, py - 30 + d * 110, 6, 18)


@cover('ArcThrowerRevamped', ['ARC', 'THROWER'], 'REVAMPED', ['HOLD TO', 'KEEP FIRING'], 'bottom')
def arc(cv, r):
    """The Arc Thrower firing arc after arc while the button stays held: one shot on top, the held shots below."""
    gy = r.top + 230
    cv.rrect('gray', 110, gy - 40, 360, gy + 34, 12)
    for k in range(3):
        cv.rect('cream', 190 + 44 * k, gy - 54, 214 + 44 * k, gy + 48)
    cv.poly('gray', [(170, gy + 30), (220, gy + 30), (196, gy + 130), (150, gy + 130)])
    cv.rect('gray', 360, gy - 22, 480, gy + 10)
    cv.rect('gray', 470, gy - 30, 490, gy + 18)
    end = (1070, gy - 20)
    main = bolt(cv, 'yellow', 494, gy - 6, end[0], end[1], 10, 46, 4)
    fork = main[5]
    bolt(cv, 'yellow', fork[0], fork[1], fork[0] + 130, fork[1] + 120, 5, 20, 9, 5)
    cv.ring('yellow', end[0] + 40, end[1], 34, 7)
    hold = r.top + r.h - 60                             # the button held down the whole time: a key and its timeline
    key_label(cv, 230, hold, 'HOLD', 30, 'cream', 18, 12, 9, 4, min_w=120)
    cv.rect('yellow', 260, hold - 7, S + 10, hold + 7)
    for k in range(7):
        lightning(cv, 'cream', 330 + 130 * k, hold - 150, 90)


@cover('GalacticMenuHotkey', ['SHIP', 'STATION'], 'HOTKEYS', ['ONE KEY FOR', 'EACH STATION'], 'top')
def hotkeys(cv, r):
    """Each default key beside the station it opens on the ship."""
    rows = [('TAB', 'GALACTIC MAP'), ('F1', 'ARMORY'), ('F5', 'CONTROL CENTER'), ('F6', 'SHIP MANAGEMENT'),
            ('F7', 'STRATAGEM HERO'), ('F8', 'HELLPOD')]
    y = r.top + 66
    for i, (key, station) in enumerate(rows):
        ink = 'yellow' if i == 1 else 'cream'
        key_label(cv, r.x0 + 116, y, key, 32, ink, 16, 11, 9, 3.5, min_w=112)
        arrow(cv, 'gray', r.x0 + 146, y, r.x0 + 214, y, 4, 14)
        label(cv, ink, r.x0 + 246, y + 16, station, 32)
        y += 88


@cover('FlameDamageFixed', ['FLAME', 'DAMAGE'], 'FIXED', ['HITS CLOSE TARGETS,', 'NOT ITSELF'], 'bottom')
def flame(cv, r):
    """A Flame Sentry's flame, one stream as the game draws it, burning a bug right in front of the nozzle: the
    flame now starts close, so near targets are hit too."""
    cy = r.top + 205
    ground = cy + 132
    cv.poly('gray', [(110, cy - 30), (150, cy - 58), (270, cy - 58), (290, cy - 30), (290, cy + 34), (110, cy + 34)])
    cv.rect('gray', 290, cy - 18, 384, cy + 4)
    cv.rect('gray', 376, cy - 26, 392, cy + 12)
    cv.rect('gray', 178, cy + 34, 222, cy + 100)
    cv.poly('gray', [(150, cy + 100), (250, cy + 100), (290, ground), (110, ground)])
    for x in (150, 200, 250):                           # hazard marks on the turret
        cv.poly('gray', [(x, cy - 20), (x + 22, cy - 20), (x + 6, cy + 14), (x - 16, cy + 14)], fill=0)
    cv.line('gray', 60, ground, 800, ground, 4)
    reach, nozzle, axis = 980, 396, cy - 7

    def plume(spread, ink, seed):
        rng = np.random.default_rng(seed)
        upper, lower = [], []
        for i in range(41):
            t = i / 40
            x = nozzle + (reach - nozzle) * t
            half = 10 + spread * t ** 0.7 * (1 + 0.22 * (rng.random() - 0.5))
            upper.append((x, axis - half))
            lower.append((x, axis + half * 0.85))
        cv.poly(ink, upper + [(reach + 46, axis)] + lower[::-1])
    plume(80, 'cream', 1)
    plume(38, 'yellow', 2)
    # The bug in the flame, drawn in front of it.
    body = ellipse_pts(570, cy + 40, 84, 58)
    head = ellipse_pts(478, cy + 58, 36, 32)
    legs = [[(x, cy + 80), (x + 16, cy + 108), (x + 4, ground)] for x in (528, 572, 616)]
    for (ex, ey, rx, ry) in ((570, cy + 40, 88, 62), (478, cy + 58, 40, 36)):     # one outline round both
        cv.poly('gray', ellipse_pts(ex, ey, rx, ry))
    for shape in (body, head):
        cv.poly('cream', shape, fill=0)
        cv.poly('yellow', shape, fill=0)
        cv.poly('gray', shape, fill=0)
        cv.poly('dim', shape)
    for leg in legs:
        stroke(cv, 'gray', leg, 8)

@cover('BetterLobbyManagement', ['BETTER', 'LOBBY'], 'MANAGEMENT', ['HOST TOOLS IN', 'THE ESCAPE MENU'], 'top')
def lobby(cv, r):
    """The escape menu's host buttons, PROMOTE picked, beside the squad: the host crown passes on. The panel ends
    under its contents."""
    frame(cv, r.x0 - 24, r.top, r.top + 640)
    y = r.top + 70
    for i, item in enumerate(['DISBAND SQUAD', 'PROMOTE', 'CANCEL SOS']):
        pick = i == 1
        cv.rrect('yellow' if pick else 'dim', r.x0, y, r.x0 + 470, y + 100, 12)
        label(cv, 'yellow' if pick else 'cream', r.x0 + 34, y + 66, item, 34, fill=0 if pick else 255)
        y += 132

    def crown(ink, x, y, s):
        cv.poly(ink, [(x - s, y + s * 0.6), (x - s, y - s * 0.5), (x - s * 0.5, y), (x, y - s * 0.7),
                      (x + s * 0.5, y), (x + s, y - s * 0.5), (x + s, y + s * 0.6)])
    sx, first, pitch = 810, r.top + 120, 136
    for k in range(4):
        sy = first + k * pitch
        ink = 'yellow' if k == 1 else 'cream' if k == 0 else 'gray'
        cv.circle(ink, sx, sy, 40)
        cv.rrect(ink, sx + 70, sy - 19, r.x1, sy + 19, 10)
    crown('gray', sx - 104, first, 32)
    crown('yellow', sx - 104, first + pitch, 32)
    turn = bezier((sx - 148, first - 4), (sx - 230, first + pitch / 2), (sx - 148, first + pitch + 4))
    stroke(cv, 'yellow', turn, 6)
    arrowhead(cv, 'yellow', turn[-1][0], turn[-1][1], heading(turn), 20, 6)


@cover('HellpodDropHold', ['HELLPOD', 'DROP'], 'HOLD', ['WAITS FOR YOUR', 'LOADING SCREEN'], 'bottom')
def drop_hold(cv, r):
    """Your hellpod held in the sky while the loading bar fills, then its drop to the ground."""
    cx, py = 280, r.top + 160
    hellpod(cv, cx, py, 72)
    for d in (-1, 1):
        x0, x1 = cx + d * 84, cx + d * 112
        cv.polyline('yellow', [(x0, py - 100), (x1, py - 100), (x1, py + 90), (x0, py + 90)], 9)
    ground = r.top + r.h - 20
    dashed(cv, 'gray', [(cx, py + 112), (cx, ground - 40)], 6, 18, 14)
    cv.line('gray', -10, ground, S + 10, ground, 4)
    ring_dashed(cv, 'cream', cx, ground - 10, 46, 5, 12)
    bx0, bx1, by = 520, r.x1, r.top + 150
    label(cv, 'gray', bx0, by - 30, 'LOADING', 26)
    cv.rrect('dim', bx0, by, bx1, by + 36, 18)
    cv.rrect('cream', bx0, by, bx0 + (bx1 - bx0) * 0.62, by + 36, 18)


@cover('LaserSentryCooldown', ['LASER', 'SENTRY'], 'COOLDOWN', ['COOLS DOWN', 'INSTEAD OF EXPLODING'], 'top')
def cooldown(cv, r):
    """Heat over time: up to max heat, a full cool-down (yellow), and firing again."""
    x0, x1 = r.x0, r.x1
    base = S - 110
    peak = r.top + 110
    cv.line('gray', x0, base, x1, base, 4)
    dashed(cv, 'yellow', [(x0, peak), (x1, peak)], 5, 18, 12)
    label(cv, 'yellow', x1, peak - 22, 'MAX HEAT', 24, anchor='right')
    up1 = [(x0, base), (x0 + 320, peak)]
    cool = [(x0 + 320, peak), (x0 + 740, base - 6)]              # a constant cooling rate, down to cold
    up2 = [(x0 + 740, base - 6), (x1 - 20, peak + 0.1 * (base - 6 - peak))]
    stroke(cv, 'cream', up1, 8)
    stroke(cv, 'yellow', cool, 9)
    stroke(cv, 'cream', up2, 8)
    cv.circle('yellow', x0 + 320, peak, 16)
    label(cv, 'yellow', x0 + 530, base + 56, 'COOLING', 24, anchor='center')


@cover('MatchYourColors', ['MATCH', 'YOUR'], 'COLORS', ['HELMET, ARMOR', 'AND CAPE MATCH'], 'bottom')
def colors(cv, r):
    """Helmet, armor and cape in the same colors: the armor's bands carried onto the other two."""
    top, bot = r.top + 90, r.top + r.h - 40
    mid = (top + bot) / 2
    hx, ax, kx = 210, 590, 1000
    helmet = curve(lambda a: (hx + 140 * math.cos(a), mid + 30 - 200 * math.sin(a)), 0, math.pi, 60) +         [(hx - 140, bot - 60), (hx - 80, bot), (hx + 80, bot), (hx + 140, bot - 60)]
    armor_w = 350
    armor_pts = armor_shape(ax, top, armor_w, bot - top)
    cape = [(kx - 110, top), (kx + 110, top), (kx + 165, bot), (kx + 55, bot - 34), (kx, bot), (kx - 55, bot - 34),
            (kx - 165, bot)]
    for shape in (helmet, armor_pts, cape):
        cv.poly('dim', shape)
        stroke(cv, 'gray', shape + [shape[0]], 4)
    cv.rect('dim', hx - 90, mid - 96, hx + 90, mid - 46, fill=0)          # the visor
    for d in (-1, 1):                                   # shoulder plates
        pad = [(ax + d * 120, top + 8), (ax + d * 205, top + 30), (ax + d * 212, top + 120), (ax + d * 150, top + 132),
               (ax + d * 118, top + 70)]
        cv.poly('gray', pad, fill=0)                    # opaque: the armor's outline stops under the plate
        cv.poly('dim', pad)
        stroke(cv, 'gray', pad + [pad[0]], 4)
    plate = [(ax - 96, top + 70), (ax + 96, top + 70), (ax + 104, mid - 14), (ax - 104, mid - 14)]
    stroke(cv, 'gray', plate + [plate[0]], 4)                                   # chest plate
    cv.rect('dim', ax - 3, top + 74, ax + 3, mid - 18, fill=0)
    for y, ink in [(mid, 'yellow'), (mid + 70, 'cream')]:
        cv.rect(ink, hx - 124, y, hx + 124, y + 46)
        cv.rect(ink, ax - 112, y, ax + 112, y + 46)
        cv.rect(ink, kx - 122, y, kx + 122, y + 46)
    y = mid + 23                                        # arrows level with the yellow band, the same gap each side
    rel = (y - top) / (bot - top)
    armor_half = armor_w * (0.36 + (0.33 - 0.36) * (rel - 0.34) / 0.66)
    cape_half = 110 + 55 * rel
    gap = 18
    arrow(cv, 'yellow', ax - armor_half - gap, y, hx + 140 + gap, y, 7, 22)
    arrow(cv, 'yellow', ax + armor_half + gap, y, kx - cape_half - gap, y, 7, 22)


@cover('StickyGrenadeHandles', ['STICKY', 'GRENADE'], 'HANDLES', ['STICKS WHEN THE', 'HANDLE HITS FIRST'], 'top')
def handles(cv, r):
    """Close up: a thermite grenade that flew in handle first, stuck to the wall by its handle."""
    wall = r.x1 - 150
    cv.rect('dim', wall, r.top - 10, S + 10, S + 10)
    cv.line('gray', wall, r.top - 10, wall, S + 10, 4)
    cy = r.top + 300
    hx0 = wall - 180
    cv.rect('cream', hx0 - 10, cy - 16, wall, cy + 16)                 # the handle, its end on the wall
    cv.rrect('cream', hx0 - 340, cy - 78, hx0, cy + 78, 36)            # the canister
    cv.rect('yellow', hx0 - 250, cy - 78, hx0 - 206, cy + 78)
    for x in (hx0 - 300, hx0 - 60):                     # its end ribs
        cv.rect('cream', x - 3, cy - 78, x + 3, cy + 78, fill=0)
    for d in (-1, 1):                                   # the hit, on the open side of the wall
        cv.line('yellow', wall - 10, cy + d * 30, wall - 34, cy + d * 74, 7)
        cv.line('yellow', wall - 40, cy + d * 26, wall - 78, cy + d * 52, 7)
    for k, dy in enumerate((-46, 0, 46)):               # it flew in this way, handle first
        x1 = hx0 - 380 - 30 * (k % 2)
        cv.line('cream', x1 - 170, cy + dy, x1, cy + dy, 6)
    label(cv, 'gray', hx0 + 60, cy - 110, 'HANDLE', 24, anchor='center')
    cv.line('gray', hx0 + 60, cy - 98, hx0 + 60, cy - 26, 4)


@cover('StratagemHeroExpanded', ['STRATAGEM', 'HERO'], 'EXPANDED', ['EVERY LOADOUT STRATAGEM', 'IN THE ARCADE'],
       'bottom')
def arcade(cv, r):
    """The arcade's arrow codes, row after row, the current one lit: stratagems the mod adds, none of them in the
    vanilla arcade's pool. Quasar Cannon, SOS Beacon, Eagle Rearm, Commando, Orbital Precision Strike, Portable
    Hellbomb."""
    codes = ['DDULR', 'UDRU', 'UULUR', 'DLUDR', 'RRU', 'DRUUU']
    names = ['QUASAR CANNON', 'SOS BEACON', 'EAGLE REARM', 'COMMANDO', 'ORBITAL PRECISION STRIKE',
             'PORTABLE HELLBOMB']
    arrow_shape = [(0.3, 0.0), (-0.02, 0.28), (-0.02, 0.1), (-0.28, 0.1), (-0.28, -0.1), (-0.02, -0.1),
                   (-0.02, -0.28)]
    size, gap, pitch = 74, 14, 98
    y = r.top + 50
    for i, code in enumerate(codes):
        if y + size > r.top + r.h:
            break
        ink = 'yellow' if i == 0 else 'cream' if i < 3 else 'gray'
        x = r.x0
        for ch in code:
            cv.rrect_outline(ink, x, y, x + size, y + size, 12, 5 if i == 0 else 4)
            cx, cy = x + size / 2, y + size / 2
            a = {'U': -math.pi / 2, 'D': math.pi / 2, 'L': math.pi, 'R': 0.0}[ch]
            cv.poly(ink, [(cx + size * (px * math.cos(a) - py * math.sin(a)),
                           cy + size * (px * math.sin(a) + py * math.cos(a))) for px, py in arrow_shape])
            x += size + gap
        label(cv, ink, r.x0 + 560, y + size / 2 + 12, names[i], 24)
        y += pitch


if __name__ == '__main__':
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'covers'
    out.mkdir(parents=True, exist_ok=True)
    for slug in sys.argv[2:] or list(COVERS):
        style.cover(COVERS[slug], out / (slug + '.png'))
        print(slug)

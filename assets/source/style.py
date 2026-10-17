"""Shared look of the CowboyBingus mod artwork.

Palette and type; the title block (cream lines over a yellow bar that bleeds off the left edge,
its word knocked out, a 45 degree chamfer and three slashes parallel to it); parts of the game's
menus drawn flat; and the three formats, each rendered from a mod's Spec:

- nexus:  the Nexus mod-page header, 1300x372. Nexus draws its breadcrumb, title and stats over
          the lower left (20 px inset) and the download button over the lower right, under a
          gradient from y=72, so everything that must read sits above y~200 and the title's
          stems line up with that 20 px inset; the menu fades out below.
- cover:  the square cover Arsenal and HD2MM show, 1254x1254.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from artlib import Canvas, cap_height, compose, font, grain, hex_rgb, ink_x, noise, to_image

TITLE = 'FRAHV.TTF'          # Franklin Gothic Heavy
UI = 'bahnschrift.ttf'       # Bahnschrift, a DIN face close to the game's UI lettering
UI_SEMI = (600, 87)          # (weight, width)
UI_BOLD = (700, 87)
C = {
    'ground': '#121110', 'panel': '#191815', 'edge': '#35322b', 'dim': '#46433b',
    'gray': '#8d887a', 'cream': '#f0e8d6', 'yellow': '#fdd00c', 'band': '#f0e8d6', 'paper': '#d7ceb9',
}
ORDER = [('panel', 1.0), ('edge', 1.0), ('band', 0.07), ('paper', 1.0), ('dim', 1.0), ('gray', 1.0), ('cream', 1.0),
         ('yellow', 1.0)]
ROUND = 'OCGQS'              # letters whose curves overshoot a margin optically


def ui_size(cap: float) -> float:
    """Bahnschrift size whose SemiBold capitals are `cap` tall."""
    return 100 * cap / cap_height(font(UI, 100, UI_SEMI))


def title_size(cap: float) -> float:
    return cap / (cap_height(font(TITLE, 1000)) / 1000)


# ------------------------------------------------------------------ title block

def cream_line(cv: Canvas, left: float, baseline: float, text: str, size: float, optical: float = 0.0) -> float:
    """A title line whose first stem sits on `left` (round letters overshoot by `optical`).
    Returns the right ink edge."""
    l, r = ink_x(text, TITLE, size)
    x = left - l - (optical if text[0] in ROUND else 0)
    cv.text('cream', x, baseline, text, TITLE, size)
    return x + r


def menu_bar(cv: Canvas, left: float, top: float, cap: float, size: float, word: str, pad: float,
             right_pad: float, chamfer: float | None = None, chamfer_ratio: float = 0.0,
             optical: float = 0.0) -> tuple[float, float]:
    """The yellow bar from the left edge with `word` knocked out and the lower right corner cut
    at 45 degrees. Returns (right edge, bottom)."""
    baseline = top + pad + cap
    bottom = baseline + pad
    l, r = ink_x(word, TITLE, size)
    x = left - l - (optical if word[0] in ROUND else 0)
    right = x + r + right_pad
    cut = chamfer if chamfer is not None else chamfer_ratio * (bottom - top)
    cv.poly('yellow', [(0, top), (right, top), (right, bottom - cut), (right - cut, bottom), (0, bottom)])
    cv.text('yellow', x, baseline, word, TITLE, size, fill=0)
    return right, bottom


def slashes(cv: Canvas, x: float, y0: float, y1: float, h: float, width: float, gap: float, count: int = 3) -> None:
    """Hazard slashes parallel to the bar's chamfer; `h` is their height (y1 - y0)."""
    for i in range(count):
        x0 = x + i * (width + gap)
        cv.poly('yellow', [(x0 + h, y0), (x0 + h + width, y0), (x0 + width, y1), (x0, y1)])


# ------------------------------------------------------------------ menu parts

@dataclass(frozen=True)
class TabMetrics:
    cap: float          # capital height of the tab labels
    pad: float          # keycap margin above the capitals and below the baseline
    key_w: float        # keycap width
    radius: float
    stroke: float
    letter_dy: float    # keycap letter baseline relative to the tab baseline
    key_gap: float      # between a keycap and the next label
    tab_gap: float      # between labels
    e_back: float       # the closing keycap sits tab_gap - e_back after the last label
    rule_dy: float      # rule below the baseline
    rule_w: float
    under_up: float     # the active label's underline rises this far above the rule
    under_ext: float    # and reaches this far past the label
    tracking: float = 0.09


NEXUS_TABS = TabMetrics(cap=14, pad=5, key_w=23, radius=4, stroke=1.5, letter_dy=-1.5, key_gap=20, tab_gap=22,
                        e_back=2, rule_dy=12, rule_w=1.2, under_up=2.2, under_ext=7)
COVER_TABS = TabMetrics(cap=27, pad=9, key_w=45, radius=7, stroke=2.6, letter_dy=-3, key_gap=34, tab_gap=38,
                        e_back=4, rule_dy=25, rule_w=2, under_up=4, under_ext=12)


def keycap(cv: Canvas, x: float, base: float, m: TabMetrics, letter: str, ink: str = 'gray') -> float:
    cv.rrect_outline(ink, x, base - m.cap - m.pad, x + m.key_w, base + m.pad, m.radius, m.stroke)
    cv.text(ink, x + m.key_w / 2, base + m.letter_dy, letter, UI, ui_size(m.cap) * 0.78, UI_BOLD, anchor='center')
    return x + m.key_w


def rule_with_underline(cv: Canvas, x0: float, x1: float, base: float, span: tuple[float, float],
                        m: TabMetrics) -> float:
    rule_y = base + m.rule_dy
    cv.rect('dim', x0, rule_y, x1, rule_y + m.rule_w)
    cv.rect('yellow', span[0] - m.under_ext, rule_y - m.under_up, span[1] + m.under_ext, rule_y + m.rule_w)
    return rule_y


def tab_header(cv: Canvas, x0: float, x1: float, base: float, labels: list[str], active: str, m: TabMetrics,
               keys: tuple[str, str] = ('Q', 'E')) -> float:
    """[Q] tabs [E] with the active tab yellow and underlined; returns the rule's y."""
    size = ui_size(m.cap)
    x = keycap(cv, x0, base, m, keys[0]) + m.key_gap
    span = (0.0, 0.0)
    for label in labels:
        a, b = cv.text('yellow' if label == active else 'gray', x, base, label, UI, size, UI_SEMI, tracking=m.tracking)
        if label == active:
            span = (a, b - m.tracking * size)
        x = b + m.tab_gap
    keycap(cv, x - m.e_back, base, m, keys[1])
    return rule_with_underline(cv, x0, x1, base, span, m)


def label_header(cv: Canvas, x0: float, x1: float, base: float, label: str, note: str, m: TabMetrics) -> float:
    """One active label on the left, a gray note on the right; returns the rule's y."""
    size = ui_size(m.cap)
    a, b = cv.text('yellow', x0, base, label, UI, size, UI_SEMI, tracking=m.tracking)
    cv.text('gray', x1, base, note, UI, size, UI_SEMI, tracking=m.tracking, anchor='right')
    return rule_with_underline(cv, x0, x1, base, (a + m.under_ext, b - m.tracking * size), m)


def chevron(cv: Canvas, ink: str, x: float, y: float, d: int, size: float = 4.6, w: float = 1.7) -> None:
    cv.polyline(ink, [(x - d * size * 0.55, y - size), (x + d * size * 0.55, y), (x - d * size * 0.55, y + size)], w)


def key_label(cv: Canvas, right: float, mid: float, text: str, cap: float, ink: str, pad_x: float, pad_y: float,
              radius: float, stroke: float, min_w: float = 0.0) -> float:
    """A keycap sized to its text (TAB, F1 ...) ending at `right`; returns its left edge."""
    size = ui_size(cap) * 0.78
    width = max(min_w, cv.measure(text, UI, size, UI_BOLD, tracking=0.04) + 2 * pad_x)
    left = right - width
    cv.rrect_outline(ink, left, mid - cap * 0.78 / 2 - pad_y, right, mid + cap * 0.78 / 2 + pad_y, radius, stroke)
    cv.text(ink, (left + right) / 2, mid + cap * 0.78 / 2, text, UI, size, UI_BOLD, tracking=0.04, anchor='center')
    return left


def checkbox(cv: Canvas, x: float, mid: float, side: float, stroke: float, checked: bool, ink: str) -> None:
    """A square box; checked boxes are filled with a knocked-out tick."""
    y0, y1 = mid - side / 2, mid + side / 2
    if checked:
        cv.rect(ink, x, y0, x + side, y1)
        tick = [(x + side * 0.22, mid + side * 0.02), (x + side * 0.42, mid + side * 0.22),
                (x + side * 0.78, mid - side * 0.2)]
        for (ax, ay), (bx, by) in zip(tick, tick[1:]):
            cv.line(ink, ax, ay, bx, by, side * 0.16, fill=0)
        cv.rect(ink, tick[1][0] - side * 0.08, tick[1][1] - side * 0.08, tick[1][0] + side * 0.08,
                tick[1][1] + side * 0.08, fill=0)
    else:
        cv.rect(ink, x, y0, x + side, y1)
        cv.rect(ink, x + stroke, y0 + stroke, x + side - stroke, y1 - stroke, fill=0)


# ------------------------------------------------------------------ formats

PITCH = 33                   # menu row pitch in the wide formats


@dataclass
class Menu:
    """Where a wide format puts the menu: content edges, the header's cap line, the first row's
    top (a row starts level with the title's bar) and the canvas bottom."""
    x0: float
    x1: float
    cap_top: float
    rows_top: float
    bottom: float
    fmt: str                    # 'nexus'
    title_bottom: float = 0.0   # bottom of the title's bar


@dataclass
class Row:
    """The cover's area for the mod's own graphic: a menu row under a centred title, or
    everything below a title set at the top margin (it may bleed off the right and bottom)."""
    x0: float
    x1: float
    top: float
    h: float


@dataclass
class Spec:
    wide: str                                        # cream line of the wide formats
    bar: str                                         # the word in the yellow bar
    square: list[str]                                # cream lines of the cover
    menu: Callable[[Canvas, Menu], None]             # the mod's graphic right of the title (wide formats)
    cover_row: Callable[[Canvas, Row], None]         # the mod's graphic on the cover
    cover_header: Callable[[Canvas, float, float, float], float] | None = None   # (cv, x0, x1, top) -> rule y
    caption: list[str] = field(default_factory=list)
    caption_line: int = 0                            # cover line the caption sits beside
    cover_layout: str = ''                           # 'center' (with a header), 'top' or 'bottom'; '' picks
    slash_line: int | None = None                    # cover cream line carrying the slashes; None: the bar
    menu_x0: float = 662                             # left edge of the menu content (wide formats)


def menu_panel(cv: Canvas, g: Menu, corner: float = 18) -> None:
    """The game-menu panel behind a wide format's menu: bleeds off the right and bottom, top left
    corner cut at the slashes' angle and marked yellow."""
    frame_x, top, right, bottom = g.x0 - 24, g.cap_top - 16, cv.width, g.bottom
    cv.poly('panel', [(frame_x + corner, top), (right, top), (right, bottom), (frame_x, bottom), (frame_x, top + corner)])
    cv.polyline('edge', [(frame_x, bottom), (frame_x, top + corner), (frame_x + corner, top), (right, top)], 1.2)
    cv.line('yellow', frame_x, top + corner, frame_x + corner, top, 2.2)


def _wide_title(cv: Canvas, spec: Spec, left: float, top: float, cap: float) -> float:
    """Cream line over the bar; returns the bar's top."""
    size = title_size(cap)
    b1 = top + cap
    cream_line(cv, left, b1, spec.wide, size)
    bar_top = b1 + 16
    inset = 17
    bar_r, bar_bot = menu_bar(cv, left, bar_top, cap, size, spec.bar, pad=14, right_pad=24, chamfer=24)
    slashes(cv, bar_r + 13, bar_top + inset, bar_bot - inset, bar_bot - bar_top - 2 * inset, 13, 10)
    return bar_top


def _finish(cv: Canvas, seed: int, light: tuple[float, float, float, float, float], ground_sigma: float,
            mottle_sigma: float, grain_sigma: float, mask_for: Callable[[str, np.ndarray], np.ndarray]):
    w, h = cv.size
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    ground = np.broadcast_to(hex_rgb(C['ground']), (h, w, 3)).copy()
    cx, cy, rx, ry, amp = light
    ground += (np.exp(-(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)) * amp)[..., None]
    ground += (noise((h, w), ground_sigma, rng, octaves=3) * 0.005)[..., None]
    mottle = noise((h, w), mottle_sigma, rng, octaves=2)
    layers = []
    for name, opacity in ORDER:
        colour = hex_rgb(C[name]) * (1 + 0.02 * mottle)[..., None]
        layers.append((mask_for(name, cv.final(name)), colour, opacity))
    out = compose(ground, layers)
    out += (grain((h, w), rng, grain_sigma) * 0.008)[..., None]
    return to_image(out)


def nexus(spec: Spec, path) -> None:
    W, H = 1300, 372
    cv = Canvas(W, H, ss=4)
    L, TOP, CH = 23, 40, 56
    bar_top = _wide_title(cv, spec, L, TOP, CH)
    x0, x1 = spec.menu_x0, W - L
    spec.menu(cv, Menu(x0, x1, TOP, bar_top - PITCH, H, 'nexus', bar_top + 84))   # header level with the title

    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    fade = np.clip(1 - (yy - 182) / 118, 0, 1) ** 1.25            # menu fades into Nexus's overlay zone
    in_menu = xx >= x0 - 30

    def mask_for(name, m):
        if name == 'panel':
            return m * np.clip(1 - (yy - 130) / 230, 0, 1)
        return np.where(in_menu, m * fade, m)

    _finish(cv, 11, (280, 110, 640, 300, 0.018), 48, 22, 0.5, mask_for).save(path, optimize=True)


def cover(spec: Spec, path) -> None:
    S, M = 1254, 88
    cv = Canvas(S, S, ss=3)
    layout = spec.cover_layout or ('top' if spec.cover_header is None else 'center')
    if layout == 'center':
        rule_y = spec.cover_header(cv, M, S - M, M)
        rule_w = COVER_TABS.rule_w

    cap_ratio = cap_height(font(TITLE, 1000)) / 1000
    over = 0.015                                                    # optical overshoot of round letters
    right_pad, lead, sw = 0.25, 0.17, 0.17                         # in capital heights
    widths = []
    for line in spec.square:
        l, r = ink_x(line, TITLE, 1.0)
        widths.append((r - l) / cap_ratio - ((line[0] in ROUND) + (line[-1] in ROUND)) * over)
    l, r = ink_x(spec.bar, TITLE, 1.0)
    bar_w = (r - l) / cap_ratio + right_pad
    if spec.slash_line is None:
        bar_w += lead + 3 * sw + 2 * 0.12 + 0.5 * 1.4                 # room for the slashes after the bar
    CH = min((S - 2 * M) / w for w in widths + [bar_w])
    size = CH / cap_ratio
    gap = round(0.2 * CH)
    pad = round(0.2 * CH)
    row_h = 62
    n = len(spec.square)
    block = (n + 1) * CH + n * gap + 2 * pad
    if layout == 'top':                                             # title on the top margin, graphic below
        b = M + CH
    elif layout == 'bottom':                                        # graphic above, bar ends on the margin
        b = S - M - block + CH
    else:                                                           # centred between header and row
        G = ((S - M - row_h) - (rule_y + rule_w) - block) / 2
        b = rule_y + rule_w + G + CH

    baselines, rights = [], []
    for i, line in enumerate(spec.square):
        if i:
            b = b + gap + CH
        rights.append(cream_line(cv, M, b, line, size, over * CH))
        baselines.append(b)
    bar_top = b + gap
    bar_r, bar_bot = menu_bar(cv, M, bar_top, CH, size, spec.bar, pad, right_pad * CH, chamfer_ratio=0.26,
                              optical=over * CH)
    sh = 0.5 * (bar_bot - bar_top)
    slash_w = sw * CH
    if spec.slash_line is None:                                     # after the bar, last one on the margin
        x = bar_r + lead * CH
        sgap = ((S - M) - x - 3 * slash_w - sh) / 2
        sgap = min(sgap, 1.4 * slash_w)                             # never wider than the motif's spacing
        y0, y1 = (bar_top + bar_bot) / 2 - sh / 2, (bar_top + bar_bot) / 2 + sh / 2
    else:                                                           # after a short cream line
        x = rights[spec.slash_line] + lead * CH
        sgap = 0.12 * CH
        mid = baselines[spec.slash_line] - CH / 2
        y0, y1 = mid - sh / 2, mid + sh / 2
    slashes(cv, x, y0, y1, sh, slash_w, sgap)

    cap_c = 22
    size_c = ui_size(cap_c)
    for i, line in enumerate(spec.caption):                         # right aligned, first cap line level
        cv.text('gray', S - M, baselines[spec.caption_line] - CH + cap_c + i * 40, line, UI, size_c, UI_SEMI,
                tracking=0.08, anchor='right')

    if layout == 'top':
        below = bar_bot + 0.55 * CH
        spec.cover_row(cv, Row(M, S - M, below, S - below))
    elif layout == 'bottom':
        spec.cover_row(cv, Row(M, S - M, 0, S - M - block - 0.55 * CH))
    else:
        spec.cover_row(cv, Row(M, S - M, S - M - row_h, row_h))
    _finish(cv, 5, (420, 520, 900, 800, 0.02), 90, 40, 0.6, lambda name, m: m).save(path, optimize=True)

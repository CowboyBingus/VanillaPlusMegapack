"""Vanilla Plus Megapack box icon (the square cover, 1254x1254), the pack's own image in Arsenal and HD2MM.

    python pack_cover.py [folder]     (default: the assets folder above this one)

A packing slip under a yellow and black hazard band lists the bundled mods, each one ticked. It
carries no counts or versions and the list runs off the edge, so the art stays true as the pack
changes. The wide formats' slip (menu) is kept for the shared Spec; the banner is not redrawn."""
import sys
from pathlib import Path

import style
from style import UI, UI_BOLD, UI_SEMI, Menu, Row, Spec, ui_size

MODS = ['BETTER STRATAGEM BOUNCE', 'HELLPOD STEERING UNLOCKED', 'REINFORCEMENT BEACONS FIXED', 'CONSISTENT VAULTING',
        'SHALLOW WATER DIVING', 'SENTRY AIM RETENTION', 'ENEMY COLLISION SYNCHRONIZED', 'CONTROLLABLE HOVER PACK',
        'KNOW YOUR CONSTELLATION', 'ARMORY PREVIEW CACHE', 'ARC THROWER REVAMPED', 'CLICKABLE SCROLLBARS',
        'SHIP STATION HOTKEYS']


def hazard_band(cv, x0, y0, x1, h, stripe):
    """Yellow band with dark stripes at the slashes' angle."""
    cv.rect('yellow', x0, y0, x1, y0 + h)
    x = x0 - h
    while x < x1:
        cv.poly('yellow', [(x + h, y0), (x + h + stripe, y0), (x + stripe, y0 + h), (x, y0 + h)], fill=0)
        x += 2 * stripe


def slip(cv, paper_x0, y0, left, right, u, rows, cut_row=None):
    """The slip's paper runs from (paper_x0, y0) off the right and bottom edges; its text sits
    between `left` and `right`. Two columns, filled row by row; u scales the type. With cut_row
    the rows are spaced so that row is cut in half by the bottom edge."""
    hazard_band(cv, paper_x0, y0, cv.width, 16 * u, 8 * u)
    top = y0 + 16 * u
    cv.rect('paper', paper_x0, top, cv.width, cv.height)
    head_cap = 12 * u
    base = top + 14 * u + head_cap
    cv.text('paper', left, base, 'CONTENTS', UI, ui_size(head_cap), UI_BOLD, tracking=0.14, fill=0)
    cv.text('paper', right, base, 'ENABLE ANY', UI, ui_size(head_cap * 0.8), UI_SEMI, tracking=0.12, anchor='right',
            fill=0)
    rule = base + 11 * u
    cv.rect('paper', left, rule, right, rule + 1.4 * u, fill=0)
    cap, pitch, box = 10.5 * u, 30 * u, 12 * u
    first = rule + 20 * u
    if cut_row is not None:
        pitch = (cv.height - first) / cut_row
    col_w = (right - left) / 2
    for i, name in enumerate(MODS[:2 * rows]):
        row, col = divmod(i, 2)
        x = left + col * col_w
        mid = first + row * pitch
        width = cv.measure(name, UI, ui_size(cap), UI_SEMI, tracking=0.05)
        assert box + 10 * u + width < col_w - 8 * u, name + ' overlaps the next column'
        cv.rect('paper', x, mid - box / 2, x + box, mid + box / 2, fill=0)           # printed box
        tick = [(x + box * 0.2, mid + box * 0.02), (x + box * 0.42, mid + box * 0.24), (x + box * 0.82, mid - box * 0.26)]
        for (ax, ay), (bx, by) in zip(tick, tick[1:]):
            cv.line('paper', ax, ay, bx, by, box * 0.17)                           # paper-coloured tick
        cv.text('paper', x + box + 10 * u, mid + cap / 2, name, UI, ui_size(cap), UI_SEMI, tracking=0.05, fill=0)


def menu(cv, g: Menu) -> None:
    slip(cv, g.x0 - 24, g.cap_top - 16, g.x0, g.x1, 1.0, rows=7)


def cover_row(cv, r: Row) -> None:
    slip(cv, 0, r.top, r.x0, r.x1, 2.05, rows=6, cut_row=5)         # the sixth row runs off the edge


SPEC = Spec(wide='VANILLA PLUS', bar='MEGAPACK', square=['VANILLA', 'PLUS'], menu=menu, cover_row=cover_row,
            caption=['ONE INSTALL', 'PICK YOUR MODS'], caption_line=0, slash_line=1, menu_x0=690)

if __name__ == '__main__':
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    style.cover(SPEC, out / 'thumbnail.png')
    print(out / 'thumbnail.png')

"""Small vector renderer for the mod artwork: shapes and type are drawn as ink masks at a
multiple of the output size, reduced to it, then composited over a dark ground with a soft
light, faint mottling and fine grain."""
from __future__ import annotations

import os
from dataclasses import dataclass, field

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter

FONTS = os.path.join(os.environ['WINDIR'], 'Fonts')


def hex_rgb(value: str) -> np.ndarray:
    value = value.lstrip('#')
    return np.array([int(value[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255.0


def font(name: str, size: float, axes: tuple[int, int] | None = None) -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(os.path.join(FONTS, name), round(size), layout_engine=ImageFont.Layout.RAQM)
    if axes is not None:
        face.set_variation_by_axes(list(axes))  # (weight, width) for Bahnschrift
    return face


def cap_height(face: ImageFont.FreeTypeFont) -> float:
    return -face.getbbox('H', anchor='ls')[1]


_INK_CACHE: dict = {}


def ink_x(s: str, face_name: str, size: float, axes=None) -> tuple[float, float]:
    """Left and right ink edges of s relative to the pen origin, in px at `size`.
    Measured from a 1000 px render because getbbox reports the advance box."""
    key = (s, face_name, axes)
    if key not in _INK_CACHE:
        face = font(face_name, 1000, axes)
        width = int(face.getlength(s)) + 2000
        im = Image.new('L', (width, 1800), 0)
        ImageDraw.Draw(im).text((1000, 1300), s, font=face, fill=255, anchor='ls')
        cols = np.where(np.asarray(im).max(0) > 127)[0]
        _INK_CACHE[key] = ((cols[0] - 1000) / 1000.0, (cols[-1] + 1 - 1000) / 1000.0)
    left, right = _INK_CACHE[key]
    return left * size, right * size


@dataclass
class Canvas:
    """Ink masks at ss times the layout size; geometry is given in layout units. `out` is the
    output size in pixels when it is not the layout size (the masks are then box-filtered)."""
    width: int
    height: int
    ss: int = 4
    out: tuple[int, int] | None = None
    inks: dict[str, Image.Image] = field(default_factory=dict)

    @property
    def size(self) -> tuple[int, int]:
        return self.out or (self.width, self.height)

    def mask(self, ink: str) -> ImageDraw.ImageDraw:
        if ink not in self.inks:
            self.inks[ink] = Image.new('L', (self.width * self.ss, self.height * self.ss), 0)
        return ImageDraw.Draw(self.inks[ink])

    def poly(self, ink: str, pts, fill: int = 255) -> None:
        self.mask(ink).polygon([(x * self.ss, y * self.ss) for x, y in pts], fill=fill)

    def rect(self, ink: str, x0, y0, x1, y1, fill: int = 255) -> None:
        self.poly(ink, [(x0, y0), (x1, y0), (x1, y1), (x0, y1)], fill)

    def circle(self, ink: str, cx, cy, r, fill: int = 255) -> None:
        s = self.ss
        self.mask(ink).ellipse(((cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s), fill=fill)

    def ring(self, ink: str, cx, cy, r, w) -> None:
        s = self.ss
        self.mask(ink).ellipse(((cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s), outline=255, width=round(w * s))

    def rrect(self, ink: str, x0, y0, x1, y1, r, fill: int = 255) -> None:
        s = self.ss
        self.mask(ink).rounded_rectangle((x0 * s, y0 * s, x1 * s - 1, y1 * s - 1), radius=r * s, fill=fill)

    def rrect_outline(self, ink: str, x0, y0, x1, y1, r, w) -> None:
        s = self.ss
        self.mask(ink).rounded_rectangle((x0 * s, y0 * s, x1 * s - 1, y1 * s - 1), radius=r * s, outline=255,
                                         width=round(w * s))

    def line(self, ink: str, x0, y0, x1, y1, w, fill: int = 255) -> None:
        """Butt-capped stroke of width w."""
        dx, dy = x1 - x0, y1 - y0
        length = float(np.hypot(dx, dy))
        nx, ny = -dy / length * w / 2, dx / length * w / 2
        self.poly(ink, [(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], fill)

    def polyline(self, ink: str, pts, w) -> None:
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            self.line(ink, x0, y0, x1, y1, w)
        for x, y in pts[1:-1]:
            self.rect(ink, x - w / 2, y - w / 2, x + w / 2, y + w / 2)

    def text(self, ink: str, x: float, baseline: float, s: str, face_name: str, size: float,
             axes=None, tracking: float = 0.0, anchor: str = 'left', fill: int = 255) -> tuple[float, float]:
        """Draws s on `baseline` with kerning plus `tracking` (em) between glyphs.
        Returns the left and right of the advance box in layout units."""
        face = font(face_name, size * self.ss, axes)
        adv = self.advances(s, face, tracking * size * self.ss)
        start = x * self.ss - {'left': 0.0, 'center': adv[-1] / 2, 'right': adv[-1]}[anchor]
        d = self.mask(ink)
        for i, ch in enumerate(s):
            if ch != ' ':
                d.text((start + adv[i], baseline * self.ss), ch, font=face, fill=fill, anchor='ls')
        return start / self.ss, (start + adv[-1]) / self.ss

    def measure(self, s: str, face_name: str, size: float, axes=None, tracking: float = 0.0) -> float:
        face = font(face_name, size * self.ss, axes)
        return self.advances(s, face, tracking * size * self.ss)[-1] / self.ss

    @staticmethod
    def advances(s: str, face, tracking_px: float) -> list[float]:
        pos = [0.0]
        for i, ch in enumerate(s):
            step = face.getlength(ch)
            if i + 1 < len(s):
                kern = face.getlength(s[i:i + 2], features=['kern']) - face.getlength(ch) - face.getlength(s[i + 1])
                step += kern + tracking_px
            pos.append(pos[-1] + step)
        return pos

    def final(self, ink: str) -> np.ndarray:
        w, h = self.size
        img = self.inks.get(ink)
        if img is None:
            return np.zeros((h, w), np.float32)
        img = img.reduce(self.ss) if self.out is None else img.resize(self.out, Image.BOX)
        return np.asarray(img, dtype=np.float32) / 255.0


def noise(shape, sigma, rng, octaves=1) -> np.ndarray:
    """Smooth zero-mean noise with unit standard deviation."""
    out = np.zeros(shape, np.float32)
    amp = 1.0
    for o in range(octaves):
        n = gaussian_filter(rng.standard_normal(shape).astype(np.float32), sigma / (2 ** o))
        out += amp * n / (n.std() + 1e-8)
        amp *= 0.5
    return out / (out.std() + 1e-8)


def grain(shape, rng, sigma=0.5) -> np.ndarray:
    g = gaussian_filter(rng.standard_normal(shape).astype(np.float32), sigma)
    return g / g.std()


def compose(ground: np.ndarray, layers) -> np.ndarray:
    """ground: HxWx3; layers: (mask HxW, colour, opacity), painted in order."""
    out = ground.copy()
    for mask, colour, opacity in layers:
        a = (mask * opacity)[..., None]
        out = out * (1 - a) + colour * a
    return out


def to_image(rgb: np.ndarray) -> Image.Image:
    return Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8), 'RGB')

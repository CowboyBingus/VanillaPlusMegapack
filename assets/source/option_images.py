"""Each Megapack option's image as the pack ships it: its cover at 512 px, a JPEG in assets/options/<Slug>.jpg.

    python option_images.py [--reused <folder>]

The twenty covers drawn in covers.py are rendered at 1254 px first. Mod Options Menu, Mod Bindings Menu, Sound
Systems Rebalanced and Foliage Pass-Through show their own repositories' covers (assets/thumbnail.png there);
--reused names a folder holding those as <Slug>.png to remake their JPEGs the same way. Without it their
committed JPEGs stay as they are."""
import sys
import tempfile
from pathlib import Path

from PIL import Image

import covers
import style

SIZE, QUALITY = 512, 92
OUT = Path(__file__).resolve().parents[1] / 'options'


def shrink(source: Path, target: Path) -> None:
    """Full-colour JPEG (no chroma subsampling, no metadata), so thin lines and small text stay clean."""
    image = Image.open(source).convert('RGB').resize((SIZE, SIZE), Image.LANCZOS)
    image.save(target, 'JPEG', quality=QUALITY, optimize=True, subsampling=0)


def main(argv: list[str]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as folder:
        for slug, spec in covers.COVERS.items():
            full = Path(folder) / (slug + '.png')
            style.cover(spec, full)
            shrink(full, OUT / (slug + '.jpg'))
            print(slug)
    if argv[:1] == ['--reused']:
        for source in sorted(Path(argv[1]).glob('*.png')):
            shrink(source, OUT / (source.stem + '.jpg'))
            print(source.stem, '(reused)')


if __name__ == '__main__':
    main(sys.argv[1:])

# Artwork

Files: [wide banner](banner.png), 2172x724 PNG, [square Arsenal box-icon](thumbnail.png), 1254x1254 PNG, and one [cover per option](options/), 512x512 JPEG.

## Option covers

Each option shows its own mod's cover beside it in Arsenal and HD2MM: `options/<Slug>.jpg`, packaged as `images/<Slug>.jpg` (the manifest's option `Image`), outside every option folder so no manager deploys it.

Drawn in code with Claude Opus 5.5 (Pillow and NumPy); no image generator was used. Same system as the Bingus Shared Loader, Mod Options Menu and Mod Bindings Menu art: Franklin Gothic Heavy for the title, Bahnschrift SemiBold (width 87) for everything else, ground `#121110`, cream `#f0e8d6`, yellow `#fdd00c`. Each cover's graphic shows what its mod does, in plain words, with no counts or versions.

- `source/covers.py` draws twenty of them (`artlib.py` and `style.py` are byte-identical copies of the shared renderer). `cd source; python option_images.py` renders them at 1254x1254 and writes their JPEGs (full color, quality 92, no metadata).
- Mod Options Menu, Mod Bindings Menu and Sound Systems Rebalanced show their own code-drawn covers, made earlier with the same renderer, shrunk the same way (`python option_images.py --reused <folder of Slug.png>`).

## Banner and box-icon

Generated as two separate assets with the built-in image-generation tool, using Bingus Shared Loader's corresponding artwork as style references. The direction is pure typography on charcoal distressed texture, cream and military yellow, clipped/angular border rules and three hazard slashes. No scenery or literal box illustration. Text and composition were visually checked. The square image is packaged as `thumbnail.png` and referenced by Arsenal's `IconPath`.

## Banner prompt

Use case: style-transfer. Create a new finished wide 3:1 banner for Vanilla Plus Megapack, using the provided Bingus Shared Loader banner as the visual family reference. Pure typography on flat charcoal distressed graphic texture. enormous condensed cream and military yellow block type, fine clipped/angular yellow border rules and three yellow hazard slashes. Exact main title in two centered lines: 'Vanilla Plus' in cream above 'Megapack' in vivid yellow. Keep all letters comfortably inside the frame with generous margins, balanced spacing and strong readability. Exact small cream footer: 'AI-assisted development with GPT-6 Astra'. No other text. No scenery, equipment, characters, icons, 3D objects, badges or landscape. Same artistic direction as the reference, with an intentional original composition sized for this title. Finished wide 3:1 PNG banner, ideally 2172x724.

## Square icon prompt

Use case: style-transfer. Create a finished square Arsenal mod box-icon for Vanilla Plus Megapack, using the attached Bingus Shared Loader square as the artistic direction reference. Pure typography on a flat charcoal distressed/crosshatched graphic texture. Enormous condensed bold block text, worn cream and vivid military yellow, fine yellow clipped-corner border and three yellow hazard slashes. Exact centered title on three lines: 'VANILLA' cream, 'PLUS' cream, 'MEGAPACK' yellow. Fit the full word MEGAPACK inside the border, adjusting its condensed width and type size to maintain margins and readability as a small square icon. Balance all three lines to fill the square attractively. Exact small cream footer: 'AI-assisted development with GPT-6 Astra'. No additional text. No scenery, characters, equipment, literal boxes, icons, 3D objects, or illustrations. Finished square PNG, ideally 1254x1254.

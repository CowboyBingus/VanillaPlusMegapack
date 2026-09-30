# Translating CowboyBingus mods

Every CowboyBingus mod that shows text in the game can be translated without touching its code.
The same files and the same tool work for all of them:

| Mod | Its texts |
| --- | --- |
| Know Your Constellation | the forecast panel: captions, constellation names, enemy names |
| Mod Options Menu | the MODS tab and its empty-state line |
| Mod Bindings Menu | the MODS tab, its empty-state line and default section name |
| Better Lobby Management | escape-menu buttons, confirm dialogs, its Mod Options Menu entries, the DISBAND chat line |
| Ship Station Hotkeys | its section name and two binding names in Mod Bindings Menu |
| Shallow Water Diving | its Mod Options Menu slider |

Words the game already has (ON, OFF, the GALACTIC MAP, ARMORY and HELLPOD bindings, CONFIRM,
CANCEL) are shown in the game's own translation and are not in these files.

## How the mods pick a language

The mods follow the game's own Text Language setting (Options). If a mod cannot read it, it uses
Steam's language for the game. Texts without a translation show in English. Nothing needs to be
set up by players: installing a translation is enough.

Language tags: `zh-Hans` (Simplified Chinese), `zh-Hant` (Traditional Chinese), `ko`, `ja`, `ru`,
`pl`, `fr`, `de`, `it`, `es` (Spain), `es-419` (Latin America), `pt-BR`. A regional tag also uses
its base language: `es-419` falls back to `es`, then English.

## The files

Each mod keeps its texts in `locales/`. `en.lua` is the English source:

```lua
return {
    mod = 'know_your_constellation',
    language = 'en',
    strings = {
        -- Ends a list that had to be cut to fit the screen. {count} is the number of
        -- enemies left out (1 or more).
        ['panel.more'] = 'and {count} more',
    },
}
```

A translation is the same file with your language tag and your texts, for example
`locales/zh-Hans.lua` with `language = 'zh-Hans'`. Rules:

- Translate only the text on the right of `=`. Keep the key in `['...']` exactly.
- Keep every `{placeholder}` (you may move it). The mod fills it in, for example with a number.
- Write the text as you want it shown, in UTF-8. Upper case is up to you: the menus upper-case
  some names for you, and that works for accented, Greek and Cyrillic letters too.
- Inside `'...'` write `\'` for a quote and `\\` for a backslash. No line breaks.
- The comment above a key says where the text shows. Keys you leave out show in English.
- Some keys have a length limit in characters (listed under `limits` in `en.lua`). The mods
  count characters, not bytes, so a Chinese character counts as one.
- Avoid `<` with a letter after it and `#` followed by capitals: the game may read them as its own
  text markup.

A translation file contains only data. Code in it is refused by the tool and by the mods' builds.

## The tool

`scripts/translations.py` (Python 3.9 or newer, in every mod repository above, with its helper
`scripts/luatable.py`) works on a kit: a folder with one subfolder per mod, each holding that mod's
`en.lua` and translations. A mod repository (or its `locales/` folder) is a kit of one mod. To
translate several mods at once, collect their `locales/` folders into one kit:

```
python scripts/translations.py kit my-kit <repo>/locales <other repo>/locales
```

The Vanilla Plus Megapack repository has the same tool, and its `components` folder is already a
kit of every mod above: run the commands below in it with `components` as the kit. A pack built
there covers all six mods, standalone or in the Megapack.

```
python scripts/translations.py template <kit> zh-Hans
```

creates `zh-Hans.lua` for every mod, or updates it after a mod update. Every English text is
listed. Untranslated ones are commented out: remove the `-- ` in front of a line and translate it.
Your existing translations are kept. The `-- English:` line above each entry records the English
text you translated.

```
python scripts/translations.py check <kit> zh-Hans
```

reports errors (the mod would ignore that text: wrong placeholders, over a limit, control
characters, invalid UTF-8, unknown keys) and warnings (the English changed since you translated it,
text probably wider than its space, markup-like characters). It ends with how many texts of each
mod are translated.

## Sharing a translation

Two ways, and you can do both:

1. **Bundled with the mod.** Send your `<tag>.lua` files (a pull request on the mod's GitHub, or
   an issue with the files attached). They ship in the mod's next release and in the Megapack
   release after it.
2. **Your own translation pack.** Build it and publish it yourself, for example on Nexus Mods:

   ```
   python scripts/translations.py pack <kit> zh-Hans --name "Chinese translation" --author "Your name"
   ```

   This makes `Translation-zh-Hans.zip`, installable with Arsenal or HD2MM like any mod. Players
   need Bingus Shared Loader v18 and the mods themselves. The pack keeps the same identity
   (GUID) for every rebuild with the same tag and author, so mod managers treat a new build as an
   update. A pack overrides bundled texts. If two packs translate the same text, the one loaded
   later wins.

   `--force` makes the mods show your language even when the game's Text Language is another one.
   Use it only for a pack that asks for that on purpose: Know Your Constellation draws with the
   game's font for its current language, which may not have every script.

## Testing in the game

1. Install your pack (or the mod build with your files) and Bingus Shared Loader.
2. Set the game's Text Language to your language.
3. Look at the mod's log in `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs`. It records the
   language it chose ("text language: zh-Hans (game setting ...)"), how many texts are
   translated, and every text it refused and why. A refused text shows in English.

Know Your Constellation fits any length: it wraps lines (between characters for Chinese and
Japanese) and shrinks its font before it cuts a list. Menu texts are drawn by the game. Keep
button labels and option names about as long as the English ones.

To check layouts without a translation, build a pseudo pack. It shows every text accented,
bracketed and 40% longer, so cut or untranslated text stands out:

```
python scripts/translations.py pack <kit> pseudo --name "Layout test" --force
```

After you change the game's Text Language, Know Your Constellation follows at once, the escape menu
and binding pages the next time you open them. With Mod Options Menu v1.0 or Mod Bindings Menu
v2.0, the texts other mods register there stay in the language the game started with.

/* Better Lobby Management v1.2.1's code signatures, generated from the Lua sources (game.lua, menu.lua, sos.lua,
 * chat.lua, region.lua, scanner.lua in the Megapack v42) for build 25480438: each record's bytes as an IDA-style
 * pattern, in the Lua's order. The one wildcard: the stratagem list's displacement in "stratagem uses" (blm_sos.c). */
#include "blm_code.h"

/* game.lua G.CODE: the game.dll code that fixes the offsets of the network context */
const BlmCode blm_game_code[] = {
    {0x13F7858u, "network components",
        "49 8D 9F D0 1C C9 01 48 8D 8B 00 B4 00 00 E8 95 81 EF FF 48 8D 8B B0 59 01 00 E8 C9 2B C9 FF 48 8D 8B C8 62 01 00 E8 CD "
        "B8 C8 FF 48 8D 8B 70 D4 01 00 E8 11 BF C9 FF 48 8D 8B C8 71 01 00"},
    {0x10834EDu, "host-left check",
        "83 B9 1C C2 0A 00 03 0F 85 C7 00 00 00 E8 D1 C3 2C 00 48 8B 15 EA 99 3F 02 84 DB 41 B9 07 00 00 00 41 BE 04 00 00 00 45 "
        "0F 45 CE 33 F6 8B 82 38 F8 01 00 48 8B 8A A8 B3 00 00"},
    {0x134FA90u, "peer list",
        "48 89 5C 24 10 56 48 83 EC 20 33 DB 48 8B F1 39 99 90 63 01 00 76 77 48 89 7C 24 30 0F 1F 40 00 8B C3 48 C1 E0 05 48 8B "
        "BC 30 98 63 01 00 48 3B"},
    {0x1337DCCu, "quickplay request", "8B 9E 8C 06 00 00 4C 8D 86 88 06 00 00"},
    {0x133812Au, "scanner request", "8B 9E E4 56 00 00 4C 8D 86 E0 56 00 00"},
    {0x133D460u, "lobby browser", "40 53 48 83 EC 40 48 8B 0D 83 FA 13 02 48 8B DA 48 81 C1 28 F0 01 00 E8"},
    {0x1082FE3u, "party join flag", "48 8D 83 30 0D 00 00 C6 83 21 05 00 00 01"},
};
const int blm_game_code_count = (int)(sizeof blm_game_code / sizeof blm_game_code[0]);

/* game.lua G.EXE_CODE: helldivers2.exe's PlayfabLobby layout */
const BlmCode blm_exe_code[] = {
    {0x8CDF90u, "PlayFab lobby layout",
        "48 8B 46 18 8B CF 48 8B 0C C8 48 8B 59 10 48 63 83 18 01 00 00 83 F8 03 0F 85 51 01 00 00 49 8B D6 48 8D 0D D8 AD DD 00 "
        "E8 23 37 CF FF 48 8B 8B 20 01 00 00 48 8D 94 24 D0 00 00 00 4C 89 BC 24 D0 00 00 00"},
    {0x8CE012u, "PlayFab lobby members", "8B 8B 00 01 00 00 48 8B 93 40 01 00 00"},
};
const int blm_exe_code_count = (int)(sizeof blm_exe_code / sizeof blm_exe_code[0]);

/* game.lua G.NATIVES: the start of each native the mod may call */
const BlmCode blm_game_natives[] = {
    {0x108D130u, "kick_peer", "48 89 5C 24 08 57 48 83 EC 20 48 8B DA 48 8B F9 4C 8B C2 48 8D 0D 2E 63 1D 01"},
    {0x108FF40u, "start_join", "48 89 5C 24 20 56 57 41 56 48 81 EC 70 01 00 00 48 8B 05 B9 C0 5A 01"},
    {0x1094DF0u, "filter_string", "40 55 56 57 48 83 EC 50 48 8B 05 11 72 5A 01 48 33 C4 48 89 44 24 30"},
    {0x1094710u, "browser_start", "4C 8B 11 4D 85 D2 74 64 48 8B 05 21 27 29 02 80 78 09 00 74 1C"},
    {0x1094780u, "browser_busy", "48 83 EC 28 4C 8B 01 4D 85 C0 75 07 32 C0 48 83 C4 28 C3 48 8B 05 A6 26 29 02"},
    {0x1094820u, "browser_count", "4C 8B 01 4D 85 C0 75 03 33 C0 C3 48 8B 05 0E 26 29 02 80 78 09 00"},
    {0x1094890u, "browser_result", "40 55 56 57 41 57 48 81 EC 38 02 00 00 48 8B 05 6C 77 5A 01"},
    {0xBF3950u, "send_kick", "48 8B D1 45 33 C9 B9 2D 37 86 F7 45 33 C0 E9 CD AA FE FF"},
    {0x13EFEA0u, "is_friend", "48 83 EC 58 48 8B 05 9D 64 F3 01 4C 8B C2 80 78 28 00 74 38"},
};
const int blm_game_natives_count = (int)(sizeof blm_game_natives / sizeof blm_game_natives[0]);

/* game.lua G.ENGINE_SLOTS: engine lobby API slots, checked through the pointer the table holds */
const BlmCode blm_engine_slots[] = {
    {0x198u, "clear_filters", "33 C0 89 81 B4 00 00 00 89 81 B8 25 00 00 C3"},
    {0x40u, "continent", "48 8B 05 A1 84 A9 01 48 8B 88 D0 05 00 00 33 C0 48 8B 89 A0 00 00 00 48 85 C9 74 0A 48 83 C1 44 38 01 48 0F 45 C1 C3"},
};
const int blm_engine_slots_count = (int)(sizeof blm_engine_slots / sizeof blm_engine_slots[0]);

/* game.lua G.PACKAGE_SLOTS: the engine package API's unload pause */
const BlmCode blm_package_slots[] = {
    {0x348u, "unload_paused", "48 8B 05 D1 EA 6E 01 48 8B 88 00 04 00 00 0F B6 81 24 32 00 00 C3"},
    {0x350u, "pause_unloads", "48 8B 05 B1 EA 6E 01 85 C9 0F 95 C2 48 8B 88 00 04 00 00 88 91 24 32 00 00 C3"},
};
const int blm_package_slots_count = (int)(sizeof blm_package_slots / sizeof blm_package_slots[0]);

/* menu.lua M.NATIVES: the escape menu's natives */
const BlmCode blm_menu_natives[] = {
    {0x144C5C0u, "add_child", "40 53 48 83 EC 20 4C 8B CA 48 8B D9 48 8B 91 E0"},
    {0x143BF90u, "set_label", "48 83 EC 28 4C 8B D9 39 91 10 01 00 00 0F 84 80"},
    {0x1441720u, "set_label_wrapped", "48 83 EC 28 4C 8B D9 39 91 10 01 00 00 0F 84 80 00 00 00 89 91 10 01 00 00 48 8B 91 70 02 00 00"},
    {0x143C950u, "set_string_arg", "40 53 48 83 EC 20 48 8B D9 48 81 C1 10 01 00 00"},
    {0x143A0F0u, "clear_args", "80 B9 58 01 00 00 00 C6 81 58 01 00 00 00 0F 97"},
    {0x144E1A0u, "measure_text", "40 53 48 83 EC 70 48 8B D9 8B 09 8B C1 C1 E8 12"},
    {0x14508E0u, "set_enabled", "48 83 EC 28 44 8B 01 4C 8B D1 41 8B C0 45 8B C8"},
    {0x179FDF0u, "dialog_setup", "40 55 56 57 48 8B EC 48 83 EC 50 83 B9 AC 4B 00 00 00"},
    {0x18FBF50u, "rebuild", "48 89 5C 24 10 56 48 83 EC 20 32 DB 48 8B F1 38 99 D8 4F 1B 00"},
    {0x143C400u, "set_marquee", "48 83 EC 28 80 89 A0 02 00 00 20 4C 8B C9 F3 0F 11 89 8C 02 00 00"},
    {0x18FB240u, "focus", "48 89 5C 24 10 57 48 83 EC 20 0F B6 81 50 0F 1E 00 48 8B F9 0F B6 DA 3A"},
    {0x18F7E00u, "card_state", "48 89 5C 24 20 55 48 8B EC 48 83 EC 40 48 8B 05 FC 41 D4 00 48 33 C4 48"},
};
const int blm_menu_natives_count = (int)(sizeof blm_menu_natives / sizeof blm_menu_natives[0]);

/* menu.lua M.CODE: the code that fixes the GAME tab's layout */
const BlmCode blm_menu_code[] = {
    {0x147476Eu, "GAME tab dispatch", "48 8D 8F 88 4B 04 00 E8 56 5E 48 00"},
    {0x18FAD76u, "GAME tab select", "83 FA 04 0F 82 A2 02 00 00 8D 42 FC 48 89 BC 24 A0 00 00 00 0F B6 BC 08 D9 4F 1B 00 8B D0 4C 69 C2 48 3A 00 00"},
    {0x18FADE7u, "GAME tab select types", "8B CF 40 84 FF 74 73 83 E9 01 74 47 83 E9 01 74 35 83 E9 01 74 23 83 F9 01"},
    {0x18FAE6Cu, "GAME tab dialog", "C6 44 24 30 00 48 8D 8B 70 10 1E 00 C6 44 24 28 01 41 B9 08 76 4B D9 C7 44 24 20 0A D4 36 8A E8 60 4F EA FF"},
    {0x18FAC55u, "GAME tab dialog result",
        "44 38 B3 13 5C 1E 00 0F 84 AB 00 00 00 0F B6 83 50 0F 1E 00 2C 04 3A 83 D8 4F 1B 00 0F 83 96 00 00 00 0F B6 C0 0F B6 8C "
        "18 D9 4F 1B 00 85 C9 74 71 83 E9 02 74 62 83 E9 01 74 15 83 F9 01 75 78"},
    {0x18FB4BEu, "GAME tab buttons",
        "C7 44 24 20 06 CF D7 42 C7 44 24 24 7B 94 E0 65 48 8D A9 D9 4F 1B 00 C7 44 24 28 E7 C7 1E 80 48 8D B1 F8 30 1A 00 C7 44 "
        "24 2C 63 F8 6F 1F 33 DB C7 44 24 30 48 41 93 CC"},
    {0x18FB500u, "GAME tab attach",
        "0F B6 87 D8 4F 1B 00 3B D8 0F 8D 98 00 00 00 48 63 C3 48 8D 97 70 29 1A 00 48 69 C8 48 3A 00 00 48 03 D1 48 8D 8F 60 28 "
        "1A 00 E8 91 10 B5 FF"},
    {0x18FA613u, "GAME tab dialog gate", "80 B9 B0 5C 1E 00 00 0F 85 06 07 00 00 49 89 7B 18 48 81 C1 70 10 1E 00 4D 89 73 20 45 32 F6 44 38 B3 10 5C 1E 00"},
    {0x18FA5F0u, "GAME tab fade gate", "F3 0F 10 81 B4 5C 1E 00 0F 57 F6 0F 2E C6 4D 8B E1 4C 8B FA 48 8B D9 0F 8A 19 07 00 00 0F 85 13 07 00 00"},
    {0x18FA64Cu, "GAME tab panel gate", "83 BB BC F6 1B 00 02 74 5D"},
    {0x18FA6B2u, "GAME tab player menu",
        "0F B6 83 50 0F 1E 00 3C 04 0F 83 F9 00 00 00 48 69 C8 30 4E 01 00 83 BC 19 98 39 16 00 02 0F 85 E4 00 00 00 48 81 C1 90 "
        "EB 14 00 4D 8B C4 48 03 CB E8 18 C9 FF FF"},
    {0x18F78B9u, "player menu kick hold", "F3 0F 58 86 10 4E 01 00"},
    {0x18F7992u, "player menu kick",
        "48 8B 9E 00 4E 01 00 48 8D 15 00 C3 96 00 48 8B 3D 49 55 B8 01 48 8D 0D CA BA 96 00 4C 8B C3 E8 4A 09 E4 FF 45 33 C9 45 "
        "33 C0 48 8B D3 B9 2D 37 86 F7 E8 67 6A 2E FF 45 33 C9 48 8D 8F B0 59 01 00 48 8B D3 45 8D 41 01 E8 B1 57 79 FF"},
    {0x18FA514u, "escape menu close", "48 8B 1D 0D 29 B8 01 4C 8D 05 5A F8 9C 00 45 33"},
    {0x18FA53Fu, "escape menu pending close", "48 8B 83 88 43 00 00 48 85 C0 74 10 C6 40 10 01"},
};
const int blm_menu_code_count = (int)(sizeof blm_menu_code / sizeof blm_menu_code[0]);

/* sos.lua B.CODE: the code that fixes the SOS system's layout */
const BlmCode blm_sos_code[] = {
    {0x67A9A0u, "SOS activate",
        "48 89 5C 24 08 57 48 83 EC 20 48 8B 1D 3F 25 E0 02 48 8B F9 48 8B 83 A8 B3 00 00 48 85 C0 74 18 48 3B 83 98 B3 00 00 74 "
        "0F C6 41 08 01 48 8B 5C 24 30 48 83 C4 20 5F C3 BA 08 00 00 00 48 8D 8B 70 D4 01 00 44 8D 42 F9 E8 E3 7B A1 00 45 33 C0 "
        "48 8B CB 41 8D 50 13 E8 A4 52 CD 00 48 8B 05 45 B9 CA 02 48 8B 5C 24 30 48 8B 48 10 48 89 0F C6 47 08 01 48 83 C4 20 5F "
        "C3"},
    {0x517FD0u, "SOS activation event", "80 3A 00 74 22 48 8B 0D 14 EC E0 02 48 8B 05 0D 4F F6 02 48 C7 01 00 00 00 00 83 B8 90 63 01 00 04 0F 82 A9 29 16 00 C3"},
    {0xB5F2C3u, "SOS re-arm after a leave", "48 8B 09 44 39 79 18 76 0B 44 38 79 08 75 05 E8 C9 B6 B1 FF"},
    {0x10871F3u, "SOS re-arm after a new host", "48 8B 09 44 39 69 18 76 0B 44 38 69 08 75 05 E8 99 37 5F FF"},
    {0x10924E6u, "lobby key setter",
        "48 8D 59 38 48 69 C5 01 01 00 00 49 8B F0 48 8B F9 48 03 D8 41 8B 00 85 C0 75 04 38 03 74 5C 48 8B 4E 08 4C 8B C0 48 8B "
        "D3 E8 4C 38 04 01 85 C0 74 49 48 8B 47 20 48 8B CB 48 0F AB E8 48 89 47 20 48 8B 47 18 48 0F AB E8 48 89 47 18"},
    {0x109411Du, "lobby post countdown",
        "F3 0F 10 87 80 1B 00 00 48 8B 05 1C 22 29 02 F3 0F 5C 00 0F 2F F0 F3 0F 11 87 80 1B 00 00 0F 93 C3 84 DB 74 1A 48 8B 05 "
        "97 8D 3E 02 66 0F 6E 80 68 CE 03 00 0F 5B C0 F3 0F 11 87 80 1B 00 00"},
    {0x66D3D0u, "stratagem uses",
        "48 83 EC 28 41 8B C0 4C 8D 15 ?? ?? ?? ?? 48 8D 0C 40 48 03 C9 8B 84 CA 8C 01 00 00 44 8B 84 CA 88 01 00 00 48 8D 15 75 "
        "E0 15 03 89 44 24 40 48 8B C2 45 85 C0 74 04 4B 8B 04 C2 83 B8 94 00 00 00 00 74 46 83 78 50 FF 74 40"},
    {0x66F060u, "player records",
        "45 8B 81 00 D2 02 00 45 85 C0 0F 84 07 01 00 00 49 8B D1 4C 39 22 74 1F FF C1 48 81 C2 90 16 00 00 41 3B C8 72 ED 48 8B "
        "5C 24 68 48 83 C4 20 41 5D 41 5C 5F 5E 5D C3 4C 89 7C 24 60 4D 8D 79 38 8B C1 48 69 C8 90 16 00 00 4C 03 F9 0F 84 C0 00 "
        "00 00"},
    {0x66F0F8u, "stratagem slots",
        "41 8B B7 88 07 00 00 49 8B D4 48 8B 0D EF 73 CB 02 83 FE 10 41 0F 43 F5 45 33 C9 48 8D 3C 76 48 C1 E7 04 49 03 FF 44 89 "
        "87 88 01 00 00 E8 26 A4 20 00 89 87 8C 01 00 00"},
};
const int blm_sos_code_count = (int)(sizeof blm_sos_code / sizeof blm_sos_code[0]);

/* chat.lua C.CODE: the code that fixes the chat's place and the messages */
const BlmCode blm_chat_code[] = {
    {0x186025Du, "chat box send", "48 8B 0D 8C CC C1 01 4C 8D 87 D4 16 00 00 48 81 C1 18 C4 00 00 E8 E9 72 83 FF"},
    {0xBEB103u, "chat message RPC", "41 B9 01 00 00 00 48 8B D7 B9 8E B8 DD 9F E8 1A 33 FF FF"},
    {0x1097A7Cu, "chat history", "8B 87 94 95 00 00 8B 8F 90 95 00 00"},
    {0x108A2DCu, "new host notice",
        "48 8D 45 67 48 89 5D 67 41 B9 01 00 00 00 48 89 45 E7 4C 8D 45 DF C7 45 DF 09 00 00 00 48 C7 C2 FF FF FF FF C7 45 E3 08 "
        "00 00 00 B9 36 7C E7 B9 E8 1F 41 B5 FF"},
};
const int blm_chat_code_count = (int)(sizeof blm_chat_code / sizeof blm_chat_code[0]);

/* region.lua R.CODE: the continent filter's code */
const BlmCode blm_region_code[] = {
    {0x133B1A3u, "continent filter", "C7 85 C0 00 00 00 24 C5 3B 67 48 8D 35 64 7F E9 00 C7 85 C4 00 00 00 6B D3 F5 5D 4C 8D 35 EB 93 E9 00 41 BC 07 00 00 00"},
    {0x133B229u, "continent flag check", "48 8B 0D C8 1B 14 02 41 8B D7 E8 58 C7 FA FF 48 85 C0 74 21 83 78 0C 07 75 1B 44 38 68 10 75 15"},
    {0x12E7990u, "override lookup",
        "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 56 85 D2 4C 8B D1 B9 78 20 01 00 B8 28 60 00 00 0F 45 C1 "
        "44 8B F2 49 03 C2 33 D2"},
    {0x103F61Du, "override refresh",
        "8B 83 70 20 01 00 41 8B 8D 20 60 00 00 89 44 24 28 89 4C 24 2C 3B C1 74 3E 41 8B 45 14 48 8D 8B 70 C0 00 00 89 83 64 C0 "
        "00 00 49 8D 55 20 41 8B 45 18 41 B8 00 60 00 00 89 83 68 C0 00 00 E8 90 92 05 01 41 8B 85 20 60 00 00 89 83 70 20 01 00"},
};
const int blm_region_code_count = (int)(sizeof blm_region_code / sizeof blm_region_code[0]);

/* scanner.lua M.CODE: the scanner's recharge code */
const BlmCode blm_scanner_code[] = {
    {0x1337FA8u, "recharge reader",
        "48 8B 05 31 4F 14 02 45 8B CE 66 0F 6E 80 4C CE 03 00 8B 86 28 A7 00 00 C7 86 3C BD 10 00 32 00 00 00 89 86 40 F1 0C 00 "
        "89 86 D8 F2 0C 00 0F 5B C0 F3 0F 11 86 74 BD 10 00"},
    {0x133752Eu, "countdown update", "F3 0F 10 81 74 BD 10 00 0F 2F C6 76 0C F3 0F 5C C7 F3 0F 11 81 74 BD 10 00"},
    {0x133E9E0u, "matchmaking global", "48 8B 05 99 E4 13 02 88 90 5D BD 10 00 C3"},
};
const int blm_scanner_code_count = (int)(sizeof blm_scanner_code / sizeof blm_scanner_code[0]);

/* sos.lua B.DEACTIVATE: the game's own SOS off */
const BlmCode blm_sos_deactivate = {0x67AA20u, "B.DEACTIVATE",
    "48 89 5C 24 08 57 48 83 EC 20 48 8B 3D BF 24 E0 02 48 8B D9 48 8B 87 A8 B3 00 00 48 85 C0 74 1F 48 3B 87 98 B3 00 00 74 "
    "16 C6 41 08 00 48 C7 01 00 00 00 00 48 8B 5C 24 30 48 83 C4 20 5F C3 45 33 C0 48 8D 8F 70 D4 01 00 41 8D 50 08 E8 5E 7B "
    "A1 00 48 8B 05 C7 B8 CA 02 BA 13 00 00 00 48 8B CF 44 8B 80 50 C5 0A 00 E8 13 52 CD 00 C6 43 08 00 48 C7 03 00 00 00 00 "
    "48 8B 5C 24 30 48 83 C4 20 5F C3"};

/* sos.lua B.SET_KEY: the game's lobby key setter for numbers */
const BlmCode blm_sos_set_key = {0x10925D0u, "B.SET_KEY",
    "4C 8B DC 49 89 5B 20 57 48 81 EC C0 00 00 00 48 8B 05 2A 9A 5A 01 48 33 C4 48 89 84 24 B0 00 00 00 0F 57 C0 8B FA 0F 11 "
    "44 24 30 48 8B D9 45 8B C8 0F 11 44 24 40 4C 8D 05 23 55 1B 01 BA 80 00 00 00 0F 11 44 24 50 48 8D 4C 24 30 0F 11 44 24 "
    "60 0F 11 44 24 70 41 0F 11 43 B8 41 0F 11 43 C8 41 0F 11 43 D8 E8 E6 B2 45 FF 48 8D 4C 24 30 48 C7 C0 FF FF FF FF 48 FF "
    "C0 80 3C 01 00 75 F7 89 44 24 20 4C 8D 44 24 20 48 8D 44 24 30 8B D7 48 89 44 24 28 48 8B CB 0F 28 44 24 20 66 0F 7F 44 "
    "24 20 E8 59 FE FF FF"};

/* chat.lua C.SEND: the game's chat send */
const BlmCode blm_chat_send_code = {0x1097560u, "C.SEND",
    "41 56 41 57 48 81 EC 78 04 00 00 48 8B 05 9E 4A 5A 01 48 33 C4 48 89 84 24 50 04 00 00 80 39 00"};

/* chat.lua C.RPC: the game's RPC send */
const BlmCode blm_chat_rpc_code = {0xBDE430u, "C.RPC",
    "40 53 55 56 57 41 56 41 57 48 81 EC 98 00 00 00 48 8B 05 C9 DB A5 01 48 33 C4 48 89"};

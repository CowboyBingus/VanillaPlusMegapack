/* The code signatures (blm_code.c): what each part of Better Lobby Management checks once before it runs. */
#ifndef BLM_CODE_H
#define BLM_CODE_H

#include <stdint.h>

/* A game.dll or exe function or code span (rva), or an engine API slot (rva holds the slot offset), and its
 * bytes. name: the Lua's name for it (the refusal says "<name> changed"). */
typedef struct BlmCode { uint32_t rva; const char* name; const char* pattern; } BlmCode;

extern const BlmCode blm_game_code[];
extern const int blm_game_code_count;
extern const BlmCode blm_exe_code[];
extern const int blm_exe_code_count;
extern const BlmCode blm_game_natives[];
extern const int blm_game_natives_count;
extern const BlmCode blm_engine_slots[];
extern const int blm_engine_slots_count;
extern const BlmCode blm_package_slots[];
extern const int blm_package_slots_count;
extern const BlmCode blm_menu_natives[];
extern const int blm_menu_natives_count;
extern const BlmCode blm_menu_code[];
extern const int blm_menu_code_count;
extern const BlmCode blm_sos_code[];
extern const int blm_sos_code_count;
extern const BlmCode blm_chat_code[];
extern const int blm_chat_code_count;
extern const BlmCode blm_region_code[];
extern const int blm_region_code_count;
extern const BlmCode blm_scanner_code[];
extern const int blm_scanner_code_count;
extern const BlmCode blm_sos_deactivate;
extern const BlmCode blm_sos_set_key;
extern const BlmCode blm_chat_send_code;
extern const BlmCode blm_chat_rpc_code;

#endif

/* Better Lobby Management: squad messages (chat.lua), on action frames only.
 *
 * A chat line: one line of the game's own text chat, sent the way the chat box sends what the host types (game.dll
 * 0x186025D hands the network context's chat, ctx + 0xC418, and the text to 0x1097560, which sends
 * rpc_ingame_chat_message to every other peer the host has not muted and shows it in the host's own chat). Every
 * client shows it as "<host>: text".
 *
 * The new squad leader notice: rpc_from_host_notify_new_host (0xB9E77C36, one u64 peer id), which a host that took
 * over after a mission migration sends to every peer (0x108A2DC); a client accepts it from its current host and shows
 * "<name> is the new squad leader". */
#include "blm.h"

#define CHAT 0xC418u          /* network context -> the game's text chat; +0 enabled (byte) */
#define MAX_TEXT 512u         /* the game sends at most 512 bytes and drops a line that is not valid UTF-8 */
#define NEW_HOST 0xB9E77C36u  /* rpc_from_host_notify_new_host */
#define ARG_U64 9u
#define ARG_U64_SIZE 8u
#define EVERY_PEER 0xFFFFFFFFFFFFFFFFull
#define ARGS_SIZE 24u         /* one RPC argument: {u32 type, u32 size, u64 address of the value}; the value follows */
#define ARG_VALUE 16u

typedef void (*BlmChatSend)(uint64_t chat, uint64_t unused, uint64_t text);
typedef void (*BlmRpcSend)(uint32_t hash, uint64_t target, uint64_t args, uint32_t count);

static struct
{
    BlmChatSend send;
    BlmRpcSend rpc;
} s;

/* The buffers handed to the game (static: they outlive the call, as the Lua's api.buffer did). */
static char g_line[MAX_TEXT + 1];
static _Alignas(16) uint8_t g_args[ARGS_SIZE];

void blm_chat_reset(void) { memset(&s, 0, sizeof s); }

int blm_chat_verify(const char** why)
{
    if (!vpm_game_code_matches(blm_chat_send_code.rva, blm_chat_send_code.pattern)) { *why = "chat send changed"; return 0; }
    if (!vpm_game_code_matches(blm_chat_rpc_code.rva, blm_chat_rpc_code.pattern)) { *why = "RPC send changed"; return 0; }
    if (!blm_game_code_ok(blm_chat_code, blm_chat_code_count, why)) return 0;
    s.send = (BlmChatSend)(vpm_game() + blm_chat_send_code.rva);
    s.rpc = (BlmRpcSend)(vpm_game() + blm_chat_rpc_code.rva);
    const uint32_t type = ARG_U64, size = ARG_U64_SIZE;
    const uint64_t value = (uint64_t)(uintptr_t)(g_args + ARG_VALUE);
    memset(g_args, 0, sizeof g_args);
    memcpy(g_args, &type, 4);
    memcpy(g_args + 4, &size, 4);
    memcpy(g_args + 8, &value, 8);
    return 1;
}

/* The other players in the session (direct loads). */
static uint32_t Others(uintptr_t ctx)
{
    uint64_t own = blm_load64(ctx + BLM_LOCAL);
    uint32_t count = blm_load32(ctx + BLM_PEER_COUNT), n = 0;
    if (count > BLM_MAX_PEERS) count = BLM_MAX_PEERS;
    for (uint32_t i = 0; i < count; i++)
        if (blm_load64(ctx + BLM_PEERS + i * BLM_PEER_STRIDE) != own) n++;
    return n;
}

int blm_chat_send(const char* text, uint32_t* sent, const char** why)
{
    uintptr_t ctx = (uintptr_t)blm_global(BLM_CONTEXT_PTR);
    if (s.send == NULL) { *why = "not verified"; return 0; }
    if (ctx == 0) { *why = "no network session"; return 0; }
    uint32_t enabled;
    if (!vpm_read_u32(ctx + CHAT, &enabled)) { *why = "the chat is unreadable"; return 0; }
    if ((enabled & 0xFFu) == 0) { *why = "text chat is off"; return 0; }
    uint32_t n = Others(ctx);
    if (n == 0) { *why = "nobody else in the session"; return 0; }
    size_t length = vpm_utf8_clip(text, MAX_TEXT); /* chat.lua cut: no character split */
    memcpy(g_line, text, length);
    g_line[length] = 0;
    s.send(ctx + CHAT, 0, (uint64_t)(uintptr_t)g_line);
    *sent = n;
    return 1;
}

int blm_chat_new_leader(uint64_t peer, uint32_t* sent, const char** why)
{
    uintptr_t ctx = (uintptr_t)blm_global(BLM_CONTEXT_PTR);
    if (s.rpc == NULL) { *why = "not verified"; return 0; }
    if (ctx == 0) { *why = "no network session"; return 0; }
    uint32_t n = Others(ctx);
    if (n == 0) { *why = "nobody else in the session"; return 0; }
    memcpy(g_args + ARG_VALUE, &peer, 8);
    s.rpc(NEW_HOST, EVERY_PEER, (uint64_t)(uintptr_t)g_args, 1);
    *sent = n;
    return 1;
}

/* Match Your Colors: read-only access to the game's data files (files.lua), with UTF-16 paths so any install folder
 * works, and the listing of its patch files. Runs on the worker thread only, inside a job: each read is one ReadFile at
 * an explicit offset. The Lua used overlapped handles polled once per frame so the game's frame never waited on the
 * disk; on the worker a read may block (the game thread does not wait for it), so handles are plain, closed at once
 * (the Lua queued closes, about 0.09 ms each in game, a few per frame), and nothing is cancelled at a pause: the
 * worker finishes its read and the job is dropped. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "myc_io.h"

static double MycFilesSeconds(void)
{
    LARGE_INTEGER now, frequency;
    QueryPerformanceCounter(&now);
    QueryPerformanceFrequency(&frequency);
    return (double)now.QuadPart / (double)frequency.QuadPart;
}

int myc_files_data_folder(wchar_t* out, int capacity)
{
    static wchar_t path[32768];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (length == 0 || length >= 32768) return 0;
    int separators = 0, cut = -1;
    for (int i = (int)length - 1; i >= 0; i--)
        if (path[i] == L'\\' || path[i] == L'/')
        {
            separators++;
            if (separators == 2) { cut = i; break; }
        }
    if (cut < 0 || cut + 7 >= capacity) return 0;
    memcpy(out, path, (size_t)(cut + 1) * sizeof(wchar_t));
    memcpy(out + cut + 1, L"data\\", 6 * sizeof(wchar_t));
    return 1;
}

void myc_files_init(MycFiles* files, const wchar_t* folder)
{
    memset(files, 0, sizeof *files);
    size_t n = wcslen(folder);
    if (n >= 1023) n = 1023;
    memcpy(files->folder, folder, n * sizeof(wchar_t));
    files->folder[n] = 0;
    files->length = (int)n;
}

/* The folder followed by a UTF-8 name, UTF-16; 0 when it does not fit or is not UTF-8. */
static int MycFilesJoin(const MycFiles* files, const char* name, wchar_t* out, int capacity)
{
    int n = (int)strlen(name);
    int extra = n > 0 ? MultiByteToWideChar(CP_UTF8, 0, name, n, NULL, 0) : 0;
    if ((n > 0 && extra <= 0) || files->length + extra + 1 > capacity) return 0;
    memcpy(out, files->folder, (size_t)files->length * sizeof(wchar_t));
    if (extra > 0 && MultiByteToWideChar(CP_UTF8, 0, name, n, out + files->length, extra) != extra) return 0;
    out[files->length + extra] = 0;
    return 1;
}

int myc_files_open(MycFiles* files, const char* name, MycErr* err)
{
    wchar_t path[2048];
    if (!MycFilesJoin(files, name, path, 2048)) { myc_fail(err, "file name not UTF-8: %s", name); return -1; }
    HANDLE handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_FLAG_RANDOM_ACCESS, NULL);
    if (handle == INVALID_HANDLE_VALUE) { myc_fail(err, "cannot open game file %s", name); return -1; }
    int slot = -1;
    for (int i = 0; i < files->capacity && slot < 0; i++)
        if (files->handles[i] == NULL) slot = i;
    if (slot < 0)
    {
        int capacity = files->capacity < 16 ? 16 : files->capacity * 2;
        void** grown = realloc(files->handles, sizeof(void*) * (size_t)capacity);
        if (grown == NULL) { CloseHandle(handle); myc_fail(err, "out of memory for a file handle"); return -1; }
        for (int i = files->capacity; i < capacity; i++) grown[i] = NULL;
        slot = files->capacity;
        files->handles = grown;
        files->capacity = capacity;
    }
    files->handles[slot] = handle;
    files->held++;
    return slot;
}

int myc_files_read(MycFiles* files, int handle, uint64_t at, uint32_t size, void* out, MycErr* err)
{
    if (size == 0) return 1;
    if (handle < 0 || handle >= files->capacity || files->handles[handle] == NULL) return myc_fail(err, "game file read failed");
    OVERLAPPED overlapped;
    memset(&overlapped, 0, sizeof overlapped);
    overlapped.Offset = (DWORD)(at & 0xFFFFFFFFu);
    overlapped.OffsetHigh = (DWORD)(at >> 32);
    double started = MycFilesSeconds();
    DWORD done = 0;
    if (!ReadFile(files->handles[handle], out, size, &done, &overlapped) || done != size)
        return myc_fail(err, "game file read failed");
    double took = MycFilesSeconds() - started;
    if (took > files->longest) { files->longest = took; files->longest_size = size; }
    files->reads++;
    files->bytes += size;
    return 1;
}

void myc_files_close(MycFiles* files, int handle)
{
    if (handle < 0 || handle >= files->capacity || files->handles[handle] == NULL) return;
    CloseHandle(files->handles[handle]);
    files->handles[handle] = NULL;
    files->held--;
}

void myc_files_close_all(MycFiles* files)
{
    for (int i = 0; i < files->capacity; i++) myc_files_close(files, i);
    free(files->handles);
    files->handles = NULL;
    files->capacity = files->held = 0;
}

/* A find record's name as ASCII into out, or 0 (a name that is not ASCII: no patch file's is). */
static int MycFilesAscii(const wchar_t* name, char* out, int capacity)
{
    int n = 0;
    for (; name[n] != 0; n++)
    {
        if (name[n] > 127 || n + 1 >= capacity) return 0;
        out[n] = (char)name[n];
    }
    out[n] = 0;
    return 1;
}

int myc_files_list(MycFiles* files, const char* pattern, MycArena* arena, char*** names)
{
    wchar_t path[2048];
    *names = NULL;
    if (!MycFilesJoin(files, pattern, path, 2048)) return 0;
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(path, FindExInfoBasic, &data, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
    if (find == INVALID_HANDLE_VALUE) return 0;
    MycVec list = {0};
    do
    {
        char name[MAX_PATH];
        if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 && MycFilesAscii(data.cFileName, name, MAX_PATH))
        {
            char** slot = myc_vec_push(arena, &list, sizeof(char*));
            char* copy = myc_strdup(arena, name);
            if (slot == NULL || copy == NULL) break;
            *slot = copy;
        }
    } while (FindNextFileW(find, &data));
    FindClose(find);
    *names = list.items;
    return list.count;
}

/* ---- the worker's scratch buffers (Slim.grower) ------------------------------------------------------------------- */

static uint8_t* g_scratch[4];
static size_t g_scratchSize[4];

uint8_t* myc_scratch(int which, size_t size)
{
    if (size <= g_scratchSize[which]) return g_scratch[which];
    size_t want = g_scratchSize[which] > 0 ? g_scratchSize[which] : 65536;
    while (want < size) want *= 2;
    uint8_t* grown = realloc(g_scratch[which], want);
    if (grown == NULL) return NULL;
    g_scratch[which] = grown;
    g_scratchSize[which] = want;
    return grown;
}

void myc_scratch_free(void)
{
    for (int i = 0; i < 4; i++)
    {
        free(g_scratch[i]);
        g_scratch[i] = NULL;
        g_scratchSize[i] = 0;
    }
}

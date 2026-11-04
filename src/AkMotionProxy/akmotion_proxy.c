/* akmotion_proxy.c - AkMotion.dll proxy, v2: pass-through + trigger haptics
 *
 * v1 (validated): replacing AkMotion.dll works - the game starts, Wwise keeps its plugin
 * list, sound and native grip rumble are intact:
 *      proxy attached / orig plugin list = 0x7ffd... / init fn resolved
 *
 * v2 adds, inside the game process:
 *   - a hook on XInputSetState in whichever xinput module appears (they load lazily, so a
 *     watcher thread re-scans every 500 ms and patches each module once)
 *   - a 8 ms pump that writes ALL FOUR motors through GameInput:
 *         triggers  = max(mirrored grips, value published by the Router in trigger.bin)
 *         grips     = mirrored values from the game
 *     Mirroring the grips means every action that rumbles the grips also drives the
 *     triggers, with the game's own per-weapon envelope - no event needed.
 *
 * The Router's explicit events still work: they write trigger.bin, and we take the max.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

/* ---------------- game data channel (unchanged from v1) ---------------- */
static HMODULE g_self = NULL;
static HMODULE g_orig = NULL;
static void (*g_pInit)(void) = NULL;
__declspec(dllexport) void *g_pAKPluginList = NULL;

/* ---------------- gameinput ---------------- */
typedef struct { float low; float high; float lt; float rt; } RumbleParams;
typedef HRESULT (WINAPI *PFN_GameInputCreate)(void **ppv);
typedef void (WINAPI *PFN_DeviceCb)(UINT64, void *, void *, UINT64, UINT32, UINT32);
typedef HRESULT (WINAPI *PFN_RegDev)(void *, void *, UINT32, UINT32, UINT32, void *, PFN_DeviceCb, UINT64 *);
typedef void (*PFN_SetRumble)(void *, const RumbleParams *);

static void *g_gi = NULL;
static void *g_dev = NULL;
static UINT64 g_tok = 0;
static PFN_SetRumble g_setRumble = NULL;
static volatile LONG g_giReady = 0;

/* ---------------- mirrored state ---------------- */
static volatile float g_gripLo = 0.0f;
static volatile float g_gripHi = 0.0f;
static HANDLE g_trigFile = INVALID_HANDLE_VALUE;
static volatile LONG g_pumps = 0;
static volatile LONG g_lastLogMs = 0;
static float g_gainCur = 1.0f;     /* smoothed gain, 1.0 = full */

/* external rumble captured from whoever else calls SetRumbleState (the Wwise Motion
   plugin writes the real haptics through GameInput, bypassing XInput entirely) */
static volatile float g_extLo = 0.0f;
static volatile float g_extHi = 0.0f;
static volatile LONG  g_extMs = 0;
static volatile LONG  g_extCount = 0;
static PFN_SetRumble g_origSetRumble = NULL;

/* trigger.bin layout (16 bytes, little endian, floats):
 *   [0..3] lt          explicit left-trigger pulse from the Router
 *   [4..7] rt          explicit right-trigger pulse
 *   [8..11] combat     1 = in combat (gain 1.0), 0 = out of combat (gain = [12..15])
 *   [12..15] outGain   gain used outside combat (tunable without restarting the game)
 */

static void logf_(const char *fmt, ...);

static void log_line(const char *text)
{
    HANDLE h = CreateFileW(L"D:\\PBZ_Xbox\\router\\akmotion\\log.txt",
                           FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD w = 0;
    WriteFile(h, text, (DWORD)lstrlenA(text), &w, NULL);
    WriteFile(h, "\r\n", 2, &w, NULL);
    CloseHandle(h);
}

static void logf_(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    buf[sizeof(buf) - 1] = 0;
    log_line(buf);
}

static void *vtbl_slot(void *obj, int idx)
{
    void **vt = *(void ***)obj;
    return vt[idx];
}

static void WINAPI on_dev(UINT64 t, void *c, void *d, UINT64 ts, UINT32 a, UINT32 b)
{
    (void)t; (void)c; (void)ts; (void)a; (void)b;
    if (d && !g_dev) g_dev = d;
}

/* Replacement for IGameInputDevice::SetRumbleState (vtable slot 10).
   The Wwise Motion plugin writes the real haptics through this entry point, so
   intercepting it gives us the grip values that XInput no longer carries. */
static void hook_vt_SetRumble(void *device, const RumbleParams *p)
{
    if (p != NULL) {
        g_extLo = p->low;
        g_extHi = p->high;
        g_extMs = (LONG)GetTickCount();
        LONG n = InterlockedIncrement(&g_extCount);
        if (n <= 5 || (n % 200) == 0) {
            logf_("ext#%ld lo=%.2f hi=%.2f lt=%.2f rt=%.2f",
                  (long)n, p->low, p->high, p->lt, p->rt);
        }
    }
    if (g_origSetRumble != NULL) g_origSetRumble(device, p);
}

static void install_setrumble_hook(void)
{
    if (g_dev == NULL || g_origSetRumble != NULL) return;
    void **vt = *(void ***)g_dev;
    if (vt == NULL) return;
    g_origSetRumble = (PFN_SetRumble)vt[10];
    if (g_origSetRumble == NULL) { log_line("vt[10] null"); return; }

    DWORD old = 0;
    if (!VirtualProtect(&vt[10], sizeof(void *), PAGE_EXECUTE_READWRITE, &old)) {
        log_line("vtable protect FAILED");
        g_origSetRumble = NULL;
        return;
    }
    vt[10] = (void *)hook_vt_SetRumble;
    VirtualProtect(&vt[10], sizeof(void *), old, &old);
    log_line("SetRumbleState vtable hooked");
}

static void ensure_gi(void)
{
    /* retry-friendly: the device can appear later (plugging the cable in). */
    if (g_dev != NULL && g_setRumble != NULL) return;

    if (InterlockedCompareExchange(&g_giReady, 1, 0) == 0) {
        HMODULE gi = LoadLibraryW(L"GameInput.dll");
        if (gi) {
            PFN_GameInputCreate create = (PFN_GameInputCreate)GetProcAddress(gi, "GameInputCreate");
            if (create && create(&g_gi) == 0 && g_gi) {
                PFN_RegDev reg = (PFN_RegDev)vtbl_slot(g_gi, 9);
                if (reg) {
                    HRESULT hr = reg(g_gi, NULL, 0x0004000Eu, 0x00FFFFFFu, 2u, NULL, on_dev, &g_tok);
                    logf_("reg hr=0x%08X tok=%llu", (unsigned)hr, (unsigned long long)g_tok);
                }
                for (int i = 0; i < 10 && g_dev == NULL; i++) Sleep(100);
            }
        }
    } else if (g_gi != NULL && g_dev == NULL) {
        PFN_RegDev reg = (PFN_RegDev)vtbl_slot(g_gi, 9);
        if (reg && g_tok == 0) reg(g_gi, NULL, 0x0004000Eu, 0x00FFFFFFu, 2u, NULL, on_dev, &g_tok);
        for (int i = 0; i < 5 && g_dev == NULL; i++) Sleep(100);
    }

    if (g_dev != NULL && g_setRumble == NULL) {
        g_setRumble = (PFN_SetRumble)vtbl_slot(g_dev, 10);
        logf_("gameinput: rumble=%s dev=%p", g_setRumble ? "ok" : "null", g_dev);
    }
    if (g_dev != NULL) install_setrumble_hook();
}

static void pump_once(void)
{
    if (!g_origSetRumble || !g_dev) return;

    static int wasActive = 0;

    DWORD now = GetTickCount();

    /* Rumble written by the motion plugin (and anything else) through GameInput.
       Hold it briefly so the trigger mirror does not flicker between its updates. */
    float extGrip = 0.0f;
    float extLo = 0.0f, extHi = 0.0f;
    if ((DWORD)(now - (DWORD)g_extMs) < 250) {
        extLo = g_extLo;
        extHi = g_extHi;
        extGrip = extLo > extHi ? extLo : extHi;
    }

    float lo = g_gripLo, hi = g_gripHi;
    float xiGrip = lo > hi ? lo : hi;
    float grip = xiGrip > extGrip ? xiGrip : extGrip;

    float evLt = 0.0f, evRt = 0.0f;
    float combat = 1.0f, outGain = 1.0f;

    if (g_trigFile != INVALID_HANDLE_VALUE) {
        float buf[4] = { 0.0f, 0.0f, 1.0f, 1.0f };
        DWORD got = 0;
        SetFilePointer(g_trigFile, 0, NULL, FILE_BEGIN);
        if (ReadFile(g_trigFile, buf, sizeof(buf), &got, NULL) && got >= 8) {
            evLt = buf[0];
            evRt = buf[1];
            if (got >= 16) { combat = buf[2]; outGain = buf[3]; }
        }
    }
    if (outGain < 0.0f) outGain = 0.0f;
    if (outGain > 1.0f) outGain = 1.0f;

    float target = (combat > 0.5f) ? 1.0f : outGain;
    if (g_gainCur < target) { g_gainCur += 0.055f; if (g_gainCur > target) g_gainCur = target; }
    else if (g_gainCur > target) { g_gainCur -= 0.055f; if (g_gainCur < target) g_gainCur = target; }

    float lt, rt;
    if (evLt > 0.02f || evRt > 0.02f) {
        lt = evLt;
        rt = evRt;
    } else {
        lt = grip * g_gainCur;
        rt = grip * g_gainCur;
    }
    if (lt > 1) lt = 1; if (rt > 1) rt = 1;

    int active = (lt > 0.02f || rt > 0.02f);
    if (!active) {
        if (wasActive) {
            RumbleParams z;
            z.low = lo; z.high = hi; z.lt = 0.0f; z.rt = 0.0f;
            g_origSetRumble(g_dev, &z);   /* one final frame so triggers do not stick */
            wasActive = 0;
        }
        return;
    }
    wasActive = 1;

    RumbleParams p;
    p.low = lo; p.high = hi; p.lt = lt; p.rt = rt;
    g_origSetRumble(g_dev, &p);

    LONG n = InterlockedIncrement(&g_pumps);
    if (lt > 0.05f || rt > 0.05f) {
        if ((DWORD)(now - (DWORD)g_lastLogMs) > 300) {
            g_lastLogMs = (LONG)now;
            logf_("pump#%ld lt=%.2f rt=%.2f grips=%.2f/%.2f ext=%.2f/%.2f combat=%.0f gain=%.2f",
                  (long)n, lt, rt, lo, hi, extLo, extHi, combat, g_gainCur);
        }
    }
}

static DWORD WINAPI pump_thread(LPVOID unused)
{
    (void)unused;
    for (;;) { pump_once(); Sleep(8); }
    return 0;
}

/* ---------------- xinput hook ---------------- */
typedef struct { WORD wLeftMotorSpeed; WORD wRightMotorSpeed; } XINPUT_VIBRATION;
static volatile LONG g_patched14 = 0, g_patched13 = 0, g_patched90 = 0;
static volatile LONG g_calls = 0;

static DWORD WINAPI hook_SetState(DWORD idx, XINPUT_VIBRATION *vib)
{
    (void)idx;
    if (vib) {
        g_gripLo = (float)vib->wLeftMotorSpeed / 65535.0f;
        g_gripHi = (float)vib->wRightMotorSpeed / 65535.0f;
    } else {
        g_gripLo = 0.0f;
        g_gripHi = 0.0f;
    }

    LONG n = InterlockedIncrement(&g_calls);
    if (n <= 20 || (n % 300) == 0) {
        logf_("SetState#%ld slot=%lu lo=%.2f hi=%.2f", (long)n, (unsigned long)idx, g_gripLo, g_gripHi);
    }

    pump_once();
    return 0;
}

static void try_patch(const wchar_t *name, volatile LONG *flag, const char *label)
{
    if (*flag) return;
    HMODULE m = GetModuleHandleW(name);
    if (!m) return;

    void *target = GetProcAddress(m, "XInputSetState");
    if (!target) return;

    unsigned char patch[12];
    patch[0] = 0x48; patch[1] = 0xB8;
    *(void **)(patch + 2) = (void *)hook_SetState;
    patch[10] = 0xFF; patch[11] = 0xE0;

    DWORD old = 0;
    if (!VirtualProtect(target, sizeof(patch), PAGE_EXECUTE_READWRITE, &old)) {
        logf_("VirtualProtect failed on %s", label);
        return;
    }
    memcpy(target, patch, sizeof(patch));
    VirtualProtect(target, sizeof(patch), old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof(patch));
    InterlockedExchange(flag, 1);
    logf_("patched %s", label);
}

static DWORD WINAPI hook_watcher(LPVOID unused)
{
    (void)unused;
    LONG announced = 0;
    for (int i = 0; i < 1000000; i++) {      /* effectively forever: self-heal if the pad shows up late */
        ensure_gi();
        if (g_setRumble == NULL) {
            /* No GameInput device (e.g. the pad is on Bluetooth): leave XInput completely
               untouched so the game's own rumble keeps working. */
            if (!announced) { announced = 1; log_line("no rumble device yet - XInput NOT patched"); }
            Sleep(1000);
            continue;
        }
        try_patch(L"XInput1_4.dll", &g_patched14, "XInput1_4");
        try_patch(L"XInput1_3.dll", &g_patched13, "XInput1_3");
        try_patch(L"XInput9_1_0.dll", &g_patched90, "XInput9_1_0");
        Sleep(500);
    }
    return 0;
}

/* ---------------- original DLL ---------------- */
static void ensure_orig(void)
{
    if (g_orig != NULL) return;
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(g_self, path, MAX_PATH);
    if (n == 0) { log_line("GetModuleFileName failed"); return; }
    wchar_t *slash = wcsrchr(path, L'\\');
    if (slash == NULL) { log_line("no path separator"); return; }
    lstrcpynW(slash + 1, L"AkMotion_orig.dll", MAX_PATH - (int)(slash + 1 - path));
    g_orig = LoadLibraryW(path);
    if (g_orig == NULL) { log_line("LoadLibrary(AkMotion_orig) FAILED"); return; }

    void **slot = (void **)GetProcAddress(g_orig, "g_pAKPluginList");
    if (slot) { g_pAKPluginList = *slot; logf_("orig plugin list = %p", g_pAKPluginList); }
    else log_line("g_pAKPluginList not found in orig");

    g_pInit = (void (*)(void))GetProcAddress(g_orig, "AkMotionInitializeScePadFunctions");
    log_line(g_pInit ? "init fn resolved" : "init fn NOT found");
}

static DWORD WINAPI boot(LPVOID unused)
{
    (void)unused;
    Sleep(500);
    ensure_gi();
    if (g_setRumble == NULL) log_line("boot: no rumble device - XInput will stay untouched");
    g_trigFile = CreateFileW(L"D:\\PBZ_Xbox\\router\\trigger.bin", GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, NULL);
    logf_("trigger.bin %s", (g_trigFile != INVALID_HANDLE_VALUE) ? "open" : "FAILED");

    HANDLE t1 = CreateThread(NULL, 0, hook_watcher, NULL, 0, NULL);
    if (t1) CloseHandle(t1);
    HANDLE t2 = CreateThread(NULL, 0, pump_thread, NULL, 0, NULL);
    if (t2) CloseHandle(t2);
    log_line("boot complete");
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = hInst;
        DisableThreadLibraryCalls(hInst);
        log_line("proxy attached");
        ensure_orig();
#ifndef PASSTHROUGH_ONLY
        HANDLE t = CreateThread(NULL, 0, boot, NULL, 0, NULL);
        if (t) CloseHandle(t);
#else
        log_line("PASSTHROUGH ONLY build: no hooks, no pump");
#endif
    }
    return TRUE;
}

__declspec(dllexport) void AkMotionInitializeScePadFunctions(void)
{
    ensure_orig();
    if (g_pInit != NULL) g_pInit();
}

/*
 * WoWAutoLoginBridge 5875 v1
 * World of Warcraft 1.12.1 build 5875, Windows x86 ONLY.
 *
 * A Multibox-launched WoW process inherits:
 *   WOW112_AUTOLOGIN_ACCOUNT - account name
 *   WOW112_AUTOLOGIN_BLOB    - DPAPI-protected password (base64)
 *
 * The bridge removes both variables immediately, waits for Glue readiness,
 * dispatches on the game window thread, calls native login 0x0046AFB0 and
 * scrubs plaintext buffers. No SendInput, focus switching or edit-box timing.
 *
 * Exact current PARALLEL binary evidence:
 * candidate 5328812bebb5bdfdd0d554ed95c4e243ae918c7c
 * EXE sha256 c841336b297e10df597da6a0b5ded4a66efae22f17c3d64d0a88438d39e4bc06
 * DefaultServerLogin binding 0x0046D160; native Glue login 0x0046AFB0.
 * External corroboration only: brues-code/ClassicAPI commit
 * 71805db62f1e8a154477033dc1f50960c535af8b (GPL-3.0-or-later).
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWAutoLoginBridge requires x86.
#endif

#include <windows.h>
#include <wincrypt.h>
#include <dpapi.h>

#define LOGIN_FN       0x0046AFB0u
#define GLUE_READY1    0x00B41DFCu
#define GLUE_READY2    0x00B41E04u
#define GLUE_STATE     0x00B41DA0u
#define WM_AUTOLOGIN   (WM_APP + 0x2A7u)
#define WM_LOW_SPEC    (WM_APP + 0x2A8u)
#define FRAMESCRIPT_EXECUTE 0x00704CD0u
#define OBJMGR_GLOBAL  0x00B41414u
#define OM_LOCAL_GUID_LO 0x000000C0u
#define OM_LOCAL_GUID_HI 0x000000C4u
#define ACCOUNT_CAP    64u
#define BLOB_CAP       2048u

typedef void (__fastcall *GlueLoginFn)(const char*, char*);
typedef void (__fastcall *FrameScriptExecuteFn)(const char*, const char*);
typedef BOOL (WINAPI *CryptStringToBinaryAFn)(LPCSTR,DWORD,DWORD,BYTE*,DWORD*,DWORD*,DWORD*);
typedef BOOL (WINAPI *CryptUnprotectDataFn)(DATA_BLOB*,LPWSTR*,DATA_BLOB*,PVOID,CRYPTPROTECT_PROMPTSTRUCT*,DWORD,DATA_BLOB*);

static volatile LONG g_stop=0;
static volatile LONG g_done=0;
static volatile LONG g_low_spec=0;
static volatile LONG g_low_spec_done=0;
static DWORD g_pid=0;
static HWND g_hwnd=NULL;
static WNDPROC g_prev=NULL;
static char g_account[ACCOUNT_CAP];
static char g_blob[BLOB_CAP];
static HWND g_best=NULL;
static DWORD g_best_area=0u;

static void wipe(void *p,DWORD n)
{
    volatile BYTE *b=(volatile BYTE*)p;
    while(b && n--) *b++=0;
}

/* CRT-less build: clang may lower small structure/array copies to memcpy. */
void *memcpy(void *dst,const void *src,size_t n)
{
    BYTE *d=(BYTE*)dst;
    const BYTE *s=(const BYTE*)src;
    size_t i;
    for(i=0;i<n;++i) d[i]=s[i];
    return dst;
}

static int guard_ok(void)
{
    static const BYTE sig[]={
        0xA1,0xFC,0x1D,0xB4,0x00,0x85,0xC0,0x56,0x8B,0xF2,
        0x0F,0x84,0xF4,0x00,0x00,0x00,
        0xA1,0x04,0x1E,0xB4,0x00,0x85,0xC0,
        0x0F,0x84,0xE7,0x00,0x00,0x00,
        0xA1,0xA0,0x1D,0xB4,0x00,0x85,0xC0
    };
    const volatile BYTE *p=(const volatile BYTE*)(DWORD)LOGIN_FN;
    DWORD i;
    for(i=0u;i<(DWORD)sizeof(sig);++i) if(p[i]!=sig[i]) return 0;
    return 1;
}

static int glue_ready(void)
{
    return *(volatile DWORD*)(DWORD)GLUE_READY1!=0u &&
           *(volatile DWORD*)(DWORD)GLUE_READY2!=0u &&
           *(volatile DWORD*)(DWORD)GLUE_STATE==0u;
}

static int load_profile(void)
{
    char low[8]={0};
    DWORD a=GetEnvironmentVariableA("WOW112_AUTOLOGIN_ACCOUNT",g_account,ACCOUNT_CAP);
    DWORD b=GetEnvironmentVariableA("WOW112_AUTOLOGIN_BLOB",g_blob,BLOB_CAP);
    DWORD l=GetEnvironmentVariableA("WOW112_LOW_SPEC",low,(DWORD)sizeof(low));
    SetEnvironmentVariableA("WOW112_AUTOLOGIN_ACCOUNT",NULL);
    SetEnvironmentVariableA("WOW112_AUTOLOGIN_BLOB",NULL);
    SetEnvironmentVariableA("WOW112_LOW_SPEC",NULL);
    g_low_spec=(l>0u && l<(DWORD)sizeof(low) && low[0]=='1')?1:0;
    wipe(low,(DWORD)sizeof(low));
    if(a==0u || a>=ACCOUNT_CAP || b==0u || b>=BLOB_CAP) {
        wipe(g_account,sizeof(g_account));
        wipe(g_blob,sizeof(g_blob));
        return 0;
    }
    return 1;
}

static int native_login(void)
{
    static const BYTE entropyBytes[]="WoW112Updater-wow-accounts-v1";
    HMODULE crypt=LoadLibraryA("crypt32.dll");
    CryptStringToBinaryAFn decode;
    CryptUnprotectDataFn unprotect;
    DATA_BLOB inBlob,outBlob,entropy;
    BYTE *protectedBytes=NULL,*password=NULL;
    DWORD protectedSize=0u,flags=0u;
    int ok=0;

    if(!crypt) return 0;
    decode=(CryptStringToBinaryAFn)GetProcAddress(crypt,"CryptStringToBinaryA");
    unprotect=(CryptUnprotectDataFn)GetProcAddress(crypt,"CryptUnprotectData");
    if(!decode || !unprotect) goto done;

    if(!decode(g_blob,0u,CRYPT_STRING_BASE64,NULL,&protectedSize,NULL,NULL) ||
       protectedSize==0u || protectedSize>4096u) goto done;
    protectedBytes=(BYTE*)LocalAlloc(LMEM_FIXED,protectedSize);
    if(!protectedBytes) goto done;
    if(!decode(g_blob,0u,CRYPT_STRING_BASE64,protectedBytes,&protectedSize,NULL,NULL)) goto done;

    inBlob.cbData=protectedSize;
    inBlob.pbData=protectedBytes;
    entropy.cbData=(DWORD)(sizeof(entropyBytes)-1u);
    entropy.pbData=(BYTE*)entropyBytes;
    outBlob.cbData=0u;
    outBlob.pbData=NULL;

    if(!unprotect(&inBlob,NULL,&entropy,NULL,NULL,CRYPTPROTECT_UI_FORBIDDEN,&outBlob) ||
       !outBlob.pbData || outBlob.cbData==0u || outBlob.cbData>=256u) goto done;

    password=(BYTE*)LocalAlloc(LMEM_FIXED,outBlob.cbData+1u);
    if(!password) goto done;
    CopyMemory(password,outBlob.pbData,outBlob.cbData);
    password[outBlob.cbData]=0u;

    ((GlueLoginFn)(DWORD)LOGIN_FN)(g_account,(char*)password);
    ok=1;

done:
    if(password) { wipe(password,outBlob.cbData+1u); LocalFree(password); }
    if(outBlob.pbData) { wipe(outBlob.pbData,outBlob.cbData); LocalFree(outBlob.pbData); }
    if(protectedBytes) { wipe(protectedBytes,protectedSize); LocalFree(protectedBytes); }
    wipe(g_blob,sizeof(g_blob));
    wipe(g_account,sizeof(g_account));
    if(crypt) FreeLibrary(crypt);
    return ok;
}

static int world_ready(void)
{
    DWORD manager=*(volatile DWORD*)(DWORD)OBJMGR_GLOBAL;
    DWORD lo,hi;
    if(manager<0x00010000u || manager>0x7FFF0000u) return 0;
    lo=*(volatile DWORD*)(DWORD)(manager+OM_LOCAL_GUID_LO);
    hi=*(volatile DWORD*)(DWORD)(manager+OM_LOCAL_GUID_HI);
    return (lo|hi)!=0u;
}

static void apply_low_spec(void)
{
    static const char script[]=
        "if not W112_LOW_SPEC_APPLIED then "
        "W112_LOW_SPEC_APPLIED=1;"
        "W112_LOW_SPEC_KEYS={'farclip','groundEffectDensity','groundEffectDist','detailDoodadAlpha','smallcull','skycloudlod','particleDensity','extShadowQuality','weatherDensity','specular','anisotropic','gxMultisample'};"
        "W112_LOW_SPEC_OLD={};local v={'177','16','1','1','2','0','0.3','0','0','0','1','1'};"
        "for i=1,table.getn(W112_LOW_SPEC_KEYS) do local k=W112_LOW_SPEC_KEYS[i];W112_LOW_SPEC_OLD[i]=GetCVar(k);SetCVar(k,v[i]) end;"
        "W112_LOW_SPEC_FRAME=CreateFrame('Frame');W112_LOW_SPEC_FRAME:RegisterEvent('PLAYER_LOGOUT');"
        "W112_LOW_SPEC_FRAME:SetScript('OnEvent',function() if W112_LOW_SPEC_OLD then for i=1,table.getn(W112_LOW_SPEC_KEYS) do local k=W112_LOW_SPEC_KEYS[i];local x=W112_LOW_SPEC_OLD[i];if x then SetCVar(k,x) end end end end);"
        "end";
    ((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(script,script);
}

static LRESULT WINAPI login_wndproc(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp)
{
    if(msg==WM_AUTOLOGIN && !g_done) {
        if(!guard_ok()) { g_done=-1; return 0; }
        if(!glue_ready()) return 0;
        g_done=native_login()?1:-2;
        return 0;
    }
    if(msg==WM_LOW_SPEC && g_low_spec && !g_low_spec_done) {
        if(!world_ready()) return 0;
        apply_low_spec();
        g_low_spec_done=1;
        return 0;
    }
    return g_prev ? CallWindowProcA(g_prev,hwnd,msg,wp,lp) : DefWindowProcA(hwnd,msg,wp,lp);
}

static BOOL CALLBACK enum_windows(HWND hwnd,LPARAM unused)
{
    DWORD pid=0u,area;
    RECT r;
    (void)unused;
    if(!IsWindowVisible(hwnd)) return TRUE;
    GetWindowThreadProcessId(hwnd,&pid);
    if(pid!=g_pid || !GetClientRect(hwnd,&r)) return TRUE;
    area=(DWORD)((r.right-r.left)>0?(r.right-r.left):0) *
         (DWORD)((r.bottom-r.top)>0?(r.bottom-r.top):0);
    if(area>g_best_area) { g_best_area=area; g_best=hwnd; }
    return TRUE;
}

static HWND find_main_window(void)
{
    g_best=NULL; g_best_area=0u;
    EnumWindows(enum_windows,0);
    return g_best;
}

static int ensure_hook(void)
{
    LONG old;
    HWND found;
    if(g_hwnd && g_prev && IsWindow(g_hwnd)) return 1;
    found=find_main_window();
    if(!found) return 0;
    old=SetWindowLongA(found,GWL_WNDPROC,(LONG)(DWORD)login_wndproc);
    if(!old) return 0;
    g_hwnd=found;
    g_prev=(WNDPROC)(DWORD)old;
    return 1;
}

static void release_hook(void)
{
    if(g_hwnd && g_prev && IsWindow(g_hwnd)) {
        LONG current=GetWindowLongA(g_hwnd,GWL_WNDPROC);
        if((WNDPROC)(DWORD)current==login_wndproc)
            SetWindowLongA(g_hwnd,GWL_WNDPROC,(LONG)(DWORD)g_prev);
    }
    g_hwnd=NULL; g_prev=NULL;
}

static DWORD WINAPI worker(LPVOID unused)
{
    DWORD start;
    (void)unused;
    if(!load_profile()) return 0u; /* ordinary launch: bridge stays inert */
    if(!guard_ok()) { g_done=-1; wipe(g_blob,sizeof(g_blob)); wipe(g_account,sizeof(g_account)); return 0u; }

    g_pid=GetCurrentProcessId();
    start=GetTickCount();
    while(!g_stop && !g_done && (DWORD)(GetTickCount()-start)<40000u) {
        if(ensure_hook()) PostMessageA(g_hwnd,WM_AUTOLOGIN,0,0);
        Sleep(50u);
    }
    if(!g_done) { wipe(g_blob,sizeof(g_blob)); wipe(g_account,sizeof(g_account)); }
    if(g_low_spec && g_done==1) {
        start=GetTickCount();
        while(!g_stop && !g_low_spec_done && (DWORD)(GetTickCount()-start)<60000u) {
            if(world_ready() && ensure_hook()) PostMessageA(g_hwnd,WM_LOW_SPEC,0,0);
            Sleep(100u);
        }
    }
    release_hook();
    return 0u;
}

BOOL WINAPI DllMain(HMODULE module,DWORD reason,LPVOID reserved)
{
    HANDLE th;
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH) {
        g_stop=0; g_done=0; g_low_spec=0; g_low_spec_done=0;
        DisableThreadLibraryCalls(module);
        th=CreateThread(NULL,0u,worker,NULL,0u,NULL);
        if(th) CloseHandle(th);
    } else if(reason==DLL_PROCESS_DETACH) {
        g_stop=1;
        release_hook();
        wipe(g_blob,sizeof(g_blob));
        wipe(g_account,sizeof(g_account));
    }
    return TRUE;
}

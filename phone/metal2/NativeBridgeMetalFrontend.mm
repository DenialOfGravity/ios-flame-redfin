// SPDX-License-Identifier: MIT
// Native Metal API frontend over the bridge (bridge/NativeMetalObjects.h): the metal2vulkan runtime on Turnip, on the Adreno 740 through
// NativeAdreno. Same shape as the offline frontend: the device is a dynamically allocated subclass of the target's own _MTLDevice that
// only adds this file's implementations; every other object is an own class answering the Metal protocol methods it implements.
// Every result comes from the runtime and the GPU: a refused call returns nil/NO with the runtime's reason, an encoder call the runtime
// refuses fails its command buffer (status Error, handlers run) instead of being dropped. A selector this frontend does not implement is
// reported through the missing-selector hook before the usual exception, so a hardware run names the gap.
// Shared events work within this process (no cross-process handle yet). Not yet implemented here: heaps, argument buffers, indirect commands, drawables/presentation.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <chrono>
#include <pthread.h>
#include <pthread/qos.h>
#include <sched.h>
#include <mach/mach_time.h>
#include <string>
#include <unordered_map>
#include <vector>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <math.h>
#include <unistd.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <os/lock.h>
#include "bridge/NativeMetalObjects.h"
#include "NativeBridgeMetalFrontend.h"

// u-cpu: CPU savings of the frontend, env SWEET_CPUFAST (a bitmask, from /var/local/mtl2-env; unset = kCpuFastDefault):
//  0x1 answers   the device queries that take an argument (supportsFamily:, supportsTextureSampleCount:, ...) answered once per
//                selector and argument, then from a table. They are functions of the device alone (its properties and format
//                answers, fixed at open). prof2 (Settings flings): Metal's MTLPixelFormatGetInfoForDevice, which Core Animation calls
//                through MTLGetTextureLevelInfoForDeviceWithOptions, asked supportsFamily: and the runtime audited every row of the
//                family each time (families::audit, its format answers cloned) = 23% of the display thread's samples.
//  0x2 viewport  setViewport:/setScissorRect: with the value the encoder's last accepted call of it set is not sent again: the
//                state is the same, the runtime logs no call, and its fast draw (SWEET_FASTDRAW) keeps its entries.
// "native-metal: T cpufast 5s:" counts them.
enum : uint32_t {CPUFAST_ANSWERS=0x1,CPUFAST_VIEWPORT=0x2};
static const uint32_t kCpuFastDefault=CPUFAST_ANSWERS|CPUFAST_VIEWPORT;
// u-lab: live knobs. /var/local/mtl2-live (KEY=VALUE lines, like mtl2-env) is looked at once a second from -commit (its
// mtime; one stat per second) and its values override the env for the knobs that need no pipeline, device or thread
// setup: SWEET_CPUFAST (bits), SWEET_ENCSTAT, SWEET_FNSTAT (0/1, with the timeline on), SWEET_ENC_SLOW_MS. A key not in the
// file (or no file) = the env value again. Changes are logged "native-metal: live: KEY=VALUE". No restart: an A/B of
// these switches in a second (tools-claude/exp-run.py `live` lines). All else (TU_DEBUG, SWEET_UBWC, bridge knobs, QoS)
// is read once at startup and still needs the backboardd restart.
// u-combo: also SWEET_M2V_SCRATCH (bridge 0111, chosen per pass: passed on with nmb_sweet_scratch_live) and
// SWEET_ENCTHREAD_REPLACE (a flush before replaceRegion, per call; matters only with SWEET_ENCTHREAD on). Not live, by design:
// SWEET_ENCTHREAD (a command buffer's mode is fixed at creation; switching would reorder commits against the worker's queue),
// SWEET_ENCTHREAD_PRI/_SPIN_US (worker start), SWEET_M2V_COLOR_WRITES (compiled SPIR-V, cache keys), SWEET_TU_* (Turnip).
static std::atomic<int64_t> gLiveCpuFast{-1},gLiveEncStat{-1},gLiveFnStat{-1},gLiveEncSlowMs{-1},gLiveScratch{-1},gLiveEncReplace{-1};
// ovd: SWEET_DRAWBOX=N (in /var/local/mtl2-live, backboardd with the timeline; each change of the file re-arms, at most 20): for the next N frames
// (backboardd command buffers with a framebuffer pass) every render pass and draw as "DB" lines: pipeline functions + label,
// blend, write mask, viewport, scissor, the position attribute's bounding box (raw and in pixels) and the vertex uniform bytes.
static std::atomic<int32_t> gDrawboxLeft{0};static std::atomic<uint32_t> gDrawboxSeq{0};
// g9 SWEET_DEADFILL (env or /var/local/mtl2-live, read at each render encoder's creation; default 0 = off). 1: a draw that is a
// full-target opaque constant-colour fill (Core Animation's "draw.PBGRAXm_A2Xhf" pipeline: no blending, all channels written, no
// depth/stencil, untextured; viewport/scissor the whole attachment; every vertex the same colour with alpha 1; position bbox covering
// the attachment in pixels) is held; the encoder's later calls are recorded behind it until the next draw. If that draw is such a fill
// too, the held one is dropped (it would be completely overwritten); otherwise the held draw and the recorded calls go out in their
// order before it. Nothing else is reordered. 2: also, while no draw went out yet, the encoder's creation is held when its colour
// attachment 0 loads (Load or DontCare) and it has no other attachment: if its first surviving draw is such a fill, the pass clears
// to the fill's colour instead and the draw is dropped (A6xx fast clear). "native-metal: DF 5s:" counts them (with the timeline).
static std::atomic<int64_t> gLiveDeadfill{-1};
static std::atomic<uint64_t> gDfDeferred{0},gDfDropped{0},gDfCleared{0},gDfPx{0};static std::atomic<int32_t> gDfCapturing{0};
static int deadfillMode() {
 static const int env=[]{const char *e=getenv("SWEET_DEADFILL");return e && *e?atoi(e):0;}();
 const int64_t live=gLiveDeadfill.load(std::memory_order_relaxed);
 return live>=0?(int)live:env;
}
// g9 SWEET_LUMA_BOOST=0 (env or /var/local/mtl2-live; unset = CA unchanged): Core Animation's luma boost pass (one full-screen
// luma_boost_lph draw a frame) off. QuartzCore 16.7 reads CA_DISABLE_LUMA_BOOST from the environment once, before the plugin's
// setenv; it is debug option 91 of its table (CA_COLOR_FLUSH = 0 .. CA_PRINT_FILM_GRAIN = 152) and the render path tests that byte
// every frame, so CASetDebugOption(91, 1) turns the pass off live (backboardd, the render server). Restored (0) when the knob goes.
static void lumaKnob(int64_t live);

static uint32_t cpuFast() {
 static const uint32_t bits=[]{const char *e=getenv("SWEET_CPUFAST");return e && *e?(uint32_t)strtoul(e,nullptr,0):kCpuFastDefault;}();
 const int64_t live=gLiveCpuFast.load(std::memory_order_relaxed);
 return live>=0?(uint32_t)live:bits;
}
static std::atomic<uint64_t> gCfAnswerHits{0},gCfAnswerAsks{0},gCfViewportSkips{0},gCfScissorSkips{0},gCfViewportSent{0},gCfScissorSent{0};


extern "C" void sys_dcache_flush(void *start, size_t length);

static NmbDevice *gDevice;
static id gDeviceObject;
static uint64_t gRegistryID;
static NSString *gName;
static void (*gMissing)(const char *, const char *);

// What this device has been asked and refused, for the plugin's status line (native_bridge_metal_status): commits, render/compute pipelines made,
// refusals, and the last two refusals' texts. Counters only; nothing here changes a result.
static std::atomic<uint64_t> gCommits,gCommitFailures,gPipelines,gProblems,gCompleted;
// What the render server actually asks of the GPU (int-141: 59 commits in 200 s, and a desktop that behaves like CPU compositing): render passes,
// draws, the pixels of their first colour attachment, compute dispatches, blits and the largest pass (pixels).
static std::atomic<uint64_t> gPasses,gDraws,gPassPixels,gDispatches,gBlits,gBiggestPass,gFullScreenPasses;
// Where the time goes on the CPU side of the bridge: pipeline, library and function creation (count, total and slowest, in microseconds), and the
// last commits with what each held and how long the GPU took (commit to completion).
static uint64_t nowUs() {return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000;}
static void noteShadowCopies();   // WS-U: backboardd's 5 s "J copies" line (defined by the telemetry table)
// u-f (r36): SWEET_SHADOW_SEED=1, surface-seed shadow copy skip (bridge patch 0107; see bumpWrittenSeeds).
static bool shadowSeedOn() {
 static int on=-1;
 if(on<0){const char *e=getenv("SWEET_SHADOW_SEED");on=e && *e && strcmp(e,"0")?1:0;}
 return on;
}
struct Timed {std::atomic<uint64_t> count{0},total{0},slowest{0};
 void add(uint64_t began){const uint64_t took=nowUs()-began;count++;total+=took;uint64_t seen=slowest.load();while(took>seen && !slowest.compare_exchange_weak(seen,took)){}}};
static Timed gTimePipeline,gTimeLibrary,gTimeFunction,gTimeEncodeToCommit;
static Timed gTimeWaitScheduled,gTimeWaitCompleted;
static Timed gTimeResourceWait;
static std::atomic<uint64_t> gResourceChecks,gResourceSkipped;
static Timed gTimeSurfaceFlush;
// u-t (r31): backboardd's frame timeline. Every command buffer's life on one clock (CLOCK_MONOTONIC_RAW, the runtime's host clock,
// on which it places the GPU's timestamps through VK_KHR_calibrated_timestamps): created, first encoder, commit, the scheduler's
// submission (kernel start/end), GPU start/end, the completion callback (notice) and its completed handlers' start. A command
// buffer with a render pass into an IOSurface of 1.5 Mpx or more is a frame (CA's framebuffer). Every 5 s, from a commit, one line
// "native-metal: T 5s: ..." (and a "T2" line of the runtime's scheduler counts) goes to the console and /var/local/mtl2.log.
// /var/local/mtl2-env SWEET_TIMELINE=0 turns it off (the plugin sets 1 for backboardd).
size_t (*native_bridge_metal_pass_report)(char *,size_t,unsigned);
size_t (*native_bridge_metal_cpu_report)(char *,size_t);
size_t (*native_bridge_metal_ubwc_report)(char *,size_t);
size_t (*native_bridge_metal_draw_report)(char *,size_t);   // u-gpudraw: Turnip 0112 "T tu-draw"
size_t (*native_bridge_metal_perf_report)(char *,size_t,unsigned);   // u-perfctr: Turnip 0113 "T tu-perf 5s"
static bool timelineOn() {
 static int on=-1;
 if(on<0){const char *e=getenv("SWEET_TIMELINE");on=!strcmp(getprogname(),"backboardd") && e && *e && strcmp(e,"0")?1:0;}
 return on==1;
}
static uint64_t tlNow() {return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);}
enum EncCat : uint8_t {EC_PIPE,EC_TEX,EC_BUF,EC_ENC,EC_DRAW,EC_BIND,EC_BLIT,EC_UPLOAD,EC_WAIT,EC_CB,EC_COUNT};
// u-e: one frame's (command buffer's) encode window split (see EncScope).
struct EncFrame {float ms[EC_COUNT];uint16_t n[EC_COUNT];uint32_t scopes;float cpuMs,mhz,vkMs;uint16_t vkN;int8_t cpu0,cpu1;bool valid;};
struct EncodedWork {uint32_t passes,draws,dispatches,blits;uint64_t pixels;};
struct TLRecord {uint64_t created,commit,kStart,kEnd,gStart,gEnd,notice,handler;EncodedWork work;EncFrame enc;uint32_t surface;bool frame,waitedCompleted,waitedScheduled;};
static std::mutex gTLLock;
static std::vector<TLRecord> gTL;   // completed since the last report (at most 4096 kept)
static void timelineReport(std::vector<TLRecord> records,uint64_t spanNs);
static std::atomic<uint64_t> gSurfaceFlushBytes,gSurfaceFlushDuplicates;
struct CommitRecord {uint64_t committedUs=0,callbackUs=0,ageUs=0;int64_t scheduledUs=-1;uint32_t index=0;EncodedWork work={};};
static CommitRecord gCommitRing[32];
static std::mutex gCommitLock;
static std::mutex gProblemLock;
static char gLastProblems[2][200];
static void noteProblem(NSString *what) {
 gProblems++;
 std::lock_guard<std::mutex> lock(gProblemLock);
 memcpy(gLastProblems[1],gLastProblems[0],sizeof gLastProblems[0]);
 strlcpy(gLastProblems[0],what.UTF8String?:"?",sizeof gLastProblems[0]);
}
extern "C" void sm2_logs(const char *);
#define NBLOG(...) do{NSString *nbText=[NSString stringWithFormat:__VA_ARGS__];sm2_logs(nbText.UTF8String);noteProblem(nbText);}while(0)
// u-encthread (SWEET_ENCTHREAD, see "the encode thread" below): the frontend records render/blit encoder calls and commits and a
// worker thread replays them into the bridge. The calls that need the replayed state now wait for it (a sync flush, by reason).
enum EncFlushWhy : uint8_t {EF_SCHEDULED,EF_COMPLETED,EF_RESOURCE,EF_GETBYTES,EF_COMPUTE,EF_PURGEABLE,EF_REPLACE,EF_BACKPRESSURE,EF_WHY_COUNT};
static bool encThreadOn();
static void encFlush(EncFlushWhy why);
// u-e (r33): encode-time accounting (backboardd, with the timeline; /var/local/mtl2-env SWEET_ENCSTAT=0 turns it off). Every
// Metal call CA makes into this frontend that can cost (creation, encoder begin/end, binds, draws, blits, uploads, waits) runs in
// an EncScope: two mach_absolute_time reads around the call, counted on the calling thread by category (outermost scope only, so a
// nested call is never counted twice) and per call site (count, total, max). A command buffer takes the thread's counts at its first
// encoder and at commit: the frame's time per category, the time inside no category (CA's own work between calls, and calls not
// instrumented), its thread's CPU time in the window, the CPU it committed on and the core's speed then (a fixed chain of dependent
// adds, timed: "MHz-eq"). Every 5 s with the T line: "T3" (per-frame categories p50/p95, calls, mean per call), "T4" (the 10 call
// sites with most time), "T slow frame" (frames whose encode passed 50 ms, split). A single call over SWEET_ENC_SLOW_MS (20) logs
// "E slow" at once (at most 12 per 5 s) with its category, site and object.
static const char *const kEncCatName[EC_COUNT]={"pipe","tex","buf","enc","draw","bind","blit","upload","wait","cb"};
static bool timelineOn();
static bool fnStatOn() {   // u-gpudraw
 static int on=-1;
 if(on<0){const char *e=getenv("SWEET_FNSTAT");on=timelineOn() && e && *e && strcmp(e,"0")?1:0;}
 const int64_t live=gLiveFnStat.load(std::memory_order_relaxed);
 return live>=0?live && timelineOn():on==1;
}
static bool encStatOn() {
 static int on=-1;
 if(on<0){const char *e=getenv("SWEET_ENCSTAT");on=timelineOn() && !(e && !strcmp(e,"0"))?1:0;}
 const int64_t live=gLiveEncStat.load(std::memory_order_relaxed);
 return live>=0?live && timelineOn():on==1;
}
static double encTickNs() {
 static double ns=0;
 if(ns==0){mach_timebase_info_data_t tb;mach_timebase_info(&tb);ns=tb.denom?(double)tb.numer/tb.denom:1;}
 return ns;
}
static uint64_t encSlowTicks() {
 static uint64_t ticks=0;
 if(!ticks){const char *e=getenv("SWEET_ENC_SLOW_MS");double ms=e && atof(e)>0?atof(e):20;ticks=(uint64_t)(ms*1e6/encTickNs());}
 const int64_t live=gLiveEncSlowMs.load(std::memory_order_relaxed);
 return live>0?(uint64_t)(live*1e6/encTickNs()):ticks;
}
// g9: SWEET_LUMA_BOOST (live: 0/1 from /var/local/mtl2-live, -1: the env's, else leave CA alone or restore what was set)
static void lumaKnob(int64_t live) {
 static int applied=-1;   // what was set: 1 disabled, 0 restored, -1 never touched
 static const bool bb=!strcmp(getprogname(),"backboardd");
 if(!bb)return;
 int want=-1;
 if(live>=0)want=live==0?1:0;
 else{const char *e=getenv("SWEET_LUMA_BOOST");if(e && *e)want=strcmp(e,"0")?0:1;else if(applied==1)want=0;}
 if(want<0 || want==applied)return;
 static void (*set)(int,uint8_t)=(void (*)(int,uint8_t))dlsym(RTLD_DEFAULT,"CASetDebugOption");
 static int (*get)(int)=(int (*)(int))dlsym(RTLD_DEFAULT,"CAGetDebugOption");
 char text[200];
 if(!set){snprintf(text,sizeof text,"native-metal: luma: SWEET_LUMA_BOOST=%d NOT applied (no CASetDebugOption)",want?0:1);sm2_logs(text);applied=want;return;}
 applied=want;
 // off the render thread (CASetDebugOption posts a notification after it sets the byte; its observers may take CA's locks)
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  set(91,(uint8_t)want);
  char line[200];
  snprintf(line,sizeof line,"native-metal: luma: SWEET_LUMA_BOOST=%d applied: CASetDebugOption(91 = CA_DISABLE_LUMA_BOOST, %d), reads back %d",want?0:1,want,get?get(91):-1);
  sm2_logs(line);
 });
}
// once a second at most (one thread wins the slot): the file's mtime; on a change, parse it and publish the values
static void liveKnobsPoll() {
 static std::atomic<uint64_t> next{0};
 static struct timespec seen;
 static bool had;
 const uint64_t now=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
 uint64_t due=next.load(std::memory_order_relaxed);
 if(now<due || !next.compare_exchange_strong(due,now+1000000000ull))return;
 {static bool lumaFirst=false;if(!lumaFirst){lumaFirst=true;lumaKnob(-1);}}   // g9: the env's SWEET_LUMA_BOOST at the first poll
 struct stat st;
 const bool have=stat("/var/local/mtl2-live",&st)==0;
 if(have==had && (!have || (st.st_mtimespec.tv_sec==seen.tv_sec && st.st_mtimespec.tv_nsec==seen.tv_nsec)))return;
 had=have;
 seen=have?st.st_mtimespec:(struct timespec){0,0};
 int64_t cf=-1,es=-1,fs=-1,ms=-1,sc=-1,er=-1,df=-1,lb=-1;
 if(FILE *f=have?fopen("/var/local/mtl2-live","r"):nullptr) {
  char line[256];
  while(fgets(line,sizeof line,f)) {
   line[strcspn(line,"\r\n")]=0;
   char *eq=strchr(line,'=');
   if(line[0]=='#' || !eq)continue;
   *eq=0;
   const char *v=eq+1;
   if(!strcmp(line,"SWEET_CPUFAST") && *v)cf=(int64_t)strtoul(v,nullptr,0);
   else if(!strcmp(line,"SWEET_ENCSTAT"))es=strcmp(v,"0")?1:0;
   else if(!strcmp(line,"SWEET_FNSTAT"))fs=*v && strcmp(v,"0")?1:0;
   else if(!strcmp(line,"SWEET_ENC_SLOW_MS") && atof(v)>0)ms=(int64_t)atof(v);
   else if(!strcmp(line,"SWEET_M2V_SCRATCH"))sc=*v && strcmp(v,"0")?1:0;   // u-combo: as the bridge reads the env
   else if(!strcmp(line,"SWEET_ENCTHREAD_REPLACE"))er=*v=='1'?1:0;
   else if(!strcmp(line,"SWEET_DRAWBOX") && atoi(v)>0)gDrawboxLeft.store(std::min(atoi(v),20));   // ovd
   else if(!strcmp(line,"SWEET_DEADFILL") && *v)df=atoi(v);   // g9
   else if(!strcmp(line,"SWEET_LUMA_BOOST") && *v)lb=strcmp(v,"0")?1:0;   // g9
  }
  fclose(f);
 }
 gLiveCpuFast.store(cf,std::memory_order_relaxed);gLiveEncStat.store(es,std::memory_order_relaxed);
 gLiveFnStat.store(fs,std::memory_order_relaxed);gLiveEncSlowMs.store(ms,std::memory_order_relaxed);
 gLiveEncReplace.store(er,std::memory_order_relaxed);
 gLiveDeadfill.store(df,std::memory_order_relaxed);lumaKnob(lb);   // g9
 if(gLiveScratch.exchange(sc)!=sc)nmb_sweet_scratch_live((int32_t)sc);   // u-combo: the bridge, from its next pass
 char text[360];
 snprintf(text,sizeof text,"native-metal: live: %s -> SWEET_CPUFAST=0x%x SWEET_ENCSTAT=%d SWEET_FNSTAT=%d SWEET_ENC_SLOW_MS=%llu"
  " SWEET_M2V_SCRATCH=%s SWEET_ENCTHREAD_REPLACE=%s SWEET_DEADFILL=%d SWEET_LUMA_BOOST=%s",
  have?"/var/local/mtl2-live read":"no /var/local/mtl2-live (env values)",cpuFast(),encStatOn(),fnStatOn(),
  (unsigned long long)llround(encSlowTicks()*encTickNs()/1e6),sc<0?"env":sc?"1":"0",er<0?"env":er?"1":"0",deadfillMode(),lb<0?"env":lb?"1":"0");
 sm2_logs(text);
}
struct EncTLS {uint64_t ticks[EC_COUNT];uint32_t n[EC_COUNT];uint32_t depth;uint64_t scopes;};
static __thread EncTLS tEnc;
static __thread char tEncDetail[200];   // what the current slow call worked on (set by the call, only when it is slow)
struct EncSite {
 const char *name;uint8_t cat;std::atomic<uint64_t> n,ticks,max;std::atomic<bool> listed;
 constexpr EncSite(const char *nm,uint8_t c):name(nm),cat(c),n(0),ticks(0),max(0),listed(false){}
};
enum {kEncSites=128};
static std::atomic<EncSite *> gEncSites[kEncSites];
static std::atomic<unsigned> gEncSiteCount;
static std::atomic<unsigned> gEncSlowLogged;   // E slow lines in this 5 s window
static void encList(EncSite *s) {
 bool f=false;
 if(s->listed.compare_exchange_strong(f,true)){const unsigned i=gEncSiteCount.fetch_add(1);if(i<kEncSites)gEncSites[i].store(s);}
}
static void encSlow(const EncSite *s,uint64_t ticks) {
 if(gEncSlowLogged.fetch_add(1)>=12){tEncDetail[0]=0;return;}
 char line[400];
 snprintf(line,sizeof line,"native-metal: E slow %.1f ms %s %s%s%s",ticks*encTickNs()/1e6,kEncCatName[s->cat],s->name,tEncDetail[0]?": ":"",tEncDetail);
 tEncDetail[0]=0;
 sm2_logs(line);
}
struct EncScope {
 EncSite *site;uint64_t t0;bool outer;
 explicit EncScope(EncSite *s):site(nullptr),t0(0),outer(false) {
  if(!encStatOn())return;
  site=s;
  if(tEnc.depth++==0){outer=true;tEncDetail[0]=0;t0=mach_absolute_time();}
 }
 // Whether the call has run past the slow threshold so far (a call then describes its object into tEncDetail).
 bool slow() const {return site && outer && mach_absolute_time()-t0>encSlowTicks();}
 ~EncScope() {
  if(!site)return;
  tEnc.depth--;
  if(!outer)return;
  const uint64_t d=mach_absolute_time()-t0;
  tEnc.ticks[site->cat]+=d;tEnc.n[site->cat]++;tEnc.scopes++;
  site->n.fetch_add(1,std::memory_order_relaxed);site->ticks.fetch_add(d,std::memory_order_relaxed);
  if(d>site->max.load(std::memory_order_relaxed))site->max.store(d,std::memory_order_relaxed);
  if(!site->listed.load(std::memory_order_relaxed))encList(site);
  if(d>encSlowTicks())encSlow(site,d);
 }
};
#define ENC_SCOPE(cat,name) static EncSite encSite_{name,cat};EncScope encScope_(&encSite_)
static int encCPU() {
 static int (*cpuNumber)(size_t *)=(int (*)(size_t *))dlsym(RTLD_DEFAULT,"pthread_cpu_number_np");
 size_t n=0;return cpuNumber && cpuNumber(&n)==0?(int)n:-1;
}
// The core's speed: 8192 dependent adds (about one per cycle on the A76 and the A55), timed.
static float encMHz() {
 uint64_t x=0;const uint64_t t0=mach_absolute_time();
 __asm__ volatile("mov x9, #2048\n1:\n add %0, %0, #1\n add %0, %0, #1\n add %0, %0, #1\n add %0, %0, #1\n subs x9, x9, #1\n b.ne 1b\n"
                  :"+r"(x)::"x9","cc");
 const double ns=(mach_absolute_time()-t0)*encTickNs();
 return ns>0?(float)(8192e3/ns):0;
}
// What one EncScope costs (two clock reads, the thread's counts, the site's three atomics), measured once, for the T3 line.
static double encScopeNs() {
 static double ns=-1;
 if(ns<0) {
  static EncSite probe{"probe",EC_CB};
  const uint64_t t0=mach_absolute_time();
  for(int i=0;i<2000;i++){volatile uint64_t a=mach_absolute_time();(void)a;volatile uint64_t b=mach_absolute_time();
   probe.n.fetch_add(1,std::memory_order_relaxed);probe.ticks.fetch_add(b-a,std::memory_order_relaxed);
   if(b-a>probe.max.load(std::memory_order_relaxed))probe.max.store(b-a,std::memory_order_relaxed);tEnc.scopes+=0;}
  ns=(mach_absolute_time()-t0)*encTickNs()/2000;
 }
 return ns;
}
// The encoding thread, once per thread: its priority and QoS (the scheduler's sweetbig=2 sends threads at 47 or above to an idle big
// core first). SWEET_RENDER_QOS=ui|in sets its QoS class, SWEET_RENDER_PRI=N a fixed priority N (SCHED_RR) first: both off by default.
static void encThreadNote() {
 static __thread bool noted;
 if(noted)return;
 noted=true;
 const char *qosKnob=getenv("SWEET_RENDER_QOS"),*priKnob=getenv("SWEET_RENDER_PRI");
 char done[96]="";
 if(qosKnob && (!strcmp(qosKnob,"ui") || !strcmp(qosKnob,"in"))) {
  const int r=pthread_set_qos_class_self_np(!strcmp(qosKnob,"ui")?QOS_CLASS_USER_INTERACTIVE:QOS_CLASS_USER_INITIATED,0);
  snprintf(done,sizeof done," | set qos %s: %d",qosKnob,r);
 }
 if(priKnob && atoi(priKnob)>0) {
  struct sched_param sp={};sp.sched_priority=atoi(priKnob);
  const int r=pthread_setschedparam(pthread_self(),SCHED_RR,&sp);
  const size_t at=strlen(done);snprintf(done+at,sizeof done-at," | set pri %d rr: %d",sp.sched_priority,r);
 }
 thread_extended_info_data_t info={};mach_msg_type_number_t count=THREAD_EXTENDED_INFO_COUNT;
 const mach_port_t self=mach_thread_self();
 const kern_return_t kr=thread_info(self,THREAD_EXTENDED_INFO,(thread_info_t)&info,&count);
 mach_port_deallocate(mach_task_self(),self);
 qos_class_t qos=QOS_CLASS_UNSPECIFIED;int relative=0;pthread_get_qos_class_np(pthread_self(),&qos,&relative);
 uint64_t tid=0;pthread_threadid_np(nullptr,&tid);
 (void)encScopeNs();
 char line[400];
 snprintf(line,sizeof line,"native-metal: encode thread %llu '%s': pri cur %d base %d max %d policy %d qos 0x%x%+d cpu %d MHz-eq %.0f%s",
  (unsigned long long)tid,kr==KERN_SUCCESS?info.pth_name:"?",kr==KERN_SUCCESS?info.pth_curpri:-1,kr==KERN_SUCCESS?info.pth_priority:-1,
  kr==KERN_SUCCESS?info.pth_maxpriority:-1,kr==KERN_SUCCESS?info.pth_policy:-1,(unsigned)qos,relative,encCPU(),encMHz(),done);
 sm2_logs(line);
}
// u-e (r34): render pipeline prewarm. Every render pipeline state CA makes (backboardd, SpringBoard) is recorded once in
// <cache>/prewarm.v1: both functions by their library's digest (SHA-256 of its bytes, the library kept as prewarm-lib-DIGEST.bin
// beside it), name and constant values, and the bridge descriptor's bytes. At the next device creation a utility-QoS thread makes them
// again, in the order CA first asked, before CA asks: the runtime keeps what a making produced by content (translations, libraries of
// pipeline parts, variants' pipelines), so CA's own creation of the same state finds it made. The prewarmed states are kept for the
// process's life. Bounded by SWEET_PREWARM_MAX (300 states) and SWEET_PREWARM_MS (30000 ms); "native-metal: prewarm: N pipelines in
// M ms" when done. /var/local/mtl2-env SWEET_PREWARM=0: no recording, no prewarm.
static std::string gPrewarmDir;
static std::mutex gPrewarmLock;
static std::unordered_map<std::string,bool> gPrewarmSeen;   // recorded lines (the file's and this process's)
static std::atomic<bool> gPrewarmRunning{false};
static std::unordered_map<std::string,bool> gPrewarmUsed;   // mode 2: records CA made this process (under gPrewarmLock)
// G6: 2 = idle priming (SWEET_PREWARM=2), 1 = the prewarm at device creation (default; 0 turns both off through prewarmOn).
static int prewarmMode() {
 static int mode=-1;
 if(mode<0){const char *e=getenv("SWEET_PREWARM");mode=e && atoi(e)==2?2:1;}
 return mode;
}
static bool prewarmOn() {
 static int on=-1;
 if(on<0){const char *e=getenv("SWEET_PREWARM"),*p=getprogname();
  on=!(e && !strcmp(e,"0")) && (!strcmp(p,"backboardd") || !strcmp(p,"SpringBoard"))?1:0;}
 return on==1 && !gPrewarmDir.empty();
}
static unsigned prewarmKnob(const char *name,unsigned fallback) {const char *e=getenv(name);return e && atoi(e)>0?(unsigned)atoi(e):fallback;}
static std::string hexOf(const void *bytes,size_t size) {
 static const char digits[]="0123456789abcdef";std::string out;out.resize(size*2);
 for(size_t i=0;i<size;i++){const uint8_t b=((const uint8_t *)bytes)[i];out[2*i]=digits[b>>4];out[2*i+1]=digits[b&15];}
 return out;
}
static bool unhex(const std::string &text,std::vector<uint8_t> &out) {
 if(text.size()%2)return false;
 out.resize(text.size()/2);
 auto v=[](char c)->int{return c>='0' && c<='9'?c-'0':c>='a' && c<='f'?c-'a'+10:-1;};
 for(size_t i=0;i<out.size();i++){const int h=v(text[2*i]),l=v(text[2*i+1]);if(h<0 || l<0)return false;out[i]=(uint8_t)(h<<4|l);}
 return true;
}
static std::vector<std::string> splitOn(const std::string &s,char by) {
 std::vector<std::string> out;size_t at=0;
 for(;;){const size_t next=s.find(by,at);out.push_back(s.substr(at,next==std::string::npos?std::string::npos:next-at));if(next==std::string::npos)break;at=next+1;}
 return out;
}
// A library's digest (prewarm records name it), its bytes kept once in the cache directory; "" where prewarm is off.
static std::string prewarmLibrary(const void *bytes,size_t size) {
 if(!prewarmOn() || !bytes || !size)return "";
 unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,(CC_LONG)size,digest);
 const std::string name=hexOf(digest,16);
 const std::string path=gPrewarmDir+"/prewarm-lib-"+name+".bin";
 if(access(path.c_str(),R_OK)!=0) {
  const std::string temp=path+".tmp"+std::to_string(getpid());
  if(FILE *f=fopen(temp.c_str(),"wb")) {
   const bool ok=fwrite(bytes,1,size,f)==size;
   if(fclose(f)==0 && ok)rename(temp.c_str(),path.c_str());else unlink(temp.c_str());
  }
 }
 return name;
}
// A function's part of a record: LIB:S|P:NAMEHEX:CONSTANTS (TYPE.INDEX.NAMEHEX.BYTESHEX joined by ',', or -).
static std::string prewarmFunctionKey(const std::string &library,NSString *name,const NmbConstant *constants,size_t count,bool specialized) {
 if(library.empty() || !name.UTF8String)return "";
 std::string key=library+(specialized?":S:":":P:")+hexOf(name.UTF8String,strlen(name.UTF8String))+":";
 if(!count)key+="-";
 for(size_t i=0;i<count;i++) {
  const NmbConstant &c=constants[i];
  char head[48];snprintf(head,sizeof head,"%s%llu.%llu.",i?",":"",(unsigned long long)c.type,(unsigned long long)c.index);
  key+=head;key+=c.name?hexOf(c.name,strlen(c.name)):"";key+=".";key+=hexOf(c.bytes,(size_t)c.length);
 }
 return key;
}
// Record a state CA made: "P1 VERTEX FRAGMENT|- OPTIONS DESCRIPTOR" (the descriptor's bytes, functions zeroed, trailing zeros dropped).
static void prewarmRecord(const std::string &vertex,const std::string &fragment,const NmbRenderPipelineDescriptor &d,uint64_t options) {
 if(!prewarmOn() || vertex.empty() || fragment=="")return;
 NmbRenderPipelineDescriptor copy=d;copy.vertex=nullptr;copy.fragment=nullptr;
 size_t size=sizeof copy;const uint8_t *bytes=(const uint8_t *)&copy;
 while(size && !bytes[size-1])size--;
 char opts[24];snprintf(opts,sizeof opts,"%llx",(unsigned long long)options);
 const std::string line="P1 "+vertex+" "+fragment+" "+opts+" "+hexOf(bytes,size);
 std::lock_guard<std::mutex> lock(gPrewarmLock);
 if(prewarmMode()==2 && gPrewarmUsed.size()<4000)gPrewarmUsed.emplace(line,true);   // G6: made by CA this boot
 if(gPrewarmSeen.size()>=1000 || !gPrewarmSeen.emplace(line,true).second)return;
 if(FILE *f=fopen((gPrewarmDir+"/prewarm.v1").c_str(),"a")){fputs(line.c_str(),f);fputc('\n',f);fclose(f);}
}
// Makes recorded states again (both prewarm modes): the libraries read once, kept for the process's life like the states.
struct PrewarmMaker {
 std::unordered_map<std::string,NmbLibrary *> libraries;
 unsigned bad=0;
 NmbFunction *function(const std::string &key,bool &missing) {
  const std::vector<std::string> p=splitOn(key,':');
  if(p.size()!=4){bad++;return nullptr;}
  NmbLibrary *library=nullptr;
  auto at=libraries.find(p[0]);
  if(at!=libraries.end())library=at->second;
  else {
   NSData *data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:(gPrewarmDir+"/prewarm-lib-"+p[0]+".bin").c_str()]
                                       options:NSDataReadingMappedIfSafe error:nil];
   library=data?nmb_library_new(gDevice,data.bytes,data.length,false):nullptr;
   libraries[p[0]]=library;
  }
  if(!library){missing=true;return nullptr;}
  std::vector<uint8_t> nameBytes;if(!unhex(p[2],nameBytes)){bad++;return nullptr;}
  const std::string name(nameBytes.begin(),nameBytes.end());
  if(p[1]=="P")return nmb_function_new(library,name.c_str());
  std::vector<NmbConstant> constants;std::vector<std::string> names;std::vector<std::vector<uint8_t>> values;
  if(p[3]!="-") {
   const std::vector<std::string> items=splitOn(p[3],',');
   names.reserve(items.size());values.reserve(items.size());
   for(const std::string &item:items) {
    const std::vector<std::string> f=splitOn(item,'.');
    if(f.size()!=4){bad++;return nullptr;}
    std::vector<uint8_t> n,v;if(!unhex(f[2],n) || !unhex(f[3],v)){bad++;return nullptr;}
    names.emplace_back(n.begin(),n.end());values.push_back(v);
    constants.push_back({strtoull(f[0].c_str(),nullptr,10),strtoull(f[1].c_str(),nullptr,10),nullptr,nullptr,(uint64_t)v.size()});
   }
   for(size_t i=0;i<constants.size();i++){constants[i].name=names[i].empty()?nullptr:names[i].c_str();constants[i].bytes=values[i].data();}
  }
  return nmb_function_new_specialized(library,name.c_str(),constants.data(),(uint32_t)constants.size());
 }
 // One record: -1 unreadable line (not tried), 0 made (into kept), 1 failed, 2 without its library.
 int make(const std::string &line,std::vector<NmbRenderPipeline *> &kept) {
  const std::vector<std::string> t=splitOn(line,' ');
  if(t.size()!=5 || t[0]!="P1"){bad++;return -1;}
  int result;
  bool missing=false;
  NmbFunction *vertex=function(t[1],missing);
  NmbFunction *fragment=t[2]=="-"?nullptr:function(t[2],missing);
  std::vector<uint8_t> bytes;
  NmbRenderPipelineDescriptor d={};
  if(!vertex || (t[2]!="-" && !fragment) || !unhex(t[4],bytes) || bytes.size()>sizeof d) {
   result=missing?2:1;
  } else {
   memcpy(&d,bytes.data(),bytes.size());d.vertex=vertex;d.fragment=fragment;
   const NmbPipelineOptions options={strtoull(t[3].c_str(),nullptr,16),nullptr,0};
   NmbRenderPipeline *state=nmb_render_pipeline_new_with_options(gDevice,&d,&options);
   if(state){kept.push_back(state);result=0;}else result=1;
  }
  if(vertex)nmb_function_release(vertex);
  if(fragment)nmb_function_release(fragment);
  return result;
 }
};
static std::vector<NmbRenderPipeline *> gPrewarmKept;   // the prewarmed states, for the process's life
// The prewarm itself (a utility-QoS GCD thread, from device creation).
static void prewarmRun(std::vector<std::string> lines) {
 gPrewarmRunning=true;
 const uint64_t began=nowUs();
 const unsigned most=prewarmKnob("SWEET_PREWARM_MAX",300),budgetMs=prewarmKnob("SWEET_PREWARM_MS",30000);
 PrewarmMaker maker;
 unsigned made=0,failed=0,noLibrary=0,tried=0;
 NmbShaderCacheStats c0={},c1={};const bool haveC0=nmb_device_shader_cache_stats(gDevice,&c0);
 for(const std::string &line:lines) {
  if(tried>=most || (nowUs()-began)/1000>=budgetMs)break;
  const int r=maker.make(line,gPrewarmKept);
  if(r<0)continue;
  tried++;
  if(r==0)made++;else if(r==2)noLibrary++;else failed++;
 }
 const unsigned bad=maker.bad;
 const bool haveC1=haveC0 && nmb_device_shader_cache_stats(gDevice,&c1);
 char line[400];
 snprintf(line,sizeof line,"native-metal: prewarm: %u pipelines in %llu ms (%u records, %u tried, %u failed, %u without their library, %u unreadable)"
  " | cache: spirv hit %llu miss %llu, drv loads %llu saves %llu same %llu",made,(unsigned long long)((nowUs()-began)/1000),(unsigned)lines.size(),
  tried,failed,noLibrary,bad,haveC1?(unsigned long long)(c1.hits-c0.hits):0ull,haveC1?(unsigned long long)(c1.misses-c0.misses):0ull,
  haveC1?(unsigned long long)(c1.driver_loads-c0.driver_loads):0ull,haveC1?(unsigned long long)(c1.driver_saves-c0.driver_saves):0ull,
  haveC1?(unsigned long long)(c1.driver_unchanged-c0.driver_unchanged):0ull);
 sm2_logs(line);
 gPrewarmRunning=false;
}
// G6 (SWEET_PREWARM=2): idle priming, after UniXNU AdrenoMetal f0c3177/PrimeShaders.h (waitForQuiet). Mode 1 makes every record 200 ms
// after device creation, while the boot animation and the first SpringBoard frames draw. Mode 2 starts SWEET_PREWARM_DELAY_S (90) s
// after device creation, on a background-QoS thread, and makes only the records CA has not made itself this boot (rechecked before
// each one). Before each making it waits while backboardd committed more than SWEET_PREWARM_BUSY (8) command buffers in the last
// 250 ms (an idle 60/90 Hz desktop commits fewer, any animation more), and after such a pause until SWEET_PREWARM_QUIET_MS (500) ms
// were quiet. backboardd publishes its commit count in /var/local/mtl2-prime-busy (one page, only with mode 2) so SpringBoard pauses
// for backboardd's work too (its own count where the page is missing). Each record CA itself makes this boot is marked used; mode 2
// primes only the recorded pipelines not used this boot (CA's own makings already did the rest). SWEET_PREWARM_MAX bounds the makings, SWEET_PREWARM_MS the
// making time (pauses not counted). "native-metal: PR prime: done/total, paused N, ms" when done.
struct PrimeBusyPage {uint32_t magic,version;std::atomic<uint64_t> commits;};
static const uint32_t kPrimeBusyMagic=0x53505242;   // 'SPRB'
static PrimeBusyPage *gPrimeBusyOut;                // backboardd, mode 2: its commits, published
// backboardd's commit count (gCommits: submitted command buffers), published at each completion (a few ms late, no hunk in commit).
static inline void primeNoteCommit() {if(PrimeBusyPage *p=gPrimeBusyOut)p->commits.store(gCommits.load(std::memory_order_relaxed),std::memory_order_relaxed);}
static PrimeBusyPage *primeBusyMap(bool write) {
 const int fd=open("/var/local/mtl2-prime-busy",write?O_RDWR|O_CREAT:O_RDONLY,0644);
 if(fd<0)return nullptr;
 if(write)fchmod(fd,0644);
 struct stat st;
 if(write?ftruncate(fd,4096)!=0:(fstat(fd,&st)!=0 || st.st_size<(off_t)sizeof(PrimeBusyPage))){close(fd);return nullptr;}
 void *page=mmap(nullptr,4096,write?PROT_READ|PROT_WRITE:PROT_READ,MAP_SHARED,fd,0);
 close(fd);
 if(page==MAP_FAILED)return nullptr;
 PrimeBusyPage *p=(PrimeBusyPage *)page;
 if(write){p->version=1;p->magic=kPrimeBusyMagic;}
 else if(p->magic!=kPrimeBusyMagic){munmap(page,4096);return nullptr;}
 return p;
}
// backboardd's commits so far (its page, or this process's own count without one).
static uint64_t primeCommitCount() {
 static PrimeBusyPage *in;static uint64_t nextTryMs;
 if(gPrimeBusyOut)return gCommits.load(std::memory_order_relaxed);
 if(!in) {
  const uint64_t ms=nowUs()/1000;
  if(ms>=nextTryMs){in=primeBusyMap(false);nextTryMs=ms+5000;}
 }
 return in?in->commits.load(std::memory_order_relaxed):gCommits.load(std::memory_order_relaxed);
}
// backboardd's commits in the last 250 ms: samples every 50 ms while waiting; after a making (no sample in the last 250-500 ms) it takes
// a fresh 250 ms window.
struct PrimeGate {
 uint64_t ms[32],n[32];unsigned head=0,count=0;
 void sample() {ms[head]=nowUs()/1000;n[head]=primeCommitCount();head=(head+1)%32;if(count<32)count++;}
 unsigned recent() {
  for(int round=0;round<2;round++) {
   sample();
   const unsigned newest=(head+31)%32;
   for(unsigned k=1;k<count;k++) {
    const unsigned i=(newest+32-k)%32;
    const uint64_t span=ms[newest]-ms[i];
    if(span<250)continue;
    if(span>500)break;
    const uint64_t d=n[newest]-n[i];return (unsigned)(d*250/span);
   }
   count=1;head=(newest+1)%32;   // keep only the newest sample
   usleep(250000);
  }
  return 0;
 }
};
static void prewarmIdleRun(std::vector<std::string> lines) {
 const unsigned delayS=prewarmKnob("SWEET_PREWARM_DELAY_S",90),busyMax=prewarmKnob("SWEET_PREWARM_BUSY",8),
  quietMs=prewarmKnob("SWEET_PREWARM_QUIET_MS",500),most=prewarmKnob("SWEET_PREWARM_MAX",300),budgetMs=prewarmKnob("SWEET_PREWARM_MS",30000);
 sleep(delayS);
 const uint64_t began=nowUs();
 std::vector<std::string> pending;
 {
  std::lock_guard<std::mutex> lock(gPrewarmLock);
  for(const std::string &line:lines)if(!gPrewarmUsed.count(line))pending.push_back(line);
 }
 sm2_logs([NSString stringWithFormat:@"native-metal: PR prime: start, %zu of %zu records not made this boot (busy > %u per 250 ms pauses)",
  pending.size(),lines.size(),busyMax].UTF8String);
 PrewarmMaker maker;PrimeGate gate;
 unsigned made=0,failed=0,noLibrary=0,tried=0,usedMeanwhile=0,paused=0;
 uint64_t activeUs=0,pausedMs=0;
 NmbShaderCacheStats c0={},c1={};const bool haveC0=nmb_device_shader_cache_stats(gDevice,&c0);
 for(const std::string &line:pending) {
  if(tried>=most || activeUs/1000>=budgetMs)break;
  // wait for a quiet display
  bool wasBusy=false;uint64_t pauseBegan=0,quietSince=0;
  for(;;) {
   const uint64_t ms=nowUs()/1000;
   if(gate.recent()>busyMax) {
    if(!wasBusy){wasBusy=true;paused++;pauseBegan=ms;}
    quietSince=0;usleep(50000);continue;
   }
   if(!wasBusy)break;
   if(!quietSince)quietSince=ms;
   if(ms-quietSince>=quietMs){pausedMs+=ms-pauseBegan;break;}
   usleep(50000);
  }
  {std::lock_guard<std::mutex> lock(gPrewarmLock);if(gPrewarmUsed.count(line)){usedMeanwhile++;continue;}}
  const uint64_t t0=nowUs();
  gPrewarmRunning=true;
  const int r=maker.make(line,gPrewarmKept);
  gPrewarmRunning=false;
  activeUs+=nowUs()-t0;
  if(r<0)continue;
  tried++;
  if(r==0)made++;else if(r==2)noLibrary++;else failed++;
 }
 const bool haveC1=haveC0 && nmb_device_shader_cache_stats(gDevice,&c1);
 char line[480];
 snprintf(line,sizeof line,"native-metal: PR prime: %u/%zu, paused %u, %llu ms (paused %llu ms, wall %llu ms; %u failed, %u without their library,"
  " %u unreadable, %u made by CA meanwhile) | cache: spirv hit %llu miss %llu, drv loads %llu saves %llu same %llu",made,pending.size(),paused,
  (unsigned long long)(activeUs/1000),(unsigned long long)pausedMs,(unsigned long long)((nowUs()-began)/1000),failed,noLibrary,maker.bad,usedMeanwhile,
  haveC1?(unsigned long long)(c1.hits-c0.hits):0ull,haveC1?(unsigned long long)(c1.misses-c0.misses):0ull,
  haveC1?(unsigned long long)(c1.driver_loads-c0.driver_loads):0ull,haveC1?(unsigned long long)(c1.driver_saves-c0.driver_saves):0ull,
  haveC1?(unsigned long long)(c1.driver_unchanged-c0.driver_unchanged):0ull);
 sm2_logs(line);
}
static void *prewarmIdleThread(void *arg) {
 std::vector<std::string> *lines=(std::vector<std::string> *)arg;
 pthread_setname_np("sweet.prime");
 @autoreleasepool{prewarmIdleRun(*lines);}
 delete lines;
 return nullptr;
}
// At device creation: read the records (they also seed the "seen" set) and start the prewarm.
static void prewarmStart(const char *cache) {
 if(!cache)return;
 gPrewarmDir=cache;
 if(!prewarmOn())return;
 std::vector<std::string> lines;
 if(FILE *f=fopen((gPrewarmDir+"/prewarm.v1").c_str(),"r")) {
  std::string line;int c;
  while((c=fgetc(f))!=EOF) {
   if(c!='\n'){line+=(char)c;continue;}
   if(!line.empty()){std::lock_guard<std::mutex> lock(gPrewarmLock);if(gPrewarmSeen.emplace(line,true).second)lines.push_back(line);}
   line.clear();
  }
  fclose(f);
 }
 if(prewarmMode()==2) {   // G6: idle priming
  if(!strcmp(getprogname(),"backboardd") && !gPrimeBusyOut)gPrimeBusyOut=primeBusyMap(true);
  if(lines.empty()){sm2_logs("native-metal: PR prime: no records yet");return;}
  sm2_logs([NSString stringWithFormat:@"native-metal: PR prime: %zu records, idle priming in %u s",lines.size(),prewarmKnob("SWEET_PREWARM_DELAY_S",90)].UTF8String);
  pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
  pthread_attr_set_qos_class_np(&attr,QOS_CLASS_BACKGROUND,0);
  pthread_t thread;auto *copy=new std::vector<std::string>(std::move(lines));
  if(pthread_create(&thread,&attr,prewarmIdleThread,copy)!=0){delete copy;sm2_logs("native-metal: PR prime: no thread");}
  pthread_attr_destroy(&attr);
  return;
 }
 if(lines.empty()){sm2_logs("native-metal: prewarm: no records yet");return;}
 sm2_logs([NSString stringWithFormat:@"native-metal: prewarm: %zu records, starting",lines.size()].UTF8String);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{prewarmRun(lines);}});
}
// The pixel formats textures were asked for (first eight distinct), with how many were refused: native_bridge_metal_formats.
static uint32_t gFormats[8];static unsigned gFormatCount;static std::atomic<uint64_t> gTextureRefusals;
static void noteFormat(uint32_t format,bool made) {
 std::lock_guard<std::mutex> lock(gProblemLock);
 if(!made)gTextureRefusals++;
 for(unsigned i=0;i<gFormatCount;i++)if(gFormats[i]==format)return;
 if(gFormatCount<8)gFormats[gFormatCount++]=format;
}
static NSError *nbError(NSString *why) {
 return [NSError errorWithDomain:@"org.blu-sharky.native-metal" code:-1 userInfo:@{NSLocalizedDescriptionKey:why?:@"refused"}];
}
static NSString *lastError() {return [NSString stringWithUTF8String:nmb_last_error()];}
// The render pipeline journal: one line per render pipeline creation (when, on which thread, how long, the outcome, both functions with
// every constant value, the attachments, blending and vertex descriptor) appended to pipelines.log in the runtime's cache directory, which
// the board log exports with the caches (CacheExport.h): every pipeline a boot made, or was refused, can be made again on the host.
static std::mutex gJournalLock;
static std::string gJournalPath;
static uint64_t gJournalBegan;
static void journal(const std::string &line) {
 if(gJournalPath.empty())return;
 std::lock_guard<std::mutex> lock(gJournalLock);
 if(FILE *f=fopen(gJournalPath.c_str(),"a")){fwrite(line.data(),1,line.size(),f);fputc('\n',f);fclose(f);}
}

@interface NBObject : NSObject
@property(atomic,copy) NSString *label;
@end
@implementation NBObject
- (id<MTLDevice>)device {return gDeviceObject;}
// Metal SPI (Metal Performance Shaders asks every encoder and command buffer): an identity for its traces.
- (uint64_t)globalTraceObjectID {return (uint64_t)(uintptr_t)self;}
- (void)doesNotRecognizeSelector:(SEL)selector {
 if(gMissing)gMissing(class_getName(object_getClass(self)),sel_getName(selector));
 noteProblem([NSString stringWithFormat:@"missing %s %s",class_getName(object_getClass(self)),sel_getName(selector)]);
 [super doesNotRecognizeSelector:selector];
}
// SweetMetal2 (C1): an object that conforms to one of Metal's protocols (MTLFunction, MTLSamplerState, ... added at device open) may be
// sent any selector the protocol, or Metal's private twin of it (NAME + "SPI"), declares. One this file does not implement is answered
// 0/nil with the protocol's type encoding, logged once (MISSING line), instead of raising in the render server; any other selector still
// reaches doesNotRecognizeSelector: as before.
static const char *declaredTypes(Class cls,SEL selector) {
 for(Class c=cls;c;c=class_getSuperclass(c)) {
  unsigned count=0;Protocol *__unsafe_unretained *list=class_copyProtocolList(c,&count);
  for(unsigned i=0;i<count;i++) {
   Protocol *candidates[2]={list[i],objc_getProtocol([NSString stringWithFormat:@"%s%s",protocol_getName(list[i]),"SPI"].UTF8String)};
   for(Protocol *p:candidates)for(int required=1;p && required>=0;required--) {
    struct objc_method_description d=protocol_getMethodDescription(p,selector,required,YES);
    if(d.types){free(list);return d.types;}
   }
  }
  free(list);
 }
 return nullptr;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
 if(NSMethodSignature *own=[super methodSignatureForSelector:selector])return own;
 const char *types=declaredTypes(object_getClass(self),selector);
 return types?[NSMethodSignature signatureWithObjCTypes:types]:nil;
}
- (void)forwardInvocation:(NSInvocation *)invocation {
 if(gMissing)gMissing(class_getName(object_getClass(self)),[NSString stringWithFormat:@"%s (answered 0: declared by a Metal protocol)",sel_getName(invocation.selector)].UTF8String);
 const NSUInteger length=invocation.methodSignature.methodReturnLength;
 if(length){std::vector<uint8_t> zero(length,0);[invocation setReturnValue:zero.data()];}
}
@end

// ---- resources ----
// The wait takes a strong snapshot of already-committed buffers; new commits require the
// caller's usual resource synchronization. Storage dependency checks are in the runtime.
static NSMutableSet *gInFlight;
static void waitForResource(id resource);
// Resource SPI the runtime has no state for: no protected content (Metal's default options), and no owner transfer
// (memory attribution is the kernel driver's, by the importing task), refused as not supported.
#define NB_RESOURCE_SPI \
- (uint64_t)protectionOptions {return 0;} \
- (id<MTLHeap>)heap {return _parentHeap;} \
- (BOOL)isAliasable {return NO;} \
- (int)setOwnerWithIdentity:(unsigned)identity {(void)identity;return 46; /* KERN_NOT_SUPPORTED */} \
- (void)waitUntilComplete {waitForResource(self);}
@interface NBBuffer : NBObject
@property(nonatomic) NmbBuffer *handle;
@property(nonatomic) MTLResourceOptions options;
@property(nonatomic,copy) void (^deallocator)(void *,NSUInteger);
@property(nonatomic) void *wrapped;
@property(nonatomic) IOSurfaceRef surfaceOwner; // keeps a shared import's CPU mapping alive
@property(nonatomic,strong) id<MTLHeap> parentHeap;   // the heap that made the buffer, nil otherwise
@property(nonatomic) NSUInteger heapOffset;
@end
@interface NBTexture : NBObject {
@public
 std::atomic<uint32_t> encReplaceEpoch;   // u-encthread: replaceRegion calls (a recorded setTexture's shadow seed is stale past one)
}
@property(nonatomic) NmbTexture *handle;
@property(nonatomic) NmbTextureDescriptor descriptor;
@property(nonatomic,strong) NBBuffer *buffer;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic) NSUInteger offset,rowBytes,plane;
@property(nonatomic) uint64_t reportedFormat;   // non-zero: the format the client asked for (a converted copy's)
@property(nonatomic) uint32_t surfaceSeed;      // a converted copy's: the surface's seed when it was filled
@property(nonatomic) IOSurfaceRef ycbcrSource;   // a converted copy's surface (retained); not `surface`: the copy is no surface memory
@property(nonatomic,strong) NSMutableArray *turns; // a converted copy's pictures (textures over buffers of their own, up to 3): the one
                                                   // bound is borrowed from one of them, filled while the others may still be sampled
@property(nonatomic) bool borrowedHandle;        // `handle` is a turn's: not released here
@property(nonatomic,strong) NBTexture *readyTurn; // a converted copy's newest completed picture not bound yet
@property(nonatomic) uint32_t readySeed,fillSeed; // its surface seed, and the seed of the fill under way
@property(nonatomic) bool filling;               // a fill runs on the worker
@property(nonatomic) const void *lastCommandBuffer; // the command buffer that last bound it (identity only)
@property(nonatomic) NmbTexture *previousHandle; // the picture bound before the current one (its command buffer may not be committed)
@property(nonatomic) bool ycbcrGPU;              // a two-plane YCbCr texture the runtime converts (its planes' generation set at use)
@property(nonatomic) bool ycbcr709;              // a converted copy's matrix: BT.709 (else BT.601), read when it was made
@property(nonatomic,strong) id<MTLTexture> parent;
@property(nonatomic,strong) id<MTLHeap> parentHeap;
@property(nonatomic) NSUInteger heapOffset;
@property(nonatomic) uint64_t rotationValue;      // SweetMetal2: a rotated framebuffer's rotation (1-4), 0 otherwise
@property(nonatomic) bool framebufferOnlyValue;
- (void)holdSurface:(IOSurfaceRef)surface;
@end
static void ycbcrRefresh(NBTexture *texture,id commandBuffer);
static uint64_t linearAlignment();
// C4: the device's linear pitch for `format` x `width` rounded up to linearAlignment() (64: Turnip's explicit-layout pitch).
static uint64_t sweetLinearRow(uint64_t format,uint64_t width);
static void surfaceHold(IOSurfaceRef surface);
static void surfaceDrop(IOSurfaceRef surface);
@implementation NBBuffer
- (void)dealloc {
 const NSUInteger length=nmb_buffer_length(_handle);nmb_buffer_release(_handle);
 if(_deallocator)_deallocator(_wrapped,length);
 if(_surfaceOwner)CFRelease(_surfaceOwner);
}
- (NSUInteger)length {return nmb_buffer_length(_handle);}
- (void *)contents {return nmb_buffer_contents(_handle);}
- (uint64_t)gpuAddress {return nmb_buffer_gpu_address(_handle);}
- (MTLResourceOptions)resourceOptions {return _options;}
- (MTLStorageMode)storageMode {return (MTLStorageMode)((_options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift);}
- (MTLCPUCacheMode)cpuCacheMode {return (MTLCPUCacheMode)((_options&MTLResourceCPUCacheModeMask)>>MTLResourceCPUCacheModeShift);}
- (MTLHazardTrackingMode)hazardTrackingMode {return (MTLHazardTrackingMode)((_options&MTLResourceHazardTrackingModeMask)>>MTLResourceHazardTrackingModeShift);}
- (void)didModifyRange:(NSRange)range {(void)range;}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
 if(state!=MTLPurgeableStateKeepCurrent && encThreadOn())encFlush(EF_PURGEABLE);   // u-encthread: recorded uses replayed first
 const uint64_t answer=nmb_buffer_set_purgeable_state(_handle,state);
 if(!answer)NBLOG(@"native-metal: buffer setPurgeableState refused: %@",lastError());
 return (MTLPurgeableState)answer;
}
- (NSUInteger)allocatedSize {return nmb_buffer_length(_handle);}
- (IOSurfaceRef)iosurface {return nullptr;}   // a buffer is never the backing of a surface here (surfaces back textures)
NB_RESOURCE_SPI
@end
// Reuse only an import still held by a texture/view or pending command. Weak
// values never extend a GPU allocation's lifetime. The strong buffer snapshot
// and its retained surface prevent object/address reuse during a hit. A new
// mapping, allocation identity or size needs a separate import; ordinary
// caller-owned no-copy buffers do not enter this cache.
static NSMapTable<NSValue *,NBBuffer *> *gSurfaceImports;
static std::mutex gSurfaceImportLock;
static NBBuffer *surfaceBuffer(IOSurfaceRef surface,void *base,size_t bytes) {
 struct Key {uint64_t identity,address,bytes;};
 const Key value={IOSurfaceGetID(surface),(uintptr_t)base,bytes};
 NSValue *key=value.identity?[NSValue valueWithBytes:&value objCType:@encode(Key)]:nil;
 std::lock_guard<std::mutex> lock(gSurfaceImportLock);
 if(!gSurfaceImports)gSurfaceImports=[NSMapTable strongToWeakObjectsMapTable];
 NBBuffer *buffer=key?[gSurfaceImports objectForKey:key]:nil;
 if(buffer)return buffer;
 NmbBuffer *handle=nmb_buffer_new_no_copy(gDevice,base,bytes,MTLResourceStorageModeShared);
 if(!handle){NBLOG(@"native-metal: surface import refused: %@",lastError());return nil;}
 buffer=[NBBuffer new];buffer.handle=handle;buffer.options=MTLResourceStorageModeShared;
 buffer.surfaceOwner=(IOSurfaceRef)CFRetain(surface);
 if(key) {
  // Bound metadata without retaining old frames. Evicting an association is
  // harmless: its owners still retain the actual import until their own end.
  if(gSurfaceImports.count>=256) {
   for(NSValue *old in gSurfaceImports.keyEnumerator.allObjects)
    if(![gSurfaceImports objectForKey:old])[gSurfaceImports removeObjectForKey:old];
   if(gSurfaceImports.count>=256)[gSurfaceImports removeObjectForKey:gSurfaceImports.keyEnumerator.nextObject];
  }
  [gSurfaceImports setObject:buffer forKey:key];
 }
 return buffer;
}
// Core Animation's extended-range "deep" layers (b3a8 surfaces: BGRA plane + A8 plane) are asked for as
// MTLPixelFormatRGB10A8_2P_XR10(_sRGB), 550/551, which Turnip has no format for: Camera.app's preview area
// (1125x1500) and some of its controls failed ("Failed to allocate [1125 x 1500] b3a8 framebuffer"). They are made
// BGRA8Unorm(_sRGB) over the BGRA plane, the same in every texture, view and pipeline, so the only loss is the range
// beyond 0..1 and the separate alpha plane.
// (C2 note: what is lost is the range above 1.0 and the A8 plane's alpha, which reads 1. metal2vulkan 720ef1ce can hold 550/551 over
// a b3a8 surface's two planes itself (texture/surface_two_planes.rs: an R32G32_UINT image and a shadow of both planes) given the
// surface's facts, which nmb_texture_new_on_surface now passes; not used: every such layer would be copied in and out per pass, and
// backboardd's framebuffer stays 8-bit (supportsExtendedXR10Formats answers no there).)
static uint64_t sweetFormat(uint64_t format) {return format==550?80:format==551?81:format;}
// SweetMetal2: the descriptor's SPI rotation (0-4) and framebufferOnly (iOS 16's MTLTextureDescriptor has both getters), 0/NO where absent.
static uint64_t descriptorRotation(MTLTextureDescriptor *d) {
 static SEL sel=sel_registerName("rotation");
 if(!d || ![d respondsToSelector:sel])return 0;
 return (uint64_t)((NSUInteger(*)(id,SEL))objc_msgSend)(d,sel);
}
static bool descriptorFramebufferOnly(MTLTextureDescriptor *d) {
 static SEL sel=sel_registerName("framebufferOnly");
 if(!d || ![d respondsToSelector:sel])return false;
 return ((BOOL(*)(id,SEL))objc_msgSend)(d,sel);
}
static bool textureDescriptor(MTLTextureDescriptor *d,NmbTextureDescriptor *out) {
 if(!d)return false;
 *out={(uint64_t)d.textureType,sweetFormat((uint64_t)d.pixelFormat),d.width,d.height,d.depth,d.mipmapLevelCount,d.sampleCount,d.arrayLength,(uint64_t)d.usage,(uint64_t)d.resourceOptions};
 return true;
}
@implementation NBTexture
- (void)dealloc {
 if(!_borrowedHandle)nmb_texture_release(_handle);
 if(_surface){surfaceDrop(_surface);CFRelease(_surface);}
 if(_ycbcrSource)CFRelease(_ycbcrSource);
}
// The surface whose memory this texture is (retained; its cache state is kept while any texture holds it: flushSurfaces).
- (void)holdSurface:(IOSurfaceRef)surface {
 if(!surface || _surface)return;
 _surface=(IOSurfaceRef)CFRetain(surface);surfaceHold(_surface);
}
- (MTLTextureType)textureType {return (MTLTextureType)_descriptor.type;}
- (MTLPixelFormat)pixelFormat {return (MTLPixelFormat)(_reportedFormat?_reportedFormat:_descriptor.format);}
- (NSUInteger)width {return _descriptor.width;}
- (NSUInteger)height {return _descriptor.height;}
- (NSUInteger)depth {return _descriptor.depth;}
- (NSUInteger)mipmapLevelCount {return _descriptor.levels;}
- (NSUInteger)sampleCount {return _descriptor.samples;}
- (NSUInteger)arrayLength {return _descriptor.array_length;}
- (MTLTextureUsage)usage {return (MTLTextureUsage)_descriptor.usage;}
- (MTLResourceOptions)resourceOptions {return (MTLResourceOptions)_descriptor.options;}
- (MTLStorageMode)storageMode {return (MTLStorageMode)((_descriptor.options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift);}
- (MTLCPUCacheMode)cpuCacheMode {return (MTLCPUCacheMode)((_descriptor.options&MTLResourceCPUCacheModeMask)>>MTLResourceCPUCacheModeShift);}
- (BOOL)isFramebufferOnly {return _framebufferOnlyValue;}
- (IOSurfaceRef)iosurface {return _surface?_surface:_ycbcrSource;}
- (NSUInteger)iosurfacePlane {return _plane;}
- (id<MTLBuffer>)buffer {return _surface || _reportedFormat?nil:(id<MTLBuffer>)_buffer;}
- (NSUInteger)bufferOffset {return _offset;}
- (NSUInteger)bufferBytesPerRow {return _rowBytes;}
- (id<MTLTexture>)parentTexture {return _parent;}
- (NSUInteger)rotation {return (NSUInteger)_rotationValue;}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
 if(state!=MTLPurgeableStateKeepCurrent && encThreadOn())encFlush(EF_PURGEABLE);   // u-encthread: recorded uses replayed first
 const uint64_t answer=nmb_texture_set_purgeable_state(_handle,state);
 if(!answer)NBLOG(@"native-metal: texture setPurgeableState refused: %@",lastError());
 return (MTLPurgeableState)answer;
}
NB_RESOURCE_SPI
- (id<MTLTexture>)view:(NmbTexture *)handle {ENC_SCOPE(EC_TEX,"newTextureView");
 if(!handle){NBLOG(@"native-metal: texture view refused: %@",lastError());return nil;}
 NBTexture *view=[NBTexture new];view.handle=handle;NmbTextureDescriptor descriptor;nmb_texture_describe(handle,&descriptor);view.descriptor=descriptor;
 view.parent=(id<MTLTexture>)self;view.buffer=_buffer;view.offset=_offset;view.rowBytes=_rowBytes;
 [view holdSurface:_surface];view.ycbcrGPU=_ycbcrGPU;
 return (id<MTLTexture>)view;
}
// A view of a GPU-converted YCbCr texture in another format (CA's 501 view of a 500 texture: Metal's sRGB twin, which reads the
// colour linearised) is refused as it was for the CPU copy, whose RGBA8 texture has no such view: on r19a the preview drawn through
// the runtime's sRGB twin came out washed out, through the plain texture (the CPU copy's case) right. /var/local/mtl2-env
// SWEET_YCBCR_VIEWS=1 makes them.
- (bool)refusesView:(MTLPixelFormat)format {
 if(!_ycbcrGPU || (uint64_t)format==_descriptor.format)return false;
 static int allow=-1;if(allow<0){const char *e=getenv("SWEET_YCBCR_VIEWS");allow=e && *e=='1';}
 if(allow)return false;
 static std::atomic<bool> logged{false};
 if(!logged.exchange(true))NBLOG(@"native-metal: view of a YCbCr texture (%llu) as %lu refused (SWEET_YCBCR_VIEWS=1 makes it)",
                                 (unsigned long long)_descriptor.format,(unsigned long)format);
 return true;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format {
 if([self refusesView:format])return nil;
 return [self view:nmb_texture_new_view(_handle,sweetFormat(format),0,nullptr,nullptr,true)];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices {
 if([self refusesView:format])return nil;
 const uint64_t l[2]={levels.location,levels.length},s[2]={slices.location,slices.length};
 return [self view:nmb_texture_new_view(_handle,sweetFormat(format),type,l,s,false)];
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image {ENC_SCOPE(EC_UPLOAD,"replaceRegion");if(encStatOn())snprintf(tEncDetail,sizeof tEncDetail,"%lux%lu of %lux%lu fmt %lu",(unsigned long)r.size.width,(unsigned long)r.size.height,(unsigned long)self.width,(unsigned long)self.height,(unsigned long)self.pixelFormat);
 if(encThreadOn()) {   // u-encthread: a recorded bind of this texture not replayed yet must not take the old shadow seed
  encReplaceEpoch.fetch_add(1);
  static const bool flushFirst=[]{const char *e=getenv("SWEET_ENCTHREAD_REPLACE");return e && *e=='1';}();
  const int64_t live=gLiveEncReplace.load(std::memory_order_relaxed);   // u-combo: live knob
  if(live>=0?live==1:flushFirst)encFlush(EF_REPLACE);
 }
 const uint64_t region[6]={r.origin.x,r.origin.y,r.origin.z,r.size.width,r.size.height,r.size.depth};
 const uint64_t length=(r.size.depth>1?image*(r.size.depth-1):0)+row*r.size.height;
 if(!nmb_texture_replace(_handle,region,level,slice,bytes,row,image,length))NBLOG(@"native-metal: replaceRegion refused: %@",lastError());
 if(shadowSeedOn() && self.surface)nmb_texture_set_bytes_generation(_handle,0);   // u-f: bytes changed with no seed
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row {
 [self replaceRegion:r mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:row bytesPerImage:row*r.size.height];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {ENC_SCOPE(EC_UPLOAD,"getBytes");
 if(encThreadOn())encFlush(EF_GETBYTES);   // u-encthread: what was committed is in the bridge before the CPU reads
 const uint64_t region[6]={r.origin.x,r.origin.y,r.origin.z,r.size.width,r.size.height,r.size.depth};
 const uint64_t length=(r.size.depth>1?image*(r.size.depth-1):0)+row*r.size.height;
 if(!nmb_texture_get_bytes(_handle,bytes,row,image,length,region,level,slice))NBLOG(@"native-metal: getBytes refused: %@",lastError());
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level {
 [self getBytes:bytes bytesPerRow:row bytesPerImage:row*r.size.height fromRegion:r mipmapLevel:level slice:0];
}
@end
// SweetMetal2 (C3): the A620 does not snoop the CPU's caches, so an IOSurface the GPU uses is cleaned (dc civac) before its
// command buffer runs and, where the GPU wrote it, cleaned and invalidated again once it completed. Before, every surface of
// every command buffer was flushed twice (the 11 MB CA frame and each camera picture included). Now:
// - at commit a surface is cleaned only if its seed (IOSurface's, moved on by every write unlock: the CPU wrote it) differs from
//   the seed at this process's last clean of it, or it was never cleaned here;
// - at completion only the surfaces the command buffer wrote (attachments, blit destinations, shader-writable textures) are
//   flushed, and their seed recorded.
// A CPU writer that writes without a lock is not seen: /var/local/mtl2-env SWEET_FLUSH=all restores the old flushes.
// The state lives while a texture holds the surface (surfaceHold/surfaceDrop), keyed by the IOSurfaceRef it retains.
struct SurfaceState {uint32_t seed=0;bool known=false;uint32_t refs=0;};
static std::mutex gSurfaceStateLock;
static std::unordered_map<const void *,SurfaceState> gSurfaceStates;
static std::atomic<uint64_t> gSurfaceCleanSkips,gSurfaceInvalidates;
static bool flushAll() {
 static int all=-1;
 if(all<0){const char *e=getenv("SWEET_FLUSH");all=e && !strcmp(e,"all");}
 return all>0;
}
static void surfaceHold(IOSurfaceRef surface) {std::lock_guard<std::mutex> l(gSurfaceStateLock);gSurfaceStates[surface].refs++;}
static void surfaceDrop(IOSurfaceRef surface) {
 std::lock_guard<std::mutex> l(gSurfaceStateLock);
 auto it=gSurfaceStates.find(surface);
 if(it!=gSurfaceStates.end() && --it->second.refs==0)gSurfaceStates.erase(it);
}
// completion: false at commit (clean what the CPU wrote since), true at completion (flush what the GPU wrote: `surfaces` holds those).
// u-f (r36): SWEET_SHADOW_SEED=1 (off by default). The runtime skips a surface texture's shadow copy in while its image holds the
// bytes of the seed the texture is bound at (bridge patch 0107): setTexture gives it the seed + 1, replaceRegion 0. As the GPU's
// writes of surfaces complete, their seeds are moved on (a lock/unlock pair), so another process's shadow of them copies in again; the
// clean-flush state takes the new seed (the bytes were just invalidated).
static void bumpWrittenSeeds(NSSet *surfaces);
static void flushSurfaces(NSSet *surfaces,bool completion) {
 if(!surfaces.count)return;
 const bool all=flushAll();
 std::vector<IOSurfaceRef> distinct;
 distinct.reserve(surfaces.count);
 std::vector<IOSurfaceRef> rotated;   // rotfb4: surfaces under a rotated texture, whose CPU writes the runtime must copy in again
 for(NBTexture *texture in surfaces)if(texture.surface){distinct.push_back(texture.surface);if(texture.rotationValue)rotated.push_back(texture.surface);}
 std::sort(distinct.begin(),distinct.end());
 const auto last=std::unique(distinct.begin(),distinct.end());
 gSurfaceFlushDuplicates+=(uint64_t)(distinct.end()-last);
 for(auto it=distinct.begin();it!=last;++it) {
  IOSurfaceRef surface=*it;
  const uint32_t seed=IOSurfaceGetSeed(surface);   // read before the flush: a write after it moves the seed on again
  if(!completion && !all) {
   std::lock_guard<std::mutex> l(gSurfaceStateLock);
   auto state=gSurfaceStates.find(surface);
   if(state!=gSurfaceStates.end() && state->second.known && state->second.seed==seed){gSurfaceCleanSkips++;continue;}
  }
  if(!completion && std::find(rotated.begin(),rotated.end(),surface)!=rotated.end())nmb_rotated_planes_written();
  const uint64_t began=nowUs();const size_t bytes=IOSurfaceGetAllocSize(surface);
  sys_dcache_flush(IOSurfaceGetBaseAddress(surface),bytes);
  gSurfaceFlushBytes+=bytes;gTimeSurfaceFlush.add(began);
  if(completion)gSurfaceInvalidates++;
  std::lock_guard<std::mutex> l(gSurfaceStateLock);
  auto state=gSurfaceStates.find(surface);
  if(state!=gSurfaceStates.end()){state->second.seed=seed;state->second.known=true;}
 }
}
static void bumpWrittenSeeds(NSSet *surfaces) {
 if(!surfaces.count)return;
 std::vector<IOSurfaceRef> distinct;
 for(NBTexture *texture in surfaces)if(texture.surface)distinct.push_back(texture.surface);
 std::sort(distinct.begin(),distinct.end());
 distinct.erase(std::unique(distinct.begin(),distinct.end()),distinct.end());
 for(IOSurfaceRef surface:distinct) {
  uint32_t seed=0;
  if(IOSurfaceLock(surface,0,&seed)!=0)continue;
  IOSurfaceUnlock(surface,0,&seed);
  seed=IOSurfaceGetSeed(surface);
  std::lock_guard<std::mutex> l(gSurfaceStateLock);
  auto state=gSurfaceStates.find(surface);
  if(state!=gSurfaceStates.end() && state->second.known)state->second.seed=seed;
 }
}
// Whether a texture bound to a shader may be written by it (a storage texture): such a surface is flushed at completion too.
static bool shaderWritable(NBTexture *texture) {return (texture.descriptor.usage&MTLTextureUsageShaderWrite)!=0;}
// C4: a texture over memory (a buffer, a surface) whose rows are not 64-byte multiples is one Turnip refuses as an explicit layout
// (the runtime then keeps an image of its own and copies): the first 24 kinds (format, row mod 64, what) are logged, so the makers
// left can be found.
static void noteUnalignedRow(uint64_t format,uint64_t width,uint64_t row,const char *what) {
 if(!(row%64))return;
 static std::mutex lock;static std::vector<uint64_t> seen;
 const uint64_t key=(format<<16)^((row%64)<<8)^(uint64_t)what[0];
 {std::lock_guard<std::mutex> l(lock);if(seen.size()>=24 || std::find(seen.begin(),seen.end(),key)!=seen.end())return;seen.push_back(key);}
 sm2_logs([NSString stringWithFormat:@"native-metal: %s texture fmt %llu width %llu over rows of %llu bytes (not 64-byte multiples: Turnip copies it)",
           what,(unsigned long long)format,(unsigned long long)width,(unsigned long long)row].UTF8String);
}
static NBTexture *textureOnBuffer(NBBuffer *buffer,MTLTextureDescriptor *d,NSUInteger offset,NSUInteger row,bool surface) {
 NmbTextureDescriptor descriptor;if(!buffer || !textureDescriptor(d,&descriptor))return nil;
 if(d.textureType!=MTLTextureTypeTextureBuffer)noteUnalignedRow(descriptor.format,descriptor.width,row,surface?"surface":"buffer");
 NmbTexture *handle=nmb_texture_new_on_buffer(buffer.handle,&descriptor,offset,row,surface);
 if(!handle){NBLOG(@"native-metal: texture over buffer refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.buffer=buffer;texture.offset=offset;texture.rowBytes=row;return texture;
}
@implementation NBBuffer (Textures)
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)row {ENC_SCOPE(EC_TEX,"newTexture(buffer)");
 return (id<MTLTexture>)textureOnBuffer(self,d,offset,row,false);
}
- (id<MTLTexture>)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image {ENC_SCOPE(EC_TEX,"newTexture(linear)");
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor))return nil;
 noteUnalignedRow(descriptor.format,descriptor.width,row,"linear");
 NmbTexture *handle=nmb_texture_new_linear(self.handle,&descriptor,offset,row,image);
 if(!handle){NBLOG(@"native-metal: linear texture refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.buffer=self;texture.offset=offset;texture.rowBytes=row;return (id<MTLTexture>)texture;
}
@end

// ---- libraries, functions, states ----
@interface NBLibrary : NBObject
@property(nonatomic) NmbLibrary *handle;
@property(nonatomic) std::string prewarmDigest;   // u-e: its bytes' digest (prewarm records), "" where prewarm is off
@end
@interface NBFunction : NBObject
@property(nonatomic) NmbFunction *handle;
@property(nonatomic,copy) NSString *name;
@property(nonatomic) MTLFunctionType functionType;
@property(nonatomic) std::string constantsText;   // name:type:hex of each constant value it was specialized with (the journal's)
@property(nonatomic) std::string prewarmKey;      // u-e: library digest, name and constants (prewarm records), "" where prewarm is off
@end
// SweetMetal2 (C1): iOS 16.7 Metal checks a pipeline descriptor's functions against the MTLFunction protocol and NSLogs
// "vertexFunction is not a MTLFunction." / "fragmentFunction is not a MTLFunction." on a miss (r18g: 450 lines from backboardd,
// one per function of each pipeline Core Animation made). NBFunction now conforms (native_bridge_metal_open adds the protocol, as
// for MTLTextureImplementation) and answers the whole public protocol: no reflection is offered (no vertex/stage-input attributes,
// no function constants named), which is what a Metal function built without reflection answers. Any other selector Metal's own
// function protocols declare is answered 0/nil (logged once each) rather than raising, so a validation path that the conformance
// newly opens cannot take backboardd down.
@implementation NBFunction
- (void)dealloc {nmb_function_release(_handle);}
- (MTLFunctionOptions)options {return MTLFunctionOptionNone;}
- (MTLPatchType)patchType {return MTLPatchTypeNone;}
- (NSInteger)patchControlPointCount {return 0;}
- (NSArray *)vertexAttributes {return @[];}
- (NSArray *)stageInputAttributes {return @[];}
- (NSDictionary *)functionConstantsDictionary {return @{};}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)index {
 if(gMissing)gMissing("NBFunction","newArgumentEncoderWithBufferIndex: (argument buffers)");
 (void)index;return nil;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)index reflection:(MTLAutoreleasedArgument *)reflection {
 if(reflection)*reflection=nil;
 return [self newArgumentEncoderWithBufferIndex:index];
}
@end
// The target's own accessors of MTLFunctionConstantValues (as the offline frontend reads them); their ABI is checked before any call.
@interface MTLFunctionConstantValues (NBOriginalConstantAccess)
- (NSArray *)newIndexedConstantArray;
- (NSArray *)newNamedConstantArray;
@end
@protocol NBOriginalConstantValue
- (NSUInteger)dataType;
- (void *)data;
- (NSUInteger)index;
- (NSString *)name;
@end
static bool methodABI(id object,SEL selector,const char *encoding) {
 Method method=class_getInstanceMethod(object_getClass(object),selector);
 return method && !strcmp(method_getTypeEncoding(method),encoding);
}
// Bytes of a function constant of MTLDataType `type`: lanes packed tightly, as metal2vulkan takes them (its CLI: bool3 = 3 bytes).
// 3-wide vectors added for iOS 16, whose QuartzCore specialises fixed_frag with uchar3 fc_color_opcodes0/1 (MTLDataTypeUChar3).
static uint64_t constantBytes(uint64_t type) {
 switch(type) {
  case 5:case 31:case 35:return 12;	/* float3, int3, uint3 */
  case 18:case 39:case 43:return 6;	/* half3, short3, ushort3 */
  case 47:case 51:case 55:return 3;	/* char3, uchar3, bool3 */
  case 83:case 87:return 24;		/* long3, ulong3 */
  case 3:case 29:case 33:return 4;
  case 4:case 30:case 34:return 8;
  case 6:case 32:case 36:return 16;
  case 16:case 37:case 41:return 2;
  case 17:case 38:case 42:return 4;
  case 19:case 40:case 44:return 8;
  case 45:case 49:case 53:return 1;
  case 46:case 50:case 54:return 2;
  case 48:case 52:case 56:return 4;
  case 81:case 85:return 8;
  case 82:case 86:return 16;
  case 84:case 88:return 32;
  default:return 0;
 }
}
static std::string quartzCoreCallers();
@implementation NBLibrary
- (void)dealloc {nmb_library_release(_handle);}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error {ENC_SCOPE(EC_PIPE,"newFunction(constants)");if(encStatOn())snprintf(tEncDetail,sizeof tEncDetail,"%s",name.UTF8String?:"?");
 if(!name || !values || !methodABI(values,@selector(newIndexedConstantArray),"@16@0:8") || !methodABI(values,@selector(newNamedConstantArray),"@16@0:8")) {
  NBLOG(@"native-metal: %@: unqualified function constant values (%s)",name,values?object_getClassName(values):"nil");
  if(error)*error=nbError(@"unqualified function constant values");return nil;
 }
 MTLFunctionConstantValues *snapshot=[values copy];
 NSArray *indexed=[snapshot newIndexedConstantArray],*named=[snapshot newNamedConstantArray];
 std::vector<NmbConstant> constants;
 for(unsigned group=0;group<2;group++)for(id value in (group?named:indexed)) {
  if(!methodABI(value,@selector(dataType),"Q16@0:8") || !methodABI(value,@selector(data),"^v16@0:8") ||
     !methodABI(value,group?@selector(name):@selector(index),group?"@16@0:8":"Q16@0:8")) {
   NBLOG(@"native-metal: %@: unqualified constant value ABI (%s)",name,object_getClassName(value));
   if(error)*error=nbError(@"unqualified constant value ABI");return nil;
  }
  id<NBOriginalConstantValue> v=value;
  const uint64_t bytes=constantBytes(v.dataType);
  if(!bytes || !v.data){NBLOG(@"native-metal: %@: constant type %lu is not qualified",name,(unsigned long)v.dataType);
   if(error)*error=nbError([NSString stringWithFormat:@"constant type %lu is not qualified",(unsigned long)v.dataType]);return nil;}
  constants.push_back({v.dataType,group?0:v.index,group?v.name.UTF8String:nullptr,v.data,bytes});
 }
 std::string text;
 for(const NmbConstant &c:constants) {
  char head[32];if(!c.name)snprintf(head,sizeof head,"#%llu",(unsigned long long)c.index);
  text+=text.empty()?"":" ";text+=c.name?c.name:head;snprintf(head,sizeof head,":%llu:",(unsigned long long)c.type);text+=head;
  for(uint64_t i=0;i<c.length;i++){snprintf(head,sizeof head,"%02x",((const uint8_t *)c.bytes)[i]);text+=head;}
 }
 const uint64_t functionBegan=nowUs();
 NmbFunction *handle=nmb_function_new_specialized(_handle,name.UTF8String,constants.data(),(uint32_t)constants.size());gTimeFunction.add(functionBegan);
 // One S line per specialization (int-155: every QuartzCore pipeline was made on its draw, and a refused generic function would leave its
 // generic pipeline unmade without a word): the function, its constants, the time, the refusal and QuartzCore's callers.
 if(!gJournalPath.empty()) {
  char head[96];snprintf(head,sizeof head,"S t=%llu us=%llu ok=%d name=",(unsigned long long)((functionBegan-gJournalBegan)/1000),
      (unsigned long long)(nowUs()-functionBegan),handle?1:0);
  journal(head+std::string(name.UTF8String?:"?")+" k="+text+(handle?std::string():" err="+std::string(lastError().UTF8String?:"?"))+" | "+quartzCoreCallers());
 }
 if(!handle){
  noteProblem([NSString stringWithFormat:@"specialized function %@: %@",name,lastError()]);
  if(error)*error=nbError([NSString stringWithFormat:@"specialized function: %@",lastError()]);return nil;
 }
 NBFunction *function=[NBFunction new];function.handle=handle;function.name=name;function.functionType=(MTLFunctionType)nmb_function_type(handle);
 function.constantsText=text;function.prewarmKey=prewarmFunctionKey(self.prewarmDigest,name,constants.data(),constants.size(),true);
 if(error)*error=nil;return (id<MTLFunction>)function;
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values completionHandler:(void (^)(id<MTLFunction>,NSError *))handler {
 NSError *error=nil;id<MTLFunction> function=[self newFunctionWithName:name constantValues:values error:&error];
 handler(function,error);
}
- (MTLLibraryType)type {return MTLLibraryTypeExecutable;}
// The descriptor's name and constants; its specialized name only labels Metal's function and its options ask for compile-time work the
// runtime does when the function is made.
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)error {
 if(!d.name){if(error)*error=nbError(@"a function name is required");return nil;}
 if(d.constantValues)return [self newFunctionWithName:d.name constantValues:d.constantValues error:error];
 id<MTLFunction> function=[self newFunctionWithName:d.name];
 if(!function){if(error)*error=nbError([NSString stringWithFormat:@"function %@: %@",d.name,lastError()]);return nil;}
 if(error)*error=nil;return function;
}
- (NSArray<NSString *> *)functionNames {
 NSMutableArray *names=[NSMutableArray array];
 for(uint32_t i=0,n=nmb_library_function_count(_handle);i<n;i++) {
  char name[256];nmb_library_function_name(_handle,i,name,sizeof name);[names addObject:[NSString stringWithUTF8String:name]];
 }
 return names;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {ENC_SCOPE(EC_PIPE,"newFunction");if(encStatOn())snprintf(tEncDetail,sizeof tEncDetail,"%s",name.UTF8String?:"?");
 const uint64_t functionBegan=nowUs();
 NmbFunction *handle=name?nmb_function_new(_handle,name.UTF8String):nullptr;gTimeFunction.add(functionBegan);
 if(!handle)return nil;
 NBFunction *function=[NBFunction new];function.handle=handle;function.name=name;function.functionType=(MTLFunctionType)nmb_function_type(handle);
 function.prewarmKey=prewarmFunctionKey(self.prewarmDigest,name,nullptr,0,false);
 return (id<MTLFunction>)function;
}
@end
@interface NBComputePipeline : NBObject
@property(nonatomic) NmbComputePipeline *handle;
@end
@implementation NBComputePipeline
- (void)dealloc {nmb_compute_pipeline_release(_handle);}
- (NSUInteger)maxTotalThreadsPerThreadgroup {return nmb_compute_pipeline_max_threads(_handle);}
- (NSUInteger)threadExecutionWidth {return nmb_compute_pipeline_execution_width(_handle);}
@end
@interface NBRenderPipeline : NBObject {
@public
 char encNames[80];   // u-e: its vertex + fragment function names, for "E slow" draws
 // ovd (SWEET_DRAWBOX): colour attachment 0's blend and mask, the label's tail, attribute 0 (format, offset, buffer, stride)
 char dbLabel[48];uint8_t dbBlend,dbMask,dbSrc,dbDst,dbSrcA,dbDstA;uint32_t dbFmt,dbOff,dbBuf,dbStride,dbCFmt,dbCOff;   // + the first 4-wide colour-like attribute after 0 (half4/float4/uchar4n)
}
@property(nonatomic) NmbRenderPipeline *handle;
@end
@implementation NBRenderPipeline
- (void)dealloc {nmb_render_pipeline_release(_handle);}
// The threadgroup size a tile dispatch of this pipeline could use: the device's limit (no tile shaders are offered).
- (NSUInteger)maxTotalThreadsPerThreadgroup {
 uint64_t s[3]={};if(!nmb_device_max_threads_per_threadgroup(gDevice,s))return 0;
 return s[0];
}
@end
@interface NBSampler : NBObject
@property(nonatomic) NmbSampler *handle;
@end
@implementation NBSampler
- (void)dealloc {nmb_sampler_release(_handle);}
- (NSUInteger)pixelFormat {return MTLPixelFormatInvalid;}   // SPI: a sampler built from a plain descriptor names no format
@end
@interface NBDepthStencil : NBObject
@property(nonatomic) NmbDepthStencil *handle;
@end
@implementation NBDepthStencil
- (void)dealloc {nmb_depth_stencil_release(_handle);}
@end

// ---- events and fences ----
@interface NBEvent : NBObject
@property(nonatomic) NmbEvent *handle;
@end
@implementation NBEvent
- (void)dealloc {nmb_event_release(_handle);}
@end
@interface NBSharedEvent : NBEvent
@end
static void notified(void *context,uint64_t value);
@implementation NBSharedEvent
- (uint64_t)signaledValue {return nmb_shared_event_value(self.handle);}
- (void)setSignaledValue:(uint64_t)value {nmb_shared_event_set_value(self.handle,value);}
- (BOOL)waitUntilSignaledValue:(uint64_t)value timeoutMS:(uint64_t)milliseconds {return nmb_shared_event_wait(self.handle,value,milliseconds);}
// The block runs on the listener's dispatch queue (Metal's contract); the bridge's listener thread only forwards it there.
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
 if(!block)return;
 dispatch_queue_t queue=listener.dispatchQueue?:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0);
 NSArray *job=@[self,queue,[block copy]];
 if(!nmb_shared_event_notify(self.handle,value,notified,(__bridge_retained void *)job)) {
  (void)(__bridge_transfer NSArray *)(__bridge void *)job;
  NBLOG(@"native-metal: notifyListener refused: %@",lastError());
 }
}
// A handle for another process needs a kernel-backed event this bridge does not have yet: refused, never a handle that could not work.
- (MTLSharedEventHandle *)newSharedEventHandle {
 if(gMissing)gMissing("NBSharedEvent","newSharedEventHandle (cross-process)");
 return nil;
}
@end
static void notified(void *context,uint64_t value) {
 NSArray *job=(__bridge_transfer NSArray *)context;
 id<MTLSharedEvent> event=job[0];MTLSharedEventNotificationBlock block=job[2];
 dispatch_async(job[1],^{block(event,value);});
}
@interface NBFence : NBObject
@property(nonatomic) NmbFence *handle;
@end
@implementation NBFence
- (void)dealloc {nmb_fence_release(_handle);}
@end

// ---- command buffers and encoders ----
@interface NBQueue : NBObject
@property(nonatomic) NmbQueue *handle;
@property(atomic,strong) dispatch_queue_t completionQueue;   // SPI: where command buffers' handlers run (nil: the runtime's thread)
@end
@interface NBCommandBuffer : NBObject {
@public
 EncodedWork encodedWork;   // the command buffer's single encoder thread, not global counter deltas
 uint64_t createdUs;
 // u-t frame timeline (SWEET_TIMELINE, backboardd): CLOCK_MONOTONIC_RAW ns, the runtime's host clock (its GPU and kernel times)
 uint64_t tlCreated,tlFirstEncoder,tlCommit,tlNotice;
 uint32_t tlSurface;   // the frame's framebuffer IOSurface ID (CA's swap chain: how many it cycles through)
 // u-e: the encoding thread's counts at the first encoder (EncScope), its CPU time, CPU, and the runtime's VkPipeline makings then
 EncTLS encStart;uint64_t encCpuStart,encThread,encVkStart[2];int8_t encCpu0;EncFrame encFrame;
 bool tlFrame,tlWaitedCompleted,tlWaitedScheduled;
 uint32_t dbFrame,dbPasses;   // ovd: SWEET_DRAWBOX frame number (0: not logged), passes so far
 // u-encthread: recorded for the worker (SWEET_ENCTHREAD, fixed at creation); the commit was replayed (the bridge has it);
 // and returned (waits may use the bridge's); the recorded encoder not ended yet (kept alive by its recorded creation until its
 // end or discard is replayed)
 bool encDeferred;std::atomic<bool> encCommitStarted,encCommitDone;__unsafe_unretained id encOpen;
 uint64_t encCommitTick;   // g4: the caller's commit (mach ticks), for the submit-lag telemetry
}
@property(nonatomic) NmbCommandBuffer *handle;
@property(nonatomic,strong) NBQueue *queue;
@property(atomic,copy) NSString *encodeFailure;
@property(atomic) BOOL committed,failedLocally;
@property(nonatomic) uint64_t committedUs;
@property(nonatomic) uint32_t commitIndex;
@property(nonatomic) BOOL rotatedFrame;   // rotfb4: a pass of it renders a rotated (landscape framebuffer) texture
@property(nonatomic,strong) NSMutableArray *scheduledHandlers,*completedHandlers;
@property(nonatomic,strong) NSMutableSet *surfaces;          // every surface texture it uses (cleaned at commit if the CPU wrote it)
@property(nonatomic,strong) NSMutableSet *writtenSurfaces;   // those the GPU may write (flushed at completion)
// Runtime handles retain GPU storage, but only the Objective-C owner retains
// a no-copy deallocator, its memory owner and texture/heap ancestry.
@property(nonatomic,strong) NSMutableSet *resourceOwners;
@property(nonatomic,strong) dispatch_group_t handlers;
@property(nonatomic,strong) dispatch_group_t schedulingHandlers;
@property(nonatomic) BOOL schedulingDelivered;
- (void)refuse:(NSString *)what;
- (void)commitSubmit;
@end

// ---- u-encthread: the encode thread (SWEET_ENCTHREAD) ----
// prof (Settings flings): the bridge's draw path (frontend -> metal2vulkan -> Turnip record) is ~46% of CA's display thread, ~70-80 us
// a draw, and it runs inline between CA's own work, so a frame's first GPU submit waits for both. With SWEET_ENCTHREAD=1 (backboardd;
// 2: every process) the render and blit encoders' calls, encoder creation/end, encoded events and commit are recorded by the frontend
// (validation, resource ownership, counters and CA-visible state at the call, as before) into a compact command list, with small
// inline data (setBytes, the pass descriptor, blit regions) copied, and replayed into the bridge in call order by one worker thread
// ("sweet.encthread", user-interactive QoS), which starts while CA still records. Every bridge call on a recorded command buffer or
// its encoders happens on the worker. Ownership: buffers and textures a command names are the command buffer's resourceOwners (as
// today, released at completion); pipeline, sampler, depth/stencil, fence and event objects are retained by their command; an encoder
// is retained by its recorded creation until its end (or discard) is replayed; an event or commit command retains its command buffer.
// Waits (must-flush, the worker catches up with everything recorded so far first): waitUntilScheduled / waitUntilCompleted /
// commitAndWaitUntilSubmitted of a command buffer whose commit is not replayed yet, a resource's waitUntilComplete, getBytes,
// setPurgeableState (not KeepCurrent), a compute encoder on a recorded command buffer (compute stays inline, after the flush),
// SWEET_ENCTHREAD_REPLACE=1 replaceRegion, and over 32768 commands queued (backpressure). Synchronous as before (no flush): every
// creation, query and CPU-visible answer (contents, pixel formats, sizes), replaceRegion (its bytes are written now, as Metal does;
// a bind recorded before it re-copies its surface's shadow), shared event CPU calls. status/error/GPU times answer Committed/none
// until the commit is replayed. A refusal at replay fails the command buffer as before (logged, completed with an error).
// "native-metal: T enc-thread 5s:" (with the timeline) counts it. SWEET_ENCTHREAD_SPIN_US (50): the worker's spin before it sleeps;
// SWEET_ENCTHREAD_PRI (54, CA's display thread's; 0 = user-interactive QoS only): its fixed RR priority.
// SWEET_ENCTHREAD=3 (g4, backboardd): the same, handed over in batches (UniXNU's design; see "g4 mode 3" below).
enum EncOp : uint8_t {EO_RENDER_NEW,EO_BLIT_NEW,EO_END,EO_DISCARD,EO_BUFFER,EO_OFFSET,EO_BYTES,EO_TEXTURE,EO_SAMPLER,EO_FENCE,EO_PIPELINE,
 EO_DSS,EO_VIEWPORT,EO_SCISSOR,EO_RASTER,EO_DEPTH_BIAS,EO_LINE_WIDTH,EO_VISIBILITY,EO_STENCIL_REF,EO_BLEND_COLOR,EO_DRAW,EO_DRAW_INDEXED,
 EO_COPY_BUFFER,EO_FILL_BUFFER,EO_COPY_TEXTURE,EO_BUFFER_TO_TEXTURE,EO_TEXTURE_TO_BUFFER,EO_MIPMAPS,EO_EVENT,EO_COMMIT,EO_COUNT};
enum : uint8_t {ECF_RETAIN_A=1,ECF_NULL_BYTES=2};
// target: the encoder (or, for EO_EVENT/EO_COMMIT, the command buffer, retained); a/b: the objects named; off/len: inline data
struct EncCmd {uint8_t op,stage,flags,mask;uint32_t index;void *target,*a,*b;uint64_t u[6];uint32_t off,len;};
struct EncChunk {std::vector<EncCmd> cmds;std::vector<uint8_t> bytes;uint64_t handTick=0;};   // handTick: g4, mode 3's hand-off
static void encReplay(const EncCmd &c,const uint8_t *bytes);
// g4 (SWEET_ENCTHREAD=3, backboardd only): the same recorded commands, handed to the worker in batches (see "batched" below).
static int encThreadMode() {
 static int mode=-1;
 if(mode<0){const char *e=getenv("SWEET_ENCTHREAD");const int v=e && *e?atoi(e):0;const bool bb=!strcmp(getprogname(),"backboardd");
  mode=v==2 || (v==1 && bb)?1:v==3 && bb?3:0;}
 return mode;
}
static bool encThreadOn() {return encThreadMode()!=0;}
static bool encBatched() {return encThreadMode()==3;}
static os_unfair_lock gEqLock=OS_UNFAIR_LOCK_INIT;
static EncChunk *gEqOpen;                        // what the worker takes next (gEqLock)
static std::vector<EncChunk *> gEqFree;          // replayed chunks for reuse (gEqLock)
static std::atomic<uint64_t> gEqAppended{0},gEqReplayed{0};   // commands recorded / replayed since start
static std::atomic<bool> gEqIdle{false},gEqStarted{false};
static bool gEqBroken;   // the worker could not be started: commands replay at once on the caller
static std::atomic<unsigned> gEqWaiters{0};
static std::mutex gEqSleepLock;static std::condition_variable gEqWake,gEqDone;
static pthread_t gEqThread;
// telemetry (cumulative; the 5 s line takes deltas)
static std::atomic<uint64_t> gEtOps[EO_COUNT],gEtRecordTicks,gEtReplayTicks,gEtBatches,gEtBatchMax,gEtDepthMax,gEtWakes,gEtCommits;
static std::atomic<uint64_t> gEtFlushCalls[EF_WHY_COUNT],gEtFlushWaits[EF_WHY_COUNT],gEtFlushTicks[EF_WHY_COUNT],gEtFlushOnWorker,gEtStalls;
static const char *const kEncFlushName[EF_WHY_COUNT]={"sched","done","resource","getbytes","compute","purgeable","replace","backpressure"};
static __thread uint32_t tEtDepth;
// g4: the submit's lag, per replayed commit (both modes): caller's commit -> the worker starts commitSubmit; the worker's wake (if
// it slept after the commit was handed, else the commit) -> that start; commitSubmit's own time; a frame's first encoder -> that
// start. Batches replayed on a big core (cpu 6-7). The 5 s "T enc-lat" line prints them (p50/p95) with batches/s.
static std::mutex gEtLatLock;static std::vector<int64_t> gEtLat[4];   // ns: commit->submit, wake->submit, submit call, frame enc->submit
static std::atomic<uint64_t> gEtBatchBig,gEtBatchCmds;
static uint64_t gEqWakeTick;   // the worker's last return from its sleep (the worker's alone)
// g4 mode 3: UniXNU's batching (UniXNU/AdrenoMetal feat/ipados27-gpu-parity 6c7b0a0 "one thread of its own, fed in batches",
// f1f51bf "calls as closures in reused batch memory"; credit UniXNU, BSD-2-Clause-Patent): each recording thread fills a batch of
// its own (no shared lock, no wake per command) and hands it over at 64 commands, at an encoder's end or an encoded event, at a commit (at once: the
// worker submits it as it reaches it, no further hop) and before every flush; the worker sleeps on a
// condition variable (no spin) and wakes once per batch handed while it sleeps. As UniXNU's: an encoder's calls and its command
// buffer's commit come from one thread (CA's case; Metal requires the encoder ended before the commit), since another thread's
// open batch is not handed by this thread's flush or commit. Our commands stay the compact EncCmd records
// (UniXNU's f1f51bf moved from blocks to closures in reused memory: ours were never blocks). Not ported: mimalloc.
static __thread EncChunk *tEqBatch;           // mode 3: this thread's batch being filled
static std::deque<EncChunk *> gEqBatches;     // mode 3: handed over, in order (gEqSleepLock)
// The caller's time inside a recording call (outermost only): what the display thread still pays.
struct EtRec {
 uint64_t t0;bool outer;
 EtRec():t0(0),outer(tEtDepth++==0){if(outer)t0=mach_absolute_time();}
 ~EtRec(){tEtDepth--;if(outer)gEtRecordTicks.fetch_add(mach_absolute_time()-t0,std::memory_order_relaxed);}
};
#define ET_REC EtRec etRec_
static void encWake() {
 std::lock_guard<std::mutex> l(gEqSleepLock);
 if(gEqIdle.exchange(false)){gEtWakes.fetch_add(1,std::memory_order_relaxed);gEqWake.notify_one();}
}
static EncChunk *encChunk() {   // gEqLock held
 if(gEqFree.empty())return new EncChunk();
 EncChunk *k=gEqFree.back();gEqFree.pop_back();return k;
}
static void *encWorkerMain(void *) {
 pthread_setname_np("sweet.encthread");
 // CA's display thread runs at a fixed priority 54 (RR): the work it hands over keeps that (SWEET_ENCTHREAD_PRI=N, 0: QoS only)
 const char *pri=getenv("SWEET_ENCTHREAD_PRI");const int priority=pri && *pri?atoi(pri):54;
 if(priority>0){struct sched_param sp={};sp.sched_priority=priority;pthread_setschedparam(pthread_self(),SCHED_RR,&sp);}
 encThreadNote();
 static const uint64_t spinTicks=[]{const char *e=getenv("SWEET_ENCTHREAD_SPIN_US");const double us=e && *e?atof(e):50;
  return (uint64_t)(std::max(0.0,us)*1e3/encTickNs());}();
 for(;;) {
  EncChunk *k=nullptr;
  os_unfair_lock_lock(&gEqLock);
  if(!gEqOpen->cmds.empty()){k=gEqOpen;gEqOpen=encChunk();}
  os_unfair_lock_unlock(&gEqLock);
  if(!k) {
   // nothing recorded: spin a little (the next call is usually microseconds away), then sleep until a recording wakes it
   const uint64_t until=mach_absolute_time()+spinTicks;
   while(gEqAppended.load()==gEqReplayed.load() && mach_absolute_time()<until)__asm__ volatile("yield");
   if(gEqAppended.load()!=gEqReplayed.load())continue;
   gEqIdle.store(true);
   os_unfair_lock_lock(&gEqLock);const bool empty=gEqOpen->cmds.empty();os_unfair_lock_unlock(&gEqLock);
   if(!empty){gEqIdle.store(false);continue;}
   std::unique_lock<std::mutex> l(gEqSleepLock);
   gEqWake.wait(l,[]{return !gEqIdle.load();});
   gEqWakeTick=mach_absolute_time();   // g4 telemetry
   continue;
  }
  const uint64_t t0=mach_absolute_time();
  @autoreleasepool {for(const EncCmd &c:k->cmds)encReplay(c,k->bytes.data());}
  gEtReplayTicks.fetch_add(mach_absolute_time()-t0,std::memory_order_relaxed);
  const uint64_t n=k->cmds.size();
  gEtBatches.fetch_add(1,std::memory_order_relaxed);
  gEtBatchCmds.fetch_add(n,std::memory_order_relaxed);if(encCPU()>=6)gEtBatchBig.fetch_add(1,std::memory_order_relaxed);   // g4
  uint64_t seen=gEtBatchMax.load();while(n>seen && !gEtBatchMax.compare_exchange_weak(seen,n)){}
  gEqReplayed.fetch_add(n);
  if(gEqWaiters.load()){std::lock_guard<std::mutex> l(gEqSleepLock);gEqDone.notify_all();}
  k->cmds.clear();
  if(k->bytes.capacity()>(1u<<20))std::vector<uint8_t>().swap(k->bytes);else k->bytes.clear();
  os_unfair_lock_lock(&gEqLock);
  if(gEqFree.size()<4){gEqFree.push_back(k);k=nullptr;}
  os_unfair_lock_unlock(&gEqLock);
  delete k;
 }
 return nullptr;
}
// g4 mode 3: the worker takes handed batches in order; asleep on gEqWake while there are none (UniXNU 6c7b0a0's thread).
static void *encBatchWorkerMain(void *) {
 pthread_setname_np("sweet.encthread");
 const char *pri=getenv("SWEET_ENCTHREAD_PRI");const int priority=pri && *pri?atoi(pri):54;   // as mode 1 (0: QoS only, UniXNU's)
 int pr=0;   // logged: a priority above the user range (MAXPRI_USER 63, e.g. r66's 80) is refused and leaves the QoS priority
 if(priority>0){struct sched_param sp={};sp.sched_priority=priority;pr=pthread_setschedparam(pthread_self(),SCHED_RR,&sp);}
 {char line[120];snprintf(line,sizeof line,"native-metal: enc-thread mode 3 worker: SCHED_RR %d -> %d",priority,pr);sm2_logs(line);}
 encThreadNote();
 for(;;) {
  EncChunk *k;
  {
   std::unique_lock<std::mutex> l(gEqSleepLock);
   if(gEqBatches.empty()) {
    gEqIdle.store(true);
    gEqWake.wait(l,[]{return !gEqBatches.empty();});
    gEqIdle.store(false);
    gEqWakeTick=mach_absolute_time();
   }
   k=gEqBatches.front();gEqBatches.pop_front();
  }
  const uint64_t t0=mach_absolute_time();
  @autoreleasepool {for(const EncCmd &c:k->cmds)encReplay(c,k->bytes.data());}
  gEtReplayTicks.fetch_add(mach_absolute_time()-t0,std::memory_order_relaxed);
  const uint64_t n=k->cmds.size();
  gEtBatches.fetch_add(1,std::memory_order_relaxed);
  gEtBatchCmds.fetch_add(n,std::memory_order_relaxed);if(encCPU()>=6)gEtBatchBig.fetch_add(1,std::memory_order_relaxed);
  uint64_t seen=gEtBatchMax.load();while(n>seen && !gEtBatchMax.compare_exchange_weak(seen,n)){}
  gEqReplayed.fetch_add(n);
  if(gEqWaiters.load()){std::lock_guard<std::mutex> l(gEqSleepLock);gEqDone.notify_all();}
  k->cmds.clear();
  if(k->bytes.capacity()>(1u<<20))std::vector<uint8_t>().swap(k->bytes);else k->bytes.clear();
  os_unfair_lock_lock(&gEqLock);
  if(gEqFree.size()<8){gEqFree.push_back(k);k=nullptr;}
  os_unfair_lock_unlock(&gEqLock);
  delete k;
 }
 return nullptr;
}
static void encStart() {
 static dispatch_once_t once;
 dispatch_once(&once,^{
  gEqOpen=new EncChunk();
  pthread_attr_t attr;pthread_attr_init(&attr);
  pthread_attr_set_qos_class_np(&attr,QOS_CLASS_USER_INTERACTIVE,0);
  pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
  const int r=pthread_create(&gEqThread,&attr,encBatched()?encBatchWorkerMain:encWorkerMain,nullptr);
  pthread_attr_destroy(&attr);
  if(r){NBLOG(@"native-metal: enc-thread: worker not started (%d): commands are replayed at once by the caller",r);gEqBroken=true;return;}
  gEqStarted=true;
  sm2_logs([NSString stringWithFormat:@"native-metal: enc-thread on (SWEET_ENCTHREAD=%s): render/blit encoders and commits replayed on 'sweet.encthread'%s",
            encBatched()?"3, batched":"1",r?" (NOT STARTED)":""].UTF8String);
 });
}
static bool encOnWorker() {return gEqStarted.load() && pthread_equal(pthread_self(),gEqThread);}
// g4 mode 3: this thread's batch to the worker (UniXNU's encodeFlush), woken only if it sleeps; counted as recorded at the hand-off.
static void encHand() {
 EncChunk *k=tEqBatch;
 if(!k || k->cmds.empty())return;
 tEqBatch=nullptr;
 const uint64_t n=k->cmds.size();
 k->handTick=mach_absolute_time();
 bool wake;uint64_t depth;
 {
  std::lock_guard<std::mutex> l(gEqSleepLock);
  gEqBatches.push_back(k);
  depth=gEqAppended.fetch_add(n)+n-gEqReplayed.load();   // with the push, under the lock: a flush's target covers every batch before it
  wake=gEqIdle.load();
 }
 if(wake){gEtWakes.fetch_add(1,std::memory_order_relaxed);gEqWake.notify_one();}
 uint64_t seen=gEtDepthMax.load(std::memory_order_relaxed);
 while(depth>seen && !gEtDepthMax.compare_exchange_weak(seen,depth)){}
 if(depth>32768)encFlush(EF_BACKPRESSURE);
}
static void encPushBatched(EncCmd &c,const void *extra,size_t length) {
 EncChunk *k=tEqBatch;
 if(!k){os_unfair_lock_lock(&gEqLock);k=encChunk();os_unfair_lock_unlock(&gEqLock);tEqBatch=k;}
 if(extra && length) {
  const size_t at=(k->bytes.size()+7)&~(size_t)7;
  k->bytes.resize(at+length);memcpy(k->bytes.data()+at,extra,length);
  c.off=(uint32_t)at;c.len=(uint32_t)length;
 }
 k->cmds.push_back(c);
 // UniXNU's points, and an encoded event (outside an encoder: its commit may come from another thread); a discard precedes its commit
 if(k->cmds.size()>=64 || c.op==EO_END || c.op==EO_EVENT || c.op==EO_COMMIT)encHand();
}
static bool dfStash(EncCmd &c,const void *extra,size_t length);   // g9: an encoder capturing behind a held fill keeps it
// Records a command (and `length` bytes of inline data) for the worker, in call order.
static void encPush(EncCmd &c,const void *extra=nullptr,size_t length=0) {
 if(gDfCapturing.load(std::memory_order_relaxed)>0 && c.op>=EO_BUFFER && c.op<=EO_DRAW_INDEXED && dfStash(c,extra,length))return;   // g9
 encStart();
 gEtOps[c.op].fetch_add(1,std::memory_order_relaxed);
 if(gEqBroken){c.off=0;c.len=(uint32_t)length;@autoreleasepool{encReplay(c,(const uint8_t *)extra);}return;}
 if(encBatched()){encPushBatched(c,extra,length);return;}   // g4
 os_unfair_lock_lock(&gEqLock);
 EncChunk *k=gEqOpen;
 if(extra && length) {
  const size_t at=(k->bytes.size()+7)&~(size_t)7;
  k->bytes.resize(at+length);memcpy(k->bytes.data()+at,extra,length);
  c.off=(uint32_t)at;c.len=(uint32_t)length;
 }
 k->cmds.push_back(c);
 const uint64_t depth=gEqAppended.fetch_add(1)+1-gEqReplayed.load();
 os_unfair_lock_unlock(&gEqLock);
 uint64_t seen=gEtDepthMax.load(std::memory_order_relaxed);
 while(depth>seen && !gEtDepthMax.compare_exchange_weak(seen,depth)){}
 if(gEqIdle.load())encWake();
 if(depth>32768)encFlush(EF_BACKPRESSURE);
}
// Waits until the worker replayed every command recorded so far (not on the worker itself: it replays in order anyway).
static void encFlush(EncFlushWhy why) {
 if(!gEqStarted.load())return;
 gEtFlushCalls[why].fetch_add(1,std::memory_order_relaxed);
 if(encOnWorker()){gEtFlushOnWorker.fetch_add(1,std::memory_order_relaxed);return;}
 if(encBatched())encHand();   // g4 mode 3: what this thread recorded goes first (other threads' open batches are theirs, as UniXNU's drain)
 const uint64_t target=gEqAppended.load();
 if(gEqReplayed.load()>=target)return;
 gEtFlushWaits[why].fetch_add(1,std::memory_order_relaxed);
 const uint64_t t0=mach_absolute_time();
 gEqWaiters.fetch_add(1);
 if(!encBatched() && gEqIdle.load())encWake();   // g4: mode 3's worker wakes on the batches themselves
 {
  std::unique_lock<std::mutex> l(gEqSleepLock);
  bool logged=false;
  while(gEqReplayed.load()<target) {
   if(!gEqDone.wait_for(l,std::chrono::seconds(2),[&]{return gEqReplayed.load()>=target;}) && !logged) {
    logged=true;gEtStalls.fetch_add(1);
    char line[200];snprintf(line,sizeof line,"native-metal: enc-thread: %s flush waits > 2 s (%llu commands behind)",kEncFlushName[why],
     (unsigned long long)(target-gEqReplayed.load()));
    sm2_logs(line);
   }
  }
 }
 gEqWaiters.fetch_sub(1);
 gEtFlushTicks[why].fetch_add(mach_absolute_time()-t0,std::memory_order_relaxed);
}
// u-gpudraw: SWEET_FNSTAT=1 (backboardd, with the timeline): draws per render pipeline (its vertex + fragment function
// names) every 5 s as "T fn" lines, with one draw's inputs per pipeline: the vertex count, the last setVertexBytes /
// setFragmentBytes (index and the first 64 bytes as floats) and 64 bytes of vertex buffer 0 at the draw's offset.
// Matches Turnip 0112's fragment shader census (T tu-draw) by draw counts.
static bool fnStatOn();
struct FnSnap {uint8_t b[64];uint16_t n,index;};
static thread_local FnSnap tFnBytes[3];   // by stage: 1 vertex, 2 fragment
static thread_local __unsafe_unretained id tFnVb0;static thread_local NSUInteger tFnVb0Off;static thread_local const void *tFnVb0Enc;
struct FnEnt {char name[80];uint32_t draws,verts,inst;FnSnap vb,fb,v0;bool have;};
static std::mutex gFnLock;static FnEnt gFn[48];static unsigned gFnN;static uint64_t gFnOther;
static void fnNote(const void *enc,const char *name,uint32_t verts,uint32_t inst,NSUInteger vertexStart) {
 std::lock_guard<std::mutex> l(gFnLock);
 unsigned i=0;for(;i<gFnN && strncmp(gFn[i].name,name,sizeof gFn[i].name);i++);
 if(i==gFnN){if(gFnN==48){gFnOther++;return;}gFnN++;memset(&gFn[i],0,sizeof gFn[i]);snprintf(gFn[i].name,sizeof gFn[i].name,"%s",name);}
 FnEnt &e=gFn[i];e.draws++;e.verts+=verts;e.inst+=inst;
 if(!e.have || (e.draws%64)==0) {   // a sample now and then
  e.have=true;e.vb=tFnBytes[1];e.fb=tFnBytes[2];memset(&e.v0,0,sizeof e.v0);
  if(tFnVb0 && tFnVb0Enc==enc && [tFnVb0 respondsToSelector:@selector(contents)] && [tFnVb0 respondsToSelector:@selector(length)]) {
   const uint8_t *c=(const uint8_t *)[(id<MTLBuffer>)tFnVb0 contents];NSUInteger len=[(id<MTLBuffer>)tFnVb0 length];
   if(c && tFnVb0Off<len){e.v0.n=(uint16_t)std::min<NSUInteger>(64,len-tFnVb0Off);memcpy(e.v0.b,c+tFnVb0Off,e.v0.n);}
  }
  (void)vertexStart;
 }
}
static void fnPut(char *out,size_t size,const char *what,const FnSnap &s) {
 size_t at=strlen(out);if(!s.n)return;
 at+=snprintf(out+at,size>at?size-at:0," %s[%u] %u:",what,s.index,s.n);
 for(unsigned k=0;k+4<=s.n && k<64;k+=4){float f;memcpy(&f,s.b+k,4);at+=snprintf(out+at,size>at?size-at:0," %.4g",f);}
}
static void fnReport() {
 if(!fnStatOn())return;
 std::vector<FnEnt> v;uint64_t other;
 {std::lock_guard<std::mutex> l(gFnLock);v.assign(gFn,gFn+gFnN);gFnN=0;other=gFnOther;gFnOther=0;}
 std::sort(v.begin(),v.end(),[](const FnEnt &a,const FnEnt &b){return a.draws>b.draws;});
 for(size_t i=0;i<v.size() && i<12;i++) {
  char line[1300];
  snprintf(line,sizeof line,"native-metal: T fn %s: d%u v%.1f i%.1f",v[i].name,v[i].draws,v[i].draws?(double)v[i].verts/v[i].draws:0,
   v[i].draws?(double)v[i].inst/v[i].draws:0);
  fnPut(line,sizeof line,"vbytes",v[i].vb);fnPut(line,sizeof line,"fbytes",v[i].fb);fnPut(line,sizeof line,"vb0",v[i].v0);
  sm2_logs(line);
 }
 if(other){char line[80];snprintf(line,sizeof line,"native-metal: T fn: %llu draws of more pipelines",(unsigned long long)other);sm2_logs(line);}
}
@interface NBEncoder : NBObject {
@public
 // ovd (SWEET_DRAWBOX): this encoder logs (its command buffer's DB frame, pass index); vertex-stage buffers and bytes by index (0..7)
 uint32_t dbFrame,dbPass,dbDraws;__unsafe_unretained id dbVb[8];NSUInteger dbVbOff[8];std::vector<uint8_t> dbVbytes[8];
 // g9 (SWEET_DEADFILL): vertex-stage bindings tracked (dfTrack); calls recorded behind a held fill (dfCapturing: dfList, inline
 // data in dfBytes; an entry whose op is EO_COUNT is skipped), the held draw's index there (-1: none), the creation held (mode 2),
 // and whether the encoder is a direct one (encDeferred only while capturing)
 bool dfTrack,dfCapturing,dfPending,dfDirect,dfHeldPx;int8_t dfMode;int32_t dfHeld;uint32_t dfHeldD;float dfHeldCol[4];
 std::vector<EncCmd> dfList;std::vector<uint8_t> dfBytes;NmbRenderPassDescriptor *dfPass;uint64_t dfPx,dfHeldBind;
 bool encDeferred,encEnded;   // u-encthread: recorded for the worker (then `handle` is the worker's alone); endEncoding recorded
}
@property(nonatomic) NmbEncoder *handle;
@property(nonatomic,strong) NBCommandBuffer *commandBuffer;
- (bool)check:(bool)ok what:(const char *)what;
- (void)dfCapture;
- (void)dfRelease:(bool)drop clear:(bool)clear;
@end
// u-encthread: a recording call on an encoder already ended fails its command buffer (never recorded: the encoder may be gone).
#define ENC_LIVE() do{if(encEnded){[self.commandBuffer refuse:@"encoder call after endEncoding"];return;}}while(0)
// g9: a recording call of an encoder capturing behind a held fill: kept (with its inline data) until the hold resolves
static bool dfStash(EncCmd &c,const void *extra,size_t length) {
 NBEncoder *e=(__bridge NBEncoder *)c.target;
 if(!e || !e->dfCapturing)return false;
 if(extra && length) {
  const size_t at=(e->dfBytes.size()+7)&~(size_t)7;
  e->dfBytes.resize(at+length);memcpy(e->dfBytes.data()+at,extra,length);
  c.off=(uint32_t)at;c.len=(uint32_t)length;
 }
 e->dfList.push_back(c);
 return true;
}
static void waitForResource(id resource) {
 ENC_SCOPE(EC_WAIT,"waitForResource");
 if(encThreadOn())encFlush(EF_RESOURCE);   // u-encthread: committed command buffers are in gInFlight once replayed
 const uint64_t began=nowUs();
 NSArray *pending;@synchronized(gInFlight){pending=gInFlight.allObjects;}
 for(NBCommandBuffer *commandBuffer in pending) {
  int dependency=-1;
  if([resource isKindOfClass:[NBBuffer class]])dependency=nmb_command_buffer_uses_buffer(commandBuffer.handle,[(NBBuffer *)resource handle]);
  else if([resource isKindOfClass:[NBTexture class]])dependency=nmb_command_buffer_uses_texture(commandBuffer.handle,[(NBTexture *)resource handle]);
  gResourceChecks++;
  // An unknown result retains the old conservative wait. False means no matching storage
  // (or GPU work already completed), not a fabricated completion for a pending dependency.
  if(dependency!=0)[(id<MTLCommandBuffer>)commandBuffer waitUntilCompleted];else gResourceSkipped++;
 }
 gTimeResourceWait.add(began);
}
@implementation NBEncoder
- (void)dealloc {if(_handle)nmb_encoder_discard(_handle);delete dfPass;if(dfCapturing)gDfCapturing.fetch_sub(1);}
- (bool)check:(bool)ok what:(const char *)what {
 if(!ok)[_commandBuffer refuse:[NSString stringWithFormat:@"%s: %@",what,lastError()]];
 return ok;
}
// g9 (SWEET_DEADFILL): start holding (the calls from here are recorded into dfList; a direct encoder records as a deferred one)
- (void)dfCapture {
 if(dfCapturing)return;
 dfCapturing=true;gDfCapturing.fetch_add(1);
 dfDirect=!encDeferred;encDeferred=true;
}
// mode 2: the held creation made now (a clear to the held fill's colour when `clear`)
- (void)dfCreate:(bool)clear {
 if(!dfPending)return;
 NmbRenderPassDescriptor pass=*dfPass;delete dfPass;dfPass=nullptr;dfPending=false;
 if(clear){pass.colors[0].load=MTLLoadActionClear;for(int i=0;i<4;i++)pass.colors[0].clear[i]=dfHeldCol[i];}
 NBCommandBuffer *cb=_commandBuffer;
 if(dfDirect) {
  NmbEncoder *h=cb.committed?nullptr:nmb_render_encoder_new(cb.handle,&pass);
  if(!h)[cb refuse:[NSString stringWithFormat:@"renderCommandEncoder: %@",lastError()]];
  _handle=h;
 } else {
  EncCmd c={};c.op=EO_RENDER_NEW;c.target=(__bridge_retained void *)self;   // released as its end (or discard) is replayed
  const bool was=dfCapturing;dfCapturing=false;encPush(c,&pass,sizeof pass);dfCapturing=was;
 }
}
// the hold ends: `drop` drops the held fill (`clear`: the held creation clears to its colour instead); the recorded calls go out in order
- (void)dfRelease:(bool)drop clear:(bool)clear {
 if(!dfCapturing)return;
 if(dfHeld>=0 && drop)dfList[(size_t)dfHeld].op=EO_COUNT;
 dfCapturing=false;gDfCapturing.fetch_sub(1);
 [self dfCreate:clear];
 if(dfDirect)encDeferred=false;
 std::vector<EncCmd> list;list.swap(dfList);std::vector<uint8_t> bytes;bytes.swap(dfBytes);
 for(EncCmd c:list) {
  if(c.op==EO_COUNT)continue;
  if(dfDirect){c.target=(__bridge void *)self;encReplay(c,bytes.data());}
  else encPush(c,c.len?bytes.data()+c.off:nullptr,c.len);
 }
 dfHeld=-1;dfDirect=false;
}
- (void)endEncoding {
 if(dfCapturing) {   // g9: a fill still held at the end is the pass's last draw: it goes out (mode 2: a pass of only fills clears)
  const bool clearIt=dfPending && dfHeld>=0 && dfHeldPx;
  if(clearIt){gDfCleared.fetch_add(1);gDfPx.fetch_add(dfPx);if(dbFrame){char l[120];snprintf(l,sizeof l,"native-metal: DB f%u p%u d%u DF cleared (pass end)",dbFrame,dbPass,dfHeldD);sm2_logs(l);}}
  [self dfRelease:clearIt clear:clearIt];
 }
 static EncSite renderEnd{"endEncoding(render)",EC_ENC},blitEnd{"endEncoding(blit)",EC_ENC},computeEnd{"endEncoding(compute)",EC_ENC};
 EncScope encScope_([self respondsToSelector:@selector(setRenderPipelineState:)]?&renderEnd:
                    [self respondsToSelector:@selector(setComputePipelineState:)]?&computeEnd:&blitEnd);
 if(encDeferred) {
  ET_REC;
  if(encEnded){[_commandBuffer refuse:@"endEncoding twice"];return;}
  encEnded=true;
  if(_commandBuffer->encOpen==self)_commandBuffer->encOpen=nil;
  EncCmd c={};c.op=EO_END;c.target=(__bridge void *)self;encPush(c);
  return;
 }
 NmbEncoder *handle=_handle;_handle=nullptr;
 if(!handle){[_commandBuffer refuse:@"endEncoding twice"];return;}
 [self check:nmb_encoder_end(handle) what:"endEncoding"];
 if(encScope_.slow()) {
  uint64_t work[10]={};NBCommandBuffer *cb=_commandBuffer;
  if(gDevice && nmb_device_work_stats(gDevice,work) && cb->encThread)
   snprintf(tEncDetail,sizeof tEncDetail,"%u draws in the frame; VkPipelines this frame so far %llu in %.1f ms",cb->encodedWork.draws,
    (unsigned long long)(work[0]-cb->encVkStart[0]),(work[1]-cb->encVkStart[1])/1e3);
 }
}
- (void)insertDebugSignpost:(NSString *)s {(void)s;}
- (void)pushDebugGroup:(NSString *)s {(void)s;}
- (void)popDebugGroup {}
// Stage 0 compute, 1 vertex, 2 fragment (the bridge's numbering).
- (void)buffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset index:(NSUInteger)index stage:(uint32_t)stage {ENC_SCOPE(EC_BIND,"setBuffer");
 if((dbFrame || dfTrack) && stage==1 && index<8){dbVb[index]=buffer;dbVbOff[index]=offset;dbVbytes[index].clear();}   // ovd, g9
 if(stage==1 && index==0 && fnStatOn()){tFnVb0=buffer;tFnVb0Off=offset;tFnVb0Enc=(__bridge const void *)self;}
 if(buffer && ![(id)buffer isKindOfClass:[NBBuffer class]]){[_commandBuffer refuse:@"foreign buffer"];return;}
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  if(buffer)[_commandBuffer.resourceOwners addObject:buffer];
  EncCmd c={};c.op=EO_BUFFER;c.stage=(uint8_t)stage;c.index=(uint32_t)index;c.target=(__bridge void *)self;c.a=(__bridge void *)buffer;c.u[0]=offset;
  encPush(c);return;
 }
 if(buffer)[_commandBuffer.resourceOwners addObject:buffer];
 [self check:nmb_encoder_set_buffer(_handle,stage,buffer?[(NBBuffer *)buffer handle]:nullptr,offset,(uint32_t)index) what:"setBuffer"];
}
- (void)texture:(id<MTLTexture>)texture index:(NSUInteger)index stage:(uint32_t)stage {ENC_SCOPE(EC_BIND,"setTexture");
 if(texture && ![(id)texture isKindOfClass:[NBTexture class]]){[_commandBuffer refuse:@"foreign texture"];return;}
 if(encDeferred) {   // u-encthread: the YCbCr refresh, the shadow seed and the handle (a YCbCr copy's turn) are the replay's
  ET_REC;ENC_LIVE();
  if(texture)[_commandBuffer.resourceOwners addObject:texture];
  if(texture && [(NBTexture *)texture surface]) {
   [_commandBuffer.surfaces addObject:texture];
   if(shaderWritable((NBTexture *)texture))[_commandBuffer.writtenSurfaces addObject:texture];
  }
  EncCmd c={};c.op=EO_TEXTURE;c.stage=(uint8_t)stage;c.index=(uint32_t)index;c.target=(__bridge void *)self;c.a=(__bridge void *)texture;
  if(texture)c.u[0]=((NBTexture *)texture)->encReplaceEpoch.load();
  encPush(c);return;
 }
 if(texture)ycbcrRefresh((NBTexture *)texture,_commandBuffer);
 if(texture && shadowSeedOn() && [(NBTexture *)texture surface] && !((NBTexture *)texture).ycbcrGPU)
  nmb_texture_set_bytes_generation([(NBTexture *)texture handle],(uint64_t)IOSurfaceGetSeed([(NBTexture *)texture surface])+1);
 [self check:nmb_encoder_set_texture(_handle,stage,texture?[(NBTexture *)texture handle]:nullptr,(uint32_t)index) what:"setTexture"];
}
- (void)sampler:(id<MTLSamplerState>)sampler index:(NSUInteger)index stage:(uint32_t)stage {ENC_SCOPE(EC_BIND,"setSamplerState");
 if(sampler && ![(id)sampler isKindOfClass:[NBSampler class]]){[_commandBuffer refuse:@"foreign sampler"];return;}
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_SAMPLER;c.stage=(uint8_t)stage;c.index=(uint32_t)index;c.target=(__bridge void *)self;
  if(sampler){c.a=(__bridge_retained void *)sampler;c.flags=ECF_RETAIN_A;}
  encPush(c);return;
 }
 [self check:nmb_encoder_set_sampler(_handle,stage,sampler?[(NBSampler *)sampler handle]:nullptr,(uint32_t)index) what:"setSamplerState"];
}
- (void)bytes:(const void *)bytes length:(NSUInteger)length index:(NSUInteger)index stage:(uint32_t)stage {ENC_SCOPE(EC_BIND,"setBytes");
 if((dbFrame || dfTrack) && stage==1 && index<8){dbVb[index]=nil;dbVbytes[index].assign((const uint8_t *)bytes,(const uint8_t *)bytes+(bytes?std::min<NSUInteger>(length,65536):0));}   // ovd
 if(stage<3 && fnStatOn()){FnSnap &f=tFnBytes[stage];f.n=(uint16_t)std::min<NSUInteger>(64,length);f.index=(uint16_t)index;if(bytes)memcpy(f.b,bytes,f.n);}
 if(encDeferred) {   // the bytes are the caller's only during the call: copied
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_BYTES;c.stage=(uint8_t)stage;c.index=(uint32_t)index;c.target=(__bridge void *)self;
  if(!bytes || !length){c.flags=ECF_NULL_BYTES;c.u[0]=(uint64_t)(uintptr_t)bytes;c.u[1]=length;encPush(c);}
  else encPush(c,bytes,length);
  return;
 }
 [self check:nmb_encoder_set_bytes(_handle,stage,bytes,length,(uint32_t)index) what:"setBytes"];
}
- (void)fence:(id<MTLFence>)fence stages:(uint64_t)stages update:(bool)update {ENC_SCOPE(EC_BIND,"fence");
 if(![(id)fence isKindOfClass:[NBFence class]]){[_commandBuffer refuse:@"foreign fence"];return;}
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_FENCE;c.target=(__bridge void *)self;c.a=(__bridge_retained void *)fence;c.flags=ECF_RETAIN_A;c.u[0]=stages;c.u[1]=update;
  encPush(c);return;
 }
 NmbFence *handle=[(NBFence *)fence handle];
 [self check:update?nmb_encoder_update_fence(_handle,handle,stages):nmb_encoder_wait_fence(_handle,handle,stages) what:update?"updateFence":"waitForFence"];
}
- (void)updateFence:(id<MTLFence>)fence {[self fence:fence stages:0 update:true];}
- (void)waitForFence:(id<MTLFence>)fence {[self fence:fence stages:0 update:false];}
- (void)offset:(NSUInteger)offset index:(NSUInteger)index stage:(uint32_t)stage {ENC_SCOPE(EC_BIND,"setBufferOffset");
 if((dbFrame || dfTrack) && stage==1 && index<8)dbVbOff[index]=offset;   // ovd, g9
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_OFFSET;c.stage=(uint8_t)stage;c.index=(uint32_t)index;c.target=(__bridge void *)self;c.u[0]=offset;
  encPush(c);return;
 }
 [self check:nmb_encoder_set_buffer_offset(_handle,stage,offset,(uint32_t)index) what:"setBufferOffset"];
}
@end

@interface NBComputeEncoder : NBEncoder
@end
@implementation NBComputeEncoder
- (MTLDispatchType)dispatchType {return MTLDispatchTypeSerial;}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {ENC_SCOPE(EC_BIND,"setComputePipelineState");
 if(![(id)state isKindOfClass:[NBComputePipeline class]]){[self.commandBuffer refuse:@"foreign compute pipeline"];return;}
 [self check:nmb_compute_set_pipeline(self.handle,[(NBComputePipeline *)state handle]) what:"setComputePipelineState"];
}
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {[self buffer:b offset:o index:i stage:0];}
- (void)setBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:0];}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger [])o withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self buffer:b[k] offset:o[k] index:r.location+k stage:0];
}
- (void)setBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {[self bytes:p length:n index:i stage:0];}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {[self texture:t index:i stage:0];}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self texture:t[k] index:r.location+k stage:0];
}
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {[self sampler:s index:i stage:0];}
- (void)setThreadgroupMemoryLength:(NSUInteger)n atIndex:(NSUInteger)i {
 [self check:nmb_compute_set_threadgroup_memory(self.handle,(uint32_t)n,(uint32_t)i) what:"setThreadgroupMemoryLength"];
}
- (void)dispatch:(MTLSize)size group:(MTLSize)group threads:(bool)threads {ENC_SCOPE(EC_DRAW,"dispatch");
 gDispatches++;self.commandBuffer->encodedWork.dispatches++;
 const uint64_t s[3]={size.width,size.height,size.depth},g[3]={group.width,group.height,group.depth};
 [self check:nmb_compute_dispatch(self.handle,s,g,threads) what:"dispatch"];
}
- (void)dispatchThreads:(MTLSize)t threadsPerThreadgroup:(MTLSize)g {[self dispatch:t group:g threads:true];}
- (void)dispatchThreadgroups:(MTLSize)t threadsPerThreadgroup:(MTLSize)g {[self dispatch:t group:g threads:false];}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {(void)r;(void)u;}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s {(void)s;}
@end

@interface NBRenderEncoder : NBEncoder {
@public
 char encPipeline[80];   // u-e: the bound pipeline's function names (copied: "E slow" draws name it)
 uint64_t rasterCull,rasterWinding,rasterFill;   // Metal's defaults (0) until set (were associated objects: a global lock and an NSNumber each)
 // u-cpu 0x2: the values the last accepted setViewport:/setScissorRect: set (have*: one was accepted)
 bool haveViewport,haveScissor;double lastViewport[6];uint64_t lastScissor[4];
 // ovd: the bound pipeline, viewport/scissor as set (any CPUFAST), the colour attachment's size and load action
 NBRenderPipeline *dbPipe;double dbVp[4];uint64_t dbSc[4];bool dbHaveVp,dbHaveSc;uint32_t dbW,dbH,dbLoad;
 bool dfDss,dfClipKind;   // g9: a depth/stencil state was set; the last fill tested was in clip space (else pixels)
}
@end
@implementation NBRenderEncoder
// ovd (SWEET_DRAWBOX): one "DB" line for a draw: where its pixels can go (viewport, scissor) and where its vertices are.
- (void)dbDraw:(uint32_t)prim start:(uint32_t)start count:(uint32_t)count inst:(uint32_t)inst index:(id<MTLBuffer>)ib type:(uint32_t)itype
        offset:(NSUInteger)ioff base:(int32_t)base {
 NBRenderPipeline *p=dbPipe;const uint32_t d=dbDraws++;
 char line[1400];size_t at=0;
#define DBP(...) do{at+=snprintf(line+at,at<sizeof line?sizeof line-at:0,__VA_ARGS__);}while(0)
 DBP("native-metal: DB f%u p%u d%u %s [%s] bl%d m%x f%d/%d/%d/%d prim%u n%u i%u%s",dbFrame,dbPass,d,p?p->encNames:"?",p?p->dbLabel:"?",p?p->dbBlend:-1,p?p->dbMask:0,
  p?p->dbSrc:0,p?p->dbDst:0,p?p->dbSrcA:0,p?p->dbDstA:0,prim,count,inst,ib?" idx":"");
 if(dbHaveVp)DBP(" vp %.0f,%.0f %.0fx%.0f",dbVp[0],dbVp[1],dbVp[2],dbVp[3]);else DBP(" vp -");
 if(dbHaveSc)DBP(" sc %llu,%llu %llux%llu",(unsigned long long)dbSc[0],(unsigned long long)dbSc[1],(unsigned long long)dbSc[2],(unsigned long long)dbSc[3]);else DBP(" sc -");
 // the position attribute (pipeline attribute 0) of the vertices drawn: float2/3/4 or half2/4
 const uint32_t fmt=p?p->dbFmt:0,buf=p?p->dbBuf:99;
 const uint8_t *src=nullptr;size_t len=0;
 if(fmt && buf<8) {
  if(!dbVbytes[buf].empty()){src=dbVbytes[buf].data();len=dbVbytes[buf].size();}
  else if(id vb=dbVb[buf]){if([vb respondsToSelector:@selector(contents)]){const uint8_t *c=(const uint8_t *)[(id<MTLBuffer>)vb contents];NSUInteger l=[(id<MTLBuffer>)vb length];
   if(c && dbVbOff[buf]<l){src=c+dbVbOff[buf];len=l-dbVbOff[buf];}}}
 }
 const int comps=fmt==MTLVertexFormatFloat2?2:fmt==MTLVertexFormatFloat3?3:fmt==MTLVertexFormatFloat4?4:fmt==MTLVertexFormatHalf2?-2:fmt==MTLVertexFormatHalf4?-4:0;
 if(src && comps) {
  const uint8_t *ix=nullptr;size_t ilen=0;
  if(ib){const uint8_t *c=(const uint8_t *)[ib contents];NSUInteger l=[ib length];if(c && ioff<l){ix=c+ioff;ilen=l-ioff;}}
  float x0=1e30f,y0=1e30f,x1=-1e30f,y1=-1e30f,w0=1e30f,w1=-1e30f;uint32_t got=0;
  const uint32_t stride=p->dbStride?p->dbStride:(uint32_t)(abs(comps)*(comps>0?4:2));
  for(uint32_t k=0;k<count && k<4096;k++) {
   int64_t v;
   if(ib){if(!ix)break;if(itype==MTLIndexTypeUInt16){if((k+1)*2>ilen)break;v=((const uint16_t *)ix)[k];}else{if((k+1)*4>ilen)break;v=((const uint32_t *)ix)[k];}v+=base;}
   else v=(int64_t)start+k;
   const size_t o=(size_t)v*stride+p->dbOff;if(v<0 || o+(comps>0?comps*4:-comps*2)>len)continue;
   float c4[4]={0,0,0,1};
   if(comps>0)memcpy(c4,src+o,comps*4);else{const __fp16 *h=(const __fp16 *)(src+o);for(int q=0;q<-comps;q++)c4[q]=(float)h[q];}
   x0=std::min(x0,c4[0]);x1=std::max(x1,c4[0]);y0=std::min(y0,c4[1]);y1=std::max(y1,c4[1]);
   const float w=(comps==4||comps==-4)?c4[3]:1;w0=std::min(w0,w);w1=std::max(w1,w);got++;
  }
  if(got) {
   DBP(" pos %.1f,%.1f..%.1f,%.1f w%.2f..%.2f (%u)",x0,y0,x1,y1,w0,w1,got);
   {   // the first drawn vertex's colour attribute
    int64_t v0=start;if(ib && ix && ilen>=4)v0=(itype==MTLIndexTypeUInt16?((const uint16_t *)ix)[0]:((const uint32_t *)ix)[0])+base;
    const size_t o=(size_t)v0*stride+p->dbCOff;float c[4];bool ok=p->dbCFmt && v0>=0;
    if(ok && p->dbCFmt==MTLVertexFormatHalf4 && o+8<=len){const __fp16 *h=(const __fp16 *)(src+o);for(int q=0;q<4;q++)c[q]=(float)h[q];}
    else if(ok && p->dbCFmt==MTLVertexFormatFloat4 && o+16<=len)memcpy(c,src+o,16);
    else if(ok && p->dbCFmt==MTLVertexFormatUChar4Normalized && o+4<=len){for(int q=0;q<4;q++)c[q]=src[o+q]/255.f;}
    else ok=false;
    if(ok)DBP(" col %.3f,%.3f,%.3f,%.3f",c[0],c[1],c[2],c[3]);
   }
   // as clip space with w 1, in the viewport (else the attachment): pixels
   const double vx=dbHaveVp?dbVp[0]:0,vy=dbHaveVp?dbVp[1]:0,vw=dbHaveVp?dbVp[2]:dbW,vh=dbHaveVp?dbVp[3]:dbH;
   if(w0==1 && w1==1 && x0>=-1.01f && x1<=1.01f && y0>=-1.01f && y1<=1.01f)
    DBP(" px %.0f,%.0f %.0fx%.0f",vx+(x0*0.5+0.5)*vw,vy+(0.5-y1*0.5)*vh,(x1-x0)*0.5*vw,(y1-y0)*0.5*vh);
  } else DBP(" pos none");
 } else DBP(" pos ?fmt%u buf%u",fmt,buf);
 // the vertex stage's other bytes (CA's transform/uniforms): the first set index other than the position's, 16 floats
 for(uint32_t k=0;k<8;k++) if(k!=buf && !dbVbytes[k].empty()) {
  DBP(" u%u/%zu:",k,dbVbytes[k].size());
  for(size_t q=0;q+4<=dbVbytes[k].size() && q<64;q+=4){float f;memcpy(&f,dbVbytes[k].data()+q,4);DBP(" %.4g",f);}
  break;
 }
 // g9: and the first vertex buffer other than the position's (CA's transform when it is not set as bytes): 16 floats at its offset
 for(uint32_t k=0;k<8;k++) if(k!=buf && dbVbytes[k].empty() && dbVb[k] && [dbVb[k] isKindOfClass:[NBBuffer class]]) {
  const uint8_t *c=(const uint8_t *)[(id<MTLBuffer>)dbVb[k] contents];const NSUInteger l=[(id<MTLBuffer>)dbVb[k] length];
  if(!c || dbVbOff[k]>=l)continue;
  DBP(" b%u+%lu:",k,(unsigned long)dbVbOff[k]);
  for(size_t q=0;q+4<=l-dbVbOff[k] && q<64;q+=4){float f;memcpy(&f,c+dbVbOff[k]+q,4);DBP(" %.4g",f);}
  break;
 }
#undef DBP
 sm2_logs(line);
}
// g9 (SWEET_DEADFILL): is this draw a full-target opaque constant-colour fill? Only Core Animation's untextured, unblended
// "draw.PBGRAXm_A2Xhf" pipeline (all channels written), one instance of triangles, no depth/stencil state, viewport and scissor
// the whole attachment (or unset), the position attribute (float4, w 1) spanning exactly [0,W]x[0,H] pixels or [-1,1] clip space,
// and every drawn vertex's colour attribute the same with alpha 1. Its colour into col.
- (bool)dfIsFill:(uint32_t)prim start:(uint32_t)start count:(uint32_t)count inst:(uint32_t)inst index:(id<MTLBuffer>)ib type:(uint32_t)itype
          offset:(NSUInteger)ioff base:(int32_t)base color:(float *)col {
 NBRenderPipeline *p=dbPipe;
 if(!p || dfDss || inst!=1 || (prim!=MTLPrimitiveTypeTriangle && prim!=MTLPrimitiveTypeTriangleStrip) || count<3 || count>64)return false;
 if(strcmp(p->dbLabel,"draw.PBGRAXm_A2Xhf") || p->dbBlend || p->dbMask!=0xf)return false;
 if(p->dbFmt!=MTLVertexFormatFloat4 && p->dbFmt!=MTLVertexFormatFloat2)return false;
 if(p->dbCFmt!=MTLVertexFormatHalf4 && p->dbCFmt!=MTLVertexFormatFloat4 && p->dbCFmt!=MTLVertexFormatUChar4Normalized)return false;
 if(!dbW || !dbH || p->dbBuf>=8)return false;
 if(dbHaveVp && (dbVp[0]!=0 || dbVp[1]!=0 || dbVp[2]!=dbW || dbVp[3]!=dbH))return false;
 if(dbHaveSc && (dbSc[0]!=0 || dbSc[1]!=0 || dbSc[2]!=dbW || dbSc[3]!=dbH))return false;
 const uint8_t *src=nullptr;size_t len=0;
 if(!dbVbytes[p->dbBuf].empty()){src=dbVbytes[p->dbBuf].data();len=dbVbytes[p->dbBuf].size();}
 else if(id vb=dbVb[p->dbBuf]){if(![vb isKindOfClass:[NBBuffer class]])return false;const uint8_t *c=(const uint8_t *)[(id<MTLBuffer>)vb contents];
  const NSUInteger l=[(id<MTLBuffer>)vb length];if(c && dbVbOff[p->dbBuf]<l){src=c+dbVbOff[p->dbBuf];len=l-dbVbOff[p->dbBuf];}}
 if(!src)return false;
 const uint8_t *ix=nullptr;size_t ilen=0;
 if(ib){if(![(id)ib isKindOfClass:[NBBuffer class]])return false;const uint8_t *c=(const uint8_t *)[(id<MTLBuffer>)ib contents];const NSUInteger l=[(id<MTLBuffer>)ib length];
  if(!c || ioff>=l)return false;ix=c+ioff;ilen=l-ioff;}
 const int comps=p->dbFmt==MTLVertexFormatFloat4?4:2;
 const uint32_t stride=p->dbStride?p->dbStride:(uint32_t)comps*4;
 if(!(prim==MTLPrimitiveTypeTriangle?count==6:count==4))return false;   // one rectangle: two triangles
 float x0=1e30f,y0=1e30f,x1=-1e30f,y1=-1e30f;float c0[4]={0,0,0,0};float vx[6],vy[6];
 for(uint32_t k=0;k<count;k++) {
  int64_t v;
  if(ib){if(itype==MTLIndexTypeUInt16){if((k+1)*2>ilen)return false;v=((const uint16_t *)ix)[k];}else{if((k+1)*4>ilen)return false;v=((const uint32_t *)ix)[k];}v+=base;}
  else v=(int64_t)start+k;
  if(v<0)return false;
  const size_t o=(size_t)v*stride+p->dbOff;if(o+comps*4>len)return false;
  float q[4]={0,0,0,1};memcpy(q,src+o,comps*4);
  if(q[3]!=1)return false;
  vx[k]=q[0];vy[k]=q[1];
  x0=std::min(x0,q[0]);x1=std::max(x1,q[0]);y0=std::min(y0,q[1]);y1=std::max(y1,q[1]);
  const size_t co=(size_t)v*stride+p->dbCOff;float c[4];
  if(p->dbCFmt==MTLVertexFormatHalf4){if(co+8>len)return false;const __fp16 *h=(const __fp16 *)(src+co);for(int i=0;i<4;i++)c[i]=(float)h[i];}
  else if(p->dbCFmt==MTLVertexFormatFloat4){if(co+16>len)return false;memcpy(c,src+co,16);}
  else{if(co+4>len)return false;for(int i=0;i<4;i++)c[i]=src[co+i]/255.f;}
  if(k==0)memcpy(c0,c,sizeof c0);else if(memcmp(c0,c,sizeof c0))return false;
 }
 if(c0[3]!=1)return false;
 const bool pixels=fabsf(x0)<=0.01f && fabsf(y0)<=0.01f && fabsf(x1-(float)dbW)<=0.01f && fabsf(y1-(float)dbH)<=0.01f;
 const bool clip=fabsf(x0+1)<=1e-4f && fabsf(y0+1)<=1e-4f && fabsf(x1-1)<=1e-4f && fabsf(y1-1)<=1e-4f;
 if(!pixels && !clip)return false;
 // the two triangles cover the rectangle: their vertices are its corners, each triangle three distinct ones, and the two they share
 // are opposite corners (a diagonal)
 int cr[6];
 for(uint32_t k=0;k<count;k++) {
  const bool lx=vx[k]==x0,hx=vx[k]==x1,ly=vy[k]==y0,hy=vy[k]==y1;
  if(!(lx||hx) || !(ly||hy))return false;
  cr[k]=(hx?1:0)|(hy?2:0);
 }
 const int t0[3]={cr[0],cr[1],cr[2]},t1[3]={prim==MTLPrimitiveTypeTriangle?cr[3]:cr[1],prim==MTLPrimitiveTypeTriangle?cr[4]:cr[2],prim==MTLPrimitiveTypeTriangle?cr[5]:cr[3]};
 auto distinct=[](const int *t){return t[0]!=t[1] && t[1]!=t[2] && t[0]!=t[2];};
 if(!distinct(t0) || !distinct(t1))return false;
 int shared[3],ns=0;
 for(int a=0;a<3;a++)for(int b=0;b<3;b++)if(t0[a]==t1[b] && ns<3)shared[ns++]=t0[a];
 if(ns!=2 || (shared[0]^shared[1])!=3)return false;
 memcpy(col,c0,sizeof c0);
 dfClipKind=clip;
 return true;
}
// g9: the vertex stage's bindings other than the position's (CA's transform/uniforms): a held fill is dropped only for a fill drawn
// with the same ones (same positions and same transform: the same pixels)
- (uint64_t)dfBindHash {
 const uint32_t buf=dbPipe?dbPipe->dbBuf:99;uint64_t h=1469598103934665603ull;
 auto mix=[&](const void *p,size_t n){const uint8_t *b=(const uint8_t *)p;for(size_t i=0;i<n;i++){h^=b[i];h*=1099511628211ull;}};
 for(uint32_t k=0;k<8;k++) {
  if(k==buf)continue;
  // the bound bytes (CA's per-draw uniforms come from a ring buffer at changing offsets: their contents, not where they are)
  if(!dbVbytes[k].empty()){mix(&k,sizeof k);mix(dbVbytes[k].data(),std::min<size_t>(dbVbytes[k].size(),256));}
  else if(id vb=dbVb[k]) {
   mix(&k,sizeof k);
   if([vb isKindOfClass:[NBBuffer class]]){const uint8_t *c=(const uint8_t *)[(id<MTLBuffer>)vb contents];const NSUInteger l=[(id<MTLBuffer>)vb length];
    if(c && dbVbOff[k]<l)mix(c+dbVbOff[k],std::min<size_t>(l-dbVbOff[k],256));else{const void *o=(__bridge const void *)vb;mix(&o,sizeof o);}}
   else{const void *o=(__bridge const void *)vb;mix(&o,sizeof o);}
  }
 }
 return h;
}
// g9: before a draw goes out: resolve a held fill against it. True: this draw is held itself (it is a fill), recorded as the stash's next entry.
- (void)dfDraw:(uint32_t)prim start:(uint32_t)start count:(uint32_t)count inst:(uint32_t)inst index:(id<MTLBuffer>)ib type:(uint32_t)itype
        offset:(NSUInteger)ioff base:(int32_t)base {
 float col[4];
 const bool fill=[self dfIsFill:prim start:start count:count inst:inst index:ib type:itype offset:ioff base:base color:col];
 const uint32_t d=dbDraws?dbDraws-1:0;
 if(fill) {
  const uint64_t bind=[self dfBindHash]^(dfClipKind?0x9e3779b97f4a7c15ull:0);
  if(dfCapturing && dfHeld>=0 && bind!=dfHeldBind) {   // a fill under another transform: the held one goes out first (kept)
   const bool clearIt=false;[self dfRelease:clearIt clear:clearIt];
  }
  if(dfCapturing && dfHeld>=0) {   // the held fill is completely overwritten by this one
   dfList[(size_t)dfHeld].op=EO_COUNT;gDfDropped.fetch_add(1);gDfPx.fetch_add(dfPx);
   if(dbFrame){char l[120];snprintf(l,sizeof l,"native-metal: DB f%u p%u d%u DF dropped (overwritten by d%u)",dbFrame,dbPass,dfHeldD,d);sm2_logs(l);}
  }
  gDfDeferred.fetch_add(1);
  [self dfCapture];
  dfHeld=(int32_t)dfList.size();dfHeldD=d;memcpy(dfHeldCol,col,sizeof col);dfPx=(uint64_t)dbW*dbH;dfHeldBind=bind;dfHeldPx=!dfClipKind;
  return;
 }
 if(!dfCapturing)return;
 const bool clearIt=dfPending && dfHeld>=0 && dfHeldPx;   // mode 2: the first surviving draw of the pass is a fill (in pixels): a clear instead
 if(clearIt){gDfCleared.fetch_add(1);gDfPx.fetch_add(dfPx);if(dbFrame){char l[160];snprintf(l,sizeof l,"native-metal: DB f%u p%u d%u DF cleared (load->clear %.3f,%.3f,%.3f,%.3f)",dbFrame,dbPass,dfHeldD,
  dfHeldCol[0],dfHeldCol[1],dfHeldCol[2],dfHeldCol[3]);sm2_logs(l);}}
 [self dfRelease:clearIt clear:clearIt];
}
// u-e: a draw past the slow threshold: its pipeline, and the VkPipelines the runtime made in this frame so far (it makes them at draws).
- (void)encDescribeSlowDraw {
 uint64_t work[10]={};NBCommandBuffer *cb=self.commandBuffer;
 if(gDevice && nmb_device_work_stats(gDevice,work) && cb->encThread)
  snprintf(tEncDetail,sizeof tEncDetail,"%s; VkPipelines this frame so far %llu in %.1f ms",encPipeline[0]?encPipeline:"?",
   (unsigned long long)(work[0]-cb->encVkStart[0]),(work[1]-cb->encVkStart[1])/1e3);
 else snprintf(tEncDetail,sizeof tEncDetail,"%s",encPipeline[0]?encPipeline:"?");
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state {ENC_SCOPE(EC_BIND,"setRenderPipelineState");
 if(![(id)state isKindOfClass:[NBRenderPipeline class]]){[self.commandBuffer refuse:@"foreign render pipeline"];return;}
 if(encStatOn() || fnStatOn())memcpy(encPipeline,((NBRenderPipeline *)state)->encNames,sizeof encPipeline);
 dbPipe=(NBRenderPipeline *)state;   // ovd
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_PIPELINE;c.target=(__bridge void *)self;c.a=(__bridge_retained void *)state;c.flags=ECF_RETAIN_A;encPush(c);return;
 }
 [self check:nmb_render_set_pipeline(self.handle,[(NBRenderPipeline *)state handle]) what:"setRenderPipelineState"];
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {[self buffer:b offset:o index:i stage:1];}
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {[self buffer:b offset:o index:i stage:2];}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:1];}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:2];}
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger [])o withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self buffer:b[k] offset:o[k] index:r.location+k stage:1];
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger [])o withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self buffer:b[k] offset:o[k] index:r.location+k stage:2];
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {[self bytes:p length:n index:i stage:1];}
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {[self bytes:p length:n index:i stage:2];}
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {[self texture:t index:i stage:1];}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {[self texture:t index:i stage:2];}
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self texture:t[k] index:r.location+k stage:2];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {[self sampler:s index:i stage:1];}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {[self sampler:s index:i stage:2];}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state {ENC_SCOPE(EC_BIND,"setDepthStencilState");
 if(state)dfDss=true;   // g9
 if(state && ![(id)state isKindOfClass:[NBDepthStencil class]]){[self.commandBuffer refuse:@"foreign depth/stencil state"];return;}
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_DSS;c.target=(__bridge void *)self;if(state){c.a=(__bridge_retained void *)state;c.flags=ECF_RETAIN_A;}encPush(c);return;
 }
 [self check:nmb_render_set_depth_stencil(self.handle,state?[(NBDepthStencil *)state handle]:nullptr) what:"setDepthStencilState"];
}
- (void)setViewport:(MTLViewport)v {ENC_SCOPE(EC_BIND,"setViewport");
 if(dbFrame || dfTrack){dbVp[0]=v.originX;dbVp[1]=v.originY;dbVp[2]=v.width;dbVp[3]=v.height;dbHaveVp=true;}   // ovd
 const double values[6]={v.originX,v.originY,v.width,v.height,v.znear,v.zfar};
 // u-cpu 0x2: the same bits as the viewport set last (bitwise: a NaN or -0 is sent again unless it is the very value)
 const bool fast=cpuFast()&CPUFAST_VIEWPORT;
 if(fast && haveViewport && !memcmp(values,lastViewport,sizeof values)){gCfViewportSkips.fetch_add(1,std::memory_order_relaxed);return;}
 haveViewport=false;
 if(encDeferred) {   // u-encthread: taken as accepted (a refusal at replay fails the command buffer anyway)
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_VIEWPORT;c.target=(__bridge void *)self;memcpy(c.u,values,sizeof values);encPush(c);
  if(fast){memcpy(lastViewport,values,sizeof values);haveViewport=true;}
  gCfViewportSent.fetch_add(1,std::memory_order_relaxed);
  return;
 }
 if([self check:nmb_render_set_viewport(self.handle,values) what:"setViewport"] && fast){memcpy(lastViewport,values,sizeof values);haveViewport=true;}
 gCfViewportSent.fetch_add(1,std::memory_order_relaxed);
}
- (void)setScissorRect:(MTLScissorRect)r {ENC_SCOPE(EC_BIND,"setScissorRect");
 if(dbFrame || dfTrack){dbSc[0]=r.x;dbSc[1]=r.y;dbSc[2]=r.width;dbSc[3]=r.height;dbHaveSc=true;}   // ovd
 const uint64_t values[4]={r.x,r.y,r.width,r.height};
 const bool fast=cpuFast()&CPUFAST_VIEWPORT;
 if(fast && haveScissor && !memcmp(values,lastScissor,sizeof values)){gCfScissorSkips.fetch_add(1,std::memory_order_relaxed);return;}
 haveScissor=false;
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_SCISSOR;c.target=(__bridge void *)self;memcpy(c.u,values,sizeof values);encPush(c);
  if(fast){memcpy(lastScissor,values,sizeof values);haveScissor=true;}
  gCfScissorSent.fetch_add(1,std::memory_order_relaxed);
  return;
 }
 if([self check:nmb_render_set_scissor(self.handle,values) what:"setScissorRect"] && fast){memcpy(lastScissor,values,sizeof values);haveScissor=true;}
 gCfScissorSent.fetch_add(1,std::memory_order_relaxed);
}
// The runtime takes cull mode, winding and fill mode together; this encoder keeps Metal's defaults until each is set.
- (void)raster {ENC_SCOPE(EC_BIND,"raster state");
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_RASTER;c.target=(__bridge void *)self;c.u[0]=rasterCull;c.u[1]=rasterWinding;c.u[2]=rasterFill;encPush(c);return;
 }
 [self check:nmb_render_set_raster(self.handle,rasterCull,rasterWinding,rasterFill) what:"raster state"];
}
- (void)setCullMode:(MTLCullMode)m {rasterCull=(uint64_t)m;[self raster];}
- (void)setFrontFacingWinding:(MTLWinding)w {rasterWinding=(uint64_t)w;[self raster];}
- (void)setTriangleFillMode:(MTLTriangleFillMode)f {rasterFill=(uint64_t)f;[self raster];}
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp {
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_DEPTH_BIAS;c.target=(__bridge void *)self;memcpy(&c.u[0],&bias,4);memcpy(&c.u[1],&slope,4);memcpy(&c.u[2],&clamp,4);
  encPush(c);return;
 }
 [self check:nmb_render_set_depth_bias(self.handle,bias,slope,clamp) what:"setDepthBias"];
}
- (void)setLineWidth:(float)width {
 if(encDeferred){ET_REC;ENC_LIVE();EncCmd c={};c.op=EO_LINE_WIDTH;c.target=(__bridge void *)self;memcpy(&c.u[0],&width,4);encPush(c);return;}
 [self check:nmb_render_set_line_width(self.handle,width) what:"setLineWidth"];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
 if(encDeferred){ET_REC;ENC_LIVE();EncCmd c={};c.op=EO_VISIBILITY;c.target=(__bridge void *)self;c.u[0]=(uint64_t)mode;c.u[1]=offset;encPush(c);return;}
 [self check:nmb_render_set_visibility_mode(self.handle,mode,offset) what:"setVisibilityResultMode"];
}
- (void)setFragmentTexture:(id<MTLTexture>)t atTextureIndex:(NSUInteger)ti samplerState:(id<MTLSamplerState>)s atSamplerIndex:(NSUInteger)si {
 [self texture:t index:ti stage:2];[self sampler:s index:si stage:2];
}
// Tile shaders and imageblock tile memory (Apple GPU families 4 and up) are not offered: supportsTileShaders answers no, and a call that
// reaches one anyway fails its command buffer.
- (NSUInteger)tileWidth {return 0;}
- (NSUInteger)tileHeight {return 0;}
- (void)setTileTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {(void)t;(void)i;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)setTileBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {(void)p;(void)n;(void)i;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)dispatchThreadsPerTile:(MTLSize)size {(void)size;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)dispatchThreadsPerTile:(MTLSize)size inRegion:(MTLRegion)region {(void)size;(void)region;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)setStencilReferenceValue:(uint32_t)v {
 if(encDeferred){[self setStencilFrontReferenceValue:v backReferenceValue:v];return;}
 [self check:nmb_render_set_stencil_reference(self.handle,v,v) what:"setStencilReferenceValue"];
}
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b {
 if(encDeferred){ET_REC;ENC_LIVE();EncCmd c={};c.op=EO_STENCIL_REF;c.target=(__bridge void *)self;c.u[0]=f;c.u[1]=b;encPush(c);return;}
 [self check:nmb_render_set_stencil_reference(self.handle,f,b) what:"setStencilReferenceValues"];
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_BLEND_COLOR;c.target=(__bridge void *)self;const float v[4]={r,g,b,a};memcpy(c.u,v,sizeof v);encPush(c);return;
 }
 const float c[4]={r,g,b,a};[self check:nmb_render_set_blend_color(self.handle,c) what:"setBlendColor"];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i baseInstance:(NSUInteger)b {ENC_SCOPE(EC_DRAW,"drawPrimitives");
 gDraws++;self.commandBuffer->encodedWork.draws++;
 if(fnStatOn())fnNote((__bridge const void *)self,encPipeline,(uint32_t)n,(uint32_t)i,s);
 if(dbFrame)[self dbDraw:(uint32_t)t start:(uint32_t)s count:(uint32_t)n inst:(uint32_t)i index:nil type:0 offset:0 base:0];   // ovd
 if(dfTrack)[self dfDraw:(uint32_t)t start:(uint32_t)s count:(uint32_t)n inst:(uint32_t)i index:nil type:0 offset:0 base:0];   // g9
 if(encDeferred) {
  ET_REC;ENC_LIVE();
  EncCmd c={};c.op=EO_DRAW;c.target=(__bridge void *)self;c.u[0]=(uint64_t)t;c.u[1]=(uint32_t)s;c.u[2]=(uint32_t)n;c.u[3]=(uint32_t)i;c.u[4]=(uint32_t)b;
  encPush(c);return;
 }
 [self check:nmb_render_draw(self.handle,t,(uint32_t)s,(uint32_t)n,(uint32_t)i,(uint32_t)b) what:"drawPrimitives"];
 if(encScope_.slow())[self encDescribeSlowDraw];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i {
 [self drawPrimitives:t vertexStart:s vertexCount:n instanceCount:i baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {
 [self drawPrimitives:t vertexStart:s vertexCount:n instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)k indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o
                instanceCount:(NSUInteger)i baseVertex:(NSInteger)v baseInstance:(NSUInteger)bi {ENC_SCOPE(EC_DRAW,"drawIndexedPrimitives");
 if(![(id)b isKindOfClass:[NBBuffer class]]){[self.commandBuffer refuse:@"foreign index buffer"];return;}
 if(encDeferred)ENC_LIVE();
 [self.commandBuffer.resourceOwners addObject:b];
 gDraws++;self.commandBuffer->encodedWork.draws++;
 if(fnStatOn())fnNote((__bridge const void *)self,encPipeline,(uint32_t)n,(uint32_t)i,0);
 if(dbFrame)[self dbDraw:(uint32_t)t start:0 count:(uint32_t)n inst:(uint32_t)i index:b type:(uint32_t)k offset:o base:(int32_t)v];   // ovd
 if(dfTrack)[self dfDraw:(uint32_t)t start:0 count:(uint32_t)n inst:(uint32_t)i index:b type:(uint32_t)k offset:o base:(int32_t)v];   // g9
 if(encDeferred) {
  ET_REC;
  EncCmd c={};c.op=EO_DRAW_INDEXED;c.target=(__bridge void *)self;c.a=(__bridge void *)b;c.u[0]=(uint64_t)t;c.u[1]=(uint64_t)(uint32_t)n<<32|(uint32_t)i;
  c.u[2]=(uint64_t)k;c.u[3]=o;c.u[4]=(uint64_t)(uint32_t)(int32_t)v<<32|(uint32_t)bi;
  encPush(c);return;
 }
 [self check:nmb_render_draw_indexed(self.handle,t,(uint32_t)n,k,[(NBBuffer *)b handle],o,(uint32_t)i,(int32_t)v,(uint32_t)bi) what:"drawIndexedPrimitives"];
 if(encScope_.slow())[self encDescribeSlowDraw];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)k indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o
                instanceCount:(NSUInteger)i {
 [self drawIndexedPrimitives:t indexCount:n indexType:k indexBuffer:b indexBufferOffset:o instanceCount:i baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)k indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o {
 [self drawIndexedPrimitives:t indexCount:n indexType:k indexBuffer:b indexBufferOffset:o instanceCount:1 baseVertex:0 baseInstance:0];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s {(void)r;(void)u;(void)s;}
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages {[self fence:fence stages:stages update:true];}
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages {[self fence:fence stages:stages update:false];}
@end

@interface NBBlitEncoder : NBEncoder
@end
@implementation NBBlitEncoder
// The arguments are passed as a plain array: an NSArray literal raises on a nil element, and a nil resource (a refused allocation) must fail the
// command buffer like any invalid argument, not abort the host process.
#define NB_OBJECTS(...) ((__unsafe_unretained id[]){__VA_ARGS__})
- (bool)buffers:(__unsafe_unretained id *)objects count:(size_t)count {
 for(size_t i=0;i<count;i++)if(![objects[i] isKindOfClass:[NBBuffer class]]){[self.commandBuffer refuse:@"missing or foreign blit buffer"];return false;}
 for(size_t i=0;i<count;i++)[self.commandBuffer.resourceOwners addObject:objects[i]];
 return true;
}
// written: bit i set when the blit writes objects[i] (a destination). A source that is a converted YCbCr copy is filled again first
// (C2: before, only draws refreshed it, and a blit copied the stale picture).
- (bool)textures:(__unsafe_unretained id *)objects count:(size_t)count written:(unsigned)written {
 for(size_t i=0;i<count;i++) {
  id o=objects[i];
  if(![o isKindOfClass:[NBTexture class]]){[self.commandBuffer refuse:@"missing or foreign blit texture"];return false;}
  [self.commandBuffer.resourceOwners addObject:o];
  if([(NBTexture *)o surface]) {
   [self.commandBuffer.surfaces addObject:o];
   if(written&(1u<<i))[self.commandBuffer.writtenSurfaces addObject:o];
  }
  if(!(written&(1u<<i)) && !encDeferred)ycbcrRefresh((NBTexture *)o,self.commandBuffer);   // u-encthread: the replay's
 }
 return true;
}
- (void)copyFromBuffer:(id<MTLBuffer>)s sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)d destinationOffset:(NSUInteger)dO size:(NSUInteger)n {ENC_SCOPE(EC_BLIT,"blit copyBuffer");
 if(encDeferred)ENC_LIVE();
 if(![self buffers:NB_OBJECTS(s,d) count:2])return;
 if(encDeferred) {
  ET_REC;EncCmd c={};c.op=EO_COPY_BUFFER;c.target=(__bridge void *)self;c.a=(__bridge void *)s;c.b=(__bridge void *)d;c.u[0]=so;c.u[1]=dO;c.u[2]=n;
  encPush(c);return;
 }
 [self check:nmb_blit_copy_buffer(self.handle,[(NBBuffer *)s handle],so,[(NBBuffer *)d handle],dO,n) what:"copyFromBuffer:toBuffer:"];
}
- (void)fillBuffer:(id<MTLBuffer>)b range:(NSRange)r value:(uint8_t)v {ENC_SCOPE(EC_BLIT,"blit fillBuffer");
 if(encDeferred)ENC_LIVE();
 if(![self buffers:NB_OBJECTS(b) count:1])return;
 if(encDeferred) {
  ET_REC;EncCmd c={};c.op=EO_FILL_BUFFER;c.target=(__bridge void *)self;c.a=(__bridge void *)b;c.u[0]=r.location;c.u[1]=r.location+r.length;c.u[2]=v;
  encPush(c);return;
 }
 [self check:nmb_blit_fill_buffer(self.handle,[(NBBuffer *)b handle],r.location,r.location+r.length,v) what:"fillBuffer"];
}
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)z
              toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dO {ENC_SCOPE(EC_BLIT,"blit copyTexture");
 if(encDeferred)ENC_LIVE();
 if(![self textures:NB_OBJECTS(s,d) count:2 written:2])return;
 const uint64_t a[3]={so.x,so.y,so.z},size[3]={z.width,z.height,z.depth},b[3]={dO.x,dO.y,dO.z};
 if(encDeferred) {
  ET_REC;EncCmd c={};c.op=EO_COPY_TEXTURE;c.target=(__bridge void *)self;c.a=(__bridge void *)s;c.b=(__bridge void *)d;c.mask=1;
  const uint64_t args[13]={ss,sl,a[0],a[1],a[2],size[0],size[1],size[2],ds,dl,b[0],b[1],b[2]};
  encPush(c,args,sizeof args);return;
 }
 [self check:nmb_blit_copy_texture(self.handle,[(NBTexture *)s handle],ss,sl,a,size,[(NBTexture *)d handle],ds,dl,b) what:"copyFromTexture:toTexture:"];
}
- (void)copyFromTexture:(id<MTLTexture>)s toTexture:(id<MTLTexture>)d {ENC_SCOPE(EC_BLIT,"blit copyTexture(whole)");
 if(![self textures:NB_OBJECTS(s,d) count:2 written:2])return;
 const NSUInteger levels=MIN(s.mipmapLevelCount,d.mipmapLevelCount),slices=MIN(s.arrayLength,d.arrayLength);
 for(NSUInteger slice=0;slice<slices;slice++)for(NSUInteger level=0;level<levels;level++) {
  MTLSize size=MTLSizeMake(MAX(s.width>>level,(NSUInteger)1),MAX(s.height>>level,(NSUInteger)1),MAX(s.depth>>level,(NSUInteger)1));
  [self copyFromTexture:s sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:size toTexture:d destinationSlice:slice
       destinationLevel:level destinationOrigin:MTLOriginMake(0,0,0)];
 }
}
- (void)copyFromBuffer:(id<MTLBuffer>)s sourceOffset:(NSUInteger)o sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)image
            sourceSize:(MTLSize)z toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
     destinationOrigin:(MTLOrigin)dO {ENC_SCOPE(EC_BLIT,"blit bufferToTexture");
 if(encDeferred)ENC_LIVE();
 if(![self buffers:NB_OBJECTS(s) count:1] || ![self textures:NB_OBJECTS(d) count:1 written:1])return;
 const uint64_t size[3]={z.width,z.height,z.depth},b[3]={dO.x,dO.y,dO.z};
 if(encDeferred) {
  ET_REC;EncCmd c={};c.op=EO_BUFFER_TO_TEXTURE;c.target=(__bridge void *)self;c.a=(__bridge void *)s;c.b=(__bridge void *)d;
  const uint64_t args[11]={o,row,image,size[0],size[1],size[2],slice,level,b[0],b[1],b[2]};
  encPush(c,args,sizeof args);return;
 }
 [self check:nmb_blit_buffer_to_texture(self.handle,[(NBBuffer *)s handle],o,row,image,size,[(NBTexture *)d handle],slice,level,b) what:"copyFromBuffer:toTexture:"];
}
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)z
               toBuffer:(id<MTLBuffer>)d destinationOffset:(NSUInteger)o destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)image {ENC_SCOPE(EC_BLIT,"blit textureToBuffer");
 if(encDeferred)ENC_LIVE();
 if(![self textures:NB_OBJECTS(s) count:1 written:0] || ![self buffers:NB_OBJECTS(d) count:1])return;
 const uint64_t a[3]={so.x,so.y,so.z},size[3]={z.width,z.height,z.depth};
 if(encDeferred) {
  ET_REC;EncCmd c={};c.op=EO_TEXTURE_TO_BUFFER;c.target=(__bridge void *)self;c.a=(__bridge void *)s;c.b=(__bridge void *)d;c.mask=1;
  const uint64_t args[11]={slice,level,a[0],a[1],a[2],size[0],size[1],size[2],o,row,image};
  encPush(c,args,sizeof args);return;
 }
 [self check:nmb_blit_texture_to_buffer(self.handle,[(NBTexture *)s handle],slice,level,a,size,[(NBBuffer *)d handle],o,row,image) what:"copyFromTexture:toBuffer:"];
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)t {ENC_SCOPE(EC_BLIT,"blit generateMipmaps");
 if(encDeferred)ENC_LIVE();
 if(![self textures:NB_OBJECTS(t) count:1 written:1])return;
 if(encDeferred){ET_REC;EncCmd c={};c.op=EO_MIPMAPS;c.target=(__bridge void *)self;c.a=(__bridge void *)t;encPush(c);return;}
 [self check:nmb_blit_generate_mipmaps(self.handle,[(NBTexture *)t handle]) what:"generateMipmapsForTexture"];
}
- (void)synchronizeResource:(id<MTLResource>)r {(void)r;}
@end

// u-encthread: one recorded command, on the worker (in call order): the bridge calls the inline paths make, with the same refusals.
static void encReplay(const EncCmd &c,const uint8_t *bytes) {
 if(c.op==EO_COMMIT) {
  NBCommandBuffer *cb=(__bridge_transfer NBCommandBuffer *)c.target;
  cb->encCommitStarted=true;
  const uint64_t s0=mach_absolute_time(),f0=cb->tlFrame && cb->tlFirstEncoder?tlNow():0;
  [cb commitSubmit];
  const uint64_t s1=mach_absolute_time();
  cb->encCommitDone=true;
  if(cb->encCommitTick && s0>=cb->encCommitTick) {   // g4: the submit's lag
   const double tick=encTickNs();
   const int64_t lag[4]={(int64_t)((s0-cb->encCommitTick)*tick),(int64_t)((s0-std::max(cb->encCommitTick,gEqWakeTick))*tick),
    (int64_t)((s1-s0)*tick),f0?(int64_t)f0-(int64_t)cb->tlFirstEncoder:-1};
   std::lock_guard<std::mutex> l(gEtLatLock);
   for(int i=0;i<4;i++)if(lag[i]>=0 && gEtLat[i].size()<4096)gEtLat[i].push_back(lag[i]);
  }
  gEtCommits.fetch_add(1,std::memory_order_relaxed);
  return;
 }
 if(c.op==EO_EVENT) {
  NBCommandBuffer *cb=(__bridge_transfer NBCommandBuffer *)c.target;NBEvent *event=(__bridge_transfer NBEvent *)c.a;
  const bool signal=c.u[1];
  if(!(signal?nmb_command_buffer_signal_event(cb.handle,event.handle,c.u[0]):nmb_command_buffer_wait_event(cb.handle,event.handle,c.u[0])))
   [cb refuse:[NSString stringWithFormat:@"%s: %@",signal?"encodeSignalEvent":"encodeWaitForEvent",lastError()]];
  return;
 }
 if(c.op==EO_RENDER_NEW || c.op==EO_BLIT_NEW) {   // the recorded creation keeps the encoder until its end
  NBEncoder *e=(__bridge NBEncoder *)c.target;NBCommandBuffer *cb=e.commandBuffer;
  NmbEncoder *h=c.op==EO_RENDER_NEW?nmb_render_encoder_new(cb.handle,(const NmbRenderPassDescriptor *)(bytes+c.off)):nmb_blit_encoder_new(cb.handle);
  if(!h)[cb refuse:[NSString stringWithFormat:@"%@: %@",c.op==EO_RENDER_NEW?@"renderCommandEncoder":@"blitCommandEncoder",lastError()]];
  e.handle=h;
  return;
 }
 if(c.op==EO_END || c.op==EO_DISCARD) {
  NBEncoder *e=(__bridge_transfer NBEncoder *)c.target;
  NmbEncoder *h=e.handle;e.handle=nullptr;
  if(h){if(c.op==EO_END)[e check:nmb_encoder_end(h) what:"endEncoding"];else nmb_encoder_discard(h);}
  return;
 }
 NBEncoder *e=(__bridge NBEncoder *)c.target;
 id a;   // released at the end of the replay when the command retained it
 if(c.flags&ECF_RETAIN_A)a=(__bridge_transfer id)c.a;else a=(__bridge id)c.a;
 NmbEncoder *h=e.handle;
 if(!h)return;   // its creation was refused: the command buffer failed then
 const uint32_t stage=c.stage,index=c.index;
 switch(c.op) {
 case EO_BUFFER:[e check:nmb_encoder_set_buffer(h,stage,a?[(NBBuffer *)a handle]:nullptr,c.u[0],index) what:"setBuffer"];break;
 case EO_OFFSET:[e check:nmb_encoder_set_buffer_offset(h,stage,c.u[0],index) what:"setBufferOffset"];break;
 case EO_BYTES:
  [e check:c.flags&ECF_NULL_BYTES?nmb_encoder_set_bytes(h,stage,(const void *)(uintptr_t)c.u[0],(size_t)c.u[1],index):
                                  nmb_encoder_set_bytes(h,stage,bytes+c.off,c.len,index) what:"setBytes"];
  break;
 case EO_TEXTURE: {
  NBTexture *t=(NBTexture *)a;
  if(t) {
   ycbcrRefresh(t,e.commandBuffer);
   // a replaceRegion since the bind was recorded: its bytes are not the seed's (0 = copied again)
   if(shadowSeedOn() && t.surface && !t.ycbcrGPU)
    nmb_texture_set_bytes_generation(t.handle,t->encReplaceEpoch.load()==(uint32_t)c.u[0]?(uint64_t)IOSurfaceGetSeed(t.surface)+1:0);
  }
  [e check:nmb_encoder_set_texture(h,stage,t?t.handle:nullptr,index) what:"setTexture"];
  break;
 }
 case EO_SAMPLER:[e check:nmb_encoder_set_sampler(h,stage,a?[(NBSampler *)a handle]:nullptr,index) what:"setSamplerState"];break;
 case EO_FENCE: {
  NmbFence *f=[(NBFence *)a handle];const bool update=c.u[1];
  [e check:update?nmb_encoder_update_fence(h,f,c.u[0]):nmb_encoder_wait_fence(h,f,c.u[0]) what:update?"updateFence":"waitForFence"];
  break;
 }
 case EO_PIPELINE:[e check:nmb_render_set_pipeline(h,[(NBRenderPipeline *)a handle]) what:"setRenderPipelineState"];break;
 case EO_DSS:[e check:nmb_render_set_depth_stencil(h,a?[(NBDepthStencil *)a handle]:nullptr) what:"setDepthStencilState"];break;
 case EO_VIEWPORT: {double v[6];memcpy(v,c.u,sizeof v);[e check:nmb_render_set_viewport(h,v) what:"setViewport"];break;}
 case EO_SCISSOR:[e check:nmb_render_set_scissor(h,c.u) what:"setScissorRect"];break;
 case EO_RASTER:[e check:nmb_render_set_raster(h,c.u[0],c.u[1],c.u[2]) what:"raster state"];break;
 case EO_DEPTH_BIAS: {
  float v[3];memcpy(&v[0],&c.u[0],4);memcpy(&v[1],&c.u[1],4);memcpy(&v[2],&c.u[2],4);
  [e check:nmb_render_set_depth_bias(h,v[0],v[1],v[2]) what:"setDepthBias"];break;
 }
 case EO_LINE_WIDTH: {float w;memcpy(&w,&c.u[0],4);[e check:nmb_render_set_line_width(h,w) what:"setLineWidth"];break;}
 case EO_VISIBILITY:[e check:nmb_render_set_visibility_mode(h,c.u[0],c.u[1]) what:"setVisibilityResultMode"];break;
 case EO_STENCIL_REF:[e check:nmb_render_set_stencil_reference(h,(uint32_t)c.u[0],(uint32_t)c.u[1]) what:"setStencilReferenceValues"];break;
 case EO_BLEND_COLOR: {float v[4];memcpy(v,c.u,sizeof v);[e check:nmb_render_set_blend_color(h,v) what:"setBlendColor"];break;}
 case EO_DRAW:
  [e check:nmb_render_draw(h,c.u[0],(uint32_t)c.u[1],(uint32_t)c.u[2],(uint32_t)c.u[3],(uint32_t)c.u[4]) what:"drawPrimitives"];break;
 case EO_DRAW_INDEXED:
  [e check:nmb_render_draw_indexed(h,c.u[0],(uint32_t)(c.u[1]>>32),c.u[2],[(NBBuffer *)a handle],c.u[3],(uint32_t)c.u[1],
                                   (int32_t)(uint32_t)(c.u[4]>>32),(uint32_t)c.u[4]) what:"drawIndexedPrimitives"];
  break;
 case EO_COPY_BUFFER:
  [e check:nmb_blit_copy_buffer(h,[(NBBuffer *)a handle],c.u[0],[(NBBuffer *)(__bridge id)c.b handle],c.u[1],c.u[2]) what:"copyFromBuffer:toBuffer:"];
  break;
 case EO_FILL_BUFFER:[e check:nmb_blit_fill_buffer(h,[(NBBuffer *)a handle],c.u[0],c.u[1],(uint8_t)c.u[2]) what:"fillBuffer"];break;
 case EO_COPY_TEXTURE: {
  NBTexture *s=(NBTexture *)a,*d=(__bridge NBTexture *)c.b;
  if(c.mask&1)ycbcrRefresh(s,e.commandBuffer);
  const uint64_t *v=(const uint64_t *)(bytes+c.off);
  [e check:nmb_blit_copy_texture(h,s.handle,v[0],v[1],v+2,v+5,d.handle,v[8],v[9],v+10) what:"copyFromTexture:toTexture:"];
  break;
 }
 case EO_BUFFER_TO_TEXTURE: {
  const uint64_t *v=(const uint64_t *)(bytes+c.off);
  [e check:nmb_blit_buffer_to_texture(h,[(NBBuffer *)a handle],v[0],v[1],v[2],v+3,[(__bridge NBTexture *)c.b handle],v[6],v[7],v+8)
       what:"copyFromBuffer:toTexture:"];
  break;
 }
 case EO_TEXTURE_TO_BUFFER: {
  NBTexture *s=(NBTexture *)a;
  if(c.mask&1)ycbcrRefresh(s,e.commandBuffer);
  const uint64_t *v=(const uint64_t *)(bytes+c.off);
  [e check:nmb_blit_texture_to_buffer(h,s.handle,v[0],v[1],v+2,v+5,[(__bridge NBBuffer *)c.b handle],v[8],v[9],v[10]) what:"copyFromTexture:toBuffer:"];
  break;
 }
 case EO_MIPMAPS:[e check:nmb_blit_generate_mipmaps(h,[(NBTexture *)a handle]) what:"generateMipmapsForTexture"];break;
 default:break;
 }
}

static void completed(void *context);
static void scheduled(void *context);
// SweetMetal2 (C6): a lost Vulkan device (Turnip's: the kernel reported this client's work lost in a GPU reset, or a submit/wait
// failed) fails every later command buffer of the process: backboardd's screen froze (seen once on r18e). A refused IOSurface import
// is not that: Turnip answers it VK_ERROR_INVALID_EXTERNAL_HANDLE / OUT_OF_DEVICE_MEMORY, and the texture over it is refused alone
// (nil, logged), the device stays. When the device is lost all the same, backboardd exits once logged, so launchd starts it again with
// a new device (at most 3 times a boot, /var/local/mtl2-lost.count; never with /var/local/mtl2-lost-stay). Other processes log it.
static void noteDeviceLost(const char *why) {
 if(!why || (!strcasestr(why,"device was lost") && !strcasestr(why,"device lost") && !strcasestr(why,"DEVICE_LOST")))return;
 static std::atomic<bool> once{false};
 if(once.exchange(true))return;
 NBLOG(@"native-metal: the GPU device is lost (%s): every later command buffer fails",why);
 if(strcmp(getprogname(),"backboardd"))return;
 if(access("/var/local/mtl2-lost-stay",F_OK)==0){NBLOG(@"native-metal: backboardd stays (/var/local/mtl2-lost-stay)");return;}
 struct timeval boot={};size_t length=sizeof boot;sysctlbyname("kern.boottime",&boot,&length,nullptr,0);
 long long bootSeen=0;int restarts=0;
 if(FILE *f=fopen("/var/local/mtl2-lost.count","r")){if(fscanf(f,"%lld %d",&bootSeen,&restarts)!=2)restarts=0;fclose(f);}
 if(bootSeen!=(long long)boot.tv_sec)restarts=0;
 if(restarts>=3){NBLOG(@"native-metal: backboardd stays: 3 restarts for a lost device this boot already");return;}
 if(FILE *f=fopen("/var/local/mtl2-lost.count","w")){fprintf(f,"%lld %d\n",(long long)boot.tv_sec,restarts+1);fclose(f);}
 NBLOG(@"native-metal: backboardd exits for a new GPU device (restart %d of 3 this boot)",restarts+1);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{_exit(75);});
}
@implementation NBCommandBuffer
- (instancetype)init {
 if((self=[super init])){_scheduledHandlers=[NSMutableArray array];_completedHandlers=[NSMutableArray array];_surfaces=[NSMutableSet set];_writtenSurfaces=[NSMutableSet set];_resourceOwners=[NSMutableSet set];_handlers=dispatch_group_create();_schedulingHandlers=dispatch_group_create();}
 if(self){createdUs=nowUs();if(timelineOn())tlCreated=tlNow();encDeferred=encThreadOn();}
 return self;
}
- (void)dealloc {nmb_command_buffer_release(_handle);}
- (id<MTLCommandQueue>)commandQueue {return (id<MTLCommandQueue>)_queue;}
- (BOOL)retainedReferences {return YES;}
// Protected content is not supported (the runtime's AppleOnlyCall::SetProtectionOptions takes Metal's default only): any other option fails
// the command buffer.
- (uint64_t)protectionOptions {return 0;}
- (void)setProtectionOptions:(uint64_t)options {if(options)[self refuse:[NSString stringWithFormat:@"protection options 0x%llx",options]];}
- (void)refuse:(NSString *)what {
 if(!self.encodeFailure){self.encodeFailure=what;NBLOG(@"native-metal: command buffer refused: %@",what);}
}
- (MTLCommandBufferStatus)status {
 if(self.failedLocally)return MTLCommandBufferStatusError;
 if(encDeferred) {   // u-encthread: the bridge has the command buffer to itself until its commit is replayed
  if(!encCommitStarted.load())return self.committed?MTLCommandBufferStatusCommitted:MTLCommandBufferStatusNotEnqueued;
  const uint64_t raw=nmb_command_buffer_status(_handle);
  return (MTLCommandBufferStatus)(raw<MTLCommandBufferStatusCommitted?MTLCommandBufferStatusCommitted:raw);
 }
 return (MTLCommandBufferStatus)nmb_command_buffer_status(_handle);
}
- (NSError *)error {
 if(self.failedLocally)return nbError(self.encodeFailure);
 if(encDeferred && !encCommitStarted.load())return nil;
 if(self.status!=MTLCommandBufferStatusError)return nil;
 char text[512]={};nmb_command_buffer_error(_handle,text,sizeof text);
 return nbError([NSString stringWithUTF8String:text]);
}
// Debug groups and cache hints name work for tools and the driver's caches; they change nothing the GPU computes here.
- (void)pushDebugGroup:(NSString *)name {(void)name;}
- (void)popDebugGroup {}
- (void)encodeCacheHintTag:(uint64_t)tag resourceGroups:(const id __unsafe_unretained [])groups count:(NSUInteger)count {(void)tag;(void)groups;(void)count;}
- (void)encodeCacheHintFinalize:(uint64_t)tag resourceGroups:(const id __unsafe_unretained [])groups count:(NSUInteger)count {(void)tag;(void)groups;(void)count;}
// The kernel driver's own submission times are not recorded: 0 is Metal's answer where they are unavailable.
- (CFTimeInterval)kernelStartTime {return 0;}
- (CFTimeInterval)kernelEndTime {return 0;}
- (BOOL)commitAndWaitUntilSubmitted {tlWaitedScheduled=true;[(id<MTLCommandBuffer>)self commit];[self waitUntilScheduled];return !self.failedLocally;}
- (CFTimeInterval)GPUStartTime {return encDeferred && !encCommitStarted.load()?0:nmb_command_buffer_gpu_time(_handle,false);}
- (CFTimeInterval)GPUEndTime {return encDeferred && !encCommitStarted.load()?0:nmb_command_buffer_gpu_time(_handle,true);}
// u-encthread: a recorded encoder; its bridge encoder is made by the worker (EO_RENDER_NEW/EO_BLIT_NEW: the pass copied).
- (id)deferredEncoder:(NBEncoder *)encoder op:(uint8_t)op pass:(const NmbRenderPassDescriptor *)pass what:(NSString *)what {
 ET_REC;
 if(!tlFirstEncoder && tlCreated)tlFirstEncoder=tlNow();
 if(self.committed){[self refuse:[what stringByAppendingString:@" after commit"]];return nil;}
 encoder.commandBuffer=self;encoder->encDeferred=true;
 encOpen=encoder;
 EncCmd c={};c.op=op;c.target=(__bridge_retained void *)encoder;   // released as its end (or discard) is replayed
 encPush(c,pass,pass?sizeof *pass:0);
 return encoder;
}
- (id)encoder:(NBEncoder *)encoder handle:(NmbEncoder *)handle what:(NSString *)what {
 if(!tlFirstEncoder && tlCreated)tlFirstEncoder=tlNow();
 if(self.committed){[self refuse:[what stringByAppendingString:@" after commit"]];return nil;}
 if(!handle){[self refuse:[NSString stringWithFormat:@"%@: %@",what,lastError()]];return nil;}
 encoder.handle=handle;encoder.commandBuffer=self;return encoder;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
 [self encBegin];ENC_SCOPE(EC_ENC,"computeCommandEncoder");
 // u-encthread: compute stays inline: the worker first replays what this command buffer (and every other) recorded
 if(encDeferred)encFlush(EF_COMPUTE);
 return [self encoder:[NBComputeEncoder new] handle:self.committed?nullptr:nmb_compute_encoder_new(_handle) what:@"computeCommandEncoder"];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type {
 if(type!=MTLDispatchTypeSerial){[self refuse:@"concurrent compute dispatch"];return nil;}
 return [self computeCommandEncoder];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
 [self encBegin];ENC_SCOPE(EC_ENC,"blitCommandEncoder");
 gBlits++;encodedWork.blits++;
 if(encDeferred)return [self deferredEncoder:[NBBlitEncoder new] op:EO_BLIT_NEW pass:nullptr what:@"blitCommandEncoder"];
 return [self encoder:[NBBlitEncoder new] handle:self.committed?nullptr:nmb_blit_encoder_new(_handle) what:@"blitCommandEncoder"];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
 [self encBegin];ENC_SCOPE(EC_ENC,"renderCommandEncoder");
 NmbRenderPassDescriptor pass={};
 {
  id<MTLTexture> first=d.colorAttachments[0].texture;
  if(first) {
   const uint64_t pixels=(uint64_t)first.width*first.height;
   gPasses++;gPassPixels+=pixels;encodedWork.passes++;encodedWork.pixels+=pixels;
   uint64_t seen=gBiggestPass.load();while(pixels>seen && !gBiggestPass.compare_exchange_weak(seen,pixels)){}
   if(pixels>=2000000)gFullScreenPasses++;
   if(pixels>=1500000 && [(id)first isKindOfClass:[NBTexture class]] && ((NBTexture *)first).surface){tlFrame=true;tlSurface=IOSurfaceGetID(((NBTexture *)first).surface);}
  }
 }
 auto attachment=[&](MTLRenderPassAttachmentDescriptor *a,NmbPassAttachment &out)->bool {
  if(!a.texture)return true;
  if(![(id)a.texture isKindOfClass:[NBTexture class]])return false;
  NBTexture *texture=(NBTexture *)a.texture;if(texture.surface){[_surfaces addObject:texture];[_writtenSurfaces addObject:texture];}
  if(texture.rotationValue)self.rotatedFrame=YES;
  [_resourceOwners addObject:texture];
  out.texture=texture.handle;out.level=a.level;out.slice=a.slice;out.depth_plane=a.depthPlane;out.load=a.loadAction;out.store=a.storeAction;
  return true;
 };
 for(unsigned i=0;i<8;i++) {
  MTLRenderPassColorAttachmentDescriptor *c=d.colorAttachments[i];
  if(!attachment(c,pass.colors[i])){[self refuse:@"foreign color attachment"];return nil;}
  pass.colors[i].clear[0]=c.clearColor.red;pass.colors[i].clear[1]=c.clearColor.green;pass.colors[i].clear[2]=c.clearColor.blue;pass.colors[i].clear[3]=c.clearColor.alpha;
 }
 if(!attachment(d.depthAttachment,pass.depth) || !attachment(d.stencilAttachment,pass.stencil)){[self refuse:@"foreign depth/stencil attachment"];return nil;}
 pass.depth.clear[0]=d.depthAttachment.clearDepth;pass.stencil.clear[0]=d.stencilAttachment.clearStencil;
 pass.width=d.renderTargetWidth;pass.height=d.renderTargetHeight;pass.array_length=d.renderTargetArrayLength;pass.samples=d.defaultRasterSampleCount;
 if(d.visibilityResultBuffer) {
  if(![(id)d.visibilityResultBuffer isKindOfClass:[NBBuffer class]]){[self refuse:@"foreign visibility result buffer"];return nil;}
  [_resourceOwners addObject:d.visibilityResultBuffer];
  pass.visibility=[(NBBuffer *)d.visibilityResultBuffer handle];
 }
 NBRenderEncoder *re=[NBRenderEncoder new];
 if(gDrawboxLeft.load(std::memory_order_relaxed)>0 && timelineOn()) {   // ovd: SWEET_DRAWBOX
  if(!dbFrame)dbFrame=gDrawboxSeq.fetch_add(1)+1;
  re->dbFrame=dbFrame;re->dbPass=dbPasses++;
  id<MTLTexture> t=d.colorAttachments[0].texture;re->dbW=t?(uint32_t)t.width:0;re->dbH=t?(uint32_t)t.height:0;re->dbLoad=(uint32_t)d.colorAttachments[0].loadAction;
  char line[200];snprintf(line,sizeof line,"native-metal: DB f%u p%u pass %ux%u fmt %lu load %u store %lu surface %u",dbFrame,re->dbPass,re->dbW,re->dbH,
   t?(unsigned long)t.pixelFormat:0ul,re->dbLoad,(unsigned long)d.colorAttachments[0].storeAction,
   (t && [(id)t isKindOfClass:[NBTexture class]] && ((NBTexture *)t).surface)?IOSurfaceGetID(((NBTexture *)t).surface):0u);
  sm2_logs(line);
 }
 // g9 (SWEET_DEADFILL, backboardd): fills tracked; mode 2 holds the creation of a pass that loads colour 0 and has nothing else attached
 static const bool dfProc=!strcmp(getprogname(),"backboardd");
 if(const int mode=dfProc?deadfillMode():0) {
  id<MTLTexture> t=d.colorAttachments[0].texture;
  re->dfTrack=true;re->dfMode=(int8_t)mode;re->dfHeld=-1;re->dbW=t?(uint32_t)t.width:0;re->dbH=t?(uint32_t)t.height:0;
  bool alone=t && !d.depthAttachment.texture && !d.stencilAttachment.texture && !d.visibilityResultBuffer;
  for(unsigned i=1;i<8 && alone;i++)if(d.colorAttachments[i].texture)alone=false;
  const MTLLoadAction load=d.colorAttachments[0].loadAction;
  const MTLPixelFormat pf=t?t.pixelFormat:MTLPixelFormatInvalid;   // 8-bit unorm targets only: a clear value and a written colour store alike
  if(mode>=2 && alone && (pf==MTLPixelFormatBGRA8Unorm || pf==MTLPixelFormatRGBA8Unorm) && (load==MTLLoadActionLoad || load==MTLLoadActionDontCare) && !self.committed) {
   if(!tlFirstEncoder && tlCreated)tlFirstEncoder=tlNow();
   re.commandBuffer=self;re->dfPass=new NmbRenderPassDescriptor(pass);re->dfPending=true;
   if(encDeferred){re->encDeferred=true;encOpen=re;}
   [re dfCapture];
   return re;
  }
 }
 if(encDeferred)return [self deferredEncoder:re op:EO_RENDER_NEW pass:&pass what:@"renderCommandEncoder"];
 return [self encoder:re handle:self.committed?nullptr:nmb_render_encoder_new(_handle,&pass) what:@"renderCommandEncoder"];
}
- (void)addScheduledHandler:(MTLCommandBufferHandler)block {ENC_SCOPE(EC_CB,"addScheduledHandler");if(block)@synchronized(self){[_scheduledHandlers addObject:[block copy]];}}
- (void)addCompletedHandler:(MTLCommandBufferHandler)block {ENC_SCOPE(EC_CB,"addCompletedHandler");if(block)@synchronized(self){[_completedHandlers addObject:[block copy]];}}
- (void)enqueue {}
- (void)event:(id<MTLEvent>)event value:(uint64_t)value signal:(bool)signal {
 if(![(id)event isKindOfClass:[NBEvent class]]){[self refuse:@"foreign event"];return;}
 if(self.committed){[self refuse:@"event encoded after commit"];return;}
 if(encDeferred) {
  ET_REC;
  EncCmd c={};c.op=EO_EVENT;c.target=(__bridge_retained void *)self;c.a=(__bridge_retained void *)event;c.flags=ECF_RETAIN_A;c.u[0]=value;c.u[1]=signal;
  encPush(c);return;
 }
 NmbEvent *handle=[(NBEvent *)event handle];
 if(!(signal?nmb_command_buffer_signal_event(_handle,handle,value):nmb_command_buffer_wait_event(_handle,handle,value)))
  [self refuse:[NSString stringWithFormat:@"%s: %@",signal?"encodeSignalEvent":"encodeWaitForEvent",lastError()]];
}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {[self event:event value:value signal:true];}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {[self event:event value:value signal:false];}
// The runtime has submitted the work. Deliver scheduling without waiting for GPU completion.
- (void)didSchedule {
 {
  const uint64_t took=nowUs()-self.committedUs;
  std::lock_guard<std::mutex> lock(gCommitLock);
  CommitRecord &r=gCommitRing[self.commitIndex%32];
  if(r.index==self.commitIndex)r.scheduledUs=took;
 }
 NSArray *handlers;
 @synchronized(self){
  _schedulingDelivered=YES;handlers=[_scheduledHandlers copy];[_scheduledHandlers removeAllObjects];
 }
 void (^run)(void)=^{
  for(MTLCommandBufferHandler block in handlers)block((id<MTLCommandBuffer>)self);
  dispatch_group_leave(self->_schedulingHandlers);
 };
 // Run on the runtime's scheduled-handler thread, preserving its ordering and own-wait
 // deadlock checks. The queue's completionQueue routes completed handlers only.
 run();
}
// After completion (or a refusal): invalidate the CPU's view of imported surfaces, then completed handlers, once.
- (void)finish {
 if(!self.failedLocally && nmb_command_buffer_status(_handle)==MTLCommandBufferStatusError) {
  char text[512]={};nmb_command_buffer_error(_handle,text,sizeof text);noteDeviceLost(text);
 }
 // C3: what the GPU wrote (every surface with SWEET_FLUSH=all), invalidated for the CPU.
 flushSurfaces(flushAll()?_surfaces:_writtenSurfaces,true);
 if(shadowSeedOn())bumpWrittenSeeds(_writtenSurfaces);
 // Actual GPU completion (or a local refusal that never submitted) is the
 // release point. A retained completed command must not pin every old frame.
 [_surfaces removeAllObjects];[_writtenSurfaces removeAllObjects];[_resourceOwners removeAllObjects];
 @synchronized(gInFlight){[gInFlight removeObject:self];}
 NSArray *completedHandlers;
 @synchronized(self){
  // A frontend refusal or a failed submission never scheduled. Unblock its waiter without inventing a scheduled event.
  if(!_schedulingDelivered){_schedulingDelivered=YES;[_scheduledHandlers removeAllObjects];dispatch_group_leave(_schedulingHandlers);}
  completedHandlers=[_completedHandlers copy];[_completedHandlers removeAllObjects];
 }
 void (^run)(void)=^{
  if(self->tlNotice && !self.failedLocally)[self timelineRecord];
  for(MTLCommandBufferHandler block in completedHandlers)block((id<MTLCommandBuffer>)self);
  dispatch_group_leave(self->_handlers);
 };
 dispatch_queue_t queue=_queue.completionQueue;
 if(queue)dispatch_async(queue,run);else run();
}
// u-e: the encode window's start (the first encoder, before it is made) and end (commit): see EncScope.
- (void)encBegin {
 if(tlFirstEncoder || !tlCreated)return;
 tlFirstEncoder=tlNow();
 if(!encStatOn())return;
 encThreadNote();
 encStart=tEnc;
 encCpuStart=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
 pthread_threadid_np(nullptr,&encThread);
 encCpu0=(int8_t)encCPU();
 uint64_t work[10]={};
 if(gDevice && nmb_device_work_stats(gDevice,work)){encVkStart[0]=work[0];encVkStart[1]=work[1];}
}
- (void)encEnd {
 if(!encThread)return;
 uint64_t tid=0;pthread_threadid_np(nullptr,&tid);
 if(tid!=encThread)return;   // committed on another thread: the thread's counts say nothing of this window
 EncFrame &f=encFrame;
 const double tick=encTickNs()/1e6;
 for(int c=0;c<EC_COUNT;c++){f.ms[c]=(float)((tEnc.ticks[c]-encStart.ticks[c])*tick);f.n[c]=(uint16_t)std::min<uint32_t>(tEnc.n[c]-encStart.n[c],65535);}
 f.scopes=(uint32_t)(tEnc.scopes-encStart.scopes);
 f.cpuMs=(float)((clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-encCpuStart)/1e6);
 f.cpu0=encCpu0;f.cpu1=(int8_t)encCPU();f.mhz=encMHz();
 uint64_t work[10]={};
 if(gDevice && nmb_device_work_stats(gDevice,work)){f.vkN=(uint16_t)std::min<uint64_t>(work[0]-encVkStart[0],65535);f.vkMs=(float)((work[1]-encVkStart[1])/1e3);}
 f.valid=true;
}
- (void)commit {
 liveKnobsPoll();   // u-lab
 if(dbFrame) {   // ovd
  if(tlFrame)gDrawboxLeft.fetch_sub(1);
  char line[120];snprintf(line,sizeof line,"native-metal: DB f%u commit, %u passes, framebuffer %d, %d frames left",dbFrame,dbPasses,tlFrame,gDrawboxLeft.load());sm2_logs(line);
 }
 if(self.committed){NBLOG(@"native-metal: commit twice");return;}
 self.committed=YES;
 self.committedUs=nowUs();
 if(tlCreated) {
  tlCommit=tlNow();
  [self encEnd];
  static std::atomic<uint64_t> nextReport{0};
  uint64_t due=nextReport.load();
  if(tlCommit>=due && nextReport.compare_exchange_strong(due,tlCommit+5000000000ull) && due) {
   std::vector<TLRecord> records;
   {std::lock_guard<std::mutex> lock(gTLLock);records.swap(gTL);}
   static dispatch_queue_t reporter=dispatch_queue_create("sweet.timeline",DISPATCH_QUEUE_SERIAL);
   const uint64_t span=tlCommit-(due-5000000000ull);
   dispatch_async(reporter,^{timelineReport(records,span);});
  }
 }
 noteShadowCopies();
 {
  std::lock_guard<std::mutex> lock(gCommitLock);
  // Assign once under the same lock as publication. A concurrent commit cannot reuse this index.
  const uint32_t index=(uint32_t)(gCommits.fetch_add(1)+1);self.commitIndex=index;
  CommitRecord &r=gCommitRing[index%32];
  r={};r.index=index;r.committedUs=self.committedUs;r.ageUs=self.committedUs-createdUs;r.work=encodedWork;
 }
 dispatch_group_enter(_handlers);
 dispatch_group_enter(_schedulingHandlers);
 if(encDeferred) {   // u-encthread: the rest (in flight, surface cleans, handlers, the bridge's commit) is the worker's, in order
  ET_REC;
  if(NBEncoder *open=encOpen)if(!open->encEnded && open->dfCapturing)[open dfRelease:false clear:false];   // g9: its creation recorded first
  if(NBEncoder *open=encOpen)if(!open->encEnded){open->encEnded=true;EncCmd d={};d.op=EO_DISCARD;d.target=(__bridge void *)open;encPush(d);}
  encOpen=nil;
  encCommitTick=mach_absolute_time();
  EncCmd c={};c.op=EO_COMMIT;c.target=(__bridge_retained void *)self;encPush(c);
  return;
 }
 [self commitSubmit];
}
// The commit's submission: in flight, CPU-written surfaces cleaned, the runtime's handlers registered and its commit; a refusal
// fails it locally (completed handlers run with the error). Inline from commit, or the worker's replay of it (u-encthread).
- (void)commitSubmit {
 @synchronized(gInFlight){[gInFlight addObject:self];}
 if(!self.encodeFailure) {
  flushSurfaces(_surfaces,false);
  // Completion owns this reference; the runtime orders the non-owning scheduled callback before it.
  void *context=(__bridge_retained void *)self;
  if(nmb_command_buffer_on_completed(_handle,completed,context) &&
     nmb_command_buffer_on_scheduled(_handle,scheduled,context) && nmb_command_buffer_commit(_handle))return;
  (void)CFBridgingRelease(context);   // refused registration/commit cannot call the registered handlers
  noteDeviceLost(nmb_last_error());
  [self refuse:[@"commit: " stringByAppendingString:lastError()]];
 }
 self.failedLocally=YES;gCommitFailures++;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{[self finish];});
}
// u-encthread: a wait on a recorded command buffer: its commit replayed first (another thread's wait may come before the commit
// is recorded: it flushes again).
- (void)encAwaitCommit:(EncFlushWhy)why {
 for(unsigned tries=0;!encCommitDone.load();tries++) {
  if(encOnWorker() || !gEqStarted.load())return;
  encFlush(why);
  if(!encCommitDone.load())usleep(tries<100?20:1000);
 }
}
// u-t: this command buffer's timeline record, as its completed handlers start.
- (void)timelineRecord {
 TLRecord r={};
 r.created=tlFirstEncoder?tlFirstEncoder:tlCreated;r.commit=tlCommit;r.notice=tlNotice;r.handler=tlNow();
 auto ns=[](double seconds)->uint64_t{return seconds>0?(uint64_t)(seconds*1e9):0;};
 r.kStart=ns(nmb_command_buffer_kernel_time(_handle,false));r.kEnd=ns(nmb_command_buffer_kernel_time(_handle,true));
 r.gStart=ns(nmb_command_buffer_gpu_time(_handle,false));r.gEnd=ns(nmb_command_buffer_gpu_time(_handle,true));
 r.work=encodedWork;r.enc=encFrame;r.surface=tlSurface;r.frame=tlFrame;r.waitedCompleted=tlWaitedCompleted;r.waitedScheduled=tlWaitedScheduled;
 std::lock_guard<std::mutex> lock(gTLLock);
 if(gTL.size()<4096)gTL.push_back(r);
}
- (void)waitUntilCompleted {ENC_SCOPE(EC_WAIT,"waitUntilCompleted");
 if(!self.committed)return;
 if(encDeferred)[self encAwaitCommit:EF_COMPLETED];
 tlWaitedCompleted=true;
 const uint64_t began=nowUs();
 if(!self.failedLocally)nmb_command_buffer_wait(_handle,0);
 dispatch_group_wait(_handlers,DISPATCH_TIME_FOREVER);
 gTimeWaitCompleted.add(began);
}
- (void)waitUntilScheduled {ENC_SCOPE(EC_WAIT,"waitUntilScheduled");
 if(!self.committed)return;
 if(encDeferred)[self encAwaitCommit:EF_SCHEDULED];
 tlWaitedScheduled=true;
 const uint64_t began=nowUs();
 if(!self.failedLocally && !nmb_command_buffer_wait_scheduled(_handle)){
  NBLOG(@"native-metal: waitUntilScheduled refused: %@",lastError());return;
 }
 dispatch_group_wait(_schedulingHandlers,DISPATCH_TIME_FOREVER);
 gTimeWaitScheduled.add(began);
}
@end
static void scheduled(void *context) {[(__bridge NBCommandBuffer *)context didSchedule];}
// The runtime's completion: the command buffer's own reference, taken at commit, is given back here.
// rotfb4: once per 5 s, while landscape frames render: the command buffers with a rotated pass, their GPU ms, and the runtime's rotated
// copies (in, skipped, back, MB, dispatches) over the same 5 s.
static void rotatedFrameStats(NBCommandBuffer *commandBuffer) {
 static std::mutex lock;static uint64_t windowUs,frames,gpuUs,gpuMaxUs,last[5];
 const double start=nmb_command_buffer_gpu_time(commandBuffer.handle,false),end=nmb_command_buffer_gpu_time(commandBuffer.handle,true);
 const uint64_t took=end>start && start>0?(uint64_t)((end-start)*1e6):0;
 std::lock_guard<std::mutex> l(lock);
 frames++;gpuUs+=took;gpuMaxUs=std::max(gpuMaxUs,took);
 const uint64_t now=nowUs();
 if(!windowUs){windowUs=now;nmb_rotated_copy_stats(last);return;}
 if(now-windowUs<5000000)return;
 uint64_t c[5];nmb_rotated_copy_stats(c);
 sm2_logs([NSString stringWithFormat:@"native-metal: rotated 5s: %llu cmdbufs, GPU %llu ms (mean %.1f, max %.1f) | copies in %llu skipped %llu back %llu, %llu MB, %llu dispatches",
  (unsigned long long)frames,(unsigned long long)(gpuUs/1000),frames?gpuUs/1000.0/frames:0.0,gpuMaxUs/1000.0,(unsigned long long)(c[0]-last[0]),
  (unsigned long long)(c[1]-last[1]),(unsigned long long)(c[2]-last[2]),(unsigned long long)((c[3]-last[3])>>20),(unsigned long long)(c[4]-last[4])].UTF8String);
 memcpy(last,c,sizeof c);windowUs=now;frames=gpuUs=gpuMaxUs=0;
}
static void completed(void *context) {
 gCompleted++;primeNoteCommit();   // G6: backboardd's commits, for SpringBoard's idle priming
 NBCommandBuffer *commandBuffer=(__bridge_transfer NBCommandBuffer *)context;
 if(commandBuffer->tlCreated)commandBuffer->tlNotice=tlNow();
 if(commandBuffer.rotatedFrame)rotatedFrameStats(commandBuffer);
 {
  const uint64_t took=nowUs()-commandBuffer.committedUs;
  gTimeEncodeToCommit.count++;gTimeEncodeToCommit.total+=took;
  uint64_t seen=gTimeEncodeToCommit.slowest.load();while(took>seen && !gTimeEncodeToCommit.slowest.compare_exchange_weak(seen,took)){}
  std::lock_guard<std::mutex> lock(gCommitLock);
  CommitRecord &r=gCommitRing[commandBuffer.commitIndex%32];
  if(r.index==commandBuffer.commitIndex)r.callbackUs=took;
 }
 [commandBuffer finish];
}

// G5 (SWEET_NILENC=1): never a nil encoder, after UniXNU AdrenoMetal ce5e19e. Where renderCommandEncoderWithDescriptor:, blitCommandEncoder,
// computeCommandEncoder(WithDispatchType:) would answer nil (after commit, a foreign attachment, the runtime refused the pass), the caller
// gets a refusing encoder: an object of the right protocol that accepts every call and does nothing (declared selectors answer 0, any other
// selector too). RenderBox caches an encoder's IMPs with methodForSelector: and called address 0 on nil (UniXNU i568: WidgetRenderer). The
// command buffer is refused (if not yet committed): its commit fails locally, status error, completed handlers still run. The first
// refusal of the process is logged once with its reason ("native-metal: NILENC: ..."). Default (unset/0): nil as before; the wrappers are
// installed at device open only with SWEET_NILENC=1, so the default path is unchanged.
static std::atomic<uint64_t> gNilencRefusals,gNilencUndeclared;
@interface NBRefusingEncoder : NBObject
@property(nonatomic,strong) id commandBuffer;
@end
@implementation NBRefusingEncoder
- (void)endEncoding {}
- (void)insertDebugSignpost:(NSString *)s {(void)s;}
- (void)pushDebugGroup:(NSString *)s {(void)s;}
- (void)popDebugGroup {}
- (BOOL)respondsToSelector:(SEL)selector {return [super respondsToSelector:selector] || declaredTypes(object_getClass(self),selector)!=nullptr;}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
 if(NSMethodSignature *own=[super methodSignatureForSelector:selector])return own;
 if(!gNilencUndeclared++)sm2_logs([NSString stringWithFormat:@"native-metal: NILENC: undeclared %s %s answered nil",class_getName(object_getClass(self)),sel_getName(selector)].UTF8String);
 return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)invocation {   // silently: every call is expected to land here
 const NSUInteger length=invocation.methodSignature.methodReturnLength;
 if(length){std::vector<uint8_t> zero(length,0);[invocation setReturnValue:zero.data()];}
}
@end
@interface NBRefusingRenderEncoder : NBRefusingEncoder
@end
@implementation NBRefusingRenderEncoder
- (NSUInteger)tileWidth {return 0;}
- (NSUInteger)tileHeight {return 0;}
@end
@interface NBRefusingBlitEncoder : NBRefusingEncoder
@end
@implementation NBRefusingBlitEncoder
@end
@interface NBRefusingComputeEncoder : NBRefusingEncoder
@end
@implementation NBRefusingComputeEncoder
- (MTLDispatchType)dispatchType {return MTLDispatchTypeSerial;}
@end
static id nilencRefusing(NBCommandBuffer *commandBuffer,Class cls,const char *what) {
 NSString *reason=commandBuffer.committed?@"after commit":(commandBuffer.encodeFailure?:lastError());
 if(!commandBuffer.committed && !commandBuffer.encodeFailure)[commandBuffer refuse:[NSString stringWithFormat:@"%s: %@",what,reason]];
 const uint64_t n=++gNilencRefusals;
 if(n==1)NBLOG(@"native-metal: NILENC: refusing %s encoder instead of nil (%@); command buffer %s",what,reason,
  commandBuffer.committed?"already committed":"refused (fails at commit)");
 NBRefusingEncoder *encoder=[cls new];encoder.commandBuffer=commandBuffer;
 return encoder;
}
static IMP gNilencRender,gNilencBlit,gNilencCompute,gNilencComputeType;
static id nilencRender(id self,SEL cmd,MTLRenderPassDescriptor *d) {
 id e=((id(*)(id,SEL,MTLRenderPassDescriptor *))gNilencRender)(self,cmd,d);
 return e?:nilencRefusing((NBCommandBuffer *)self,[NBRefusingRenderEncoder class],"render");
}
static id nilencBlit(id self,SEL cmd) {
 id e=((id(*)(id,SEL))gNilencBlit)(self,cmd);
 return e?:nilencRefusing((NBCommandBuffer *)self,[NBRefusingBlitEncoder class],"blit");
}
static id nilencCompute(id self,SEL cmd) {
 id e=((id(*)(id,SEL))gNilencCompute)(self,cmd);
 return e?:nilencRefusing((NBCommandBuffer *)self,[NBRefusingComputeEncoder class],"compute");
}
static id nilencComputeType(id self,SEL cmd,MTLDispatchType type) {
 id e=((id(*)(id,SEL,MTLDispatchType))gNilencComputeType)(self,cmd,type);
 return e?:nilencRefusing((NBCommandBuffer *)self,[NBRefusingComputeEncoder class],"compute");
}
static void nilencInstall() {
 const char *e=getenv("SWEET_NILENC");
 if(!(e && atoi(e)==1) || gNilencRender)return;
 struct {Class cls;const char *protocol;} adopt[]={{[NBRefusingRenderEncoder class],"MTLRenderCommandEncoder"},
  {[NBRefusingBlitEncoder class],"MTLBlitCommandEncoder"},{[NBRefusingComputeEncoder class],"MTLComputeCommandEncoder"}};
 for(auto &a:adopt)if(Protocol *p=objc_getProtocol(a.protocol))if(![a.cls conformsToProtocol:p])class_addProtocol(a.cls,p);
 Class cb=[NBCommandBuffer class];
 gNilencRender=method_setImplementation(class_getInstanceMethod(cb,@selector(renderCommandEncoderWithDescriptor:)),(IMP)nilencRender);
 gNilencBlit=method_setImplementation(class_getInstanceMethod(cb,@selector(blitCommandEncoder)),(IMP)nilencBlit);
 gNilencCompute=method_setImplementation(class_getInstanceMethod(cb,@selector(computeCommandEncoder)),(IMP)nilencCompute);
 gNilencComputeType=method_setImplementation(class_getInstanceMethod(cb,@selector(computeCommandEncoderWithDispatchType:)),(IMP)nilencComputeType);
 sm2_logs("native-metal: NILENC: refusing encoders on (SWEET_NILENC=1)");
}

@implementation NBQueue
- (void)dealloc {nmb_queue_release(_handle);}
- (id<MTLCommandBuffer>)commandBuffer {ENC_SCOPE(EC_CB,"commandBuffer");
 NmbCommandBuffer *handle=nmb_command_buffer_new(_handle);
 if(!handle){NBLOG(@"native-metal: commandBuffer refused: %@",lastError());return nil;}
 NBCommandBuffer *commandBuffer=[NBCommandBuffer new];commandBuffer.handle=handle;commandBuffer.queue=self;return (id<MTLCommandBuffer>)commandBuffer;
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences {return [self commandBuffer];}
- (void)setSubmissionQueue:(dispatch_queue_t)queue {(void)queue;}   // submission happens on the caller's thread here
// setCompletionQueue: is the property's setter.
// GPU priorities are not applied (one hardware queue): reported as not applied.
- (BOOL)setGPUPriority:(NSUInteger)priority {(void)priority;return NO;}
- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority {(void)priority;return NO;}
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d {(void)d;return [self commandBuffer];}
@end

// ---- the device ----
template <typename T> static T failWith(NSError **error,NSString *what,T value) {
 noteProblem([NSString stringWithFormat:@"%@: %@",what,lastError()]);
 if(error)*error=nbError([NSString stringWithFormat:@"%@: %@",what,lastError()]);
 return value;
}
// Which of QuartzCore's paths asked for a pipeline (int-153: every one was made synchronously on its render thread and no generic pipeline
// was ever asked for): its return addresses as offsets from its image header (header 0x189429000 in the 21H461 cache, so offset +
// 0x189429000 is the address in that image's disassembly), the global feature flags it ORs into every context's flags, and its
// CA_DISABLE_GENERIC_SHADERS, CA_FORCE_GENERIC_SHADERS and CA_DISABLE_PRECOMPILED_PIPELINES debug options (ca_debug_options +0x55..0x57,
// read only where dladdr places that address in QuartzCore).
static std::string quartzCoreCallers() {
 /* SweetMetal2 (iOS 16.7): only the return addresses into QuartzCore, as offsets from its header. UniXNU's version also read
  * MetalContext fields and debug bytes at iPadOS 17.7.11 (21H461) offsets, which mean nothing here. */
 void *frames[24];const int n=backtrace(frames,24);
 std::string out="qc";char item[32];unsigned kept=0;
 for(int i=0;i<n && kept<8;i++) {
  Dl_info info{};
  if(!dladdr(frames[i],&info) || !info.dli_fname || !strstr(info.dli_fname,"/QuartzCore"))continue;
  snprintf(item,sizeof item," %lx",(unsigned long)((uintptr_t)frames[i]-(uintptr_t)info.dli_fbase));out+=item;++kept;
 }
 return out;
}
// What a creation cost beyond its wall time (int-156: a translation the host does in 6 ms took 665 ms on the tablet, whose single core is
// as fast): this thread's CPU time (user and system, microseconds) and the task's page faults, page-ins and context switches. A creation
// whose CPU time is near its wall time computed; one whose faults are many paid the 4 KiB fault path; one far below it waited.
struct NBCost {
 uint64_t user=0,system=0;int64_t faults=0,pageins=0,switches=0;
 static NBCost now() {
  NBCost c;thread_basic_info_data_t t{};mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;mach_port_t self=mach_thread_self();
  if(thread_info(self,THREAD_BASIC_INFO,(thread_info_t)&t,&n)==KERN_SUCCESS) {
   c.user=(uint64_t)t.user_time.seconds*1000000+t.user_time.microseconds;c.system=(uint64_t)t.system_time.seconds*1000000+t.system_time.microseconds;
  }
  mach_port_deallocate(mach_task_self(),self);
  task_events_info_data_t e{};n=TASK_EVENTS_INFO_COUNT;
  if(task_info(mach_task_self(),TASK_EVENTS_INFO,(task_info_t)&e,&n)==KERN_SUCCESS){c.faults=e.faults;c.pageins=e.pageins;c.switches=e.csw;}
  return c;
 }
 std::string since(const NBCost &b) const {
  char text[128];snprintf(text,sizeof text," cpu=%llu sys=%llu flt=%lld pin=%lld csw=%lld",(unsigned long long)(user+system-b.user-b.system),
      (unsigned long long)(system-b.system),(long long)(faults-b.faults),(long long)(pageins-b.pageins),(long long)(switches-b.switches));
  return text;
 }
};
// One journal line of a render pipeline creation begun at `began` (microseconds), `refused` its refusal or null. The label is the
// caller's name for the pipeline (QuartzCore's: its spec's encoded name).
static void journalRenderPipeline(MTLRenderPipelineDescriptor *d,uint64_t began,const char *refused,const std::string &cost) {
 if(gJournalPath.empty())return;
 const uint64_t ended=nowUs();uint64_t tid=0;pthread_threadid_np(nullptr,&tid);
 char head[256];
 snprintf(head,sizeof head,"R t=%llu tid=%llu main=%d us=%llu ok=%d samples=%lu topo=%lu ds=%lu/%lu",(unsigned long long)((began-gJournalBegan)/1000),
     (unsigned long long)tid,pthread_main_np(),(unsigned long long)(ended-began),refused?0:1,(unsigned long)d.rasterSampleCount,
     (unsigned long)d.inputPrimitiveTopology,(unsigned long)d.depthAttachmentPixelFormat,(unsigned long)d.stencilAttachmentPixelFormat);
 std::string line=head;
 line+=cost;
 line+=" label=";line+=d.label.length?d.label.UTF8String:"-";
 for(unsigned i=0;i<8;i++) {
  MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[i];if(a.pixelFormat==MTLPixelFormatInvalid)continue;
  snprintf(head,sizeof head," c%u=%lu:%lu:%d:%lu:%lu:%lu:%lu:%lu:%lu",i,(unsigned long)a.pixelFormat,(unsigned long)a.writeMask,(int)a.blendingEnabled,
      (unsigned long)a.sourceRGBBlendFactor,(unsigned long)a.destinationRGBBlendFactor,(unsigned long)a.rgbBlendOperation,(unsigned long)a.sourceAlphaBlendFactor,
      (unsigned long)a.destinationAlphaBlendFactor,(unsigned long)a.alphaBlendOperation);
  line+=head;
 }
 if(MTLVertexDescriptor *v=d.vertexDescriptor)for(unsigned i=0;i<31;i++) {
  MTLVertexAttributeDescriptor *a=v.attributes[i];if(a.format==MTLVertexFormatInvalid)continue;
  MTLVertexBufferLayoutDescriptor *l=v.layouts[a.bufferIndex<31?a.bufferIndex:0];
  snprintf(head,sizeof head," a%u=%lu:%lu:%lu:%lu:%lu:%lu",i,(unsigned long)a.format,(unsigned long)a.offset,(unsigned long)a.bufferIndex,(unsigned long)l.stride,
      (unsigned long)l.stepFunction,(unsigned long)l.stepRate);
  line+=head;
 }
 NBFunction *vf=[(id)d.vertexFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.vertexFunction:nil;
 NBFunction *ff=[(id)d.fragmentFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.fragmentFunction:nil;
 line+=" | v ";line+=vf?vf.name.UTF8String:"-";line+=" ";line+=vf?vf.constantsText:"";
 line+=" | f ";line+=ff?ff.name.UTF8String:"-";line+=" ";line+=ff?ff.constantsText:"";
 if(refused){line+=" | refused ";line+=refused;}
 line+=" | ";line+=quartzCoreCallers();
 for(char &c:line)if(c=='\n')c=' ';
 journal(line);
}
// SweetMetal2 (C1): render pipeline outcomes in the log (the journal is a file on the phone): every refused key (vertex | fragment |
// first colour format) once with the reason, and a count line at the 1st, 10th, 50th, 100th, 200th, ... pipeline made.
static void notePipeline(MTLRenderPipelineDescriptor *d,const char *refused) {
 static std::mutex lock;static std::vector<std::string> seen;static uint64_t made,failed;
 NBFunction *vf=[(id)d.vertexFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.vertexFunction:nil;
 NBFunction *ff=[(id)d.fragmentFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.fragmentFunction:nil;
 std::string key=std::string(vf?vf.name.UTF8String?:"?":"-")+" | "+(ff?ff.name.UTF8String?:"?":"-")+" | c0 "+
     std::to_string((unsigned long)d.colorAttachments[0].pixelFormat);
 bool log=false;uint64_t m,f;
 {
  std::lock_guard<std::mutex> l(lock);
  if(refused){failed++;if(seen.size()<64 && std::find(seen.begin(),seen.end(),key)==seen.end()){seen.push_back(key);log=true;}}
  else made++;
  m=made;f=failed;
 }
 if(log)NBLOG(@"native-metal: render pipeline refused (%s): %s",key.c_str(),refused);
 if(!refused && (m==1 || m==10 || m==50 || m%100==0))sm2_logs([NSString stringWithFormat:@"native-metal: render pipelines made %llu, refused %llu",
     (unsigned long long)m,(unsigned long long)f].UTF8String);
}
// A render pipeline descriptor in the bridge's form; false, with the error, for a function of another device.
static bool renderDescriptor(MTLRenderPipelineDescriptor *d,NmbRenderPipelineDescriptor *p,NSError **error) {
 if(![(id)d.vertexFunction isKindOfClass:[NBFunction class]] || (d.fragmentFunction && ![(id)d.fragmentFunction isKindOfClass:[NBFunction class]])) {
  if(error)*error=nbError(@"foreign function");return false;
 }
 p->vertex=[(NBFunction *)d.vertexFunction handle];p->fragment=d.fragmentFunction?[(NBFunction *)d.fragmentFunction handle]:nullptr;
 for(unsigned i=0;i<8;i++) {
  MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[i];
  p->colors[i]={sweetFormat((uint64_t)a.pixelFormat),(uint64_t)a.writeMask,(uint64_t)a.blendingEnabled,(uint64_t)a.sourceRGBBlendFactor,(uint64_t)a.destinationRGBBlendFactor,
      (uint64_t)a.rgbBlendOperation,(uint64_t)a.sourceAlphaBlendFactor,(uint64_t)a.destinationAlphaBlendFactor,(uint64_t)a.alphaBlendOperation};
 }
 p->depth_format=d.depthAttachmentPixelFormat;p->stencil_format=d.stencilAttachmentPixelFormat;p->samples=d.rasterSampleCount;
 p->topology=d.inputPrimitiveTopology;p->rasterization=d.rasterizationEnabled;
 if(MTLVertexDescriptor *v=d.vertexDescriptor) {
  for(unsigned i=0;i<31;i++) {
   MTLVertexAttributeDescriptor *a=v.attributes[i];if(a.format==MTLVertexFormatInvalid)continue;
   p->vertex_inputs=1;p->attributes[i]={(uint64_t)a.format,a.offset,a.bufferIndex};
   if(a.bufferIndex<31){MTLVertexBufferLayoutDescriptor *l=v.layouts[a.bufferIndex];p->layouts[a.bufferIndex]={l.stride,(uint64_t)l.stepFunction,l.stepRate};}
  }
 }
 return true;
}

// ---- heaps ----
// Metal heaps over the runtime's: an automatic heap places each resource, a placement heap takes an offset. Resources made from one keep it
// alive (their `heap`); a heap's resources share its storage mode, CPU cache mode and (here) hazard tracking mode.
@interface NBHeap : NBObject
@property(nonatomic) NmbHeap *handle;
@property(nonatomic) MTLResourceOptions options;
@property(nonatomic) MTLHeapType heapType;
@end
@implementation NBHeap
- (void)dealloc {nmb_heap_release(_handle);}
- (NSUInteger)size {return nmb_heap_size(_handle);}
- (NSUInteger)usedSize {return nmb_heap_used_size(_handle);}
- (NSUInteger)currentAllocatedSize {return nmb_heap_allocated_size(_handle);}
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment {return nmb_heap_max_available_size(_handle,alignment);}
- (MTLResourceOptions)resourceOptions {return _options;}
- (MTLStorageMode)storageMode {return (MTLStorageMode)((_options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift);}
- (MTLCPUCacheMode)cpuCacheMode {return (MTLCPUCacheMode)((_options&MTLResourceCPUCacheModeMask)>>MTLResourceCPUCacheModeShift);}
- (MTLHazardTrackingMode)hazardTrackingMode {return (MTLHazardTrackingMode)((_options&MTLResourceHazardTrackingModeMask)>>MTLResourceHazardTrackingModeShift);}
- (MTLHeapType)type {return _heapType;}
- (uint64_t)protectionOptions {return 0;}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
 const uint64_t answer=nmb_heap_set_purgeable_state(_handle,state);
 if(!answer)NBLOG(@"native-metal: heap setPurgeableState refused: %@",lastError());
 return (MTLPurgeableState)answer;
}
- (id<MTLBuffer>)bufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(uint64_t)offset {ENC_SCOPE(EC_BUF,"heap newBuffer");
 NmbBuffer *handle=nmb_heap_new_buffer(_handle,length,options,offset);
 if(!handle){NBLOG(@"native-metal: heap buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;buffer.parentHeap=(id<MTLHeap>)self;
 buffer.heapOffset=offset==UINT64_MAX?0:offset;return (id<MTLBuffer>)buffer;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {return [self bufferWithLength:length options:options offset:UINT64_MAX];}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset {
 return [self bufferWithLength:length options:options offset:offset];
}
- (id<MTLTexture>)textureWithDescriptor:(MTLTextureDescriptor *)d offset:(uint64_t)offset {ENC_SCOPE(EC_TEX,"heap newTexture");
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor))return nil;
 NmbTexture *handle=nmb_heap_new_texture(_handle,&descriptor,offset);
 if(!handle){NBLOG(@"native-metal: heap texture refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.parentHeap=(id<MTLHeap>)self;texture.heapOffset=offset==UINT64_MAX?0:offset;return (id<MTLTexture>)texture;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {return [self textureWithDescriptor:d offset:UINT64_MAX];}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset {return [self textureWithDescriptor:d offset:offset];}
@end
// Apple's SPI resource groups name resources for cache hints (encodeCacheHintTag:/Finalize:); a group only keeps its resources alive.
@interface NBResourceGroup : NBObject
@property(nonatomic,strong) NSArray *resources;
@end
@implementation NBResourceGroup
@end

// Creation and archive population must use the same complete supported descriptor.
static bool computeDescriptor(MTLComputePipelineDescriptor *d,NmbComputePipelineDescriptor *p,NSError **error) {
 if(!d || ![(id)d.computeFunction isKindOfClass:[NBFunction class]]){if(error)*error=nbError(@"foreign compute function");return false;}
 // Metal may materialize empty stage/linked descriptors on access. Preserve the
 // default meaning while refusing state this frontend cannot yet represent.
 MTLStageInputOutputDescriptor *stage=d.stageInputDescriptor;
 bool empty=!stage || (stage.indexType==MTLIndexTypeUInt16 && stage.indexBufferIndex==0);
 for(NSUInteger index=0;stage && index<31;++index) {
  MTLAttributeDescriptor *a=stage.attributes[index];MTLBufferLayoutDescriptor *b=stage.layouts[index];
  empty=empty && a.format==MTLAttributeFormatInvalid && !a.offset && !a.bufferIndex && !b.stride &&
        b.stepFunction==MTLStepFunctionPerVertex && b.stepRate==1;
 }
 if(!empty){if(error)*error=nbError(@"compute stage inputs are not implemented");return false;}
 MTLLinkedFunctions *linked=d.linkedFunctions;
 if(linked.functions.count || linked.binaryFunctions.count || linked.privateFunctions.count || linked.groups.count ||
    d.preloadedLibraries.count || d.insertLibraries.count) {
  if(error)*error=nbError(@"compute linked/dynamic libraries are not implemented");return false;
 }
 p->function=[(NBFunction *)d.computeFunction handle];p->max_threads=d.maxTotalThreadsPerThreadgroup;
 p->multiple_of_execution_width=d.threadGroupSizeIsMultipleOfThreadExecutionWidth;p->indirect=d.supportIndirectCommandBuffers;
 p->max_call_stack_depth=d.maxCallStackDepth;p->adding_binary_functions=d.supportAddingBinaryFunctions;
 for(NSUInteger index=0;index<31;++index)p->mutability[index]=d.buffers[index].mutability;
 return true;
}

// ---- binary archives ----
@interface NBBinaryArchive : NBObject
@property(nonatomic) NmbBinaryArchive *handle;
@end
@implementation NBBinaryArchive
- (void)dealloc {nmb_binary_archive_release(_handle);}
- (NSUInteger)options {return 0;}
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error {
 auto *p=new NmbRenderPipelineDescriptor();
 const bool ok=renderDescriptor(d,p,error) && nmb_binary_archive_add_render(_handle,p);delete p;
 if(!ok)return failWith<BOOL>(error,@"archive render pipeline",NO);
 if(error)*error=nil;return YES;
}
- (BOOL)addComputePipelineFunctionsWithDescriptor:(MTLComputePipelineDescriptor *)d error:(NSError **)error {
 NmbComputePipelineDescriptor p={};if(!computeDescriptor(d,&p,error))return NO;
 if(!nmb_binary_archive_add_compute_descriptor(_handle,&p))return failWith<BOOL>(error,@"archive compute pipeline",NO);
 if(error)*error=nil;return YES;
}
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error {
 if(!url.isFileURL){if(error)*error=nbError(@"a file URL is required");return NO;}
 if(!nmb_binary_archive_serialize(_handle,url.fileSystemRepresentation))return failWith<BOOL>(error,@"archive serialize",NO);
 if(error)*error=nil;return YES;
}
@end

static bool pipelineArchives(NSArray *list,std::vector<NmbBinaryArchive *> &archives,NSError **error) {
 for(id archive in list) {
  if(![archive isKindOfClass:[NBBinaryArchive class]]){if(error)*error=nbError(@"foreign binary archive");return false;}
  archives.push_back([(NBBinaryArchive *)archive handle]);
 }
 return true;
}

@interface NBDeviceMethods : NSObject
@end
// Bytes of one texel of the uncompressed formats Core Animation and RenderBox use (4 for the rest).
static uint64_t sweetTexelBytes(MTLPixelFormat f) {
 switch((NSUInteger)f) {
 case 1: case 10: case 11: case 12: case 13: case 14: return 1;
 case 20: case 22: case 23: case 24: case 25: case 30: case 32: case 33: case 34: case 40: case 41: case 42: case 43: return 2;
 case 103: case 104: case 105: case 110: case 111: case 112: case 113: case 114: case 115: case 552: case 553: return 8;
 case 123: case 124: case 125: return 16;
 default: return 4;
 }
}
typedef struct {uint64_t w[2];} SweetWatermark;   /* AGXTextureLayout's {?=[2Q]} watermark */
// Block footprint and bytes of the compressed formats the A640 samples (ASTC LDR/sRGB, ETC2/EAC); false for the rest.
static bool sweetBlock(MTLPixelFormat f, uint32_t *bw, uint32_t *bh, uint32_t *bytes) {
 static const uint8_t astc[][2] = {{4,4},{5,4},{5,5},{6,5},{6,6},{0,0},{8,5},{8,6},{8,8},{10,5},{10,6},{10,8},{10,10},{12,10},{12,12}};
 const NSUInteger n = (NSUInteger)f;
 if((n >= 186 && n <= 200) || (n >= 204 && n <= 218)) {
  const NSUInteger i = n >= 204 ? n - 204 : n - 186;
  if(!astc[i][0]) return false;
  *bw = astc[i][0]; *bh = astc[i][1]; *bytes = 16; return true;
 }
 switch(n) {
 case 170: case 172: case 180: case 181: case 182: case 183: *bw = 4; *bh = 4; *bytes = 8; return true;   /* EAC R11, ETC2 RGB8(A1) */
 case 174: case 176: case 178: case 179: *bw = 4; *bh = 4; *bytes = 16; return true;                          /* EAC RG11, RGBA8 */
 default: return false;
 }
}
// Keeps a no-copy texture's memory owner until the texture goes (its deallocator runs then).
@interface SweetMemoryOwner : NSObject
@property(nonatomic,copy) void (^deallocator)(void *,NSUInteger);
@property(nonatomic) void *bytes;
@property(nonatomic) NSUInteger length;
@end
@implementation SweetMemoryOwner
- (void)dealloc {if(_deallocator)_deallocator(_bytes,_length);}
@end
static char sweetMemoryOwnerKey;
// SweetMetal2's MTLTextureLayout (Metal SPI: AGXTextureLayout's protocol on Apple's GPUs): a linear layout of `row`-byte rows.
@interface SweetTextureLayout : NSObject
- (instancetype)initWithRow:(uint64_t)row height:(uint64_t)height texel:(uint64_t)texel;
- (instancetype)initWithBlocks:(uint32_t)bw by:(uint32_t)bh bytes:(uint32_t)bytes width:(uint64_t)width height:(uint64_t)height;
@end
@implementation SweetTextureLayout {
 uint64_t _row,_height,_texel;
 uint32_t _bw,_bh;     /* block footprint (1x1 uncompressed); _height and _texel count block rows and block bytes */
}
- (instancetype)initWithRow:(uint64_t)row height:(uint64_t)height texel:(uint64_t)texel {
 if((self=[super init])){_row=row;_height=height;_texel=texel?texel:4;_bw=_bh=1;}
 return self;
}
- (instancetype)initWithBlocks:(uint32_t)bw by:(uint32_t)bh bytes:(uint32_t)bytes width:(uint64_t)width height:(uint64_t)height {
 if((self=[super init])){_bw=bw;_bh=bh;_texel=bytes;_row=(width+bw-1)/bw*bytes;_height=(height+bh-1)/bh;}
 return self;
}
- (NSUInteger)size {const uint64_t page=(uint64_t)getpagesize();return (NSUInteger)((_row*_height+page-1)&~(page-1));}
- (NSUInteger)alignment {return (NSUInteger)getpagesize();}
- (MTLSize)copyGranularity {return MTLSizeMake(_bw,_bh,1);}
- (SweetWatermark)watermark {SweetWatermark none={{0,0}};return none;}
- (void)initializeTextureMemory:(void *)memory {(void)memory;}
- (void)finalizeTextureMemory:(void *)memory {(void)memory;}
- (void)copyFromLinearBytes:(const void *)src linearOffset:(NSUInteger)offset linearBytesPerRow:(NSUInteger)srcRow linearBytesPerImage:(NSUInteger)image
            toTextureMemory:(void *)dst textureSlice:(NSUInteger)slice textureLevel:(NSUInteger)level textureRegion:(MTLRegion)r {
 (void)image;if(slice || level)return;
 const NSUInteger x0=r.origin.x/_bw,y0=r.origin.y/_bh,w=(r.size.width+_bw-1)/_bw,h=(r.size.height+_bh-1)/_bh;
 for(NSUInteger y=0;y<h && y0+y<_height;y++)
  memcpy((uint8_t *)dst+(y0+y)*_row+x0*_texel,(const uint8_t *)src+offset+y*srcRow,w*_texel);
}
- (void)copyFromTextureMemory:(const void *)src textureSlice:(NSUInteger)slice textureLevel:(NSUInteger)level textureRegion:(MTLRegion)r
              toLinearBytes:(void *)dst linearOffset:(NSUInteger)offset linearBytesPerRow:(NSUInteger)dstRow linearBytesPerImage:(NSUInteger)image {
 (void)image;if(slice || level)return;
 const NSUInteger x0=r.origin.x/_bw,y0=r.origin.y/_bh,w=(r.size.width+_bw-1)/_bw,h=(r.size.height+_bh-1)/_bh;
 for(NSUInteger y=0;y<h && y0+y<_height;y++)
  memcpy((uint8_t *)dst+offset+y*dstRow,(const uint8_t *)src+(y0+y)*_row+x0*_texel,w*_texel);
}
@end
@implementation NBDeviceMethods
- (NSString *)name {return gName;}
- (uint64_t)registryID {return gRegistryID;}
- (NSUInteger)maxBufferLength {return nmb_device_max_buffer_length(gDevice);}
- (BOOL)hasUnifiedMemory {return YES;}
- (BOOL)isLowPower {return NO;}
- (BOOL)isRemovable {return NO;}
- (BOOL)isHeadless {return NO;}
// supportsFamily: and the other queries the runtime answers are installed from it (installAnswers); supportsFamily: also answers the target
// hardware's families (the bridge's TARGET_FAMILIES, journaled with their waived rows as F lines). No legacy feature set is claimed: the
// base implementation reads Apple tables this device does not have.
- (BOOL)supportsFeatureSet:(MTLFeatureSet)set {(void)set;return NO;}
// The original discovery (_MTLAddDevice) runs these four on every device it registers. The target's own versions fill the base class's limits
// and feature tables from a hardware profile (`featureProfile`, `indirectArgumentBufferCapabilities`, a table of Apple GPUs) that this device
// has not got: running them would claim an Apple GPU's capabilities. They are empty here, so a limit or feature the runtime measured is answered
// by this file's own answers (installAnswers) and any other stays the base class's neutral 0/NO. Nothing is claimed that nothing measured.
- (void)initLimits {}
- (void)initFeatureQueries {}
- (void)initGPUFamilySupport {}
- (void)initWorkarounds {}
- (NSString *)productName {return gName;}
- (NSString *)vendorName {char name[64]={};nmb_device_vendor_name(gDevice,name,sizeof name);return [NSString stringWithUTF8String:name];}
- (MTLSize)maxThreadsPerThreadgroup {
 uint64_t s[3]={};if(!nmb_device_max_threads_per_threadgroup(gDevice,s))NBLOG(@"native-metal: maxThreadsPerThreadgroup: %@",lastError());
 return MTLSizeMake(s[0],s[1],s[2]);
}
- (void)doesNotRecognizeSelector:(SEL)selector {
 if(gMissing)gMissing("NativeBridgeMetalDevice",sel_getName(selector));
 noteProblem([NSString stringWithFormat:@"missing device %s",sel_getName(selector)]);
 [super doesNotRecognizeSelector:selector];
}
- (id<MTLEvent>)newEvent {
 NmbEvent *handle=nmb_event_new(gDevice,false);if(!handle)return nil;
 NBEvent *event=[NBEvent new];event.handle=handle;return (id<MTLEvent>)event;
}
- (id<MTLSharedEvent>)newSharedEvent {
 NmbEvent *handle=nmb_event_new(gDevice,true);if(!handle)return nil;
 NBSharedEvent *event=[NBSharedEvent new];event.handle=handle;return (id<MTLSharedEvent>)event;
}
- (id<MTLFence>)newFence {
 NmbFence *handle=nmb_fence_new(gDevice);if(!handle)return nil;
 NBFence *fence=[NBFence new];fence.handle=handle;return (id<MTLFence>)fence;
}
- (id<MTLCommandQueue>)newCommandQueue {
 NmbQueue *handle=nmb_queue_new(gDevice);if(!handle)return nil;
 NBQueue *queue=[NBQueue new];queue.handle=handle;return (id<MTLCommandQueue>)queue;
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)d {
 if(!d)return nil;
 NmbHeap *handle=nmb_heap_new(gDevice,d.type,d.size,(uint64_t)d.resourceOptions);
 if(!handle){NBLOG(@"native-metal: heap refused: %@",lastError());return nil;}
 NBHeap *heap=[NBHeap new];heap.handle=handle;heap.options=d.resourceOptions;heap.heapType=d.type;return (id<MTLHeap>)heap;
}
- (id)newResourceGroupFromResources:(const id __unsafe_unretained [])resources count:(NSUInteger)count {
 NBResourceGroup *group=[NBResourceGroup new];
 NSMutableArray *held=[NSMutableArray arrayWithCapacity:count];
 for(NSUInteger i=0;i<count;i++)if(resources[i])[held addObject:resources[i]];
 group.resources=held;return group;
}
// SweetMetal2: a texture over raw memory, and the layout object for such memory (MTLTextureLayout SPI), in one linear layout of
// our choosing that both answer alike: rows of the runtime's required linear pitch, level 0 of a 2D texture, page-aligned
// memory (it is imported, not copied). Clients ask the layout for size and alignment, allocate, then wrap the memory
// (RenderBox's drawables; without these: "RBDisplayList: no drawable" and blank widgets). A caller that never asked
// gets the pitch its length implies where the required one does not fit.
- (id<MTLTexture>)newTextureWithBytesNoCopy:(void *)bytes length:(NSUInteger)length descriptor:(MTLTextureDescriptor *)d deallocator:(void (^)(void *,NSUInteger))deallocator {ENC_SCOPE(EC_TEX,"newTextureNoCopy");
 const size_t page=(size_t)getpagesize();
 if(!bytes || !d || !length || ((uintptr_t)bytes&(page-1)) || d.textureType!=MTLTextureType2D || d.mipmapLevelCount>1 || d.arrayLength>1 || d.sampleCount>1){
  NBLOG(@"native-metal: newTextureWithBytesNoCopy refused (%p %lu type %lu levels %lu)",bytes,(unsigned long)length,(unsigned long)d.textureType,(unsigned long)d.mipmapLevelCount);
  return nil;
 }
 uint32_t bw=0,bh=0,bb=0;
 if(sweetBlock(d.pixelFormat,&bw,&bh,&bb)) {
  /* compressed: no linear texture of it exists, so a texture of its own, filled from the caller's blocks (packed rows) */
  const NSUInteger row=(d.width+bw-1)/bw*bb,rows=(d.height+bh-1)/bh;
  if(row*rows>length){NBLOG(@"native-metal: newTextureWithBytesNoCopy: %lux%lu fmt %lu needs %lu bytes, has %lu",(unsigned long)d.width,(unsigned long)d.height,(unsigned long)d.pixelFormat,(unsigned long)(row*rows),(unsigned long)length);return nil;}
  MTLTextureDescriptor *own=[d copy];
  own.storageMode=MTLStorageModeShared;
  id<MTLTexture> texture=[(id<MTLDevice>)self newTextureWithDescriptor:own];
  if(!texture)return nil;
  [texture replaceRegion:MTLRegionMake2D(0,0,d.width,d.height) mipmapLevel:0 withBytes:bytes bytesPerRow:row];
  SweetMemoryOwner *owner=[SweetMemoryOwner new];owner.deallocator=deallocator;owner.bytes=bytes;owner.length=length;
  objc_setAssociatedObject(texture,&sweetMemoryOwnerKey,owner,OBJC_ASSOCIATION_RETAIN);
  return texture;
 }
 uint64_t row=sweetLinearRow(d.pixelFormat,d.width);
 if(row && row*d.height>length)row=nmb_device_linear_bytes_per_row(gDevice,d.pixelFormat,d.width);   // memory laid out before C4
 if(row && row*d.height>length && length%d.height==0)row=length/d.height;
 if(!row || row*d.height>length){NBLOG(@"native-metal: newTextureWithBytesNoCopy: %lux%lu fmt %lu does not fit %lu bytes",(unsigned long)d.width,(unsigned long)d.height,(unsigned long)d.pixelFormat,(unsigned long)length);return nil;}
 id<MTLBuffer> buffer=[(id<MTLDevice>)self newBufferWithBytesNoCopy:bytes length:(length+page-1)&~(page-1) options:MTLResourceStorageModeShared deallocator:deallocator];
 if(!buffer)return nil;
 return (id<MTLTexture>)textureOnBuffer((NBBuffer *)buffer,d,0,row,false);
}
- (id)newTextureLayoutWithDescriptor:(MTLTextureDescriptor *)d isHeapOrBufferBacked:(BOOL)backed {
 (void)backed;
 if(!d || d.textureType!=MTLTextureType2D || d.mipmapLevelCount>1 || d.arrayLength>1 || d.sampleCount>1){
  NBLOG(@"native-metal: newTextureLayoutWithDescriptor refused (type %lu levels %lu)",(unsigned long)d.textureType,(unsigned long)d.mipmapLevelCount);
  return nil;
 }
 uint32_t bw=0,bh=0,bb=0;
 if(sweetBlock(d.pixelFormat,&bw,&bh,&bb))
  return [[SweetTextureLayout alloc] initWithBlocks:bw by:bh bytes:bb width:d.width height:d.height];
 const uint64_t row=sweetLinearRow(d.pixelFormat,d.width);
 if(!row){NBLOG(@"native-metal: newTextureLayoutWithDescriptor: no linear pitch for fmt %lu: %@",(unsigned long)d.pixelFormat,lastError());return nil;}
 return [[SweetTextureLayout alloc] initWithRow:row height:d.height texel:sweetTexelBytes(d.pixelFormat)];
}
// C4: the offset/row alignment of a texture over a buffer (Metal's: 16; the base class answers it from Apple's tables). CA's
// 194-wide BGRA linear texture still came at 784-byte rows on r19a with every other alignment answer at 64; the first call is logged.
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format {
 static std::atomic<bool> logged{false};
 if(!logged.exchange(true))sm2_logs([NSString stringWithFormat:@"native-metal: minimumTextureBufferAlignmentForPixelFormat:%lu asked: %llu",
     (unsigned long)format,(unsigned long long)linearAlignment()].UTF8String);
 return (NSUInteger)linearAlignment();
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {(void)count;return [(id<MTLDevice>)self newCommandQueue];}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {ENC_SCOPE(EC_BUF,"newBuffer");
 NmbBuffer *handle=nmb_buffer_new(gDevice,length,options,nullptr);
 if(!handle){NBLOG(@"native-metal: buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;return (id<MTLBuffer>)buffer;
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options {ENC_SCOPE(EC_BUF,"newBufferWithBytes");
 if(!bytes)return nil;
 NmbBuffer *handle=nmb_buffer_new(gDevice,length,options,bytes);
 if(!handle){NBLOG(@"native-metal: buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;return (id<MTLBuffer>)buffer;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void *,NSUInteger))deallocator {ENC_SCOPE(EC_BUF,"newBufferNoCopy");
 NmbBuffer *handle=nmb_buffer_new_no_copy(gDevice,pointer,length,options);
 if(!handle){NBLOG(@"native-metal: no-copy buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;
 buffer.wrapped=pointer;buffer.deallocator=deallocator;
 return (id<MTLBuffer>)buffer;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {ENC_SCOPE(EC_TEX,"newTexture");
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor))return nil;
 NmbTexture *handle=nmb_texture_new(gDevice,&descriptor);noteFormat((uint32_t)descriptor.format,handle!=nullptr);
 if(!handle){NBLOG(@"native-metal: texture refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;return (id<MTLTexture>)texture;
}
// The surface's pages are the texels: its mapping in this process is imported without a copy (pinned by the kernel, mapped into the GPU's
// 4 KiB context by Turnip), so every process that imports the surface renders and samples the same memory.
// A plane of a planar surface (the camera's 420f/420v pictures: an R8 texture over the luma plane, an RG8 one over the
// chroma plane, as Core Animation asks for them) is a texture at that plane's offset with that plane's rows.
// (Redfin: before this every planar surface was refused, and Camera.app's preview stayed black.)
static void noteSurfaceTexture(IOSurfaceRef surface,MTLTextureDescriptor *d,NSUInteger plane,size_t planes,NSUInteger offset,
                               NSUInteger row,const char *what) {
 // Once per distinct (surface format, texture format, plane, planes, outcome with its whole reason): the old key took the reason's
 // first letter only, so a second reason of the same outcome ("refused (...)") was never logged.
 static std::mutex lock;static std::vector<std::string> seen;
 const uint32_t f=IOSurfaceGetPixelFormat(surface);
 char head[96];snprintf(head,sizeof head,"%08x/%lu/%lu/%zu/",f,(unsigned long)d.pixelFormat,(unsigned long)plane,planes);
 const std::string key=head+std::string(what);
 {std::lock_guard<std::mutex> l(lock);if(std::find(seen.begin(),seen.end(),key)!=seen.end() || seen.size()>=96)return;seen.push_back(key);}
 NBLOG(@"native-metal: IOSurface texture %s: surface %c%c%c%c %zux%zu, %zu planes; plane %lu as format %lu %lux%lu, offset %lu, %lu bytes a row",
       what,(char)(f>>24),(char)(f>>16),(char)(f>>8),(char)f,IOSurfaceGetWidth(surface),IOSurfaceGetHeight(surface),planes,
       (unsigned long)plane,(unsigned long)d.pixelFormat,(unsigned long)d.width,(unsigned long)d.height,(unsigned long)offset,(unsigned long)row);
}
// The surface's YCbCr matrix attachment, as NmbSurfaceFacts names it: 0 none, 1 BT.601, 2 BT.709, 3 BT.2020, 4 SMPTE 240M, 5 another.
// CoreVideo propagates a pixel buffer's kCVImageBufferYCbCrMatrixKey (camera_device.c attaches ITU_R_601_4) to its IOSurface's values;
// the key is looked for by name among the values and one level of dictionaries inside them, so the exact key spelling does not matter.
// The first surface's value keys are logged once (phase 2: which key carries it).
static uint32_t matrixOfValue(CFTypeRef value) {
 if(!value || CFGetTypeID(value)!=CFStringGetTypeID())return 5;
 NSString *text=(__bridge NSString *)value;
 if([text containsString:@"709"])return 2;
 if([text containsString:@"601"])return 1;
 if([text containsString:@"2020"])return 3;
 if([text containsString:@"240"])return 4;
 return 5;
}
static uint32_t surfaceMatrix(IOSurfaceRef surface) {
 // (r19: SweetSurface accepts and drops IOSurface values, so this answers 0, read as BT.601 like Metal's "no matrix", until the
 // kernel keeps them.)
 // Without an attachment, an HD video-range picture (a decoder's 420v, 1280x720 and up) is taken as BT.709, as CoreVideo tags those;
 // everything else (the camera's 420f, SD video) as BT.601, Metal's reading of no matrix.
 const uint32_t guess=(IOSurfaceGetPixelFormat(surface)&0xff)=='v' && IOSurfaceGetWidth(surface)>=1280 && IOSurfaceGetHeight(surface)>=720?2:0;
 CFDictionaryRef values=IOSurfaceCopyAllValues(surface);
 if(!values)return guess;
 NSDictionary *all=(__bridge_transfer NSDictionary *)values;
 static std::atomic<bool> logged{false};
 if(!logged.exchange(true)) {
  NSString *keys=[all.allKeys componentsJoinedByString:@" "];
  NBLOG(@"native-metal: YCbCr surface values: %@",keys.length>300?[keys substringToIndex:300]:keys);
 }
 uint32_t matrix=guess;
 for(id key in all) {
  id value=all[key];
  if([key isKindOfClass:[NSString class]] && [(NSString *)key containsString:@"YCbCrMatrix"])return matrixOfValue((__bridge CFTypeRef)value);
  if([value isKindOfClass:[NSDictionary class]])for(id inner in (NSDictionary *)value)
   if([inner isKindOfClass:[NSString class]] && [(NSString *)inner containsString:@"YCbCrMatrix"])matrix=matrixOfValue((__bridge CFTypeRef)((NSDictionary *)value)[inner]);
 }
 return matrix;
}
// MTLPixelFormatYCBCR8_420_2P (500) and its sRGB twin (501): Core Animation asks for one texture over both planes of a 420f/420v surface
// (photographs in Photos, videos, the camera preview). Turnip has no such format. Two ways:
// - the CPU copy (default since r19a): an RGBA8 picture in RGB, converted on the CPU into a linear texture over a buffer of its own
//   (64-byte rows: no Turnip shadow, no upload), filled again when the texture is used after its surface was written (seed). Two
//   buffers take turns, and the one written is never one a committed command buffer still uses, so a frame is never sampled half
//   filled (r19a's tiles out of step came from 71 strip uploads per picture landing while the texture was sampled).
// - SWEET_YCBCR=gpu (/var/local/mtl2-env): the runtime's two-plane texture (metal2vulkan ycbcr.rs), converted on the GPU into an
//   RGBA16F image of its own, now only when the surface's seed moved (bridge patch 0103: r19a converted at every encoder, 82 ms
//   submits at 99 % busy), one texture per surface while Core Animation holds it (r19a made one image of 13.6 MB per frame: the
//   pool climbed 163 -> 352 MB).
static bool ycbcrOnGPU() {
 static int gpu=-1;
 if(gpu<0){const char *e=getenv("SWEET_YCBCR");gpu=e && !strcmp(e,"gpu");}
 return gpu>0;
}
static NBTexture *ycbcrSurfaceTexture(IOSurfaceRef surface,MTLTextureDescriptor *d,std::string &why,uint64_t *lumaRowOut) {
 if(IOSurfaceGetPlaneCount(surface)!=2){why="not two planes";return nil;}
 void *base=IOSurfaceGetBaseAddress(surface);const size_t page=(size_t)getpagesize(),allocation=IOSurfaceGetAllocSize(surface);
 if(!base || ((uintptr_t)base&(page-1)) || !allocation || allocation>SIZE_MAX-(page-1)){why="base or size";return nil;}
 const size_t bytes=(allocation+page-1)&~(page-1);
 const uint64_t luma=(uint64_t)((uintptr_t)IOSurfaceGetBaseAddressOfPlane(surface,0)-(uintptr_t)base);
 const uint64_t chroma=(uint64_t)((uintptr_t)IOSurfaceGetBaseAddressOfPlane(surface,1)-(uintptr_t)base);
 const uint64_t lumaRow=IOSurfaceGetBytesPerRowOfPlane(surface,0),chromaRow=IOSurfaceGetBytesPerRowOfPlane(surface,1);
 *lumaRowOut=lumaRow;
 if(!lumaRow || !chromaRow || luma>=bytes || chroma>=bytes){why="plane geometry";return nil;}
 // One texture per surface and request while the caller holds it (weak): CA asks again for every frame of a pool surface.
 struct Key {uint64_t id,base,format,width,height,usage;};
 const Key value={IOSurfaceGetID(surface),(uintptr_t)base,(uint64_t)d.pixelFormat,d.width,d.height,(uint64_t)d.usage};
 NSValue *key=[NSValue valueWithBytes:&value objCType:@encode(Key)];
 static NSMapTable<NSValue *,NBTexture *> *made;static std::mutex lock;
 {std::lock_guard<std::mutex> l(lock);
  if(!made)made=[NSMapTable strongToWeakObjectsMapTable];
  if(NBTexture *known=[made objectForKey:key]){why="";return known;}}
 NBBuffer *buffer=surfaceBuffer(surface,base,bytes);
 if(!buffer){why="import";return nil;}
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor)){why="descriptor";return nil;}
 const NmbSurfaceFacts facts={IOSurfaceGetPixelFormat(surface),surfaceMatrix(surface),0,IOSurfaceGetWidth(surface),IOSurfaceGetHeight(surface),chroma,chromaRow};
 NmbTexture *handle=nmb_texture_new_on_surface(buffer.handle,&descriptor,luma,lumaRow,true,&facts);
 if(!handle){why=lastError().UTF8String?:"?";return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.buffer=buffer;texture.offset=(NSUInteger)luma;texture.rowBytes=(NSUInteger)lumaRow;texture.plane=0;[texture holdSurface:surface];
 texture.ycbcrGPU=true;
 {std::lock_guard<std::mutex> l(lock);
  if(made.count>=64)for(NSValue *old in made.keyEnumerator.allObjects)if(![made objectForKey:old])[made removeObjectForKey:old];
  [made setObject:texture forKey:key];}
 return texture;
}
// The CPU copy's picture: BT.601 or BT.709 by the surface's matrix, full range for 420f and the like, video range for 420v; 16.16
// fixed point; nearest chroma; written straight into the buffer under the texture (`row` bytes a row), then cleaned to memory.
static bool ycbcrFill(NBBuffer *into,uint64_t row,IOSurfaceRef surface,size_t w,size_t h,bool bt709) {
 const uint8_t *y=(const uint8_t *)IOSurfaceGetBaseAddressOfPlane(surface,0),*c=(const uint8_t *)IOSurfaceGetBaseAddressOfPlane(surface,1);
 const size_t ys=IOSurfaceGetBytesPerRowOfPlane(surface,0),cs=IOSurfaceGetBytesPerRowOfPlane(surface,1);
 uint8_t *out=into?(uint8_t *)nmb_buffer_contents(into.handle):nullptr;
 if(!y || !c || !ys || !cs || !out || row<w*4 || nmb_buffer_length(into.handle)<row*h)return false;
 const bool video=(IOSurfaceGetPixelFormat(surface)&0xff)=='v';
 // {luma, Cr->R, Cb->G, Cr->G, Cb->B}: BT.601 / BT.709, full / video range (chroma 255/224 and luma 255/219 for video)
 static const int32_t k[2][2][5]={{{65536,91881,22554,46802,116130},{76309,104597,25674,53279,132201}},
                                  {{65536,103206,12275,30677,121607},{76309,117489,13973,34923,138438}}};
 const int32_t *m=k[bt709][video];
 const int32_t ky=m[0],kr=m[1],kgb=m[2],kgr=m[3],kb=m[4],y0=video?16:0;
 for(size_t j=0;j<h;j++) {
  const uint8_t *yl=y+j*ys,*cl=c+(j/2)*cs;uint32_t *o=(uint32_t *)(out+j*row);
  size_t x=0;
#if defined(__aarch64__)
  // 16 pixels a step: the same matrix in 10.6 fixed point, saturating (r19a: 17-21 ms a picture scalar).
  {
   const int16_t qy=(int16_t)((ky+512)>>10),qr=(int16_t)((kr+512)>>10),qgb=(int16_t)((kgb+512)>>10),qgr=(int16_t)((kgr+512)>>10),
                 qb=(int16_t)((kb+512)>>10);
   const int16x8_t vy0=vdupq_n_s16((int16_t)y0),v128=vdupq_n_s16(128),vround=vdupq_n_s16(32);
   const uint8x16_t alpha=vdupq_n_u8(255);
   for(;x+16<=w;x+=16) {
    const uint8x16_t yv=vld1q_u8(yl+x);
    const uint8x8x2_t cc=vld2_u8(cl+x);   // 8 (Cb, Cr) pairs
    const int16x8_t cb=vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(cc.val[0])),v128),cr=vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(cc.val[1])),v128);
    const int16x8_t dr=vmulq_n_s16(cr,qr),dg=vnegq_s16(vaddq_s16(vmulq_n_s16(cb,qgb),vmulq_n_s16(cr,qgr))),db=vmulq_n_s16(cb,qb);
    const int16x8_t drl=vzip1q_s16(dr,dr),drh=vzip2q_s16(dr,dr),dgl=vzip1q_s16(dg,dg),dgh=vzip2q_s16(dg,dg),dbl=vzip1q_s16(db,db),dbh=vzip2q_s16(db,db);
    const int16x8_t ll=vaddq_s16(vmulq_n_s16(vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(yv))),vy0),qy),vround);
    const int16x8_t lh=vaddq_s16(vmulq_n_s16(vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(yv))),vy0),qy),vround);
    uint8x16x4_t px;
    px.val[0]=vcombine_u8(vqshrun_n_s16(vqaddq_s16(ll,drl),6),vqshrun_n_s16(vqaddq_s16(lh,drh),6));
    px.val[1]=vcombine_u8(vqshrun_n_s16(vqaddq_s16(ll,dgl),6),vqshrun_n_s16(vqaddq_s16(lh,dgh),6));
    px.val[2]=vcombine_u8(vqshrun_n_s16(vqaddq_s16(ll,dbl),6),vqshrun_n_s16(vqaddq_s16(lh,dbh),6));
    px.val[3]=alpha;
    vst4q_u8((uint8_t *)(o+x),px);
   }
  }
#endif
  for(;x<w;x+=2) {
   const int32_t cb=(int32_t)cl[x]-128,cr=(int32_t)cl[x+1]-128;
   const int32_t dr=kr*cr,dg=-kgb*cb-kgr*cr,db=kb*cb;
   for(size_t i=x;i<x+2 && i<w;i++) {
    const int32_t l=((int32_t)yl[i]-y0)*ky+32768;
    int32_t r=(l+dr)>>16,g=(l+dg)>>16,b=(l+db)>>16;
    r=r<0?0:r>255?255:r;g=g<0?0:g>255?255:g;b=b<0?0:b>255?255:b;
    o[i]=0xff000000u|((uint32_t)b<<16)|((uint32_t)g<<8)|(uint32_t)r;
   }
  }
 }
 sys_dcache_flush(out,(size_t)(row*h));   // the GPU does not snoop: the picture in memory before any command buffer reads it
 return true;
}
// A buffer of `row` x `h` bytes and an RGBA8 linear texture over it (64-byte rows: Turnip aliases it, no copy).
static NBTexture *copyTexture(MTLPixelFormat format,size_t w,size_t h,uint64_t row) {
 const size_t page=(size_t)getpagesize(),length=((size_t)(row*h)+page-1)&~(page-1);
 NmbBuffer *handle=nmb_buffer_new(gDevice,length,MTLResourceStorageModeShared,nullptr);
 if(!handle){NBLOG(@"native-metal: YCbCr copy buffer %zux%zu refused: %@",w,h,lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=MTLResourceStorageModeShared;
 MTLTextureDescriptor *rgba=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
 rgba.usage=MTLTextureUsageShaderRead;rgba.storageMode=MTLStorageModeShared;
 return textureOnBuffer(buffer,rgba,0,(NSUInteger)row,false);
}
static std::atomic<uint64_t> gYCbCrFills,gYCbCrSkips,gYCbCrFillUs,gYCbCrFillMaxUs;
// A picture into `turn`, timed; every 300th fill a J line in the log (/dev/console, so the klog has it).
static bool ycbcrFillTurn(NBTexture *turn,IOSurfaceRef surface,size_t w,size_t h,bool bt709) {
 const uint64_t began=nowUs();
 if(!ycbcrFill(turn.buffer,turn.rowBytes,surface,w,h,bt709))return false;
 const uint64_t took=nowUs()-began;gYCbCrFillUs+=took;
 uint64_t seen=gYCbCrFillMaxUs.load();while(took>seen && !gYCbCrFillMaxUs.compare_exchange_weak(seen,took)){}
 const uint64_t n=++gYCbCrFills;
 if(n<=2 || n%300==0)sm2_logs([NSString stringWithFormat:@"native-metal: J ycbcr cpu fills=%llu skips=%llu fill mean %llu us max %llu us",
     (unsigned long long)n,(unsigned long long)gYCbCrSkips.load(),(unsigned long long)(gYCbCrFillUs.load()/n),
     (unsigned long long)gYCbCrFillMaxUs.load()].UTF8String);
 return true;
}
static NBTexture *ycbcrCopy(IOSurfaceRef surface,MTLTextureDescriptor *d) {
 if(IOSurfaceGetPlaneCount(surface)!=2)return nil;
 const size_t w=d.width,h=d.height;
 if(!w || !h || IOSurfaceGetWidthOfPlane(surface,0)<w || IOSurfaceGetHeightOfPlane(surface,0)<h ||
    IOSurfaceGetWidthOfPlane(surface,1)*2<w || IOSurfaceGetHeightOfPlane(surface,1)*2<h)return nil;
 const uint64_t row=((uint64_t)w*4+63)&~63ull;
 NBTexture *turn=copyTexture(d.pixelFormat==501?MTLPixelFormatRGBA8Unorm_sRGB:MTLPixelFormatRGBA8Unorm,w,h,row);
 if(!turn)return nil;
 const uint32_t seed=IOSurfaceGetSeed(surface);
 const bool bt709=surfaceMatrix(surface)==2;
 if(!ycbcrFillTurn(turn,surface,w,h,bt709))return nil;
 NBTexture *texture=[NBTexture new];
 texture.handle=turn.handle;texture.borrowedHandle=true;texture.descriptor=turn.descriptor;texture.buffer=turn.buffer;
 texture.rowBytes=turn.rowBytes;texture.turns=[NSMutableArray arrayWithObject:turn];
 texture.reportedFormat=(uint64_t)d.pixelFormat;texture.surfaceSeed=seed;texture.ycbcrSource=(IOSurfaceRef)CFRetain(surface);
 texture.ycbcr709=bt709;
 return texture;
}
// Whether a committed command buffer that has not completed uses `buffer` (an unknown answer counts as yes).
static bool bufferInFlight(NBBuffer *buffer) {
 NSArray *pending;@synchronized(gInFlight){pending=gInFlight.allObjects;}
 for(NBCommandBuffer *commandBuffer in pending)
  if(nmb_command_buffer_uses_buffer(commandBuffer.handle,buffer.handle)!=0)return true;
 return false;
}
// At each use of a YCbCr texture (a draw's or a blit's): the GPU texture is told its surface's seed (converted again only when it
// moved). The CPU copy (r19a + 5a0c8ed: refilled at the binds of CA's encode thread, 17-21 ms each, and a fresher picture for the
// later draws of the same frame: "draws in chunks", the UI flickering):
// - its picture changes only at the first use in a command buffer: every draw of that command buffer samples the same picture;
// - there it takes the newest completed fill (never waits), and when the surface's seed moved on past it a fill is started on the
//   worker queue into a turn neither bound nor holding that newest fill nor used by a committed command buffer (up to 3 turns;
//   none free: started at a later use, counted as a skip);
// - the first picture is filled at creation, synchronously (a surface drawn once, Photos' and the thumbnails', has it).
static dispatch_queue_t ycbcrWorker() {
 static dispatch_queue_t queue;static dispatch_once_t once;
 dispatch_once(&once,^{queue=dispatch_queue_create("org.iosonpixel.sweetmetal2.ycbcr",
                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));});
 return queue;
}
static void ycbcrRefresh(NBTexture *texture,id commandBuffer) {
 if(texture.ycbcrGPU) {
  if(texture.surface)nmb_texture_set_converted_generation(texture.handle,(uint64_t)IOSurfaceGetSeed(texture.surface)+1);
  return;
 }
 if(!texture.reportedFormat || !texture.ycbcrSource)return;
 @synchronized(texture) {
  const void *cb=(__bridge const void *)commandBuffer;
  if(cb && texture.lastCommandBuffer==cb)return;   // this command buffer already chose its picture
  const bool firstUse=!texture.lastCommandBuffer;
  texture.lastCommandBuffer=cb;
  // The first use of a copy whose surface was written after it was made (a picture decoded into a surface CA already made the
  // texture for, drawn once: thumbnails, Photos) is filled here, synchronously, into the bound turn (nothing has sampled it yet).
  if(firstUse && !texture.filling && IOSurfaceGetSeed(texture.ycbcrSource)!=texture.surfaceSeed) {
   const uint32_t seed=IOSurfaceGetSeed(texture.ycbcrSource);
   for(NBTexture *turn in texture.turns)if(turn.handle==texture.handle) {
    if(ycbcrFillTurn(turn,texture.ycbcrSource,texture.descriptor.width,texture.descriptor.height,texture.ycbcr709))texture.surfaceSeed=seed;
    break;
   }
  }
  if(NBTexture *ready=texture.readyTurn) {
   texture.previousHandle=texture.handle;
   texture.handle=ready.handle;texture.buffer=ready.buffer;texture.surfaceSeed=texture.readySeed;texture.readyTurn=nil;
  }
  const uint32_t seed=IOSurfaceGetSeed(texture.ycbcrSource);
  if(texture.filling || seed==texture.surfaceSeed)return;
  const NmbTextureDescriptor current=texture.descriptor;
  NBTexture *next=nil;
  for(NBTexture *turn in texture.turns)
   if(turn.handle!=texture.handle && turn.handle!=texture.previousHandle && !bufferInFlight(turn.buffer)){next=turn;break;}
  if(!next && texture.turns.count<3) {
   next=copyTexture((MTLPixelFormat)current.format,current.width,current.height,texture.rowBytes);
   if(next)[texture.turns addObject:next];
  }
  if(!next){gYCbCrSkips++;return;}
  texture.filling=true;texture.fillSeed=seed;
  IOSurfaceRef surface=(IOSurfaceRef)CFRetain(texture.ycbcrSource);
  const bool bt709=texture.ycbcr709;const size_t w=current.width,h=current.height;
  dispatch_async(ycbcrWorker(),^{
   const bool ok=ycbcrFillTurn(next,surface,w,h,bt709);
   CFRelease(surface);
   @synchronized(texture) {
    texture.filling=false;
    if(ok){texture.readyTurn=next;texture.readySeed=texture.fillSeed;}
   }
  });
 }
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {ENC_SCOPE(EC_TEX,"newTexture(iosurface)");if(surface && d && encStatOn())snprintf(tEncDetail,sizeof tEncDetail,"surface %u %zux%zu fmt %lu plane %lu",IOSurfaceGetID(surface),IOSurfaceGetWidth(surface),IOSurfaceGetHeight(surface),(unsigned long)d.pixelFormat,(unsigned long)plane);
 if(!surface || !d)return nil;
 const size_t planes=IOSurfaceGetPlaneCount(surface);
 if(planes?plane>=planes:plane!=0){noteSurfaceTexture(surface,d,plane,planes,0,0,"refused (no such plane)");return nil;}
 if((d.pixelFormat==500 || d.pixelFormat==501) && plane==0) {
  const NSUInteger lumaAt=(NSUInteger)((uintptr_t)IOSurfaceGetBaseAddressOfPlane(surface,0)-(uintptr_t)IOSurfaceGetBaseAddress(surface));
  static std::atomic<unsigned> asked{0};
  const unsigned askedNow=++asked;
  if(askedNow<=3)sm2_logs([NSString stringWithFormat:@"native-metal: YCbCr texture %lu asked (#%u, %s): surface id %u %zux%zu, rows %zu/%zu",
      (unsigned long)d.pixelFormat,askedNow,ycbcrOnGPU()?"gpu":"cpu copy",IOSurfaceGetID(surface),IOSurfaceGetWidth(surface),
      IOSurfaceGetHeight(surface),IOSurfaceGetBytesPerRowOfPlane(surface,0),IOSurfaceGetBytesPerRowOfPlane(surface,1)].UTF8String);
  if(ycbcrOnGPU()) {
   std::string why;uint64_t lumaRow=0;
   if(NBTexture *texture=ycbcrSurfaceTexture(surface,d,why,&lumaRow)){
    noteSurfaceTexture(surface,d,plane,planes,lumaAt,(NSUInteger)lumaRow,"made (YCbCr on the GPU)");return (id<MTLTexture>)texture;}
   noteSurfaceTexture(surface,d,plane,planes,lumaAt,(NSUInteger)lumaRow,("YCbCr on the GPU refused, CPU copy instead: "+why).c_str());
  }
  NBTexture *copy=ycbcrCopy(surface,d);
  noteSurfaceTexture(surface,d,plane,planes,lumaAt,IOSurfaceGetBytesPerRowOfPlane(surface,0),copy?"made (YCbCr copy)":"refused (YCbCr copy)");
  return (id<MTLTexture>)copy;
 }
 void *base=IOSurfaceGetBaseAddress(surface);const size_t page=(size_t)getpagesize(),allocation=IOSurfaceGetAllocSize(surface);
 if(!page || (page&(page-1)) || !base || ((uintptr_t)base&(page-1)) || !allocation || allocation>SIZE_MAX-(page-1)) {
  noteSurfaceTexture(surface,d,plane,planes,(NSUInteger)((uintptr_t)base&(page-1)),allocation,"refused (base or size)");return nil;
 }
 const size_t bytes=(allocation+page-1)&~(page-1);
 const NSUInteger offset=planes?(NSUInteger)((uintptr_t)IOSurfaceGetBaseAddressOfPlane(surface,plane)-(uintptr_t)base):0;
 const NSUInteger row=planes?IOSurfaceGetBytesPerRowOfPlane(surface,plane):IOSurfaceGetBytesPerRow(surface);
 if(planes && (!row || offset>=bytes)){noteSurfaceTexture(surface,d,plane,planes,offset,row,"refused (plane geometry)");return nil;}
 NBBuffer *buffer=surfaceBuffer(surface,base,bytes);
 if(!buffer){noteSurfaceTexture(surface,d,plane,planes,offset,row,"refused (import)");return nil;}
 // SweetMetal2: Core Animation's landscape framebuffer is a 2436x1125 texture of rotation 1/3 (SPI -[MTLTextureDescriptor rotation],
 // framebufferOnly) over the panel's portrait 1125x2436 surface. NmbTextureDescriptor carries neither, so the runtime checked a 2436-texel
 // row against the surface's 4608 bytes and refused it (RowPitch) every frame: rotating to landscape froze the screen (r61b 2026-10-29).
 const uint64_t rotation=descriptorRotation(d);
 NBTexture *texture=nil;
 if(rotation) {
  // SweetMetal2 (rotfb3): a rotated texture is a shadow image plus a tight buffer, a staging buffer and the rotation kernel's sets
  // (metal2vulkan rotated.rs): ~2 x the surface's bytes of GPU pool and ~20 small allocations each. r62b: Core Animation asked for
  // them again and again in landscape and backboardd's pool grew 194 -> 451 MB in 30 s (live <256K 2654 -> 4453) until it crashed.
  // The last few are kept and handed out again for the same surface memory, rotation and descriptor.
  struct RotKey {uint64_t id,base,bytes,offset,row,rotation,fbo,type,format,width,height,usage,options;};
  const RotKey key={(uint64_t)IOSurfaceGetID(surface),(uint64_t)(uintptr_t)base,(uint64_t)bytes,(uint64_t)offset,(uint64_t)row,rotation,
                    descriptorFramebufferOnly(d)?1u:0u,(uint64_t)d.textureType,sweetFormat((uint64_t)d.pixelFormat),(uint64_t)d.width,
                    (uint64_t)d.height,(uint64_t)d.usage,(uint64_t)d.resourceOptions};
  static std::mutex rotLock;static std::vector<std::pair<RotKey,NBTexture *>> rotCache;static uint64_t rotMade,rotHits;
  {
   std::lock_guard<std::mutex> l(rotLock);
   for(size_t i=0;i<rotCache.size();i++) if(!memcmp(&rotCache[i].first,&key,sizeof key)) {
    NBTexture *hit=rotCache[i].second;auto entry=rotCache[i];rotCache.erase(rotCache.begin()+(long)i);rotCache.insert(rotCache.begin(),entry);
    if(++rotHits==1 || rotHits%500==0)sm2_logs([NSString stringWithFormat:@"native-metal: rotated surface textures: %llu made, %llu reused",
                                                (unsigned long long)rotMade,(unsigned long long)rotHits].UTF8String);
    return (id<MTLTexture>)hit;
   }
  }
  NmbTextureDescriptor descriptor;
  if(textureDescriptor(d,&descriptor)) {
   const NmbTextureExtras extras={rotation,descriptorFramebufferOnly(d)?1u:0u};
   NmbTexture *handle=nmb_texture_new_on_surface_rotated(buffer.handle,&descriptor,offset,row,planes!=0,&extras);
   if(!handle)NBLOG(@"native-metal: rotated surface texture refused (rotation %llu, %lux%lu): %@",(unsigned long long)rotation,
                    (unsigned long)d.width,(unsigned long)d.height,lastError());
   else {
    texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
    texture.buffer=buffer;texture.offset=offset;texture.rowBytes=row;
    NmbTextureExtras made={0,0};nmb_texture_extras(handle,&made);texture.rotationValue=made.rotation;texture.framebufferOnlyValue=made.framebuffer_only!=0;
    texture.plane=plane;[texture holdSurface:surface];
    std::lock_guard<std::mutex> l(rotLock);
    rotCache.insert(rotCache.begin(),{key,texture});
    if(rotCache.size()>3)rotCache.pop_back();      // CA's landscape chain is 2-3 surfaces; the oldest goes when its last user lets it go
    if(++rotMade<=24 || rotMade%200==0)sm2_logs([NSString stringWithFormat:@"native-metal: rotated surface texture #%llu (rotation %llu): surface %zux%zu id %u, texture %lux%lu fmt %lu usage %#lx (%llu reused so far)",
      (unsigned long long)rotMade,(unsigned long long)rotation,IOSurfaceGetWidth(surface),IOSurfaceGetHeight(surface),IOSurfaceGetID(surface),
      (unsigned long)d.width,(unsigned long)d.height,(unsigned long)d.pixelFormat,(unsigned long)d.usage,(unsigned long long)rotHits].UTF8String);
   }
  }
  noteSurfaceTexture(surface,d,plane,planes,offset,row,texture?(rotation==1?"made (rotation 1)":rotation==2?"made (rotation 2)":rotation==3?"made (rotation 3)":"made (rotation 4)")
                                                             :"refused (rotated texture over the surface)");
 } else {
  texture=textureOnBuffer(buffer,d,offset,row,true);
  noteSurfaceTexture(surface,d,plane,planes,offset,row,texture?"made":"refused (texture over the surface)");
 }
 if(!texture)return nil;
 texture.plane=plane;[texture holdSurface:surface];return (id<MTLTexture>)texture;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {ENC_SCOPE(EC_PIPE,"newLibrary(data)");
 const void *bytes=nullptr;size_t size=0;dispatch_data_t mapped=dispatch_data_create_map(data,&bytes,&size);
 const uint64_t libraryBegan=nowUs();
 NmbLibrary *handle=nmb_library_new(gDevice,bytes,size,false);gTimeLibrary.add(libraryBegan);
 if(!handle)return failWith<id<MTLLibrary>>(error,@"library",nil);
 NBLibrary *library=[NBLibrary new];library.handle=handle;library.prewarmDigest=prewarmLibrary(bytes,size);(void)mapped;
 if(error)*error=nil;return (id<MTLLibrary>)library;
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error {ENC_SCOPE(EC_PIPE,"newLibrary(file)");
 NSData *bytes=path?[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error]:nil;if(!bytes)return nil;
 const uint64_t libraryBegan=nowUs();
 NmbLibrary *handle=nmb_library_new(gDevice,bytes.bytes,bytes.length,false);gTimeLibrary.add(libraryBegan);
 if(!handle)return failWith<id<MTLLibrary>>(error,@"library",nil);
 NBLibrary *library=[NBLibrary new];library.handle=handle;library.prewarmDigest=prewarmLibrary(bytes.bytes,bytes.length);
 if(error)*error=nil;return (id<MTLLibrary>)library;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error {
 if(!url.isFileURL){if(error)*error=nbError(@"a file URL is required");return nil;}
 return [(id<MTLDevice>)self newLibraryWithFile:url.path error:error];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error {
 NSURL *url=[bundle URLForResource:@"default" withExtension:@"metallib"];
 if(!url){if(error)*error=nbError(@"the bundle has no default.metallib");return nil;}
 return [(id<MTLDevice>)self newLibraryWithURL:url error:error];
}
- (id<MTLLibrary>)newDefaultLibrary {return [(id<MTLDevice>)self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:nil];}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error {
 return [(id<MTLDevice>)self newComputePipelineStateWithFunction:function options:MTLPipelineOptionNone reflection:nil error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
                                                         reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error {ENC_SCOPE(EC_PIPE,"newComputePipelineState");
 if(reflection)*reflection=nil;
 if(![(id)function isKindOfClass:[NBFunction class]]){if(error)*error=nbError(@"foreign function");return nil;}
 const NmbPipelineOptions creation={(uint64_t)options,nullptr,0};
 const uint64_t pipelineBegan=nowUs();
 NmbComputePipeline *handle=nmb_compute_pipeline_new_with_options(gDevice,[(NBFunction *)function handle],&creation);gTimePipeline.add(pipelineBegan);
 if(!handle)return failWith<id<MTLComputePipelineState>>(error,@"compute pipeline",nil);
 NBComputePipeline *state=[NBComputePipeline new];state.handle=handle;gPipelines++;if(error)*error=nil;return (id<MTLComputePipelineState>)state;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)options
                                                       reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error {ENC_SCOPE(EC_PIPE,"newComputePipelineState(descriptor)");
 if(reflection)*reflection=nil;
 NmbComputePipelineDescriptor p={};if(!computeDescriptor(d,&p,error))return nil;
 std::vector<NmbBinaryArchive *> archives;
 if(!pipelineArchives(d.binaryArchives,archives,error))return nil;
 const NmbPipelineOptions creation={(uint64_t)options,archives.data(),archives.size()};
 const uint64_t pipelineBegan=nowUs();
 NmbComputePipeline *handle=nmb_compute_pipeline_new_with_descriptor(gDevice,&p,&creation);gTimePipeline.add(pipelineBegan);
 if(!handle)return failWith<id<MTLComputePipelineState>>(error,@"compute pipeline",nil);
 NBComputePipeline *state=[NBComputePipeline new];state.handle=handle;state.label=d.label;gPipelines++;
 if(error)*error=nil;return (id<MTLComputePipelineState>)state;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error {
 return [(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:error];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)options
                                                        reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error {ENC_SCOPE(EC_PIPE,"newRenderPipelineState");if(encStatOn())snprintf(tEncDetail,sizeof tEncDetail,"%s + %s fmt %lu",d.vertexFunction.name.UTF8String?:"-",d.fragmentFunction.name.UTF8String?:"-",(unsigned long)d.colorAttachments[0].pixelFormat);
 if(reflection)*reflection=nil;
 auto *p=new NmbRenderPipelineDescriptor();
 if(!renderDescriptor(d,p,error)){delete p;notePipeline(d,"a function of another device");return nil;}
 std::vector<NmbBinaryArchive *> archives;
 if(!pipelineArchives(d.binaryArchives,archives,error)){delete p;return nil;}
 const NmbPipelineOptions creation={(uint64_t)options,archives.data(),archives.size()};
 const uint64_t pipelineBegan=nowUs();const NBCost costBegan=NBCost::now();
 // u-e (r34): what the caches did for this creation, for its "E slow" line
 NmbShaderCacheStats cacheBefore={};uint64_t workBefore[10]={};
 const bool counted=encStatOn() && nmb_device_shader_cache_stats(gDevice,&cacheBefore) && nmb_device_work_stats(gDevice,workBefore);
 NmbRenderPipeline *handle=nmb_render_pipeline_new_with_options(gDevice,p,&creation);gTimePipeline.add(pipelineBegan);
 if(handle) {
  NBFunction *vf=[(id)d.vertexFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.vertexFunction:nil;
  NBFunction *ff=[(id)d.fragmentFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.fragmentFunction:nil;
  if(vf)prewarmRecord(vf.prewarmKey,d.fragmentFunction?(ff?ff.prewarmKey:std::string()):std::string("-"),*p,(uint64_t)options);
 }
 delete p;
 NmbShaderCacheStats cacheAfter={};uint64_t workAfter[10]={};
 if(counted && encScope_.slow() && nmb_device_shader_cache_stats(gDevice,&cacheAfter) && nmb_device_work_stats(gDevice,workAfter)) {
  const size_t at=strlen(tEncDetail);
  snprintf(tEncDetail+at,sizeof tEncDetail-at," | spirv hit %llu miss %llu, drv loads %llu saves %llu same %llu rejected %llu, VkPipelines %llu %.1f ms%s",
   (unsigned long long)(cacheAfter.hits-cacheBefore.hits),(unsigned long long)(cacheAfter.misses-cacheBefore.misses),
   (unsigned long long)(cacheAfter.driver_loads-cacheBefore.driver_loads),(unsigned long long)(cacheAfter.driver_saves-cacheBefore.driver_saves),
   (unsigned long long)(cacheAfter.driver_unchanged-cacheBefore.driver_unchanged),(unsigned long long)(cacheAfter.rejected-cacheBefore.rejected),
   (unsigned long long)(workAfter[0]-workBefore[0]),(workAfter[1]-workBefore[1])/1e3,gPrewarmRunning?" (prewarm running)":"");
 }
 journalRenderPipeline(d,pipelineBegan,handle?nullptr:nmb_last_error(),gJournalPath.empty()?std::string():NBCost::now().since(costBegan));
 notePipeline(d,handle?nullptr:nmb_last_error());
 if(!handle)return failWith<id<MTLRenderPipelineState>>(error,@"render pipeline",nil);
 NBRenderPipeline *state=[NBRenderPipeline new];state.handle=handle;gPipelines++;if(error)*error=nil;
 snprintf(state->encNames,sizeof state->encNames,"%s + %s",d.vertexFunction.name.UTF8String?:"-",d.fragmentFunction.name.UTF8String?:"-");
 {   // ovd
  const char *l=d.label.UTF8String?:"-";if(!strncmp(l,"com.apple.coreanimation.",24))l+=24;snprintf(state->dbLabel,sizeof state->dbLabel,"%s",l);
  MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[0];
  state->dbBlend=a.blendingEnabled;state->dbMask=(uint8_t)a.writeMask;state->dbSrc=(uint8_t)a.sourceRGBBlendFactor;state->dbDst=(uint8_t)a.destinationRGBBlendFactor;
  state->dbSrcA=(uint8_t)a.sourceAlphaBlendFactor;state->dbDstA=(uint8_t)a.destinationAlphaBlendFactor;
  state->dbFmt=0;state->dbCFmt=0;
  if(MTLVertexDescriptor *v=d.vertexDescriptor){MTLVertexAttributeDescriptor *at=v.attributes[0];
   if(at.format!=MTLVertexFormatInvalid && at.bufferIndex<31){state->dbFmt=(uint32_t)at.format;state->dbOff=(uint32_t)at.offset;state->dbBuf=(uint32_t)at.bufferIndex;state->dbStride=(uint32_t)v.layouts[at.bufferIndex].stride;
    for(unsigned k=1;k<31;k++){MTLVertexAttributeDescriptor *c=v.attributes[k];
     if(c.bufferIndex==at.bufferIndex && (c.format==MTLVertexFormatHalf4 || c.format==MTLVertexFormatFloat4 || c.format==MTLVertexFormatUChar4Normalized)){state->dbCFmt=(uint32_t)c.format;state->dbCOff=(uint32_t)c.offset;break;}}}}
 }
 return (id<MTLRenderPipelineState>)state;
}
- (id<MTLBinaryArchive>)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)d error:(NSError **)error {
 if(d.url && !d.url.isFileURL){if(error)*error=nbError(@"a file URL is required");return nil;}
 NmbBinaryArchive *handle=nmb_binary_archive_new(gDevice,d.url?d.url.fileSystemRepresentation:nullptr);
 if(!handle)return failWith<id<MTLBinaryArchive>>(error,@"binary archive",nil);
 NBBinaryArchive *archive=[NBBinaryArchive new];archive.handle=handle;if(error)*error=nil;return (id<MTLBinaryArchive>)archive;
}
- (NSUInteger)requiredLinearTextureBytesPerRowForDescriptor:(MTLTextureDescriptor *)d {
 // r19a: CA's linear textures (newLinearTextureWithDescriptor:offset:bytesPerRow:bytesPerImage:) still came with 16-byte-aligned
 // rows (32/112/224/608/720) after the alignment answers said 64: this is the pitch it asks for.
 const uint64_t row=sweetLinearRow(d.pixelFormat,d.width);
 if(!row)NBLOG(@"native-metal: requiredLinearTextureBytesPerRow: %@",lastError());
 return row;
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d {ENC_SCOPE(EC_PIPE,"newSamplerState");
 NmbSamplerDescriptor s={(uint64_t)d.minFilter,(uint64_t)d.magFilter,(uint64_t)d.mipFilter,(uint64_t)d.sAddressMode,(uint64_t)d.tAddressMode,(uint64_t)d.rAddressMode,
     (uint64_t)d.borderColor,(uint64_t)d.normalizedCoordinates,d.maxAnisotropy,(uint64_t)d.compareFunction,(uint64_t)d.lodAverage,d.lodMinClamp,d.lodMaxClamp};
 NmbSampler *handle=nmb_sampler_new(gDevice,&s);
 if(!handle){NBLOG(@"native-metal: sampler refused: %@",lastError());return nil;}
 NBSampler *sampler=[NBSampler new];sampler.handle=handle;return (id<MTLSamplerState>)sampler;
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d {ENC_SCOPE(EC_PIPE,"newDepthStencilState");
 auto face=[](MTLStencilDescriptor *s)->NmbStencil {
  return {(uint64_t)s.stencilCompareFunction,(uint64_t)s.stencilFailureOperation,(uint64_t)s.depthFailureOperation,(uint64_t)s.depthStencilPassOperation,s.readMask,s.writeMask};
 };
 NmbDepthStencilDescriptor s={(uint64_t)d.depthCompareFunction,(uint64_t)d.depthWriteEnabled,face(d.frontFaceStencil),face(d.backFaceStencil)};
 NmbDepthStencil *handle=nmb_depth_stencil_new(gDevice,&s);
 if(!handle){NBLOG(@"native-metal: depth/stencil state refused: %@",lastError());return nil;}
 NBDepthStencil *state=[NBDepthStencil new];state.handle=handle;return (id<MTLDepthStencilState>)state;
}
@end

// The device queries the runtime answers (nmb_device_answer_selector), as methods of the device class. One without an argument is read once
// and installed only where the device has an answer of its own; one with an argument asks the runtime each call, and a refusal answers 0/NO
// with the reason logged.
static std::unordered_map<SEL,uint64_t> gAnswers;
static NSUInteger countAnswer(id,SEL cmd) {return (NSUInteger)gAnswers.at(cmd);}
static BOOL flagAnswer(id,SEL cmd) {return gAnswers.at(cmd)!=0;}
struct AnswerKey {
 SEL sel;NSUInteger arg;
 bool operator==(const AnswerKey &o) const {return sel==o.sel && arg==o.arg;}
};
struct AnswerKeyHash {size_t operator()(const AnswerKey &k) const {return std::hash<uintptr_t>()((uintptr_t)k.sel)*31u ^ std::hash<NSUInteger>()(k.arg);}};
static os_unfair_lock gArgAnswersLock=OS_UNFAIR_LOCK_INIT;
static std::unordered_map<AnswerKey,uint64_t,AnswerKeyHash> gArgAnswers;   // u-cpu 0x1: (selector, argument) -> answer (0 = refused)
static uint64_t askAnswer(SEL cmd,NSUInteger arg) {
 const bool memo=cpuFast()&CPUFAST_ANSWERS;
 const AnswerKey key{cmd,arg};
 if(memo) {
  os_unfair_lock_lock(&gArgAnswersLock);
  const auto found=gArgAnswers.find(key);
  const bool have=found!=gArgAnswers.end();const uint64_t kept=have?found->second:0;
  os_unfair_lock_unlock(&gArgAnswersLock);
  if(have){gCfAnswerHits.fetch_add(1,std::memory_order_relaxed);return kept;}
 }
 gCfAnswerAsks.fetch_add(1,std::memory_order_relaxed);
 uint64_t value=0;
 if(!nmb_device_answer(gDevice,sel_getName(cmd),arg,&value)){NBLOG(@"native-metal: %s(%lu): %@",sel_getName(cmd),(unsigned long)arg,lastError());value=0;}
 if(memo) {
  os_unfair_lock_lock(&gArgAnswersLock);
  if(gArgAnswers.size()<4096)gArgAnswers.emplace(key,value);
  os_unfair_lock_unlock(&gArgAnswersLock);
 }
 return value;
}
static NSUInteger countArgAnswer(id,SEL cmd,NSUInteger arg) {return (NSUInteger)askAnswer(cmd,arg);}
// SweetMetal2 (C4): the row alignment the device asks of linear textures. Metal's (and the runtime's) answer is 16 bytes, but Turnip
// lays a linear image over memory it did not allocate only at 64-byte pitches (pitchalign 6): Core Animation's small A8/RG8/BGRA layers
// over its own buffers came with 32-byte pitches (96, 160, 224 ...), each refused as an explicit layout and shadow-copied every frame
// (r18g: ~100 "TU: warning: sweet: explicit layout refused"). Clients that ask lay their rows out at 64 now. /var/local/mtl2-env
// SWEET_LINEAR_ALIGN=N sets another power of two (16 = Metal's).
static uint64_t linearAlignment() {
 static uint64_t align=0;
 if(!align){const char *e=getenv("SWEET_LINEAR_ALIGN");const uint64_t v=e?strtoull(e,nullptr,0):64;align=v && !(v&(v-1))?v:64;}
 return align;
}
static uint64_t sweetLinearRow(uint64_t format,uint64_t width) {
 const uint64_t row=nmb_device_linear_bytes_per_row(gDevice,format,width),align=linearAlignment();
 return row?(row+align-1)&~(align-1):0;
}
static NSUInteger linearAlignmentAnswer(id,SEL cmd,NSUInteger arg) {
 const uint64_t value=askAnswer(cmd,arg);
 static std::atomic<bool> logged{false};
 if(!logged.exchange(true))sm2_logs([NSString stringWithFormat:@"native-metal: %s%lu asked: %llu",sel_getName(cmd),(unsigned long)arg,
     (unsigned long long)(value?std::max(value,linearAlignment()):0)].UTF8String);
 return (NSUInteger)(value?std::max(value,linearAlignment()):0);
}
static BOOL flagArgAnswer(id,SEL cmd,NSUInteger arg) {return askAnswer(cmd,arg)!=0;}
static void installAnswers(Class cls) {
 uint32_t kind=0;
 for(size_t i=0;const char *name=nmb_device_answer_selector(i,&kind);i++) {
  SEL sel=sel_registerName(name);uint64_t value=0;
  switch(kind) {
  case NMB_ANSWER_COUNT: case NMB_ANSWER_FLAG:
   if(!nmb_device_answer(gDevice,name,0,&value)){NBLOG(@"native-metal: no device answer: %@",lastError());continue;}
   // Extended-range 10-bit (XR10) framebuffers are withheld: this display chain presents 8-bit BGRX scanout only. The render server picks its
   // wide-gamut 64-bit (and Apple-compressed) framebuffer when a device offers them, and the display driver could not show it (int-089: the
   // swap's surface was '&w4a', 8 bytes per pixel, and every swap was refused).
   if(!strcmp(name,"supportsExtendedXR10Formats"))value=0;
   // C4: linear and IOSurface texture rows 64-byte aligned (linearAlignment).
   if(value && (!strcmp(name,"deviceLinearTextureAlignmentBytes") || !strcmp(name,"linearTextureAlignmentBytes") ||
      !strcmp(name,"iosurfaceTextureAlignmentBytes")))value=std::max(value,linearAlignment());
   gAnswers[sel]=value;
   class_addMethod(cls,sel,kind==NMB_ANSWER_COUNT?(IMP)countAnswer:(IMP)flagAnswer,kind==NMB_ANSWER_COUNT?"Q16@0:8":"B16@0:8");
   break;
  case NMB_ANSWER_COUNT_ARG:
   class_addMethod(cls,sel,strcmp(name,"minimumLinearTextureAlignmentForPixelFormat:")?(IMP)countArgAnswer:(IMP)linearAlignmentAnswer,"Q24@0:8Q16");
   break;
  case NMB_ANSWER_FLAG_ARG: class_addMethod(cls,sel,(IMP)flagArgAnswer,"B24@0:8Q16");break;
  }
 }
}

extern "C" id native_bridge_metal_open(const char *loader,const char *cache,uint64_t registryID,void (*missing)(const char *,const char *)) {
 if(gDeviceObject)return gDeviceObject;
 gMissing=missing;gInFlight=[NSMutableSet set];
 gDevice=nmb_device_open(loader,cache);
 if(!gDevice){NBLOG(@"native-metal: device refused: %s",nmb_last_error());return nil;}
 if(cache){gJournalPath=std::string(cache)+"/pipelines.log";gJournalBegan=nowUs();}
 prewarmStart(cache);
 nilencInstall();   // G5
 char name[128]={};nmb_device_name(gDevice,name,sizeof name);gName=[NSString stringWithUTF8String:name];gRegistryID=registryID;
 // The target families supportsFamily: answers true, with the rows of Apple's tables the device does not meet in them (nmb_device_family_waivers).
 {char waived[4096]={};nmb_device_family_waivers(gDevice,waived,sizeof waived);
  for(char *line=waived,*next;*line;line=next){next=strchr(line,'\n');if(next)*next++=0;else next=line+strlen(line);journal(std::string("F ")+line);}}
 Class base=objc_getClass("_MTLDevice");
#if !TARGET_OS_IPHONE
 // Host instrument: on NSObject every selector a client sends that this file lacks reaches the missing hook, instead of the host's
 // own _MTLDevice implementation.
 if(getenv("NMB_DEVICE_BASE_NSOBJECT"))base=[NSObject class];
#endif
#if TARGET_OS_IPHONE
 // The dynamic subclass adds no instance variables, so any base size works (iPadOS 17.7.11: 536 bytes).
 if(!base){NBLOG(@"native-metal: no _MTLDevice");return nil;}
 NBLOG(@"native-metal: _MTLDevice is %zu bytes",class_getInstanceSize(base));
#endif
 if(!base)base=[NSObject class];
 Class cls=objc_allocateClassPair(base,"NativeBridgeMetalDevice",0);if(!cls)return nil;
 unsigned count=0;Method *methods=class_copyMethodList([NBDeviceMethods class],&count);
 for(unsigned i=0;i<count;i++)class_addMethod(cls,method_getName(methods[i]),method_getImplementation(methods[i]),method_getTypeEncoding(methods[i]));
 free(methods);installAnswers(cls);class_addProtocol(cls,@protocol(MTLDevice));
 // The original registration (_MTLAddDevice) asserts that a plugin's device conforms to Metal's private device protocol as well; the target's own
 // drivers get it from their IOGPU base class. Conformance only answers conformsToProtocol:, the methods are still looked up one by one.
 if(Protocol *spi=objc_getProtocol("MTLDeviceSPI"))class_addProtocol(cls,spi);
 // SweetMetal2: Metal checks textures against its private implementation protocol too, and NSLogs "texture is not a
 // MTLTextureImplementation." on every miss (~600 lines/s from backboardd while scrolling).
 {Protocol *tp=objc_getProtocol("MTLTextureImplementation");if(tp)class_addProtocol([NBTexture class],tp);
  NBLOG(@"native-metal: MTLTextureImplementation %s",tp?([NBTexture conformsToProtocol:tp]?"adopted":"not adopted"):"missing");}
 // SweetMetal2 (C1): the same for functions ("vertexFunction is not a MTLFunction." / "fragmentFunction is not a MTLFunction.", 450
 // NSLog lines a session from backboardd on r18g, one per function of each pipeline Core Animation made) and for the other objects
 // a descriptor or an encoder hands back to Metal's validation: their public protocols. One line says what was adopted, and whether
 // Metal has the private classes a subclassing fix would need (phase 2: if the messages persist, the check is a class test).
 {
  struct {Class cls;const char *protocol;} adopt[]={{[NBFunction class],"MTLFunction"},{[NBLibrary class],"MTLLibrary"},
   {[NBRenderPipeline class],"MTLRenderPipelineState"},{[NBComputePipeline class],"MTLComputePipelineState"},
   {[NBSampler class],"MTLSamplerState"},{[NBDepthStencil class],"MTLDepthStencilState"}};
  std::string done;
  for(auto &a:adopt) {
   Protocol *p=objc_getProtocol(a.protocol);
   const bool was=p && [a.cls conformsToProtocol:p];
   if(p && !was)class_addProtocol(a.cls,p);
   done+=std::string(" ")+class_getName(a.cls)+(p?([a.cls conformsToProtocol:p]?(was?"=":"+"):"!"):"?")+a.protocol;
  }
  Class mf=objc_getClass("_MTLFunction");
  NBLOG(@"native-metal: protocols (+ adopted, = already, ? no such protocol):%s; Metal's _MTLFunction %s (%zu bytes)",done.c_str(),
        mf?"present":"absent",mf?class_getInstanceSize(mf):(size_t)0);
 }
 objc_registerClassPair(cls);
 gDeviceObject=[cls new];
 return gDeviceObject;
}

// Bare AIR bitcode (no metallib wrapper), which Metal itself refuses: for the bridge's own fixtures only.
extern "C" id native_bridge_metal_library_with_air(const void *bytes,size_t length) {
 NmbLibrary *handle=gDevice?nmb_library_new(gDevice,bytes,length,true):nullptr;if(!handle)return nil;
 NBLibrary *library=[NBLibrary new];library.handle=handle;return library;
}
extern "C" bool native_bridge_metal_shader_cache_stats(NmbShaderCacheStats *out) {
 return gDevice && nmb_device_shader_cache_stats(gDevice,out);
}
extern "C" bool native_bridge_metal_work_stats(uint64_t out[10]) {
 return gDevice && nmb_device_work_stats(gDevice,out);
}

extern "C" size_t native_bridge_metal_status(char *out,size_t size) {
 std::lock_guard<std::mutex> lock(gProblemLock);
 return (size_t)snprintf(out,size,"c%llu/%llu d%llu p%llu x%llu R%llu D%llu F%llu M%llu C%llu B%llu %s | %s",(unsigned long long)gCommits.load(),(unsigned long long)gCommitFailures.load(),(unsigned long long)gCompleted.load(),
  (unsigned long long)gPipelines.load(),(unsigned long long)gProblems.load(),(unsigned long long)gPasses.load(),(unsigned long long)gDraws.load(),(unsigned long long)gFullScreenPasses.load(),(unsigned long long)(gBiggestPass.load()>>10),(unsigned long long)gDispatches.load(),(unsigned long long)gBlits.load(),gLastProblems[0],gLastProblems[1]);
}

static size_t native_bridge_metal_formats_locked(char *out,size_t size) {
 int n=snprintf(out,size,"tex x%llu f",(unsigned long long)gTextureRefusals.load());
 for(unsigned i=0;i<gFormatCount && n>0 && (size_t)n<size;i++)n+=snprintf(out+n,size-(size_t)n,"%u ",gFormats[i]);
 return n>0?(size_t)n:0;
}
// The benchmark's rows (native_bridge_metal_benchmark), kept for the telemetry table.
static std::mutex gBenchLock;
static char gBench[4][96];
static std::atomic<unsigned> gBenchRuns;
extern "C" size_t native_bridge_metal_benchmark(id device,const char *metallib,unsigned pairs,char *out,size_t size) {
 auto now=[]{return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);};
 // the first run fills rows 0-1 (Y, Y1), a later one rows 2-3 (Z, Z1), so a busy and an idle run are both kept
 const unsigned base=gBenchRuns++?2u:0u;
 auto put=[&](unsigned row,const char *format,auto... args){std::lock_guard<std::mutex> lock(gBenchLock);snprintf(gBench[base+row],sizeof gBench[base+row],format,args...);
  if(base)gBench[base+row][0]='Z';};
 // compute: a dependent integer chain (no memory), 100M steps
 uint64_t t=now(),x=0x9e3779b97f4a7c15ull;
 for(uint32_t i=0;i<100000000u;i++){x^=x<<13;x^=x>>7;x^=x<<17;}
 const uint64_t computeUs=(now()-t)/1000;
 // first touch: 32 MiB of fresh anonymous memory (the tablet's free memory is small), one store per 4 KiB page (the kernel's fault and zero-fill), then four memsets of it
 const size_t bytes=32u<<20;
 uint64_t faultUs=0,fillUs=0,shaUs=0;
 void *m=mmap(nullptr,bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
 if(m!=MAP_FAILED) {
  volatile uint8_t *b=(volatile uint8_t *)m;
  t=now();for(size_t at=0;at<bytes;at+=4096)b[at]=1;faultUs=(now()-t)/1000;
  t=now();for(int k=0;k<4;k++)memset(m,k,bytes);fillUs=(now()-t)/1000;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  t=now();CC_SHA256(m,(CC_LONG)(16u<<20),digest);shaUs=(now()-t)/1000;
  x^=digest[0];
  munmap(m,bytes);
 }
 put(0,"Y cpu=%llums(100M) fault=%lluus/32MiB=%lluns/pg fill=%lluMB/s sha=%lluMB/s %llx",(unsigned long long)(computeUs/1000),
  (unsigned long long)faultUs,(unsigned long long)(faultUs*1000/8192),(unsigned long long)(fillUs?4ull*32*1000000/fillUs:0),
  (unsigned long long)(shaUs?16ull*1000000/shaUs:0),(unsigned long long)(x&0xf));
 // pipelines: the host tool's pairs, in its order
 uint64_t made=0,refused=0,createUs=0,createMax=0,drawUs=0,drawMax=0,libraryUs=0;
 @autoreleasepool {
  id<MTLDevice> dev=(id<MTLDevice>)device;NSError *error=nil;
  t=now();
  id<MTLLibrary> qc=metallib?[dev newLibraryWithURL:[NSURL fileURLWithPath:@(metallib)] error:&error]:nil;
  libraryUs=(now()-t)/1000;
  if(qc) {
   NSArray<NSString *> *names=qc.functionNames;
   id<MTLCommandQueue> queue=[dev newCommandQueue];
   MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
   td.usage=MTLTextureUsageRenderTarget;
   id<MTLTexture> target=[dev newTextureWithDescriptor:td];
   id<MTLBuffer> zeros=[dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
   unsigned n=0;
   for(NSString *name in names) {
    if(n>=pairs)break;
    id<MTLFunction> f=[qc newFunctionWithName:name];
    if(f.functionType!=MTLFunctionTypeVertex)continue;
    NSString *fragmentName=[name stringByReplacingOccurrencesOfString:@"_vert_" withString:@"_frag_"];
    if([fragmentName isEqualToString:name] || ![names containsObject:fragmentName])continue;
    ++n;
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=f;d.fragmentFunction=[qc newFunctionWithName:fragmentName];
    d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    t=now();
    id<MTLRenderPipelineState> state=[dev newRenderPipelineStateWithDescriptor:d error:&error];
    const uint64_t took=(now()-t)/1000;
    if(!state){++refused;continue;}
    ++made;createUs+=took;createMax=std::max(createMax,took);
    t=now();
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandBuffer> commands=[queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:state];
    for(NSUInteger i=0;i<8;++i){[encoder setVertexBuffer:zeros offset:0 atIndex:i];[encoder setFragmentBuffer:zeros offset:0 atIndex:i];}
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];[commands commit];[commands waitUntilCompleted];
    const uint64_t drew=(now()-t)/1000;
    drawUs+=drew;drawMax=std::max(drawMax,drew);
   }
  }
 }
 put(1,"Y1 qc lib=%llums made=%llu refused=%llu create=%llums max=%llums draw=%llums max=%llums",(unsigned long long)(libraryUs/1000),
  (unsigned long long)made,(unsigned long long)refused,(unsigned long long)(createUs/1000),(unsigned long long)(createMax/1000),
  (unsigned long long)(drawUs/1000),(unsigned long long)(drawMax/1000));
 size_t at=0;
 if(out && size) {
  std::lock_guard<std::mutex> lock(gBenchLock);
  out[0]=0;for(unsigned r=base;r<base+2;r++)at+=(size_t)snprintf(out+at,size>at?size-at:0,"%s\n",gBench[r]);
 }
 return at;
}
// WS-U (bridge patch 0104): the runtime's shadow copies (a texture whose rows Turnip refused as a linear layout is an image of its
// own the encoders copy into and back; rows not 64-byte multiples now go through the rotation kernel, one blit instead of one per
// row on the A6xx; SWEET_SHADOW_REPACK=0 restores the old copies). Every 5 s, from a commit, backboardd logs the 5 s deltas:
// "J copies: N done (B bytes) N skipped, refusals N, repacked N".
static void noteShadowCopies() {
 static const bool on=!strcmp(getprogname(),"backboardd");
 if(!on)return;
 static std::atomic<uint64_t> nextUs{0};
 const uint64_t t=nowUs();uint64_t due=nextUs.load();
 if(t<due || !nextUs.compare_exchange_strong(due,t+5000000))return;
 uint64_t c[5]={};
 if(!nmb_sweet_shadow_counts(c))return;
 static uint64_t last[5]={};
 if(due)sm2_logs([NSString stringWithFormat:@"native-metal: J copies: %llu done (%llu bytes) %llu skipped, refusals %llu, repacked %llu",
     (unsigned long long)(c[0]-last[0]),(unsigned long long)(c[1]-last[1]),(unsigned long long)(c[3]-last[3]),(unsigned long long)(c[4]-last[4]),
     (unsigned long long)(c[2]-last[2])].UTF8String);
 memcpy(last,c,sizeof last);
}
// u-t: the frame timeline's 5 s line (see TLRecord). Medians and 95th percentiles in ms over the frames (CA's framebuffer command
// buffers) completed in the window:
//   frames N (every p50/p95: commit to commit) | encode (first encoder to commit) | commit->submit (to the scheduler's first
//   vkQueueSubmit) | submit->gpu-start | gpu (the frame command buffer's GPU start to end) | gpu-done->cpu-notice (GPU end to the
//   runtime's completion callback; +h: on to its completed handlers) | gpu idle before a frame (since the GPU last ended any work)
//   and GPU busy % of the window | notice->next (a frame's notice to the next frame's first encoder: about 0 where CA waits for
//   completion) | cb per frame (aux: other command buffers by content, their GPU p50) | CA's waits (waitUntilCompleted and
//   waitUntilScheduled: count, ms) | top passes (Turnip: WxH format load/store gmem|sysmem avg ms x count) and Turnip's submit waits.
// T2: the runtime's submissions in the window (vkQueueSubmit calls, VkCommandBuffers, commits handed off to another thread's pass,
// internal and staging submissions, queue drains, timeline waits, re-encodes, shadow copies).
static void timelineReport(std::vector<TLRecord> records,uint64_t spanNs) {
 auto pct=[](std::vector<int64_t> v,double q)->double{
  if(v.empty())return -1;std::sort(v.begin(),v.end());size_t i=(size_t)(q*(v.size()-1)+0.5);return v[std::min(i,v.size()-1)]/1e6;};
 std::sort(records.begin(),records.end(),[](const TLRecord &a,const TLRecord &b){return a.commit<b.commit;});
 std::vector<int64_t> every,encode,c2s,s2g,gpu,notice,handler,idle,next,auxGpu;
 unsigned frames=0,aux=0,auxPasses=0,auxBlits=0,auxCompute=0,auxEmpty=0,timed=0;
 // the GPU's busy time and the idle before each frame: work in GPU start order
 std::vector<const TLRecord *> byStart;
 for(const TLRecord &r:records)if(r.gStart && r.gEnd>=r.gStart){byStart.push_back(&r);timed++;}
 std::sort(byStart.begin(),byStart.end(),[](const TLRecord *a,const TLRecord *b){return a->gStart<b->gStart;});
 uint64_t busy=0,coveredTo=0,lastEnd=0;
 for(const TLRecord *r:byStart) {
  if(r->frame && lastEnd)idle.push_back(r->gStart>lastEnd?(int64_t)(r->gStart-lastEnd):0);
  const uint64_t from=std::max(r->gStart,coveredTo);if(r->gEnd>from)busy+=r->gEnd-from;
  coveredTo=std::max(coveredTo,r->gEnd);lastEnd=std::max(lastEnd,r->gEnd);
 }
 const TLRecord *previous=nullptr;
 // hitches: the worst 3 frame intervals (commit to commit), split along the earlier frame's life and the gap after it:
 //   prev frame: sub (commit->kernel end: the submission, Turnip's CPU waits included) | q (->GPU start: queued behind earlier
 //   GPU work) | gpu | ntc (GPU end->completion callback) ; gap (its notice->this frame's first encoder: outside Metal: CA
 //   waiting for vsync/swap/its own throttle) ; enc (this frame's first encoder->commit)
 struct Hitch {int64_t every,sub,q,gpu,ntc,gap,enc;};
 std::vector<Hitch> hitches;
 std::vector<uint32_t> surfaces;
 for(const TLRecord &r:records) {
  if(!r.frame) {
   aux++;
   if(r.work.passes)auxPasses++;else if(r.work.blits)auxBlits++;else if(r.work.dispatches)auxCompute++;else auxEmpty++;
   if(r.gStart && r.gEnd>=r.gStart)auxGpu.push_back((int64_t)(r.gEnd-r.gStart));
   continue;
  }
  frames++;
  if(r.surface && std::find(surfaces.begin(),surfaces.end(),r.surface)==surfaces.end())surfaces.push_back(r.surface);
  if(previous) {
   const TLRecord &p=*previous;
   auto d=[](uint64_t a,uint64_t b)->int64_t{return a && b?(int64_t)b-(int64_t)a:-1;};
   hitches.push_back({(int64_t)(r.commit-p.commit),d(p.commit,p.kEnd),d(p.kEnd,p.gStart),d(p.gStart,p.gEnd),d(p.gEnd,p.notice),
    d(p.notice,r.created),d(r.created,r.commit)});
   every.push_back((int64_t)(r.commit-previous->commit));
   if(previous->notice)next.push_back((int64_t)r.created-(int64_t)previous->notice);
  }
  previous=&r;
  encode.push_back((int64_t)r.commit-(int64_t)r.created);
  if(r.kStart)c2s.push_back((int64_t)r.kStart-(int64_t)r.commit);
  if(r.gStart && r.gEnd>=r.gStart) {
   if(r.kStart)s2g.push_back((int64_t)r.gStart-(int64_t)r.kStart);
   gpu.push_back((int64_t)(r.gEnd-r.gStart));
   notice.push_back((int64_t)r.notice-(int64_t)r.gEnd);
  }
  handler.push_back((int64_t)r.handler-(int64_t)r.notice);
 }
 // CA's own waits in the window (the J rows' totals, as deltas)
 static uint64_t lastWaits[4];
 const uint64_t waits[4]={gTimeWaitCompleted.count.load(),gTimeWaitCompleted.total.load(),gTimeWaitScheduled.count.load(),gTimeWaitScheduled.total.load()};
 char passes[680]="n/a (Turnip has no sweet_tu_pass_report)";   // u-gpudraw: 420 before (the SEQ census)
 if(native_bridge_metal_pass_report)native_bridge_metal_pass_report(passes,sizeof passes,3);
 char line[1700];
 snprintf(line,sizeof line,"native-metal: T 5s: frames %u (every %.1f/%.1f) | encode %.1f/%.1f ms | commit->submit %.2f | submit->gpu-start %.2f"
  " | gpu %.1f/%.1f ms | gpu-done->cpu-notice %.2f/%.2f ms (+h %.2f) | gpu idle %.1f, busy %.0f%% | notice->next %.1f"
  " | cb per frame %.2f (aux %u: rp %u bl %u cs %u e %u, gpu %.1f) | waits cpl %llu/%llums sch %llu/%llums | %s",
  frames,pct(every,.5),pct(every,.95),pct(encode,.5),pct(encode,.95),pct(c2s,.5),pct(s2g,.5),pct(gpu,.5),pct(gpu,.95),
  pct(notice,.5),pct(notice,.95),pct(handler,.5),pct(idle,.5),spanNs?100.0*busy/spanNs:0,pct(next,.5),
  frames?(double)records.size()/frames:0,aux,auxPasses,auxBlits,auxCompute,auxEmpty,pct(auxGpu,.5),
  (unsigned long long)(waits[0]-lastWaits[0]),(unsigned long long)((waits[1]-lastWaits[1])/1000),
  (unsigned long long)(waits[2]-lastWaits[2]),(unsigned long long)((waits[3]-lastWaits[3])/1000),passes);
 memcpy(lastWaits,waits,sizeof lastWaits);
 sm2_logs(line);
 if(native_bridge_metal_cpu_report) {
  char cpu[1100];
  if(native_bridge_metal_cpu_report(cpu,sizeof cpu)) {
   snprintf(line,sizeof line,"native-metal: T tu-cpu: %s",cpu);
   sm2_logs(line);
  }
 }
 fnReport();
 if(native_bridge_metal_draw_report) {   // u-gpudraw: Turnip 0112's draw census (fragment shaders, draw times)
  char draw[1600];
  if(native_bridge_metal_draw_report(draw,sizeof draw)) {
   snprintf(line,sizeof line,"native-metal: T tu-draw: %s",draw);
   sm2_logs(line);
  }
 }
 if(native_bridge_metal_perf_report) {   // u-perfctr: Turnip 0113's hardware counters (SWEET_TU_PERFCTR), after tu-draw
  static char perf[1300];
  for(unsigned part=0;part<3;part++) {
   if(!native_bridge_metal_perf_report(perf,sizeof perf,part))continue;
   char pline[1400];
   snprintf(pline,sizeof pline,"native-metal: T tu-perf 5s%s: %s",part?" fs":"",perf);
   sm2_logs(pline);
  }
 }
 if(native_bridge_metal_ubwc_report) {
  char ubwc[1100];
  if(native_bridge_metal_ubwc_report(ubwc,sizeof ubwc)) {
   snprintf(line,sizeof line,"native-metal: T tu-ubwc: %s",ubwc);
   sm2_logs(line);
  }
 }
 {  // u-cpu: SWEET_CPUFAST's savings in the window
  static uint64_t lastCf[6];
  const uint64_t cf[6]={gCfAnswerHits.load(),gCfAnswerAsks.load(),gCfViewportSkips.load(),gCfViewportSent.load(),gCfScissorSkips.load(),
   gCfScissorSent.load()};
  uint64_t d[6];for(int i=0;i<6;i++)d[i]=cf[i]-lastCf[i];
  memcpy(lastCf,cf,sizeof lastCf);
  {   // g9: SWEET_DEADFILL in the window
   static uint64_t lastDf[4];const uint64_t df[4]={gDfDeferred.load(),gDfDropped.load(),gDfCleared.load(),gDfPx.load()};
   if(deadfillMode() || memcmp(df,lastDf,sizeof df)) {
    char dl[200];snprintf(dl,sizeof dl,"native-metal: DF 5s: deferred %llu dropped %llu cleared %llu px_saved %llu (mode %d)",(unsigned long long)(df[0]-lastDf[0]),
     (unsigned long long)(df[1]-lastDf[1]),(unsigned long long)(df[2]-lastDf[2]),(unsigned long long)(df[3]-lastDf[3]),deadfillMode());
    sm2_logs(dl);
   }
   memcpy(lastDf,df,sizeof df);
  }
  snprintf(line,sizeof line,"native-metal: T cpufast 5s: bits 0x%x | answers memo %llu asked %llu | viewport skipped %llu sent %llu | scissor skipped %llu sent %llu",
   cpuFast(),(unsigned long long)d[0],(unsigned long long)d[1],(unsigned long long)d[2],(unsigned long long)d[3],(unsigned long long)d[4],
   (unsigned long long)d[5]);
  sm2_logs(line);
 }
 if(encThreadOn()) {   // u-encthread: what was recorded, replayed, and what the callers still waited for, in the window
  enum {K_DRAW,K_BIND,K_ENC,K_BLIT,K_CB,K_N};
  static uint64_t lastOps[EO_COUNT],lastRec,lastRep,lastBatches,lastWakes,lastCommits,lastCalls[EF_WHY_COUNT],lastWaits[EF_WHY_COUNT],
   lastTicks[EF_WHY_COUNT],lastOnWorker;
  uint64_t kind[K_N]={},all=0;
  for(int o=0;o<EO_COUNT;o++) {
   const uint64_t now=gEtOps[o].load(),d=now-lastOps[o];lastOps[o]=now;all+=d;
   const int k=o==EO_DRAW || o==EO_DRAW_INDEXED?K_DRAW:o<=EO_DISCARD?K_ENC:o>=EO_COPY_BUFFER && o<=EO_MIPMAPS?K_BLIT:o>=EO_EVENT?K_CB:K_BIND;
   kind[k]+=d;
  }
  const double tick=encTickNs()/1e6;
  const uint64_t rec=gEtRecordTicks.load(),rep=gEtReplayTicks.load(),batches=gEtBatches.load(),wakes=gEtWakes.load(),commits=gEtCommits.load();
  const double recMs=(rec-lastRec)*tick,repMs=(rep-lastRep)*tick;
  const uint64_t dCommits=commits-lastCommits;
  double flushMs=0;
  char flushes[600]="";size_t at=0;
  for(int w=0;w<EF_WHY_COUNT;w++) {
   const uint64_t calls=gEtFlushCalls[w].load(),waits=gEtFlushWaits[w].load(),ticks=gEtFlushTicks[w].load();
   const uint64_t dc=calls-lastCalls[w],dw=waits-lastWaits[w];const double ms=(ticks-lastTicks[w])*tick;
   lastCalls[w]=calls;lastWaits[w]=waits;lastTicks[w]=ticks;flushMs+=ms;
   if(dc && at<sizeof flushes)at+=(size_t)snprintf(flushes+at,sizeof flushes-at," %s %llu/%llu %.1fms",kEncFlushName[w],(unsigned long long)dw,
    (unsigned long long)dc,ms);
  }
  const uint64_t onWorker=gEtFlushOnWorker.load();
  snprintf(line,sizeof line,"native-metal: T enc-thread 5s: cmds %llu (draw %llu bind %llu enc %llu blit %llu cb %llu) commits %llu | caller record %.1f ms"
   " (%.2f us/cmd) | worker replay %.1f ms (%.1f us/cmd, %llu batches, max %llu) | caller saved ~%.1f ms (%.2f ms/commit), flush waits %.1f ms"
   " (net %.2f ms/commit) | depth max %llu, now %llu | wakes %llu | flushes waited/calls:%s%s | on-worker %llu stalls %llu",
   (unsigned long long)all,(unsigned long long)kind[K_DRAW],(unsigned long long)kind[K_BIND],(unsigned long long)kind[K_ENC],(unsigned long long)kind[K_BLIT],
   (unsigned long long)kind[K_CB],(unsigned long long)dCommits,recMs,all?recMs*1e3/all:0,repMs,all?repMs*1e3/all:0,
   (unsigned long long)(batches-lastBatches),(unsigned long long)gEtBatchMax.exchange(0),repMs-recMs,dCommits?(repMs-recMs)/dCommits:0,flushMs,
   dCommits?(repMs-recMs-flushMs)/dCommits:0,(unsigned long long)gEtDepthMax.exchange(0),(unsigned long long)(gEqAppended.load()-gEqReplayed.load()),
   (unsigned long long)(wakes-lastWakes),at?flushes:" none",gEqBroken?" | WORKER NOT STARTED (inline)":"",(unsigned long long)(onWorker-lastOnWorker),
   (unsigned long long)gEtStalls.load());
  const uint64_t dWakes=wakes-lastWakes;   // g4
  lastRec=rec;lastRep=rep;lastBatches=batches;lastWakes=wakes;lastCommits=commits;lastOnWorker=onWorker;
  sm2_logs(line);
  {   // g4: the submit's lag and the batches (both modes)
   std::vector<int64_t> lat[4];
   {std::lock_guard<std::mutex> l(gEtLatLock);for(int i=0;i<4;i++)lat[i].swap(gEtLat[i]);}
   static uint64_t lastBig,lastCmds,lastB2;
   const uint64_t big=gEtBatchBig.load(),cmds=gEtBatchCmds.load(),db=batches-lastB2;
   const double secs=spanNs?spanNs/1e9:5;
   snprintf(line,sizeof line,"native-metal: T enc-lat 5s: mode %d | commit->submit p50/p95 %.2f/%.2f ms | wake->submit %.2f/%.2f | submit call"
    " %.2f/%.2f | frame 1st-enc->submit %.2f/%.2f (n %zu/%zu) | batches %.0f/s, %.1f cmds/batch, big-core %.0f%% | wakes %.0f/s",
    encThreadMode(),pct(lat[0],.5),pct(lat[0],.95),pct(lat[1],.5),pct(lat[1],.95),pct(lat[2],.5),pct(lat[2],.95),pct(lat[3],.5),pct(lat[3],.95),
    lat[0].size(),lat[3].size(),db/secs,db?(double)(cmds-lastCmds)/db:0,db?100.0*(big-lastBig)/db:0,dWakes/secs);
   lastBig=big;lastCmds=cmds;lastB2=batches;
   sm2_logs(line);
  }
 }
 std::sort(hitches.begin(),hitches.end(),[](const Hitch &a,const Hitch &b){return a.every>b.every;});
 {
  size_t at=(size_t)snprintf(line,sizeof line,"native-metal: T worst 5s: fb surfaces %zu |",surfaces.size());
  auto ms=[](int64_t ns){return ns<0?-1.0:ns/1e6;};
  for(size_t i=0;i<3 && i<hitches.size() && at<sizeof line;i++) {
   const Hitch &h=hitches[i];
   at+=(size_t)snprintf(line+at,sizeof line-at," %.1fms = prev[sub %.1f q %.1f gpu %.1f ntc %.1f] gap %.1f enc %.1f;",
    ms(h.every),ms(h.sub),ms(h.q),ms(h.gpu),ms(h.ntc),ms(h.gap),ms(h.enc));
  }
  if(!hitches.empty())sm2_logs(line);
 }
 // u-e: T3 (per-frame encode split), T4 (top call sites), T slow frame (frames whose encode passed 50 ms)
 if(encStatOn()) {
  gEncSlowLogged.store(0);
  std::vector<int64_t> cat[EC_COUNT],enc,inMetal,outside,cpuT,scopes,mhzBig,mhzLittle,draws,passes;
  double catTotal[EC_COUNT]={},callTotal[EC_COUNT]={};
  unsigned valid=0,cpuHist[9]={},vkFrames=0,migrated=0;double vkMs=0;uint64_t vkN=0;
  struct Slow {double enc;const TLRecord *r;};std::vector<Slow> slow;
  for(const TLRecord &r:records) {
   if(!r.frame || !r.enc.valid)continue;
   valid++;
   const double e=(r.commit-r.created)/1e6;double in=0;
   draws.push_back((int64_t)r.work.draws*1000000);passes.push_back((int64_t)(r.work.passes+r.work.blits+r.work.dispatches)*1000000);
   for(int c=0;c<EC_COUNT;c++){cat[c].push_back((int64_t)(r.enc.ms[c]*1e6));in+=r.enc.ms[c];
    catTotal[c]+=r.enc.ms[c];callTotal[c]+=r.enc.n[c];}
   enc.push_back((int64_t)(e*1e6));inMetal.push_back((int64_t)(in*1e6));outside.push_back((int64_t)((e-in)*1e6));
   cpuT.push_back((int64_t)(r.enc.cpuMs*1e6));scopes.push_back((int64_t)r.enc.scopes*1000000);
   cpuHist[r.enc.cpu1>=0 && r.enc.cpu1<8?r.enc.cpu1:8]++;
   if(r.enc.cpu0!=r.enc.cpu1)migrated++;
   (r.enc.cpu1>=6?mhzBig:mhzLittle).push_back((int64_t)(r.enc.mhz*1e6));
   if(r.enc.vkN){vkFrames++;vkN+=r.enc.vkN;vkMs+=r.enc.vkMs;}
   if(e>50)slow.push_back({e,&r});
  }
  if(valid) {
   auto pct=[](std::vector<int64_t> v,double q)->double{
    if(v.empty())return -1;std::sort(v.begin(),v.end());size_t i=(size_t)(q*(v.size()-1)+0.5);return v[std::min(i,v.size()-1)]/1e6;};
   char line[1400];
   size_t at=(size_t)snprintf(line,sizeof line,"native-metal: T3 5s: frames %u | encode %.1f/%.1f = in-metal %.1f/%.1f + unaccounted %.1f/%.1f ms"
    " | thread cpu %.1f/%.1f ms | draws %.0f/%.0f encoders %.0f/%.0f | cpu",valid,pct(enc,.5),pct(enc,.95),pct(inMetal,.5),pct(inMetal,.95),
    pct(outside,.5),pct(outside,.95),pct(cpuT,.5),pct(cpuT,.95),pct(draws,.5),pct(draws,.95),pct(passes,.5),pct(passes,.95));
   for(int c=0;c<9;c++)if(cpuHist[c]){if(c<8)at+=(size_t)snprintf(line+at,sizeof line-at," %d:%u",c,cpuHist[c]);else at+=(size_t)snprintf(line+at,sizeof line-at," ?:%u",cpuHist[c]);}
   at+=(size_t)snprintf(line+at,sizeof line-at," (moved %u) MHz-eq big %.0f little %.0f | per frame p50/p95 ms, calls, us/call:",migrated,
    std::max(0.0,pct(mhzBig,.5)),std::max(0.0,pct(mhzLittle,.5)));
   for(int c=0;c<EC_COUNT && at<sizeof line;c++) {
    if(callTotal[c]==0)continue;
    at+=(size_t)snprintf(line+at,sizeof line-at," %s %.2f/%.2f %.0f %.0f;",kEncCatName[c],pct(cat[c],.5),pct(cat[c],.95),callTotal[c]/valid,
     1000.0*catTotal[c]/callTotal[c]);
   }
   if(at<sizeof line)at+=(size_t)snprintf(line+at,sizeof line-at," | VkPipelines %llu in %u frames %.1f ms | scopes %.0f/frame ~%.2f ms",
    (unsigned long long)vkN,vkFrames,vkMs,pct(scopes,.5),pct(scopes,.5)*encScopeNs()/1e6);
   NmbShaderCacheStats cs={};
   static NmbShaderCacheStats lastCs;static bool haveCs;
   if(at<sizeof line && gDevice && nmb_device_shader_cache_stats(gDevice,&cs)) {
    if(haveCs)at+=(size_t)snprintf(line+at,sizeof line-at," | cache 5s: spirv hit %llu miss %llu wr %llu (fail %llu) drv hit %llu miss %llu save %llu"
     " load %llu same %llu rej %llu mism %llu trunc %llu rdfail %llu evict %llu",
     (unsigned long long)(cs.hits-lastCs.hits),(unsigned long long)(cs.misses-lastCs.misses),(unsigned long long)(cs.writes-lastCs.writes),
     (unsigned long long)(cs.write_failures-lastCs.write_failures),(unsigned long long)(cs.driver_hits-lastCs.driver_hits),
     (unsigned long long)(cs.driver_misses-lastCs.driver_misses),(unsigned long long)(cs.driver_saves-lastCs.driver_saves),
     (unsigned long long)(cs.driver_loads-lastCs.driver_loads),(unsigned long long)(cs.driver_unchanged-lastCs.driver_unchanged),
     (unsigned long long)(cs.rejected-lastCs.rejected),(unsigned long long)(cs.driver_mismatched-lastCs.driver_mismatched),
     (unsigned long long)(cs.driver_truncated-lastCs.driver_truncated),(unsigned long long)(cs.read_failures-lastCs.read_failures),
     (unsigned long long)(cs.evictions-lastCs.evictions));
    lastCs=cs;haveCs=true;
   }
   sm2_logs(line);
   std::sort(slow.begin(),slow.end(),[](const Slow &a,const Slow &b){return a.enc>b.enc;});
   for(size_t i=0;i<slow.size() && i<3;i++) {
    const TLRecord &r=*slow[i].r;
    at=(size_t)snprintf(line,sizeof line,"native-metal: T slow frame: encode %.1f ms, thread cpu %.1f, cpu %d->%d MHz-eq %.0f, draws %u, VkPipelines %u in %.1f ms |",
     slow[i].enc,r.enc.cpuMs,r.enc.cpu0,r.enc.cpu1,r.enc.mhz,r.work.draws,r.enc.vkN,r.enc.vkMs);
    double in=0;
    for(int c=0;c<EC_COUNT && at<sizeof line;c++){in+=r.enc.ms[c];if(r.enc.n[c])at+=(size_t)snprintf(line+at,sizeof line-at," %s %.1f/%u",kEncCatName[c],r.enc.ms[c],r.enc.n[c]);}
    if(at<sizeof line)snprintf(line+at,sizeof line-at," | unaccounted %.1f",slow[i].enc-in);
    sm2_logs(line);
   }
  }
  // T4: the call sites with most time in the window (all threads)
  struct SiteDelta {const EncSite *s;uint64_t n,ticks,max;};
  static uint64_t lastN[kEncSites],lastTicks[kEncSites];
  std::vector<SiteDelta> sites;
  const unsigned count=std::min<unsigned>(gEncSiteCount.load(),kEncSites);
  for(unsigned i=0;i<count;i++) {
   EncSite *s=gEncSites[i].load();if(!s)continue;
   const uint64_t n=s->n.load(),t=s->ticks.load(),m=s->max.exchange(0);
   if(n>lastN[i])sites.push_back({s,n-lastN[i],t-lastTicks[i],m});
   lastN[i]=n;lastTicks[i]=t;
  }
  std::sort(sites.begin(),sites.end(),[](const SiteDelta &a,const SiteDelta &b){return a.ticks>b.ticks;});
  if(!sites.empty()) {
   char line[1400];
   const double tick=encTickNs();
   size_t at=(size_t)snprintf(line,sizeof line,"native-metal: T4 top 5s (ms total, calls, us mean, ms max):");
   for(size_t i=0;i<sites.size() && i<10 && at<sizeof line;i++)
    at+=(size_t)snprintf(line+at,sizeof line-at," %s/%s %.1f %llu %.1f %.1f;",kEncCatName[sites[i].s->cat],sites[i].s->name,sites[i].ticks*tick/1e6,
     (unsigned long long)sites[i].n,sites[i].ticks*tick/1e3/sites[i].n,sites[i].max*tick/1e6);
   sm2_logs(line);
  }
 }
 // u-c (r34): T5, the runtime's render encoder steps (bridge patch 0106; /var/local/mtl2-env SWEET_DRAWSTAT=1, off by default):
 // per step of a draw (DRAW = whole draws), of a render endEncoding (END) and renderCommandEncoder (OPEN) in the window: ms total,
 // count, us mean; then counts (#rp render passes made, #fb framebuffers, #set sets allocated, #set-reused sets 0 reused, #held state
 // copies kept for re-recording, #writes descriptor writes).
 if(nmb_sweet_drawstat_on()) {
  enum {kSteps=64};
  static uint64_t lastStep[2*kSteps];static bool haveSteps;
  uint64_t step[2*kSteps]={};
  const size_t steps=nmb_sweet_drawstat(step,kSteps);
  if(haveSteps && steps) {
   char out[1400];size_t at=0;int part=0;
   auto flush=[&]{if(at)sm2_logs(out);at=0;};
   for(size_t i=0;i<steps;i++) {
    const char *name=nmb_sweet_drawstat_name(i);if(!name)break;
    const uint64_t ns=step[2*i]-lastStep[2*i],n=step[2*i+1]-lastStep[2*i+1];
    const int want=name[0]=='#'?2:!strncmp(name,"e.",2) || !strcmp(name,"END") || !strcmp(name,"OPEN")?1:0;
    if(want!=part){flush();part=want;}
    if(!at)at=(size_t)snprintf(out,sizeof out,"native-metal: T5 %s 5s:",part==0?"draw steps (ms, n, us)":part==1?"end/open steps (ms, n, us)":"counts");
    if(!n || at>=sizeof out-64)continue;
    if(part==2)at+=(size_t)snprintf(out+at,sizeof out-at," %s %llu;",name,(unsigned long long)n);
    else at+=(size_t)snprintf(out+at,sizeof out-at," %s %.1f %llu %.1f;",name,ns/1e6,(unsigned long long)n,ns/1e3/n);
   }
   flush();
  }
  memcpy(lastStep,step,sizeof lastStep);haveSteps=true;
 }
 // T2: the runtime's submissions (deltas of its WorkCounts)
 static uint64_t lastSched[9];static bool haveSched;
 uint64_t sched[9]={};
 if(gDevice && nmb_device_sched_counts(gDevice,sched)) {
  uint64_t d[9];for(int i=0;i<9;i++)d[i]=sched[i]-lastSched[i];
  if(haveSched) {
   snprintf(line,sizeof line,"native-metal: T2 5s: cbs %zu (gpu-timed %u) | vkQueueSubmit %llu (VkCommandBuffers %llu) handed-off %llu internal %llu"
    " staging %llu queue-drains %llu timeline-waits %llu reencoded %llu shadow-copies %llu",
    records.size(),timed,(unsigned long long)d[0],(unsigned long long)d[1],(unsigned long long)d[2],(unsigned long long)d[3],
    (unsigned long long)d[4],(unsigned long long)d[5],(unsigned long long)d[6],(unsigned long long)d[7],(unsigned long long)d[8]);
   sm2_logs(line);
  }
  memcpy(lastSched,sched,sizeof lastSched);haveSched=true;
 }
}
// The telemetry table the plugin streams to the kernel's log: newline-separated rows of at most 90 characters.
extern "C" size_t native_bridge_metal_telemetry(char *out,size_t size) {
 size_t at=0;out[0]=0;
 auto row=[&](const char *format,auto... args){
  char text[200];int n=snprintf(text,sizeof text,format,args...);if(n<=0)return;if(n>90)n=90;
  if(at+(size_t)n+2>=size)return;memcpy(out+at,text,(size_t)n);at+=(size_t)n;out[at++]='\n';out[at]=0;};
 auto ms=[](uint64_t us){return (unsigned long long)(us/1000);};
 {std::lock_guard<std::mutex> lock(gBenchLock);for(unsigned r=0;r<4;r++)if(gBench[r][0])row("%.90s",gBench[r]);}
 row("S c%llu/%llu d%llu p%llu x%llu R%llu D%llu F%llu M%lluk C%llu B%llu",(unsigned long long)gCommits.load(),(unsigned long long)gCommitFailures.load(),
  (unsigned long long)gCompleted.load(),(unsigned long long)gPipelines.load(),(unsigned long long)gProblems.load(),(unsigned long long)gPasses.load(),
  (unsigned long long)gDraws.load(),(unsigned long long)gFullScreenPasses.load(),(unsigned long long)(gBiggestPass.load()>>10),
  (unsigned long long)gDispatches.load(),(unsigned long long)gBlits.load());
 row("T pipeline n=%llu total=%llums max=%llums",(unsigned long long)gTimePipeline.count.load(),ms(gTimePipeline.total.load()),ms(gTimePipeline.slowest.load()));
 row("T library n=%llu total=%llums max=%llums",(unsigned long long)gTimeLibrary.count.load(),ms(gTimeLibrary.total.load()),ms(gTimeLibrary.slowest.load()));
 row("T function n=%llu total=%llums max=%llums",
  (unsigned long long)gTimeFunction.count.load(),ms(gTimeFunction.total.load()),ms(gTimeFunction.slowest.load()));
 row("G commit-to-complete n=%llu total=%llums max=%llums mean=%lluus",(unsigned long long)gTimeEncodeToCommit.count.load(),ms(gTimeEncodeToCommit.total.load()),
  ms(gTimeEncodeToCommit.slowest.load()),(unsigned long long)(gTimeEncodeToCommit.count.load()?gTimeEncodeToCommit.total.load()/gTimeEncodeToCommit.count.load():0));
 row("J scheduled wait n=%llu total=%llums max=%llums",(unsigned long long)gTimeWaitScheduled.count.load(),ms(gTimeWaitScheduled.total.load()),ms(gTimeWaitScheduled.slowest.load()));
 row("J completed wait n=%llu total=%llums max=%llums",(unsigned long long)gTimeWaitCompleted.count.load(),ms(gTimeWaitCompleted.total.load()),ms(gTimeWaitCompleted.slowest.load()));
 row("J resource wait n=%llu total=%llums max=%llums",(unsigned long long)gTimeResourceWait.count.load(),ms(gTimeResourceWait.total.load()),ms(gTimeResourceWait.slowest.load()));
 row("J resource checks=%llu skipped=%llu",(unsigned long long)gResourceChecks.load(),(unsigned long long)gResourceSkipped.load());
 row("J surface cache n=%llu bytes=%llu dup=%llu us=%llu max=%llu",(unsigned long long)gTimeSurfaceFlush.count.load(),
  (unsigned long long)gSurfaceFlushBytes.load(),(unsigned long long)gSurfaceFlushDuplicates.load(),
  (unsigned long long)gTimeSurfaceFlush.total.load(),(unsigned long long)gTimeSurfaceFlush.slowest.load());
 row("J surface cleans skipped (seed)=%llu invalidates=%llu%s",(unsigned long long)gSurfaceCleanSkips.load(),
  (unsigned long long)gSurfaceInvalidates.load(),flushAll()?" (SWEET_FLUSH=all)":"");
 row("J ycbcr %s fills=%llu skips=%llu",ycbcrOnGPU()?"gpu":"cpu",(unsigned long long)gYCbCrFills.load(),(unsigned long long)gYCbCrSkips.load());
 {uint64_t c[5]={};if(nmb_sweet_shadow_counts(c))row("J copies: %llu done (%llu bytes) %llu skipped, refusals %llu, repacked %llu",(unsigned long long)c[0],
   (unsigned long long)c[1],(unsigned long long)c[3],(unsigned long long)c[4],(unsigned long long)c[2]);}
 // The runtime's VkPipeline makings (the creation log, METAL2VULKAN_LOG_PIPELINES; they happen at draws, not at the state's creation) and
 // its shader cache: where the driver's compile time goes.
 uint64_t work[10]={};
 if(gDevice && nmb_device_work_stats(gDevice,work)) {
  row("V vkpipe n=%llu total=%llums max=%llums waited=%llums failed=%llu",
   (unsigned long long)work[0],ms(work[1]),ms(work[2]),ms(work[3]),(unsigned long long)work[4]);
  row("V cache hit%llu miss%llu wr%llu | msg i%llu w%llu",(unsigned long long)work[7],(unsigned long long)work[8],(unsigned long long)work[9],(unsigned long long)work[5],
   (unsigned long long)work[6]);
  char warning[200];size_t n=nmb_last_warning(warning,sizeof warning);
  if(n){row("W %.86s",warning);if(n>86)row("Wb %.86s",warning+86);}
 }
 {
  std::lock_guard<std::mutex> lock(gProblemLock);
  char formats[160];native_bridge_metal_formats_locked(formats,sizeof formats);row("F %.86s",formats);
  row("P0 %.86s",gLastProblems[0]);row("P0b %.86s",strlen(gLastProblems[0])>86?gLastProblems[0]+86:"");
  row("P1 %.86s",gLastProblems[1]);row("P1b %.86s",strlen(gLastProblems[1])>86?gLastProblems[1]+86:"");
 }
 {
  std::lock_guard<std::mutex> lock(gCommitLock);
  const uint32_t newest=(uint32_t)gCommits.load();
  row("%s","Q timing v2: per-buffer API counts; ctc=commit-to-callback; age includes caller idle");
  for(uint32_t k=0;k<20 && k<newest;k++) {
   const CommitRecord &r=gCommitRing[(newest-k)%32];
   if(r.index!=newest-k)continue;
   row("K%u t=%llu.%03llus rp%u dr%u kpx%llu cs%u bl%u ctc=%lluus",r.index,(unsigned long long)(r.committedUs/1000000),(unsigned long long)((r.committedUs/1000)%1000),
    r.work.passes,r.work.draws,(unsigned long long)(r.work.pixels>>10),r.work.dispatches,r.work.blits,(unsigned long long)r.callbackUs);
   if(k<4)row("E%u age=%lluus scheduled=%lldus",r.index,(unsigned long long)r.ageUs,(long long)r.scheduledUs);
  }
 }
 return at;
}

extern "C" size_t native_bridge_metal_formats(char *out,size_t size) {
 std::lock_guard<std::mutex> lock(gProblemLock);
 return native_bridge_metal_formats_locked(out,size);
}

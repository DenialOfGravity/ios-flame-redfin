# redfin: direct scanout of Core Animation's frames (plan, 2026-10-27)

Goal: the display engine (MDP, SDE/DPU 6.x on SM7250 "lito") reads CA's 1125x2436 BGRA swap-chain surface itself,
scaled to the 1080x2340 panel, flipped at frame start: no GPU blit, no CPU copy, no tearing. Today `AppleCLCD`
(SweetFramebuffer.cpp) copies each frame into ABL's splash buffer (GPU blit ~20-25 ms behind CA's GPU work, or
the 0946 CPU copy, 7-10 ms); 0905 `sweetfbflip=1` already flips VIG0/VIG1 between two panel buffers.

**Verdict: feasible, medium size (~1000 lines over three patches), low brick risk** (registers only, nothing
persistent; a reboot always gets ABL's set-up back). Chosen memory approach: **CA's framebuffer surfaces are
allocated by our IOSurface from the splash carve-out (3 slots)**, so the MDP reads them exactly the way it reads
ABL's buffer today, with no SMMU writes. Steps (a)-(c) are in patch 0948 (`p mdp dump|smmu|test|scale|restore`).

Sources: lito DT `lito-sde.dtsi` (github.com/LineageOS/android_kernel_google_redbull, branch lineage-22.2,
arch/arm64/boot/dts/vendor/qcom/), upstream `drivers/gpu/drm/msm/disp/dpu1/dpu_hw_sspp.c`, `dpu_hw_util.c`
(`dpu_hw_setup_scaler3`), `dpu_hw_sspp.h` (filter enums), `dpu_plane.c` (`_dpu_plane_setup_scaler3`,
`_dpu_plane_setup_pixel_ext`), and our `shim/sde.c`, `shim/disptest.c` (flame phases F/G: three 1125x2436 buffers at
4608-byte rows in the carve-out, flipped by SRC0_ADDR + CTL flush under autorefresh).

## 0. What the hardware is (lito DT, offsets from MDSS 0x0ae00000)

| Block | Offset | Notes |
|---|---|---|
| MDSS / MDP top | 0x0 / 0x1000 (len 0x494) | DT reg `<0xae00000 0x84208>`; our device window is 2 MB (sweet_mdp_rd) |
| CTL0-3 | 0x2000 + 0x200 n | FLUSH 0x18 (VIG0 bit 0, VIG1 bit 1, CTL bit 17), LAYER 0x00.., TOP 0x14, DSC 0xe8, INTF 0xf4 |
| VIG0, VIG1 | 0x5000, 0x7000 | len 0x1f8, QSEED **"qseedv3lite" at +0xa00**, CSC +0x1a00; DMA0-2 0x25000/0x27000/0x29000 |
| LM0-3 | 0x45000 + 0x1000 n | mixer linewidth 2560; SSPP linewidth 2880 |
| PP0-3 | 0x71000 + 0x800 n | |
| DSC0/1 | 0x81000, 0x81400 | 2 slices x 540, slice height 65 (ABL) |
| INTF1 | 0x6b800 | FRAME_COUNT 0x0ac (works), tear check 0x284.., AUTOREFRESH 0x2b4 = 0x80000001 |
| apps SMMU MDP streams | `iommus = <&apps_smmu 0xb40 0x402>` (unsec), 0xb41 (sec) | `qcom,iommu-earlymap; /* for cont-splash */` |

ABL: CTL0 -> VIG0 (left 540) / VIG1 (right 540) -> LM0/LM1 -> PP -> DSC0/1 -> INTF1, command mode, autorefresh one
frame per TE. A CTL flush is latched at the next frame start (0905 proves it: the flush bits read back clear).

## Q1. Memory: where CA's framebuffer surfaces come from

**Today.** IOMFB never allocates swap-chain surfaces. CA (in backboardd) creates its own IOSurfaces through
`IOSurfaceRootUserClient` create (SweetSurface.cpp: `IOBufferMemoryDescriptor::inTaskWithOptions(kernel_task,
kIODirectionInOut | kIOMemoryKernelUserShared, allocSize, page_size)`: scattered 16 KB pages) and names them in
SwapEnd (swap record +0x54 + 4 x layer = surface id, +0x104 layer mask). The only IOMFB surface is
`kSweetFBGetLayerDefaultSurface` = the panel memory published with `sweet_surface_create_physical()`. The
`fb surfaces 2-7` count is CA's chain growing under load. IOSurface use counts (`trapUseCount`) and
`kSweetFBSwapWait` are no-ops today.

**Does the MDP need SMMU work?** The MDP reads through the apps SMMU (streams 0xb40/0x402). ABL's pattern on this
SoC family (USB, camera and FastRPC fixes, HANDOFF.md 2026-10-20 "USB result") is a context bank with
**SCTLR.M = 0 (translation off)**, i.e. IOVA = PA, behind the hypervisor's stage 2; S2CR bypass is refused by the
hypervisor and our own stage-1 banks gave translation faults. `p mdp smmu` (0948) reads the SMR/S2CR/CBAR/SCTLR for
0xb40 to confirm. Either way the SSPP fetches a *linear* buffer (address + row pitch), so the surface must be
contiguous in IOVA; with translation off that means physically contiguous.

| Option | How | Cost | Risk |
|---|---|---|---|
| **A. Carve-out slots (chosen)** | SweetSurface create: backboardd + 1125x2436 + 'BGRA' + bpe 4, one plane, bpr 4608 -> a free slot of the splash region, `IOMemoryDescriptor::withPhysicalAddress` (as `sweet_surface_create_physical`); slot freed in `free()`. Anything else (4th surface, other sizes) keeps normal memory. | ~200 lines (SweetSurface.cpp + a 3-slot allocator) | Low: the MDP already reads this region; no SMMU writes; GPU maps the pages through its own tables like any surface |
| B. MDP context bank with page tables | stage-1 tables for each surface's scattered pages, TLB maintenance per surface, rewrite the live display bank | ~500 lines + per-surface map/unmap | High: changing the bank while it scans out faults -> blank/reset; own S1 banks have faulted before on this SoC; hypervisor mediation unknown |
| C. Contiguous RAM pool | boot-time `kmem_alloc_contig`/`IOBufferMemoryDescriptor::inTaskWithPhysicalMask(... kIOMemoryPhysicallyContiguous ...)` 3-7 x 11 MB | ~150 lines | Only if `p mdp smmu` shows M = 0 (or bypass) and the hypervisor's stage 2 lets the MDP read HLOS RAM; fragmentation after boot |

Carve-out layout (16 KB pages; surface 4608 x 2436 = 0xab4800 -> 0xab8000):

| Slot | PA | Notes |
|---|---|---|
| 0 | 0xa0000000 | overlaps ABL's buffer / 0905 front (the console is muted by then) |
| 1 | 0xa0ab8000 | overlaps 0905's back buffer 0xa0a00000 |
| 2 | 0xa1570000 | ends 0xa2028000 |
| free | 0xa2028000-0xa2200000 | 1.8 MB: corner overlay (Q3) |
| backlight DSI packet | 0xa2200000 | 0906; must stay untouched |

So direct mode (`sweetscanout=1`, later) is exclusive with `sweetfbflip`, and frames that name a non-slot surface
cannot be copied into a panel buffer. Plan: drop them (keep the last frame, count `nonslot` in the 5 s stats
line); step (e) measures how often. If CA keeps >3 surfaces, either make the in-use signal work (Q3) so the
chain stays at 3, or add option C slots if M = 0. CPU coherency: CA renders with the GPU (writes reach DDR before
the ring fence); CPU-written surfaces already go through `cpuWrote()` (clean before present).

## Q2. Scaling: QSEED3LITE, 1125x2436 -> 2 x 540x2340

Upstream DPU programs QSEED3/3LITE in **bilinear mode with no coefficient LUTs** (`lut_flag = 0`), which is
enough for a 0.96 downscale. One phase step for the whole width so the halves meet; panel column X samples source
`X * 1125/1080`. The right pipe starts at source 562.5 = column 562 + phase 0.5. Both fetch 563 columns (bilinear
needs the next one; 562 + 563 = 1125). Vertical 2436 -> 2340 (0.06% from the 1125/1080 ratio, < 1.5 px over the
height, against 0947's touch fit of 2339 rows).

| Register (VIG base +) | VIG0 | VIG1 | Source |
|---|---|---|---|
| SRC0_ADDR 0x14 | surface PA | same | |
| YSTRIDE0 0x24 | 0x1200 (4608) | same | low 16 bits = plane 0 |
| SRC_IMG 0x04 | 0x09840465 (2436<<16 \| 1125) | same | disptest.c |
| SRC_XY 0x08 | 0 | 562 | |
| SRC_SIZE 0x00 | 0x09840233 (2436<<16 \| 563) | same | |
| OUT_SIZE 0x0c / OUT_XY 0x10 | ABL's (540x2340) | ABL's | unchanged |
| SW_PIX_EXT C0/C1C2/C3 LR, TB 0x100.. | 0 | 0 | dpu_hw_sspp_setup_pe_config |
| SW_PIX_EXT *_REQ_PIXELS 0x108/0x118/0x128 | 0x09840233 | same | = crop (`_dpu_plane_setup_pixel_ext`) |
| QSEED +0x10/+0x18 PHASE_STEP_Y_H/UV_H | 0x215555 (2^21 x 1125/1080) | same | 24 bits, 21 fraction |
| QSEED +0x14/+0x1c PHASE_STEP_Y_V/UV_V | 0x215015 (2^21 x 2436/2340) | same | |
| QSEED +0x90/+0x98 PHASE_INIT_Y_H/UV_H | 0 | 0xfff4c (0.4999) | 21 bits (version != 0x1002) |
| QSEED +0x94/+0x9c PHASE_INIT_*_V | 0 | 0 | |
| QSEED +0x20 PRELOAD | 0x03040304 | same | DPU_QSEED3_DEFAULT_PRELOAD_H 4 / _V 3 |
| QSEED +0x40/+0x44 SRC_SIZE_Y_RGB_A/UV | 0x09840233 | same | |
| QSEED +0x48 DST_SIZE | 0x0924021c (2340<<16 \| 540) | same | |
| QSEED +0x04 OP_MODE | 0x80034001 | same | bit 0 on, 17:16 = 3 (DPU_SCALE_BIL), bit 14 non-DX, bit 31 blend_cfg; with alpha (FORMAT bit 8) also bit 10 + bits 30:29 = 1 -> 0xa0034401 |

Format: keep ABL's SRC_FORMAT/UNPACK. CA's 'BGRA' bytes in memory are B,G,R,A, the same order the CPU copy writes
today with correct colours. Prefer an opaque format (alpha off) so CA's alpha cannot darken the blend. All latched
by the VIG flush bits (scaler and pixel extension are VIG sub-blocks). Fetch +8.5% (658 vs 607 MB/s at 60 Hz);
src width 563 is far below the 2880 SSPP line width. DSC, LM and PP are unchanged (LM output stays 540x2340).

## Q3. Flip, latch, completion; DSC and corners

1. SwapEnd(S) with S in a slot: queue a **fence-only** packet on the GPU ring (no blit). One ring, in order, so it
   lands after CA's draws into S (GPU caches flushed by CA's end-of-pass events).
2. Fence landed and the previous flip latched (CTL0 FLUSH & 0x3 reads 0): write VIG0/VIG1 SRC0_ADDR = slot PA
   (stride, crops, scaler set once when direct mode starts) and CTL0 FLUSH = 0x3. A flush written mid-frame
   latches at the next frame start (double-buffered), so a frame is never mixed: no tearing by construction.
3. Latch: flush bits clear, cross-checked with INTF1 FRAME_COUNT (0x6b8ac) moving (0905's `flip_latched_locked`,
   34 ms fallback). The previously shown surface is free from then on.
4. Completion to CA: make the in-use signal real: increment S's use count when it is flipped to, decrement the
   previous one at latch (trapUseCount and the state page; verify which field IOSurfaceIsInUse reads), and back
   pressure: hold the next SwapEnd (0944 queue) until the previous flip has latched. With CA round-robin over 3
   surfaces, CA can then never draw into the surface on screen. A miss costs one torn frame, not a fault.
5. Latency: SwapEnd -> visible = CA's GPU tail + <= 1 TE period + scanout, vs 20-25 ms (blit) today; zero CPU.

DSC: untouched (same LM output). Corners: the panel's physical rounding hides the corner pixels; iOS draws nothing
special there, so no mattes are needed for correctness. If the antialiased iPhone-style corner is wanted, use a
static overlay: DMA0/DMA1 pipes (one per LM, multirect for two corners) on an ARGB corner mask in the free
1.8 MB at 0xa2028000, blend stage 1 above the VIG pipes; one-time set-up, no per-frame cost. Power-off fade: point
the pipes at a black slot or fade the backlight instead of writing the panel buffer.

## Q4. Staged experiments (each reversible, no persistent state)

All pokes are inert unless sent. Registers are read/written only through `sweet_mdp_rd/wr` (inside the MDP's 2 MB
window, blocks ABL already clocks, the same blocks shim/sde.c dumped); the SMMU through its own 4 KB pages, reads
only. `test`/`scale` save 29 registers per pipe first, stop presents (present() returns, 0905 flips leave the pipes
alone), and restore + flush after SECS (default 10, timer on the framebuffer work loop) or at `p mdp restore`.
Worst case (a pipe that never latches again): the panel freezes until reboot; nothing else changes.

| Step | Poke / patch | What it shows | Revert | Size | Risk |
|---|---|---|---|---|---|
| a | `p mdp dump`, `p mdp smmu` (0948) | all non-zero words of top, CTL0-3, VIG0/1 + QSEED (version reg +0xa00), DMA0-2, LM0/1, PP0/1, DSC0/1, INTF1; SMRs that take 0xb40/0x402 with S2CR type, bank CBAR/SCTLR(M)/TCR/TTBR0 | read only | in 0948 | very low (SMMU reads as the camera code does) |
| a' | `p mdp smmu walk` (0948) | if M = 1: the stage-1 descriptors for IOVA 0xa0000000 (identity? which range?) | read only | in 0948 | low-medium: maps table pages; run only if M = 1 |
| b | `p mdp test [SECS]` (0948) | 1080x2340 pattern at 0xa1400000 (white border, red block top left, colour bars, 64 px grid, red seam at 539/540) in ABL's geometry: the MDP reads a new buffer in the carve-out; flush latency and frame count logged | timer / `p mdp restore` | in 0948 | low |
| c | `p mdp scale [SECS]` (0948) | 1125x2436 pattern (4608-byte rows) through both scalers: border on all four panel edges, seam line continuous at the middle, grid evenly blurred | timer / `p mdp restore` | in 0948 | medium-low: wrong scaler values = garbage or underrun until restore |
| d | 0949: carve-out slot allocator in SweetSurface create + `p mdp ca [SECS]` (scaled pipes on the newest slot surface) | one CA surface in the carve-out shown directly (static frame) | timer / restore | ~250 lines | low |
| e | 0949b: `sweetscanout=1`: per-SwapEnd fence-only submit, flip at latch, back pressure, use counts, stats (`direct N nonslot N latch p50/p95`) | live UI without copies; fps, tearing, dropped frames | boot-arg off | ~400 lines | medium (frame pacing, CA reuse) |
| f | optional: DMA-pipe corner overlay | iPhone-style corners | `p mdp restore` / boot-arg | ~150 lines | low |

First phone run (one boot, any image with 0948): `p mdp dump`, `p mdp smmu`, then `p mdp test 10`, wait 12 s,
`p mdp scale 10`, wait 12 s; photo of the panel during each, then the klog (`SWEET MDP:` lines). Expected: dump +
smmu lines; "test: flush latched after ~0-17 ms, intf1 frames +1"; the pattern for 10 s; "restored (timer)"; the
UI back. Look for: QSEED version (0x2004.. = 3LITE), VIG1 SRC_XY (x 540 = source split from one address), FORMAT
bit 8, OUT_XY, SMMU bank M bit.


## Status 2026-10-27: steps a-c passed (r35a), d and e written (0975, 0976)

- r35a (kernel f3ce8ca): `smmu: SMR3 0x84020b40 (id 0xb40 mask 0x402) S2CR 0x2 (translate, bank 2)`, bank 2
  `SCTLR 0xe0 (M 0)`: **the MDP's bank does not translate; it reads physical addresses.** `p mdp test` and
  `p mdp scale` showed the patterns with a continuous seam, no artefacts, auto-restore worked. (The eighth colour bar
  is black by design: the bars "stop" 12.5 % short of the right edge.)
- Memory, final: **slot 0 = carve-out 0xa1400000, slots 1-6 = contiguous RAM below 4 GB** (SRC0_ADDR is 32-bit),
  made on first use and never freed. 0905's panel buffers stay, so `p scanout 0` (GPU blit / CPU present) works in
  the same boot. 7 slots cover CA's deepest chain.
- 0975 (`sweetscanout=1|2`): the slot allocator in SweetSurface create (backboardd, 1125x2436 'BGRA', one plane)
  and `p mdp ca [SLOT [SECS]]`.
- 0976: the direct path. Flip only after the frame's SwapEnd fence (0949's lesson: SwapEnd = queued, not drawn),
  one flip in flight, latch = CTL0 VIG bits clear or INTF1 frames +2, back pressure (SwapEnd K waits for K-1 on
  screen), SwapWait, displayUse/clientUse, `SWEET SCANOUT: 5s:` line, live `p scanout 0|1`. Non-slot frames switch
  the pipes back to the panel buffer and go the normal way. Not handled yet: the power-off fade (it draws into the
  panel buffer, which is not on screen in direct mode) and corner mattes.

## 2026-10-27, r36a findings and 0979

- CA's swap chain on r36a was **two** surfaces (ids 2/3; after backboardd restarts 11/12 and 28/29). Slot 0 took one;
  the RAM slot for the other failed: **XNU's RAM on redfin is all above 4 GB** (`mkadt.py --highmem`), SRC0_ADDR is
  32-bit and the MDP bank does not translate, so XNU can never give the MDP contiguous RAM. Every other frame was
  non-slot, and the pipes switched geometry on every frame (enter 70 / leave 69 per 5 s): p95 257 ms.
- 0979: slots 1-6 come from the **GPU pool** (`gpool_ranges`: HLOS RAM 0xc4000000.. below 4 GB that XNU does not
  manage, write-combined like the carve-out), reserved in AppleCLCD::start (`sweetscanslots`, default 6). 0905's
  flip buffers stay. One log line per panel-sized surface. Direct only after 3 slot frames in a row. Back pressure
  by chain depth (N = 2: SwapEnd waits until its own frame is on screen). SwapWait (CA calls it with the previous
  swap id, scalars `id, 0x80000000, ?`) waits until that swap is retired, and returns at once on the normal path.
  Latch = INTF1 frame counter past the flush and VIG bits clear, or 2 frames.

## 2026-10-27, r38a and 0985/0986

- r38a (0983): SwapWait timeouts gone, but CA stays at 2 surfaces (`chain 2-2`) even with the use counts published,
  and back pressure held every SwapEnd: SwapEnd K always arrives before K's fence and latch. 0985 replaces it with
  a gate on the swapper's GPU submits (K+1's work enters the ring only once K is on screen). This is double buffering
  that leaves CA's CPU free. `p scanout gate 0` reverts to the back pressure.
- What makes CA allocate a third surface is still open. It needs the QuartzCore strings from the phone's dyld cache
  (IOMFB property and env names around the swap-chain/buffer count).
- 0986 `p scanout corners 1`: CPU mattes in each frame's corners after its fence (no DMA-pipe overlay yet).

## 2026-10-27, r39a and 0989

- r39a "gate 0 deadlock": the power key was pressed at 491.4 s (`SWEET KEYS: key=0`), and backboardd turned the
  display off at 491.742 (`SWEET FB: display off`), 20 s before `gate 0`. No frames come while the display is off.
  0989 now leaves the direct geometry on display off, so the fade shows.
- 0989 `p scanout gate 2`: CP_WAIT_REG_MEM on a latched-frame word (scratch + 0x3000). It is released on any change
  or after 50 ms. Flips wait for the swapper's own last fence. The gate 1 cap is now 50 ms.
- Third surface, phone step (read only): `imgdump grep` in QuartzCore / IOMobileFramebuffer for the swap-chain keys.

## 2026-10-27, r40 and 0991

- Gate 2 bug: frame K+1's GPU work waits in the CP for K on screen, but K+1's SwapEnd replaced K (still waiting for
  its fence), so K was never shown and K+1 never drew until the 50 ms release. 0991 queues frames in gate 2 instead.
- r40b "stall after sweetiomfbprops": `SWEET CMD: key 0 100` at 156.685 (a power-key press) and then `display off`
  at 157.073. No frames come while the display is off. The source limits changed nothing visible (chain 2-2). The
  "nonslot 2" were backboardd's display-off swaps (surface 0, layers 0x1 / 0x80000007).

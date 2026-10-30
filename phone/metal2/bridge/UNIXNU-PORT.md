# UniXNU AdrenoMetal bridge patches 0007-0016 on the redfin bridge

Source: github.com/UniXNU/AdrenoMetal main ce5e19e, `bridge/patches/` (author bluseliu50, BSD-2-Clause-Patent; each ported
patch keeps that attribution in its header). Target: metal2vulkan 720ef1ce + our 0001-0111 (branch `ws-z-bridge`, from
`ws-u-combo` ce44728). Ported patches are numbered 0130-0137 so they never collide with the 0100-0123 series of `ws-z-merge`,
and each is self-contained (rebases onto ws-z-merge on its own; they do stack in order, 0131 before 0132 before 0133).

Every knob is read once per process from the environment (`SWEET_U00NN`, on when set and not `0`; `/var/local/mtl2-env` lines
reach it through SweetMetal2.mm). All default off = ce44728 behaviour, except 0131, which changes types only.

| UniXNU | Decision | Ours | Knob | What it does / why | Expected effect |
|---|---|---|---|---|---|
| 0006 skip draws without a pipeline | already ours | 0006 | - | byte-identical | - |
| 0007 accept two-plane RGB surfaces | ported | 0130 | `SWEET_U0007=1` | `_RB4` (render server's 2-plane RGB, `RGB8_444_2P`) in the runtime's surface table. Our frontend only routes 500/501 to the planar call, so a 542 texture still needs UniXNU's frontend change (bcbbc70 `textureOnSurface`) to reach it: not ported here (frontend, not bridge). | none until the frontend routes 542; then widget snapshots stop being white |
| 0008 alias padded rows of written textures | skipped | 0101 | - | Our 0101 already aliases every padded texture that renders or writes under `Alias` (theirs adds a new `AliasWrites` policy the bridge opts into). Same effect. | - |
| 0009 keep final pass | skipped | 0107 `SWEET_RPCACHE` | - | Our 0107 keeps every `vkCreateRenderPass2` result in `create()` by its full create info (and framebuffers too), which covers `final_pass`. | - |
| 0010 fewer allocations per draw | ported | 0131 | always | Viewports/scissors in a 16-slot inline array, push-field bytes inline (<= 32 B), a draw's own uses in place, quiet-bound-values without a specialization clone. Values unchanged; one fastdraw adaptation (`PerViewport::default`). | ~6-10 heap allocs fewer per draw: ~2-4 µs/draw |
| 0011 keep draw commands | ported | 0132 | `SWEET_U0011=1` | Encoder keeps the last `DrawCommands`; `instantiate_draw_into` refills its 10 vectors. | ~10 allocs + frees fewer per draw: ~3-6 µs/draw (D_INSTANTIATE) |
| 0012 keep draw lists | ported | 0133 | `SWEET_U0012=1` | Encoder keeps the last draw's use list and argument-sampler list (no `Vec<Arc>` collect per draw). Also brings UniXNU's `KeyUses::One` inline first use per key in the tracker (always on; same results, required by 0014). | ~2-4 µs/draw (D_USES, D_TRACK) |
| 0013 skip unchanged rebinds | ported | 0134 | `SWEET_U0013=1` | `DeviceOptions::refuse_rebinds`; the env knob turns it on for every device. Encoders then keep no replay call log while a no-copy buffer lives (always true for us: every IOSurface is one). Our bridge never calls `rebind_bytes_no_copy`. Fastdraw's `sweet_gen` counters are independent of the log. | one log push (+ arena copy for slices) per encoder call: ~3-8 µs/draw at ~8-12 calls per draw |
| 0014 map tracker keys | ported | 0135 | `SWEET_U0014=1` | `EncoderUses`/`Part`/`UnorderedWrites`/`merged` maps on `TrackMap`, which hashes with the runtime's `KeyHasher` when the knob is on and SipHash otherwise. | ~1-3 µs/draw (D_TRACK) |
| 0015 two-plane shadow as memory lies | ported | 0136 | `SWEET_U0015=1` | `surface_two_planes.rs`: the shadow image starts `Held` (no zero fill). Only 550/551 (`b3a8`) textures use this path, and our frontend maps those to BGRA8, so no effect today. | none today |
| 0016 tile stores within rows | ported, adapted | 0137 | `SWEET_U0016=1` | Theirs guards their `AliasWrites`; ours guards our 0101: under `Alias`, a padded texture that renders or writes and whose 16x4 tile stores at its right/bottom edge would leave its row pitch or the buffer gets a shadow instead. A correctness guard (Turnip GMEM stores whole tiles), not a speed-up. | maybe a few more shadows; fixes corruption past row ends if any |

Not ported now (noted for later): the parity branch `feat/ipados27-gpu-parity` draw-path patches 0025-0037 (ded1122: viewports
in place, push/table bytes kept, bind vectors kept, draw rooms handed to the next encoder, final passes by reference, barriers
batched on the stack, command pools reset on give-back, calibration off the commit path, key-hashed draw-path maps) and the
encoding thread (1353601, 6c7b0a0, 0dd1516, f1f51bf).

## Expected saving and how to measure

Combined estimate with all knobs on: ~10-20 µs of the ~70-80 µs per draw (mostly allocator work: the bridge path makes
~25-35 allocations per draw today), i.e. ~1-2 ms per 100-draw Settings frame on backboardd's display thread.

Measure A/B on the same image with `files put` of the bundle, no reboot:
1. Baseline: `SWEET_DRAWSTAT=1` in `/var/local/mtl2-env`, restart backboardd, scroll Settings, read the T5 drawstat line
   (µs/draw per step: D_INSTANTIATE, D_USES, D_TRACK, D_RETAIN and the total) and `display.primary` CPU % from sweetmon.
2. Add `SWEET_U0011=1 SWEET_U0012=1 SWEET_U0013=1 SWEET_U0014=1`, restart backboardd, same scroll, same reads.
3. If a step regresses, flip one knob at a time. 0130/0136/0137 are correctness knobs: check widgets (0130 needs the
   frontend change) and padded-surface artefacts (0137) visually.

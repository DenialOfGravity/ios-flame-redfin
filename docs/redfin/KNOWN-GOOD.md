# Known good: r57a (redfin, set 2026-10-29 by the user)

Copy of the PC project folder's `KNOWN-GOOD.txt` (no credentials in it). Previous known good: r55k.
Images, kernels and logs stay on the PC, never in git.

| | |
|---|---|
| Image | **r57a** (`redfin-r57a.img`, sha256 `bc5b9ca69a5c2e4392671671315dae71555d8d9a45080deaa993533691b9f033`) = r55k's shim, ADT and cmdline (`r55k.cmdline`, unchanged) + the kernel below |
| Kernel | branch `ws-y-int-safe` @ `b1e8c0b` (= `known-good-r57a-kernel`) = r55k kernel `101171d` + Wi-Fi patches 1012 + 1013; local build `builds/xnu/ws-y-int-safe-b1e8c0bd64/`, sha256 `1531a2375874c777e1f668e1a786b43a2e384219c968cbb43666fffe9f2e7bd0`, klog PA `0x101d0ef00`, 258 patches |
| Kept / left out | Keeps 1030 (Files > On My iPhone). Leaves **out 1014**: with it (r57b, r55a) the phone resets on wifid's join. |
| Userland on the phone | btd as `/var/local/bin/btd-bridge` from `ws-y-bt` @ `43320fd` (sha256 `108b0a339f23c14da738fb8ae6a0304f158357d537de95b224d55200637f83c7`); older copies kept: `btd-bridge.68cef4c`, `btd-bridge.f6fc88e` |
| Build tooling | `tools-localbuild` @ `c99381b` (`tools-claude/localbuild`, patch-skip guard) |
| Integration | all three merged into `redfin-int` (2026-10-29) |

## Tested 2026-10-29
- Boots; wifid joins (1013: ~22 s after the radio on r56b, ~35 s on r57a); survived a forced link drop (wland rejoined).
- User-confirmed: Files > On My iPhone shows files; iPhone Storage works.
- **Bluetooth works** (user-confirmed): scanning finds devices, basic connection to another phone. The radio still
  answers some LE/vendor commands with errors (btd's shim smooths them).

## Phone-side state it relies on (already on the phone)
- boot job `org.iosonpixel.fstypeovr` (statfs reports "apfs" for /); plist backup `/var/local/launchd.plist.pre-fstypeovr`
- `fairplayd.H2` job removed, `AirFair.syncBundle` moved to `/var/local/disabled/SyncBundles/` (iPhone Storage fix)
- / grown to 109 GiB (HFS+, journaled); never let a filesystem cover the last 17 MiB of userdata (log ring)
- SweetMetal2 bundle / mtl2-env: whatever is live on the phone now (the r35 known-good copies are history only)

## Known gaps
- wifid's own second join not yet exercised on r57a. 1014 (signal events) excluded.
- One crash, MediaRemoteUI sig 5, seen once (first media playback from Files), not investigated.

## Do not
- Read or write `/dev/rufsroot0` or `/dev/ufsroot0` from user space (physio panic); use TWRP.

## Restore
Phone agent: `to-fastboot`, wait 15 s, `boot r57a` (RAM only, `fastboot boot`), poll status until "phone answers".
Fallback: power+vol-down to fastboot, `boot r55k` (kernel `known-good-r55k-kernel` @ `101171d`).

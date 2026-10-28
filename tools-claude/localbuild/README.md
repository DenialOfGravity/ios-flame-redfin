# Local builds in WSL (no Mac, no GitHub runners)

The four CI builds run on the user's PC in WSL (Ubuntu 26.04, 16 threads), started through the phone agent. Same
steps and sources as `.github/workflows/{shim,userland,metal2,xnu}.yml`; Linux tools instead of Xcode.

| Target | Local (WSL) | CI when runners are free (2026-10-25/26 runs) |
|---|---|---|
| shim | ~10 s | ~30 s (Linux runner) |
| userland | ~2 min | 1-11 min (macOS) |
| metal2 | ~5 min full; Mesa/bridge rebuild only what changed | 6-10 min (macOS) |
| xnu | 10-60 s incremental; ~3-4 min full | 4-18 min (macOS), plus queueing; runners were unavailable for hours on 2026-10-26 |

## Use (from `device_bash`)

    cd $HOME/mnt/iOS_Pixel5/agent
    ask(){ echo "$2" > inbox/$1.req; for i in $(seq ${3:-60}); do [ -f outbox/$1.out ] && break; sleep 1; done; cat outbox/$1.out 2>/dev/null || echo "no-answer $1"; }
    ask k1-x "build xnu ws-q-quickwins"       # TARGET shim|userland|metal2|xnu, REF branch or commit (default redfin-qol)

The action returns at once (`started pid ... -> builds/logs/<...>.log`); the build runs in the background. Results:
`builds/<TARGET>/<REF>-<sha10>/` in the project folder: `BUILD.txt` (source sha, ref, time, `result ok|FAILED`),
`build.log`, and the outputs:

- xnu: `kernel.development.sweet.gz` (as on the builds-xnu branch), `SHA256SUMS`, `KLOG_PA.txt` (the agent's
  `klog` address for this kernel); on failure `errors.txt`, `errors-context.txt`, `tail.txt`, `make.log.gz`.
- userland: the same files as the builds-userland branch (RedwoodAudio.driver with `_CodeSignature`, dropbearmulti,
  dash, toybox, wland, sensd, btd, fastrpcd, phone tools, ...).
- metal2: `SweetMetal2.bundle` (as builds-metal2), `libvulkan_freedreno.dylib`, `m2vtest`, `turnip/`.
- shim: `shim-Image.lz4` (the kernel slot of rNN boot images), `redfin-probe{,-safe}.img`, `shim.elf`.

Wait with `sleep` + `tail -3 builds/logs/<log>` (one `device_bash` call is at most ~180 s), or poll `BUILD.txt`.
Read failures with `grep`/`head` on `errors.txt`; never cat a whole log. Other actions: `build-jobs`, `build-kill`,
`build-env`, `build-setup STEP` (toolchain, already done), `build-apt` (the only sudo step), `build-diag` (runs
`localbuild/diag.sh`, a throwaway check script).

One build per target at a time (later ones wait for the lock); different targets run in parallel.

## Updating these scripts

The agent runs the copies in the project folder (`tools-claude/localbuild`), not the repo's. Edit in the
container, pack to a uniquely named tar (device_commit_files may reuse an earlier upload under the same path), commit
it to `agent/stage/`, then `tar xf agent/stage/NAME.tar --overwrite -C tools-claude` (plain tar cannot replace files:
deleting is not allowed there). `bin/*` wrappers are re-installed by each userland/metal2 build. Commit the changes
to the repo afterwards.

## How it works

- `env.sh` paths: `~/redfin-build/{toolchain,src,work}` in WSL (ext4). Apple SDKs: the iPhoneOS 27 / MacOSX 27 SDKs
  `xtool setup` extracted from the user's Xcode 27 .xip into `~/.swiftpm/swift-sdks/darwin.artifactbundle`.
- **xnu** (`xnu.sh`): UniXNU's Linux toolchain (github.com/UniXNU/UniXNU `scripts/linux`, BSD-2-Clause-Patent, pinned
  in `env.sh`; built by `setup.sh`/`tc.py` without root): clang 24 with `__builtin_xnu_type_*`
  (`toolchain/llvm/bin/clang`), cctools-port ld64-956.6, mig (bootstrap_cmds-138), iig-port, their clang/plutil/
  install shims; our `bin/xcrun`. blacktop's patch steps, then `xnu/patches` (`*.sh` then `*.patch`, C locale order)
  on a pristine xnu-8796.141.3 (a patch that does not apply fails the build with `PATCH FAILED: NAME`, unless NAME is in
  `patch-skip-allow.txt`; the log says `patches applied: N`); changed files are rsynced into the build tree, so make is incremental. Linux-only
  source rewrites (not kernel patches; logged as `linux:` in the build log): mawk syscall table, arm64 ISA asm syntax,
  kextsymboltool lseek on /dev/null, and `KALLOC_TYPE_IS_COMPATIBLE_PTR` in C++ (`__remove_pointer` instead of
  `*(void *)` in `__typeof__`, which Apple clang only warns about). Also `-Wno-error=incompatible-pointer-types` (an
  error in clang 21+, a warning in Xcode 15). Target `arm64-apple-macos14.0`, SWEET's `-march=armv8.2-a+crypto`.
  Fakeroot made once: AvailabilityVersions (needs ruby), installhdrs, libplatform, libfirehose_kernel (one file,
  compiled directly), libcc_kext (compiler-rt profile runtime). No CTF (no ctfconvert on Linux) and no dSYM.
- **userland/metal2**: the distribution's clang 21 for iOS (`bin/ios-cc` = `-target arm64-apple-ios16.0 -isysroot
  <iPhoneOS27 SDK>`), linked with **xtool's ld64.lld** (`toolset/bin/orig`): Ubuntu's lld cannot read the iOS 27
  SDK's `arm64e.x1` .tbd stubs. `bin/codesign` = ldid (`-Cadhoc`, bundles signed as bundles with CodeResources and
  CFBundleIdentifier, entitlements kept). nm/strip/lipo/otool/ar = LLVM's. Rust 1.98.0 (rustup, user install).
  Mesa is a blobless checkout reset and re-patched each run; the meson build dir is kept (rebuilt from scratch when
  `bin/*` changes).

## The r29a boot failure (2026-10-26) and its fix

r29a (local kernel ws-q-bt 9f1431a) reset before USB networking; the CI kernel of the same commit (r29b) booted.
Cause: `libfirehose_kernel.a`, which xnu.sh compiles itself (not through xnu's makefiles), was built with no `-mcpu`.
For an `arm64-apple-macos` triple upstream clang then picks target-cpu **apple-m1**, and the backend used an M1-only
instruction in `firehose_buffer_stream_chunk_install`: `stlur` (FEAT_LRCPC2, Armv8.4). SM7250's Cortex-A76/A55
cores don't have it -> undefined instruction on the first kernel os_log. The kernel's own objects were fine: xnu's
makefiles pass SWEET's `-mcpu=cortex-a55+crypto` (patch 0095), so they are A55 code (`ldapr`, `udot`: both legal
on A76/A55; `xpaclri` is a hint = NOP).

Fix (xnu.sh): `-mcpu=generic` in the clang shim's flags (xnu's own `-mcpu` comes later and wins); a full rebuild
whenever the compiler or these flags change (`COMPILER.txt` in the output records them); and an **ISA check** after
the link that fails the build on any Armv8.4+ instruction (stlur/ldapur, FlagM, SHA3/SM, BF16, I8MM, SB, LS64...).
Output folders from before the fix carry `DO-NOT-BOOT.txt` instead of `COMPILER.txt`.

Checked equal to the CI kernel of 8d69d7e: kalloc_type views (all 1564 signatures, flags, sizes), the startup entry
table (4160 entries, same order), `__mod_init_func`/`__mod_term_func` lists, section set (minus `__ctf`). Remaining
differences: compiler codegen (no hot/cold splitting, more NEON, no `___chkstk_darwin`), alignment padding in
`.s` files is zero bytes instead of NOPs (only after unconditional branches/ret, never executed), symbol addresses.

## Known differences from CI output (checked on redfin-qol a2c5c3b)

- Kernel: same segment layout and entry; ~3.5% less code (upstream clang: no hot/cold splitting, no
  `___chkstk_darwin` stack probes, different inlining). **Symbol addresses differ from the CI kernel of the same
  commit**, so use the build's `KLOG_PA.txt`. First boot (r29a) failed: see above; fixed builds not boot-tested yet.
- Userland: LC_BUILD_VERSION sdk 27.0 (CI 17.5), minos 16.0 as CI; ~15% smaller; upstream clang's ObjC ARC calls
  (no `objc_release_x19` helpers); code signature identifier = file name for plain binaries (CI: `name-<hash>`).

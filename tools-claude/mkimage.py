#!/usr/bin/env python3
"""mkimage.py NAME KERNEL_DIR [BASE] [CMDLINE_FILE]: a bootable redfin image, made locally (WSL) by repacking BASE
(default r47a) with another kernel (u-lab; the phone agent's `mkimage` action runs this).

Kept from BASE (P/BASE/redfin-BASE.img, checked against its .sha256): the boot header (v3, os version/patch level,
header cmdline), the shim (boot "kernel", LZ4), the ADT inside the payload (with its /chosen gpufw,* GPU firmware and
sweet-poke script), the payload cmdline (or CMDLINE_FILE's first line), and the AVB footer's parameters (partition size,
name, algorithm, salt: the same kernel gives the same image, byte for byte).
New: KERNEL_DIR/kernel.development.sweet(.gz) through the repo's tools/mkpayload.py (chained fixups resolved, segment
table), then mkbootimg (AOSP, LineageOS android_system_tools_mkbootimg) and avbtool add_hash_footer (android_external_avb).
mkpayload's ramlog VAs come from `nm`, which cannot read the Mach-O on Linux: they stay 0, as in every image so far
(r47a); an nm stub that prints nothing makes that independent of what nm the host has.

Refused: NAME exists (P/NAME), KERNEL_DIR without COMPILER.txt, with DO-NOT-BOOT.txt, or whose build.log lacks
"ISA check ok"; a kernel whose sha256 differs from KERNEL_DIR/SHA256SUMS; a BASE whose payload carries a ramdisk.
Output P/NAME/: redfin-NAME.img, redfin-NAME.sha256, NAME.cmdline, mkpayload.log, README.txt (base, kernel sha256,
KLOG_PA, compiler, tool versions). Written to P/.NAME.tmp first and renamed at the end (a failure leaves no NAME).

Tools: ~/redfin-build/tools/{mkbootimg,avb} (cloned there once, --depth 1), else P/tools-claude/vendor/{mkbootimg,avb}
(vendored copies, Apache-2.0). mkpayload.py + adt.py: $MKPAYLOAD_DIR, else $REPO/tools (REPO default ~/ios-redfin).
"""
import gzip
import hashlib
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time

P = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS_HOME = os.path.expanduser('~/redfin-build/tools')
CLONES = {'mkbootimg': 'https://github.com/LineageOS/android_system_tools_mkbootimg',
          'avb': 'https://github.com/LineageOS/android_external_avb'}
NAME_RX = re.compile(r'^[a-z][0-9a-z]*(-[0-9a-z]+)*$')
CMDLINE_OFF, BOOT_LINE_LENGTH = 0x48, 608
RAMLOG_OFF = CMDLINE_OFF + BOOT_LINE_LENGTH - 16


def die(msg):
    print('mkimage: REFUSED: ' + msg if not msg.startswith('!') else 'mkimage: FAILED: ' + msg[1:])
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def run(args, **kw):
    r = subprocess.run(args, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        die(f'!{" ".join(shlex.quote(a) for a in args)}: exit {r.returncode}\n{r.stdout[-2000:]}{r.stderr[-2000:]}')
    return r.stdout


def tool_dir(name):
    d = os.path.join(TOOLS_HOME, name)
    if not os.path.isdir(d):
        os.makedirs(TOOLS_HOME, exist_ok=True)
        r = subprocess.run(['git', 'clone', '-q', '--depth', '1', CLONES[name], d], capture_output=True, text=True,
                           timeout=180)
        if r.returncode != 0:
            shutil.rmtree(d, ignore_errors=True)
    if os.path.isdir(d):
        rev = subprocess.run(['git', '-C', d, 'log', '-1', '--format=%H'], capture_output=True, text=True).stdout.strip()
        return d, f'{CLONES[name]} {rev or "?"}'
    v = os.path.join(P, 'tools-claude', 'vendor', name)
    if os.path.isdir(v):
        ver = open(os.path.join(v, 'VERSION.txt')).read().strip() if os.path.exists(os.path.join(v, 'VERSION.txt')) else '?'
        return v, f'vendored {ver}'
    die(f'!no {name}: clone of {CLONES[name]} failed and no tools-claude/vendor/{name}')


def resolve_in_p(path):
    p = path if os.path.isabs(path) else os.path.join(P, path)
    p = os.path.realpath(p)
    if not (p + '/').startswith(os.path.realpath(P) + '/'):
        die(f'{path}: not inside the project folder')
    return p


def avb_info(avbtool, img):
    out = run([sys.executable, avbtool, 'info_image', '--image', img])
    info = {}
    for key in ('Image size', 'Algorithm', 'Rollback Index', 'Flags', 'Rollback Index Location', 'Hash Algorithm',
                'Partition Name', 'Salt', 'Digest', 'Image Size', 'Release String'):
        m = re.search(r'^\s*' + re.escape(key) + r':\s*(.*)$', out, re.M)
        info[key] = m.group(1).strip() if m else None
    info['props'] = re.findall(r'^\s*Prop: (.*)$', out, re.M)
    info['descriptors'] = len(re.findall(r'^\s+\w[\w ]* descriptor:', out, re.M))
    info['text'] = out
    return info


def main():
    a = sys.argv[1:]
    if not 2 <= len(a) <= 4:
        print(__doc__)
        sys.exit(2)
    name, kdir = a[0], a[1]
    base = a[2] if len(a) > 2 and a[2] not in ('', '-') else 'r47a'
    clfile = a[3] if len(a) > 3 else None
    if not NAME_RX.match(name) or not NAME_RX.match(base):
        die('NAME/BASE: lower-case letters, digits and dashes')
    out_dir = os.path.join(P, name)
    if os.path.lexists(out_dir):
        die(f'{name} exists ({out_dir}): pick a new name')
    # --- kernel dir checks
    kdir = resolve_in_p(kdir)
    if not os.path.isdir(kdir):
        die(f'{kdir}: no such directory')
    if os.path.exists(os.path.join(kdir, 'DO-NOT-BOOT.txt')):
        die(f'{kdir} has DO-NOT-BOOT.txt:\n' + open(os.path.join(kdir, 'DO-NOT-BOOT.txt'), errors='replace').read()[:500])
    if not os.path.exists(os.path.join(kdir, 'COMPILER.txt')):
        die(f'{kdir} has no COMPILER.txt (not a checked kernel build)')
    blog = os.path.join(kdir, 'build.log')
    if not os.path.exists(blog) or 'ISA check ok' not in open(blog, errors='replace').read():
        die(f'{kdir}: build.log lacks "ISA check ok"')
    kraw = os.path.join(kdir, 'kernel.development.sweet')
    kgz = kraw + '.gz'
    if not os.path.exists(kraw) and not os.path.exists(kgz):
        die(f'{kdir}: no kernel.development.sweet(.gz)')
    # --- base
    bdir = os.path.join(P, base)
    bimg = os.path.join(bdir, f'redfin-{base}.img')
    if not os.path.exists(bimg):
        die(f'no base image {bimg}')
    bsha = sha256(bimg)
    bshaf = os.path.join(bdir, f'redfin-{base}.sha256')
    if os.path.exists(bshaf) and open(bshaf).read().split()[0] != bsha:
        die(f'{bimg} does not match {bshaf}')
    mkb, mkb_ver = tool_dir('mkbootimg')
    avbd, avb_ver = tool_dir('avb')
    avbtool = os.path.join(avbd, 'avbtool.py')
    mp_dir = os.environ.get('MKPAYLOAD_DIR') or os.path.join(os.path.expanduser(os.environ.get('REPO', '~/ios-redfin')), 'tools')
    mkpayload = os.path.join(mp_dir, 'mkpayload.py')
    if not os.path.exists(mkpayload) or not os.path.exists(os.path.join(mp_dir, 'adt.py')):
        die(f'!no mkpayload.py + adt.py in {mp_dir} (set MKPAYLOAD_DIR or REPO)')
    mp_ver = subprocess.run(['git', '-C', mp_dir, 'log', '-1', '--format=%h %cs', '--', 'mkpayload.py'], capture_output=True,
                            text=True).stdout.strip() or 'sha256 ' + sha256(mkpayload)[:12]

    tmp_out = os.path.join(P, f'.{name}.tmp')
    if os.path.lexists(tmp_out):
        shutil.rmtree(tmp_out)
    os.makedirs(tmp_out)
    with tempfile.TemporaryDirectory(prefix='mkimage-') as t:
        # --- the kernel (checked against SHA256SUMS when there is one)
        kern = os.path.join(t, 'kernel.development.sweet')
        if os.path.exists(kraw):
            shutil.copy(kraw, kern)
        else:
            with gzip.open(kgz, 'rb') as f, open(kern, 'wb') as o:
                shutil.copyfileobj(f, o)
        ksha = sha256(kern)
        sums = os.path.join(kdir, 'SHA256SUMS')
        if os.path.exists(sums):
            want = [l.split()[0] for l in open(sums) if l.strip().endswith('kernel.development.sweet')]
            if want and want[0] != ksha:
                die(f'kernel sha256 {ksha} != SHA256SUMS {want[0]}')
        # --- unpack BASE
        u = os.path.join(t, 'u')
        args_text = run([sys.executable, os.path.join(mkb, 'unpack_bootimg.py'), '--boot_img', bimg, '--out', u,
                         '--format=mkbootimg'])
        margs = shlex.split(args_text)
        if '--header_version' not in margs or margs[margs.index('--header_version') + 1] != '3':
            die(f'!{base}: not a boot image v3 ({args_text.strip()[:300]})')
        bpay = open(os.path.join(u, 'ramdisk'), 'rb').read()
        if bpay[:8] != b'SWEETXNU':
            die(f'!{base}: the ramdisk is not a SWEETXNU payload')
        adt_off, adt_size = struct.unpack_from('<2Q', bpay, 0x20)
        adt = bpay[adt_off:adt_off + adt_size]
        if b'RAMDisk' in adt:
            die(f'{base}: its payload carries a ramdisk (ADT memory-map RAMDisk): not supported')
        open(os.path.join(t, 'adt.bin'), 'wb').write(adt)
        bcl = bpay[CMDLINE_OFF:CMDLINE_OFF + BOOT_LINE_LENGTH - 16].split(b'\0', 1)[0].decode()
        ring_va, total_va = struct.unpack_from('<2Q', bpay, RAMLOG_OFF)
        if clfile:
            cl = open(resolve_in_p(clfile), encoding='utf-8').read().strip().splitlines()[0].strip()
        else:
            cl = bcl
        if len(cl.encode()) >= BOOT_LINE_LENGTH - 16:
            die(f'cmdline {len(cl.encode())} bytes: at most {BOOT_LINE_LENGTH - 17}')
        # --- payload (nm stub: ramlog VAs 0, as in r47a)
        stub = os.path.join(t, 'bin')
        os.makedirs(stub)
        with open(os.path.join(stub, 'nm'), 'w') as f:
            f.write('#!/bin/sh\nexit 0\n')
        os.chmod(os.path.join(stub, 'nm'), 0o755)
        env = dict(os.environ, PATH=stub + os.pathsep + os.environ.get('PATH', ''))
        pay = os.path.join(t, 'payload')
        log = run([sys.executable, mkpayload, kern, os.path.join(t, 'adt.bin'), pay, '--cmdline', cl], env=env)
        open(os.path.join(tmp_out, 'mkpayload.log'), 'w').write(log)
        npay = open(pay, 'rb').read()
        if npay[:8] != b'SWEETXNU':
            die('!mkpayload output is not a payload')
        if (ring_va, total_va) != (0, 0):
            print(f'mkimage: note: {base} had ramlog VAs {ring_va:#x} {total_va:#x}; this image has 0 (nm stub)')
        # --- boot image: BASE's header arguments, the new payload as the ramdisk
        rd = margs.index('--ramdisk')
        margs[rd + 1] = pay
        img = os.path.join(t, 'boot.img')
        run([sys.executable, os.path.join(mkb, 'mkbootimg.py')] + margs + ['--output', img])
        # --- AVB footer with BASE's parameters
        bi = avb_info(avbtool, bimg)
        if bi['props'] or bi['descriptors'] != 1 or bi['Algorithm'] != 'NONE':
            die(f'!{base}: AVB footer with properties/descriptors/signing not handled:\n{bi["text"][:800]}')
        part_size = re.match(r'(\d+)', bi['Image size'] or '')
        if not part_size or not bi['Salt'] or not bi['Partition Name']:
            die(f'!{base}: AVB info unreadable:\n{bi["text"][:800]}')
        cmd = [sys.executable, avbtool, 'add_hash_footer', '--image', img, '--partition_size', part_size.group(1),
               '--partition_name', bi['Partition Name'], '--salt', bi['Salt'],
               '--hash_algorithm', bi['Hash Algorithm'] or 'sha256']
        if bi['Rollback Index'] and bi['Rollback Index'] != '0':
            cmd += ['--rollback_index', bi['Rollback Index']]
        run(cmd)
        ni = avb_info(avbtool, img)
        for k in ('Image size', 'Algorithm', 'Hash Algorithm', 'Partition Name', 'Salt', 'Rollback Index', 'Flags'):
            if ni[k] != bi[k]:
                die(f'!AVB footer differs from {base} in {k}: {ni[k]} vs {bi[k]}')
        # --- the shim and header came through unchanged
        u2 = os.path.join(t, 'u2')
        args2 = shlex.split(run([sys.executable, os.path.join(mkb, 'unpack_bootimg.py'), '--boot_img', img, '--out', u2,
                                 '--format=mkbootimg']))
        if open(os.path.join(u2, 'kernel'), 'rb').read() != open(os.path.join(u, 'kernel'), 'rb').read():
            die('!the shim differs from the base after repacking')
        norm = lambda xs: ['<file>' if x.startswith(t) else x for x in xs]   # noqa: E731
        if norm(args2) != norm(margs):
            die(f'!header arguments differ from {base}: {norm(args2)} vs {norm(margs)}')
        isha = sha256(img)
        shutil.move(img, os.path.join(tmp_out, f'redfin-{name}.img'))
    open(os.path.join(tmp_out, f'redfin-{name}.sha256'), 'w').write(f'{isha}  redfin-{name}.img\n')
    open(os.path.join(tmp_out, f'{name}.cmdline'), 'w').write(cl + '\n')
    klog = open(os.path.join(kdir, 'KLOG_PA.txt')).read().strip() if os.path.exists(os.path.join(kdir, 'KLOG_PA.txt')) \
        else 'unknown (no KLOG_PA.txt)'
    build = open(os.path.join(kdir, 'BUILD.txt')).read().strip() if os.path.exists(os.path.join(kdir, 'BUILD.txt')) else ''
    readme = f"""redfin-{name}.img  made {time.strftime('%Y-%m-%d %H:%M:%S %z')} by tools-claude/mkimage.py (local repack)
image sha256   {isha}
base           {base} (redfin-{base}.img sha256 {bsha}): boot header, shim, ADT (GPU firmware, poke script),
               {'payload cmdline' if not clfile else 'cmdline from ' + clfile}, AVB footer parameters (salt {bi['Salt']})
kernel         {os.path.relpath(kdir, P)}/kernel.development.sweet  sha256 {ksha}
KLOG_PA        {klog}
compiler       {open(os.path.join(kdir, 'COMPILER.txt')).read().strip()}
{('build          ' + build.replace(chr(10), chr(10) + '               ')) if build else ''}
cmdline        {name}.cmdline ({len(cl)} bytes){' (differs from the base)' if cl != bcl else ' (= base)'}
ramlog VAs     0 (mkpayload's nm cannot read the Mach-O on Linux; as r47a)
tools          mkpayload.py {mp_ver}; mkbootimg {mkb_ver}; avbtool {avb_ver}
boot           {('RAM only: phone agent `boot ' + name + '` (fastboot boot; checked against the .sha256)') if name.startswith('r') else 'test name (the agent boot action takes r* names only)'}
"""
    open(os.path.join(tmp_out, 'README.txt'), 'w').write(readme)
    os.rename(tmp_out, out_dir)
    print(readme)
    for line in log.splitlines()[:8]:
        print('  mkpayload: ' + line)
    print(f'mkimage: ok -> {name}/redfin-{name}.img')


if __name__ == '__main__':
    main()

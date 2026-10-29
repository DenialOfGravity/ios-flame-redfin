#!/usr/bin/env python3
"""redfin-ram-base.py BASE_IMG SHIM_LZ4|patch OUT_IMG MKBOOTIMG_DIR AVB_DIR

A base image for tools-claude/mkimage.py with the 1033 RAM layout. mkimage keeps BASE's shim and ADT,
so a RAM-layout change needs a base that already has both:
  - the shim: SHIM_LZ4 (builds/shim/<ref>/shim-Image.lz4) replaces BASE's boot "kernel", or with `patch`
    BASE's own shim is kept and only its ramlog constants are moved (shim_patch below: the mailbox
    0x1fbe00000 -> MAILBOX_PA_REDFIN, the mirror 0x1fa000000 -> MIRROR_PA_REDFIN, i.e. shim/ramlog.c at
    ws-y-ram). The local WSL clang does not rebuild r62b's shim byte for byte, so `patch` keeps the
    known-good code and changes 6 instructions.
  - the ADT inside the SWEETXNU payload, patched in place (same size, nothing moves):
      /chosen dram-size  -> mkadt.HIGH_MEM_SIZE (dram-base must be 0x100000000)
      /pram reg          -> <mkadt.PANIC_LOG_PA, 0x80000>
    and the payload header's mem_size (0x40) to match (mkpayload.py writes it from the ADT again anyway)
BASE's header arguments and AVB footer parameters (partition size, name, salt) are kept, as mkimage does.
Name the output so the agent's `boot` refuses it (not r...): it is only a BASE for mkimage, its kernel is BASE's.
"""
import os, shlex, struct, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402
import lz4py  # noqa: E402
import mkadt  # noqa: E402


def shim_patch(lz4):
    """BASE's shim with the ramlog addresses moved: every `mov/movk xN, #0xfbe0|0xfa00, lsl #16` followed within
    three instructions by `movk xN, #0x1, lsl #32` (the 64-bit constants 0x1fbe00000 and 0x1fa000000)."""
    img = bytearray(lz4py.decompress(lz4))
    moves = {0xfbe0: mkadt.MAILBOX_PA_REDFIN, 0xfa00: mkadt.MIRROR_PA_REDFIN}
    want = {0xfbe0: 2, 0xfa00: 1}		# ramlog_arm + ramlog_rescue; ramlog_rescue
    found = dict.fromkeys(moves, 0)
    for a in range(0, len(img) - 16, 4):
        w = struct.unpack_from('<I', img, a)[0]
        # MOVZ/MOVK 64-bit, hw=1 (lsl #16)
        if (w & 0xff800000) not in (0xd2800000, 0xf2800000) or ((w >> 21) & 3) != 1:
            continue
        imm, rd = (w >> 5) & 0xffff, w & 31
        if imm not in moves:
            continue
        for b in range(a + 4, a + 16, 4):
            w2 = struct.unpack_from('<I', img, b)[0]
            if (w2 & 0xff800000) == 0xf2800000 and ((w2 >> 21) & 3) == 2 and (w2 & 31) == rd and ((w2 >> 5) & 0xffff) == 1:
                new = moves[imm]
                assert new & 0xffff == 0 and new >> 48 == 0
                struct.pack_into('<I', img, a, (w & ~(0xffff << 5)) | (((new >> 16) & 0xffff) << 5))
                struct.pack_into('<I', img, b, (w2 & ~(0xffff << 5)) | (((new >> 32) & 0xffff) << 5))
                print(f'shim {a:#x}/{b:#x}: {0x100000000 | imm << 16:#x} -> {new:#x}')
                found[imm] += 1
                break
    if found != want:
        sys.exit(f'shim: expected {want} constant sites, found {found}: not the r47a..r62b shim')
    out = lz4py.frame(bytes(img), (lz4[4], lz4[5], lz4[6]))
    assert lz4py.decompress(out) == bytes(img)
    return out


def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f'{args[0:3]}: exit {r.returncode}\n{r.stdout[-1500:]}{r.stderr[-1500:]}')
    return r.stdout


def find_prop(buf, off, path, prop):
    """Offset of the value of `prop` in node `path` (list of names below the root) of the flat ADT."""
    def walk(off, want):
        nprops, nchildren = struct.unpack_from('<II', buf, off)
        off += 8
        name, hit = None, None
        for _ in range(nprops):
            pname = buf[off:off + 32].split(b'\0')[0].decode()
            ln = struct.unpack_from('<I', buf, off + 32)[0] & 0x7fffffff
            if pname == 'name':
                name = buf[off + 36:off + 36 + ln].split(b'\0')[0].decode()
            if not want and pname == prop:
                hit = (off + 36, ln)
            off += 36 + ((ln + 3) & ~3)
        if not want and hit:
            return hit, off
        found = None
        for _ in range(nchildren):
            cnamed = child_name(off)
            if want and cnamed == want[0]:
                r, off = walk(off, want[1:])
                found = found or r
            else:
                _, off = walk(off, ['\0never'])
        return found, off

    def child_name(off):
        nprops = struct.unpack_from('<I', buf, off)[0]
        off += 8
        for _ in range(nprops):
            pname = buf[off:off + 32].split(b'\0')[0].decode()
            ln = struct.unpack_from('<I', buf, off + 32)[0] & 0x7fffffff
            if pname == 'name':
                return buf[off + 36:off + 36 + ln].split(b'\0')[0].decode()
            off += 36 + ((ln + 3) & ~3)
        return None

    r, _ = walk(off, path)
    if not r:
        sys.exit(f'ADT: no {"/".join(path)} {prop}')
    return r


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    base, shim, out, mkb, avb = sys.argv[1:]
    with tempfile.TemporaryDirectory() as t:
        u = os.path.join(t, 'u')
        margs = shlex.split(run([sys.executable, os.path.join(mkb, 'unpack_bootimg.py'), '--boot_img', base,
                                 '--out', u, '--format=mkbootimg']))
        pay = bytearray(open(os.path.join(u, 'ramdisk'), 'rb').read())
        assert pay[:8] == b'SWEETXNU', 'BASE ramdisk is not a SWEETXNU payload'
        adt_off, adt_size = struct.unpack_from('<2Q', pay, 0x20)
        a = bytes(pay[adt_off:adt_off + adt_size])
        (o, n) = find_prop(a, 0, ['chosen'], 'dram-base')
        assert n == 8 and struct.unpack_from('<Q', a, o)[0] == mkadt.HIGH_PHYS_BASE, 'dram-base is not 4 GiB'
        (o, n) = find_prop(a, 0, ['chosen'], 'dram-size')
        assert n == 8
        old_size = struct.unpack_from('<Q', a, o)[0]
        struct.pack_into('<Q', pay, adt_off + o, mkadt.HIGH_MEM_SIZE)
        (o, n) = find_prop(a, 0, ['pram'], 'reg')
        assert n == 16
        old_pram = struct.unpack_from('<2Q', a, o)
        struct.pack_into('<2Q', pay, adt_off + o, mkadt.PANIC_LOG_PA, mkadt.PANIC_LOG_SIZE)
        assert struct.unpack_from('<Q', pay, 0x38)[0] == mkadt.HIGH_PHYS_BASE
        struct.pack_into('<Q', pay, 0x40, mkadt.HIGH_MEM_SIZE)
        # check with the real parser
        root, _ = adt.parse(bytes(pay[adt_off:adt_off + adt_size]))
        ch = next(c for c in root.children if c.name == 'chosen')
        pr = next(c for c in root.children if c.name == 'pram')
        assert struct.unpack('<Q', ch.prop('dram-size'))[0] == mkadt.HIGH_MEM_SIZE
        assert struct.unpack('<2Q', pr.prop('reg')) == (mkadt.PANIC_LOG_PA, mkadt.PANIC_LOG_SIZE)
        print(f'ADT dram-size {old_size:#x} -> {mkadt.HIGH_MEM_SIZE:#x}; pram {old_pram[0]:#x}+{old_pram[1]:#x} -> '
              f'{mkadt.PANIC_LOG_PA:#x}+{mkadt.PANIC_LOG_SIZE:#x}')
        npay = os.path.join(t, 'payload')
        open(npay, 'wb').write(pay)
        margs[margs.index('--ramdisk') + 1] = npay
        if shim == 'patch':
            shim = os.path.join(t, 'shim.lz4')
            open(shim, 'wb').write(shim_patch(open(os.path.join(u, 'kernel'), 'rb').read()))
        margs[margs.index('--kernel') + 1] = shim
        img = os.path.join(t, 'boot.img')
        run([sys.executable, os.path.join(mkb, 'mkbootimg.py')] + margs + ['--output', img])
        info = run([sys.executable, os.path.join(avb, 'avbtool.py'), 'info_image', '--image', base])
        get = lambda k: next(l.split(':', 1)[1].strip() for l in info.splitlines() if l.strip().startswith(k + ':'))  # noqa: E731
        run([sys.executable, os.path.join(avb, 'avbtool.py'), 'add_hash_footer', '--image', img,
             '--partition_size', get('Image size').split()[0], '--partition_name', get('Partition Name'),
             '--salt', get('Salt'), '--hash_algorithm', get('Hash Algorithm')])
        os.replace(img, out)
    print('wrote', out)


if __name__ == '__main__':
    main()

#!/bin/bash
# dis.sh FILE BASEADDR: raw aarch64 code at BASEADDR, with branch and adrp targets at their real addresses
llvm-objcopy -I binary -O elf64-littleaarch64 --rename-section .data=.text,code "$1" /tmp/dis.o && llvm-objdump -d /tmp/dis.o | python3 -c "
import sys,re
b=int('$2',16)
for l in sys.stdin:
    m=re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)',l)
    if not m: continue
    o=int(m.group(1),16); a=b+o; ins=m.group(3)
    if ins.startswith('adrp'):
        ins=re.sub(r'0x([0-9a-f]+)( <_binary[^>]*>)?', lambda mm: hex((a&~0xfff)+int(mm.group(1),16)-(o&~0xfff)), ins)
    else:
        ins=re.sub(r'0x([0-9a-f]+) <_binary[^>]*>', lambda mm: hex(b+int(mm.group(1),16)), ins)
    try: print(hex(a), ins)
    except BrokenPipeError: break
"

#!/usr/bin/env python3
"""Run one step of UniXNU's scripts/linux/setup-toolchain.py as the user, into our prefix (no root, no /usr/bin shims).
   tc.py UNIXNU_DIR PREFIX STEP      STEP: check llvm cctools mig iig hostcc
"""
import importlib.util, os, sys
from pathlib import Path

ux, prefix, step = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location('ux_setup', ux / 'scripts/linux/setup-toolchain.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
host = m.host_tools(None)
clt, xct = prefix / 'CommandLineTools/usr', prefix / 'XcodeDefault.xctoolchain/usr'
include = clt.parent / 'SDKs/MacOSX.sdk/usr/include'
work = prefix / 'build-work'
work.mkdir(parents=True, exist_ok=True)
jobs = int(os.environ.get('JOBS', os.cpu_count() or 4))
if step == 'check':
    print(f'host clang {host.cc}, llvm-config {host.config}, resource {host.resource}')
elif step == 'llvm':
    print(m.llvm(prefix, work, jobs, host))
elif step == 'cctools':
    m.cctools(clt, include, work, jobs, host)
elif step == 'mig':
    m.mig(clt, include, work, host)
elif step == 'iig':
    m.iig(xct, work, host)
elif step == 'hostcc':
    m.host_cc(clt, include, host)
else:
    sys.exit(f'unknown step {step}')

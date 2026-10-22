#!/usr/bin/env python3
"""Files on the running phone (bsd/dev/sweet_files.c, TCP 2223 via FlameBridge 127.0.0.1:2223).

  tools/flame-files.py put LOCAL REMOTE [MODE]     (mode octal, default from LOCAL)
  tools/flame-files.py get REMOTE LOCAL
  tools/flame-files.py read REMOTE OFFSET LEN LOCAL   (range; works on devices: /dev/pmem at a PA)
  tools/flame-files.py mkdir REMOTE [MODE]
  tools/flame-files.py link TARGET REMOTE          (symlink)
  tools/flame-files.py rm REMOTE
  tools/flame-files.py chmod REMOTE MODE
"""
import os, socket, stat, sys

HOST, PORT = '127.0.0.1', 2223


def conn():
    s = socket.create_connection((HOST, PORT), timeout=30)
    return s


def reply(s):
    line = b''
    while not line.endswith(b'\n'):
        c = s.recv(1)
        if not c:
            raise SystemExit('connection closed without a reply')
        line += c
    line = line.decode().strip()
    if not line.startswith('OK'):
        raise SystemExit(f'phone: {line}')
    return line


def read_range(s, path, off, n):
    """READ (kernel 0094+): n bytes of path at off; one request per connection."""
    s.sendall(f'READ {path} {off} {n}\n'.encode())
    n = int(reply(s).split()[1])
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(min(1 << 20, n - len(buf)))
        if not chunk:
            raise SystemExit(f'short read: {len(buf)} of {n} bytes')
        buf += chunk
    return bytes(buf)


def main(argv):
    if not argv:
        raise SystemExit(__doc__)
    cmd, args = argv[0], argv[1:]
    s = conn()
    if cmd == 'put':
        local, remote = args[0], args[1]
        mode = int(args[2], 8) if len(args) > 2 else stat.S_IMODE(os.stat(local).st_mode)
        data = open(local, 'rb').read()
        s.sendall(f'PUT {remote} {mode:o} {len(data)}\n'.encode() + data)
        print(remote, reply(s))
    elif cmd == 'get':
        s.sendall(f'GET {args[0]}\n'.encode())
        n = int(reply(s).split()[1])
        buf = bytearray()
        while len(buf) < n:
            chunk = s.recv(min(65536, n - len(buf)))
            if not chunk:
                raise SystemExit('short read')
            buf += chunk
        open(args[1], 'wb').write(buf)
        print(args[0], n, 'bytes ->', args[1])
    elif cmd == 'read':
        data = read_range(s, args[0], int(args[1], 0), int(args[2], 0))
        open(args[3], 'wb').write(data)
        print(args[0], len(data), 'bytes ->', args[3])
    elif cmd in ('mkdir', 'link', 'rm', 'chmod'):
        verb = {'mkdir': 'MKDIR', 'link': 'LINK', 'rm': 'RM', 'chmod': 'CHMOD'}[cmd]
        if cmd == 'mkdir' and len(args) == 1:
            args = args + ['755']
        s.sendall(f'{verb} {" ".join(args)}\n'.encode())
        print(cmd, ' '.join(args), reply(s))
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])

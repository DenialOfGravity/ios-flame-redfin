"""Pure-Python LZ4 frame (de)compression for the shim slot of boot images (no lz4 module or binary needed).
frame(data, (flg, bd, hc)) compresses as one block with content checksum (flg 0x64, as lz4 -B7 -9 writes); decompress(d)."""
import struct
P1,P2,P3,P4,P5=2654435761,2246822519,3266489917,668265263,374761393
M=0xffffffff
def rotl(x,r): return ((x<<r)|(x>>(32-r)))&M
def xxh32(b,seed=0):
    n=len(b); i=0
    if n>=16:
        v=[(seed+P1+P2)&M,(seed+P2)&M,seed&M,(seed-P1)&M]
        while i+16<=n:
            for k in range(4):
                x=struct.unpack_from('<I',b,i+4*k)[0]
                v[k]=(rotl((v[k]+x*P2)&M,13)*P1)&M
            i+=16
        h=(rotl(v[0],1)+rotl(v[1],7)+rotl(v[2],12)+rotl(v[3],18))&M
    else: h=(seed+P5)&M
    h=(h+n)&M
    while i+4<=n:
        h=(rotl((h+struct.unpack_from('<I',b,i)[0]*P3)&M,17)*P4)&M; i+=4
    while i<n:
        h=(rotl((h+b[i]*P5)&M,11)*P1)&M; i+=1
    h^=h>>15; h=(h*P2)&M; h^=h>>13; h=(h*P3)&M; h^=h>>16
    return h
def block(src):
    n=len(src); out=bytearray(); anchor=0; i=0; table={}
    mflimit=n-12; last_lit=n-5
    def emit(lit,mlen,off):
        L=len(lit); tok=(min(L,15)<<4)|(min(mlen-4,15) if mlen else 0)
        out.append(tok)
        if L>=15:
            r=L-15
            while r>=255: out.append(255); r-=255
            out.append(r)
        out.extend(lit)
        if mlen:
            out.extend(struct.pack('<H',off)); r=mlen-4
            if r>=15:
                r-=15
                while r>=255: out.append(255); r-=255
                out.append(r)
    while i<mflimit:
        seq=src[i:i+4]; c=table.get(seq); table[seq]=i
        if c is not None and i-c<65536:
            m=4
            while i+m<last_lit and src[c+m]==src[i+m]: m+=1
            emit(src[anchor:i],m,i-c); i+=m; anchor=i
            # index a couple of positions inside the match for better ratio
            if i-2>0 and i-2<mflimit: table[src[i-2:i+2]]=i-2
        else: i+=1
    emit(src[anchor:],0,0)
    return bytes(out)
def frame(data, flg_bd_hc):
    flg,bd,hc=flg_bd_hc
    assert flg==0x64
    b=block(data)
    return struct.pack('<I',0x184D2204)+bytes([flg,bd,hc])+struct.pack('<I',len(b))+b+struct.pack('<I',0)+struct.pack('<I',xxh32(data))
import struct,sys
def _dblock(src,out):
    i=0;n=len(src)
    while i<n:
        t=src[i];i+=1;l=t>>4
        if l==15:
            while True:
                b=src[i];i+=1;l+=b
                if b!=255:break
        out+=src[i:i+l];i+=l
        if i>=n:break
        off=src[i]|src[i+1]<<8;i+=2;m=t&15
        if m==15:
            while True:
                b=src[i];i+=1;m+=b
                if b!=255:break
        m+=4;s=len(out)-off
        for k in range(m): out.append(out[s+k])
def decompress(d):
    out=bytearray();i=0
    while i<len(d):
        mg=struct.unpack_from('<I',d,i)[0]
        if mg==0x184C2102:  # legacy
            i+=4
            while i<len(d):
                sz=struct.unpack_from('<I',d,i)[0]
                if sz==0x184C2102 or i+4>len(d): break
                i+=4;_dblock(d[i:i+sz],out);i+=sz
            continue
        assert mg==0x184D2204,hex(mg)
        flg=d[i+4];i+=6+(8 if flg&8 else 0)+1
        while True:
            sz=struct.unpack_from('<I',d,i)[0];i+=4
            if sz==0:break
            raw=sz&0x80000000;sz&=0x7fffffff
            if raw: out+=d[i:i+sz]
            else: _dblock(d[i:i+sz],out)
            i+=sz+(4 if flg&0x10 else 0)
        if flg&4:i+=4
    return bytes(out)

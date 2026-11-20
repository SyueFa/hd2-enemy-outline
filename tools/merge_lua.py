# Append one Lua resource to an existing HD2 patch archive (ToC grows, data shifts, GPU file untouched).
import struct,sys
import os; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__))); from murmur import murmur64a
LUA=0xA14E8DFA2CD117E2
src_patch,lua_path,out=sys.argv[1:4]
d=open(src_patch,'rb').read()
magic,ntypes,nfiles=struct.unpack_from('<III',d,0)
assert magic==0xF0000011
HDR=0x48
types=[bytearray(d[HDR+i*32:HDR+i*32+32]) for i in range(ntypes)]
rbase=HDR+ntypes*32
rows=[bytearray(d[rbase+i*80:rbase+i*80+80]) for i in range(nfiles)]
old_toc_end=rbase+nfiles*80
old_data_start=min(struct.unpack_from('<Q',r,16)[0] for r in rows if struct.unpack_from('<I',r,56)[0]>0)
assert all(struct.unpack_from('<Q',t,8)[0]!=LUA for t in types), 'already has lua'
new_toc_end=old_toc_end+32+80
shift=((new_toc_end+15)&~15)-old_data_start
assert shift%16==0 and shift>0
source=open(lua_path,'rb').read()
first=source.split(b'\n',1)[0].strip(); assert first.startswith(b'-- HD2-Addon: ')
name=first[len(b'-- HD2-Addon: '):].decode().strip()
lua_data=struct.pack('<II',len(source),2)+source
for r in rows:
    off=struct.unpack_from('<Q',r,16)[0]
    struct.pack_into('<Q',r,16,off+shift)
body=bytearray(d[old_data_start:])
body+=b'\0'*(-(old_data_start+shift+len(body))%16)
lua_off=old_data_start+shift+len(body)
max_index=max(struct.unpack_from('<I',r,76)[0] for r in rows)
lua_row=struct.pack('<7Q6I',murmur64a(name),LUA,lua_off,0,0,0,0,len(lua_data),0,0,16,16,max_index+1)
lua_type=struct.pack('<IIQIIII',0,0,LUA,1,0,16,16)
header=bytearray(d[:HDR]); struct.pack_into('<II',header,4,ntypes+1,nfiles+1)
toc=bytes(header)+b''.join(types)+lua_type+b''.join(rows)+lua_row
pad=(old_data_start+shift)-len(toc); assert pad>=0
outb=toc+b'\0'*pad+bytes(body)+lua_data
outb+=b'\0'*(-len(outb)%16)
open(out,'wb').write(outb)
print('name',name,'%016x'%murmur64a(name),'shift',shift,'size',len(d),'->',len(outb))

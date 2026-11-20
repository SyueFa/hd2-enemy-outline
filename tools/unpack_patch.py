"""Unpack an HD2 / Stingray patch archive into one file per resource + index.json.

usage: python tools/unpack_patch.py <patch_0> <out_dir> [names.json]

out_dir/
  index.json                 header, type table, every resource row (offsets kept so
                             pack_patch.py can rebuild the archive byte for byte)
  <type>/<name>.main         main data      (patch_0)
  <type>/<name>.gpu          GPU data       (patch_0.gpu_resources), when present
  <type>/<name>.stream       stream data    (patch_0.stream), when present
<name> is the resource path when known (from names.json: {hash_hex: path}),
otherwise the 16-digit hash; '/' in a path becomes '__'.
"""
import json,os,struct,sys
TYPES={0x931e336d7646cc26:'animation',0x18dead01056b72e9:'bones',0x5f7203c8f280dab8:'physics',
       0xa486d4045106165c:'state_machine',0x1d59bd6687db6b33:'ragdoll_profile',0xcd4238c6a0c69e32:'texture',
       0xeac0b497876adedf:'material',0xe0a48d0be9a7453f:'unit',0xa14e8dfa2cd117e2:'lua'}

def read(p):
    return open(p,'rb').read() if os.path.exists(p) else b''

def main(patch,out,names_path=None):
    names={}
    if names_path:
        raw=json.load(open(names_path,encoding='utf-8'))
        names={k:(v['name'] if isinstance(v,dict) else v) for k,v in raw.items() if (v['name'] if isinstance(v,dict) else v)}
    d=read(patch); g=read(patch+'.gpu_resources'); s=read(patch+'.stream')
    magic,nt,nf=struct.unpack_from('<III',d,0); assert magic==0xF0000011
    header=d[:0x48].hex()
    types=[list(struct.unpack_from('<IIQIIII',d,0x48+i*32)) for i in range(nt)]
    base=0x48+nt*32
    idx={'header':header,'types':[[t[0],t[1],'%016x'%t[2]]+t[3:] for t in types],
         'size':{'main':len(d),'gpu':len(g),'stream':len(s)},'resources':[]}
    for i in range(nf):
        r=struct.unpack_from('<7Q6I',d,base+i*80)
        h='%016x'%r[0]; tname=TYPES.get(r[1],'%016x'%r[1])
        stem=names.get(h,h).replace('/','__')
        rel=tname+'/'+stem
        os.makedirs(os.path.join(out,tname),exist_ok=True)
        open(os.path.join(out,rel+'.main'),'wb').write(d[r[2]:r[2]+r[7]])
        if r[9]: open(os.path.join(out,rel+'.gpu'),'wb').write(g[r[4]:r[4]+r[9]])
        if r[8]: open(os.path.join(out,rel+'.stream'),'wb').write(s[r[3]:r[3]+r[8]])
        idx['resources'].append({'file':rel,'name':names.get(h),'hash':h,'type':'%016x'%r[1],
            'row':list(r[2:7])+list(r[7:])})   # data_off,stream_off,gpu_off,u1,u2,sizes...,align,idx
    json.dump(idx,open(os.path.join(out,'index.json'),'w',encoding='utf-8'),ensure_ascii=False,indent=1)
    print('%d resources -> %s'%(nf,out))

if __name__=='__main__': main(*sys.argv[1:])

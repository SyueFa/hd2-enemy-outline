"""Rebuild a patch archive from a folder made by unpack_patch.py.

usage: python tools/pack_patch.py <unpacked_dir> <out_patch_0>

Writes <out>, <out>.gpu_resources and <out>.stream. Every resource goes back to the offset
recorded in index.json; gaps are zero-filled. If a resource file changed size, edit the
offsets in index.json (or regenerate them) before packing; the script refuses overlaps.
"""
import json,os,struct,sys

def main(src,out):
    idx=json.load(open(os.path.join(src,'index.json'),encoding='utf-8'))
    main_=bytearray(idx['size']['main']); gpu=bytearray(idx['size']['gpu']); stream=bytearray(idx['size']['stream'])
    main_[0:0x48]=bytes.fromhex(idx['header'])
    for i,t in enumerate(idx['types']):
        struct.pack_into('<IIQIIII',main_,0x48+i*32,t[0],t[1],int(t[2],16),*t[3:])
    base=0x48+len(idx['types'])*32
    used=[]
    def put(buf,off,data,what):
        end=off+len(data)
        if end>len(buf): raise SystemExit('%s does not fit (size changed?)'%what)
        buf[off:end]=data
    for i,r in enumerate(idx['resources']):
        row=r['row']   # data_off,stream_off,gpu_off,u1,u2,data_sz,stream_sz,gpu_sz,a,galign,index
        p=os.path.join(src,r['file'])
        md=open(p+'.main','rb').read()
        if len(md)!=row[5]: raise SystemExit(r['file']+'.main size changed: update index.json')
        put(main_,row[0],md,r['file'])
        if row[7]: put(gpu,row[2],open(p+'.gpu','rb').read(),r['file']+'.gpu')
        if row[6]: put(stream,row[1],open(p+'.stream','rb').read(),r['file']+'.stream')
        struct.pack_into('<7Q6I',main_,base+i*80,int(r['hash'],16),int(r['type'],16),*row)
    open(out,'wb').write(main_); open(out+'.gpu_resources','wb').write(gpu); open(out+'.stream','wb').write(stream)
    print('packed %d resources -> %s'%(len(idx['resources']),out))

if __name__=='__main__': main(*sys.argv[1:])

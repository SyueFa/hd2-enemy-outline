M=0xc6a4a7935bd1e995; MASK=(1<<64)-1
def murmur64a(data,seed=0):
    if isinstance(data,str): data=data.encode()
    r=47; n=len(data); h=(seed^(n*M))&MASK
    for i in range(0,n-n%8,8):
        k=int.from_bytes(data[i:i+8],'little')
        k=(k*M)&MASK; k^=k>>r; k=(k*M)&MASK
        h^=k; h=(h*M)&MASK
    t=data[n-n%8:]
    if t:
        h^=int.from_bytes(t,'little'); h=(h*M)&MASK
    h^=h>>r; h=(h*M)&MASK; h^=h>>r
    return h

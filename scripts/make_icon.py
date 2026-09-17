"""Draw the app's simple wave mark without external asset dependencies."""
import math,struct,zlib,json
from pathlib import Path
p=Path('HydroTone/Resources/Assets.xcassets/AppIcon.appiconset')
rows=[]
for y in range(1024):
    row=bytearray([0])
    for x in range(1024):
        color=(8,28,34)
        for offset in [342,502,662]:
            wave=offset+45*math.sin((x-240)*2*math.pi/540)
            distance=abs(y-wave)
            edge=max(0,abs(x-512)-282)
            alpha=max(0,min(1,24-math.hypot(distance,edge)))
            color=tuple(round(a*(1-alpha)+b*alpha) for a,b in zip(color,(106,230,200)))
        row.extend(color)
    rows.append(row)
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
(p/'AppIcon.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1024,1024,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b''))
(p/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
(p.parent/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}')

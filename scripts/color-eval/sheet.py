import sys, glob, os
from PIL import Image, ImageDraw
d, out = sys.argv[1], sys.argv[2]
vs = ["original","current","combined","uniform","restoration","reference"]
names = sorted({os.path.basename(p).rsplit("__",1)[0] for p in glob.glob(d+"/*.jpg")})
names = names[:int(sys.argv[3])] if len(sys.argv)>3 else names
W=300
rows=[]
for n in names:
    ims=[Image.open(f"{d}/{n}__{v}.jpg") for v in vs if os.path.exists(f"{d}/{n}__{v}.jpg")]
    h=int(ims[0].height*W/ims[0].width)
    rows.append([i.resize((W,h)) for i in ims])
H=sum(r[0].height for r in rows)+20
sheet=Image.new("RGB",(W*len(vs),H),"white"); dr=ImageDraw.Draw(sheet)
for i,v in enumerate(vs): dr.text((i*W+5,4),v,fill="black")
y=20
for r in rows:
    for i,im in enumerate(r): sheet.paste(im,(i*W,y))
    y+=r[0].height
sheet.save(out,quality=85)

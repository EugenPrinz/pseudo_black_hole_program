import sys
from PIL import Image, ImageDraw, ImageFont
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
W, H = map(int, lines[0].split('\t'))
cw, ch = 10, 20
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 16)
img = Image.new('RGB', (W*cw, H*ch), (10,10,18))
d = ImageDraw.Draw(img)
def rgb(v): v=int(float(v)); return ((v>>16)&255,(v>>8)&255,v&255)
for ln in lines[1:]:
    if not ln: continue
    y,x,fg,bg,c = ln.split('\t',4)
    x,y=int(x)-1,int(y)-1
    d.rectangle([x*cw,y*ch,x*cw+cw-1,y*ch+ch-1], fill=rgb(bg))
    if c.strip(): d.text((x*cw, y*ch+1), c, font=font, fill=rgb(fg))
img.save(dst)

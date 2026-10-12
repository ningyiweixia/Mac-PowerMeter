#!/usr/bin/env python3
"""生成可由 Apple Icon Composer 打开的原生分层 .icon 源文件。"""
import json, math
from pathlib import Path
root=Path(__file__).resolve().parent/'AppIcon.icon'
assets=root/'Assets'
assets.mkdir(parents=True,exist_ok=True)
def xy(a,r=300):
    a=math.radians(a)
    return f'{512+r*math.cos(a):.2f} {480+r*math.sin(a):.2f}'
def svg(name,body):
    (assets/name).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>')
svg('Dial.svg',f'<path d="M {xy(140)} A 300 300 0 1 1 {xy(400)}" fill="none" stroke="#415565" stroke-width="40" stroke-linecap="round"/>'+''.join(f'<path d="M {xy(a,237)} L {xy(a,215)}" stroke="#96ACBA" stroke-width="7"/>' for a in [150,190,230,270,310,350,390]))
svg('PowerArc.svg',f'<path d="M {xy(140)} A 300 300 0 0 1 {xy(317)}" fill="none" stroke="#41D6C8" stroke-width="40" stroke-linecap="round"/>')
svg('Needle.svg','<path d="M 657 344 L 524 504 L 491 473 Z" fill="#E8F7F9"/><circle cx="512" cy="480" r="34" fill="#E8F7F9"/><circle cx="512" cy="480" r="14" fill="#263D4B"/><path d="M 460 731 L 483 811 L 512 745 L 541 811 L 564 731" fill="none" stroke="#E8F7F9" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>')
manifest={
 'fill':{'automatic-gradient':'extended-srgb:0.08,0.13,0.18,1.0'},
 'groups':[
  {'name':'Dial','layers':[{'image-name':'Dial.svg','name':'Dial'}], 'shadow':{'kind':'neutral','opacity':0.15},'specular':False},
  {'name':'Power arc','layers':[{'image-name':'PowerArc.svg','name':'Power arc'}], 'shadow':{'kind':'layer-color','opacity':0.25},'specular':False, 'translucency':{'enabled':False,'value':0}},
  {'name':'Needle','layers':[{'image-name':'Needle.svg','name':'Needle'}], 'shadow':{'kind':'neutral','opacity':0.25},'specular':False, 'translucency':{'enabled':False,'value':0}}
 ],
 'supported-platforms':{'squares':'shared'}
}
(root/'icon.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(root)

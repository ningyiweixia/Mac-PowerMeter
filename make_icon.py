#!/usr/bin/env python3
"""可复现的 macOS 功率计图标：石墨底、青绿色仪表、无闪电。
使用 3 倍超采样生成 1024px 透明 PNG，输出相对脚本路径。
"""
from pathlib import Path
from math import cos, sin, radians, hypot
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE, SCALE = 1024, 3
N = SIZE * SCALE

def box(bounds):
    return tuple(round(v * SCALE) for v in bounds)

def point(x, y):
    return round(x * SCALE), round(y * SCALE)

# 微弱上方照明：留出清晰的形状，避免堆叠玻璃特效。
background = Image.new('RGBA', (SIZE, SIZE))
pixels = background.load()
for y in range(SIZE):
    for x in range(SIZE):
        light = max(0, 1 - hypot((x-350)/850, (y-140)/900))
        pixels[x, y] = (int(22+23*light), int(28+26*light), int(36+31*light), 255)
background = background.resize((N, N), Image.Resampling.BICUBIC)
mask = Image.new('L', (N,N))
ImageDraw.Draw(mask).rounded_rectangle(box((100,100,924,924)), radius=185*SCALE, fill=255)
background.putalpha(mask)
image = Image.new('RGBA', (N,N))
shadow = Image.new('RGBA', (N,N))
shadow_mask = Image.new('L', (N,N))
ImageDraw.Draw(shadow_mask).rounded_rectangle(box((106,120,918,936)), radius=183*SCALE, fill=90)
shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(14*SCALE)))
image.alpha_composite(shadow)
image.alpha_composite(background)
draw = ImageDraw.Draw(image)

cx, cy, radius = 512, 506, 258
start, end = 140, 400
outer_radius = radius + 18  # Pillow 的弧线描边向内扩展，保持圆端与线的中轴一致。
bounds = box((cx-outer_radius, cy-outer_radius, cx+outer_radius, cy+outer_radius))
draw.arc(bounds, start, end, fill=(63, 79, 91, 255), width=36*SCALE)
# 用圆端点和连续渐变形成单一仪表弧。
active_end = 317
for angle in range(start, active_end):
    t = (angle-start)/(active_end-start)
    color = (int(38+63*t), int(195+38*t), int(173+53*t), 255)
    draw.arc(bounds, angle, angle+1.5, fill=color, width=36*SCALE)
for angle, color in [(start, (38,195,173,255)), (active_end, (101,233,226,255)),
                     (end, (63,79,91,255))]:
    x,y = cx+radius*cos(radians(angle)), cy+radius*sin(radians(angle))
    draw.ellipse(box((x-18,y-18,x+18,y+18)), fill=color)

# 少量宽刻度在小尺寸下也易识别。
for angle in (150, 190, 230, 270, 310, 350, 390):
    a = radians(angle)
    p1 = point(cx+202*cos(a), cy+202*sin(a))
    p2 = point(cx+183*cos(a), cy+183*sin(a))
    draw.line((p1,p2), fill=(139,163,177,210), width=6*SCALE)

# 指针指向右上，圆形轴心形成仪器识别特征。
a = radians(317)
tip = (cx+176*cos(a), cy+176*sin(a))
base = (cx-25*cos(a), cy-25*sin(a))
normal = (-sin(a)*12, cos(a)*12)
draw.polygon([point(*tip), point(base[0]+normal[0],base[1]+normal[1]),
              point(base[0]-normal[0],base[1]-normal[1])], fill=(240,248,250,255))
draw.ellipse(box((cx-30,cy-30,cx+30,cy+30)), fill=(228,242,246,255))
draw.ellipse(box((cx-12,cy-12,cx+12,cy+12)), fill=(42,58,70,255))

font = ImageFont.truetype('/System/Library/Fonts/SFNSRounded.ttf', 112*SCALE)
draw.text(point(512,716), 'W', font=font, anchor='mm', fill=(231,243,247,255))
output = Path(__file__).resolve().with_name('AppIcon_1024.png')
image.resize((SIZE,SIZE), Image.Resampling.LANCZOS).save(output)
print(f'图标已生成：{output}')

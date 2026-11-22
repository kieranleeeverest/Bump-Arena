"""Diagnostic overlays only; the source arena PNG is never rewritten."""
from __future__ import annotations

import importlib.util
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SKIN = ROOT / "prototype/assets/arena/arena_nebula_crystal_final.png"
SPEC = importlib.util.spec_from_file_location("fit_preview", ROOT / "diagnostics/final_skin_2026-11-22/fit_preview.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)
old_corners = list(mod.CORNERS)
old_outline, old_joints = mod.build()
mod.CORNERS = [(120, 347), (512, 254), (904, 347), *old_corners[3:]]
new_outline, new_joints = mod.build()

skin = Image.open(SKIN).convert("RGB")
assert skin.size == (1024, 1536)
full = skin.copy()
d = ImageDraw.Draw(full)
d.line(old_outline + [old_outline[0]], fill=(255, 87, 150), width=2)
d.line(new_outline + [new_outline[0]], fill=(123, 255, 105), width=2)
for point in old_joints[:8]:
    d.ellipse((point[0]-3, point[1]-3, point[0]+3, point[1]+3), fill=(255, 87, 150))
for point in new_joints[:8]:
    d.ellipse((point[0]-3, point[1]-3, point[0]+3, point[1]+3), fill=(255, 235, 100))
full.save(HERE / "skin_old_new_full.png")

top = full.crop((20, 135, 1004, 435)).resize((1968, 600))
draw = ImageDraw.Draw(top)
draw.rectangle((8, 8, 760, 60), fill=(18, 12, 42))
draw.text((20, 20), "OLD pink / NEW green / joins yellow | source PNG x2", fill=(255, 255, 255))
top.save(HERE / "top_old_new_2x.png")
join_boxes = [
    ("upper left", (55, 275, 195, 405)),
    ("top main", (430, 155, 594, 325)),
    ("upper right", (830, 275, 970, 405)),
]
join_collage = Image.new("RGB", (1840, 700), (18, 12, 42))
for (label, box), left in zip(join_boxes, [0, 560, 1240]):
    crop = full.crop(box).resize(((box[2]-box[0])*4, (box[3]-box[1])*4))
    join_collage.paste(crop, (left, 50))
    ImageDraw.Draw(join_collage).text((left+8, 14), label, fill=(255,255,255))
join_collage.save(HERE / "top_three_joins_4x.png")

def side_arc(draw: ImageDraw.ImageDraw, center, radius, mirror, color, begin, end, width=3):
    points = []
    for k in range(81):
        a = math.radians(begin + (end-begin)*k/80)
        points.append((center[0] + math.cos(a)*mirror[0]*radius,
                       center[1] + math.sin(a)*mirror[1]*radius))
    draw.line(points, fill=color, width=width)

sectors = skin.copy()
d = ImageDraw.Draw(sectors)
for index, center, mirror, accessible in [
    (0, (107,337), (1,1), (30,46)),
    (2, (917,337), (-1,1), (30,46)),
    (3, (107,1134), (1,-1), (31,46)),
    (5, (917,1134), (-1,-1), (31,46)),
]:
    radius = 34
    d.ellipse((center[0]-radius, center[1]-radius, center[0]+radius, center[1]+radius), outline=(255,255,255), width=2)
    side_arc(d, center, radius+5, mirror, (77,228,255), 23, 67)
    side_arc(d, center, radius+10, mirror, (255,200,82), 0, 70)
    side_arc(d, center, radius+15, mirror, (255,96,150), -5, 75)
    side_arc(d, center, radius+20, mirror, (115,255,110), *accessible)
    d.ellipse((center[0]-2,center[1]-2,center[0]+2,center[1]+2), fill=(255,255,255))
sectors.save(HERE / "four_side_tower_sectors.png")
arc_collage = Image.new("RGB", (800, 860), (18, 12, 42))
for label, box, left, top_y in [
    ("UL", (57, 287, 157, 387), 0, 30),
    ("UR", (867, 287, 967, 387), 400, 30),
    ("LL", (57, 1084, 157, 1184), 0, 445),
    ("LR", (867, 1084, 967, 1184), 400, 445),
]:
    crop = sectors.crop(box).resize((400,400))
    arc_collage.paste(crop, (left, top_y))
    ImageDraw.Draw(arc_collage).text((left+8, top_y+8), label, fill=(255,255,255))
arc_collage.save(HERE / "four_side_sectors_4x.png")
print("OLD top corners", old_corners[:3], "NEW", mod.CORNERS[:3])
for label, index in [("UL-main",0),("main-UR",1)]:
    print(label, "old", [tuple(round(v,2) for v in p) for p in old_joints[index*4:index*4+4]],
          "new", [tuple(round(v,2) for v in p) for p in new_joints[index*4:index*4+4]])

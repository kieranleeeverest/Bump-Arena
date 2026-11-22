from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "prototype/assets/arena/arena_nebula_crystal_final.png"
OUT = Path(__file__).resolve().parent

# All points are in untouched 1024 x 1536 artwork pixels.
CORNERS = [(120, 347), (512, 243), (904, 347), (904, 1121), (512, 1230), (120, 1121)]
CENTERS = [(107, 337), (512, 239), (917, 337), (917, 1134), (512, 1240), (107, 1134)]
RADII = [34, 49, 34, 34, 49, 34]
TOWER_ORDER = [0, 1, 2, 3, 4, 5]
ARC_STEP = 2.0
BLEND = 10.0
SIDE_BLEND = 6.0


def add(a, b):
    return a[0] + b[0], a[1] + b[1]


def sub(a, b):
    return a[0] - b[0], a[1] - b[1]


def mul(a, k):
    return a[0] * k, a[1] * k


def norm(v):
    d = math.hypot(*v)
    return v[0] / d, v[1] / d


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def cut(corner, neighbor, center, radius):
    direction = norm(sub(neighbor, corner))
    relative = sub(corner, center)
    along = -dot(relative, direction)
    distance = along + math.sqrt(max(0, along * along + radius * radius - dot(relative, relative)))
    return add(corner, mul(direction, distance))


def circle(center, radius, angle):
    return center[0] + math.cos(angle) * radius, center[1] + math.sin(angle) * radius


def cubic(outline, a, ca, cb, b):
    count = max(3, math.ceil(math.dist(a, b) / ARC_STEP))
    for i in range(1, count + 1):
        t = i / count
        u = 1 - t
        outline.append(add(add(mul(a, u**3), mul(ca, 3 * u * u * t)), add(mul(cb, 3 * u * t * t), mul(b, t**3))))


def build():
    entries, exits, starts, ends, angles_start, angles_end = [], [], [], [], [], []
    for i, corner in enumerate(CORNERS):
        center, radius = CENTERS[i], RADII[i]
        blend = BLEND if radius > 40.0 else SIDE_BLEND
        entry = cut(corner, CORNERS[(i - 1) % 6], center, radius)
        exit_point = cut(corner, CORNERS[(i + 1) % 6], center, radius)
        start = math.atan2(entry[1] - center[1], entry[0] - center[0])
        end = math.atan2(exit_point[1] - center[1], exit_point[0] - center[0])
        while end >= start:
            end -= math.tau
        start -= blend / radius
        end += blend / radius
        entries.append(entry)
        exits.append(exit_point)
        angles_start.append(start)
        angles_end.append(end)
        starts.append(circle(center, radius, start))
        ends.append(circle(center, radius, end))
    outline = [starts[0]]
    joints = []
    for i in range(6):
        nxt = (i + 1) % 6
        center, radius = CENTERS[i], RADII[i]
        count = max(2, math.ceil(radius * (angles_start[i] - angles_end[i]) / ARC_STEP))
        for j in range(1, count):
            angle = angles_start[i] + (angles_end[i] - angles_start[i]) * j / count
            outline.append(circle(center, radius, angle))
        outline.append(ends[i])
        direction = norm(sub(entries[nxt], exits[i]))
        blend_out = BLEND if RADII[i] > 40.0 else SIDE_BLEND
        blend_in = BLEND if RADII[nxt] > 40.0 else SIDE_BLEND
        line_start = add(exits[i], mul(direction, blend_out))
        line_end = sub(entries[nxt], mul(direction, blend_in))
        tangent_out = (math.sin(angles_end[i]), -math.cos(angles_end[i]))
        tangent_in = (math.sin(angles_start[nxt]), -math.cos(angles_start[nxt]))
        cubic(outline, ends[i], add(ends[i], mul(tangent_out, blend_out * 0.5)), sub(line_start, mul(direction, blend_out * 0.5)), line_start)
        outline.append(line_end)
        cubic(outline, line_end, add(line_end, mul(direction, blend_in * 0.5)), sub(starts[nxt], mul(tangent_in, blend_in * 0.5)), starts[nxt])
        joints.extend([ends[i], line_start, line_end, starts[nxt]])
    outline.pop()
    return outline, joints


def render():
    image = Image.open(SOURCE).convert("RGB")
    outline, joints = build()
    overlay = image.copy()
    draw = ImageDraw.Draw(overlay)
    draw.line(outline + [outline[0]], fill=(145, 255, 95), width=3, joint="curve")
    for center, radius in zip(CENTERS, RADII):
        draw.ellipse((center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius), outline=(70, 235, 255), width=2)
        draw.ellipse((center[0] - 3, center[1] - 3, center[0] + 3, center[1] + 3), fill=(255, 80, 80))
    for x, y in joints:
        draw.ellipse((x - 3, y - 3, x + 3, y + 3), fill=(255, 220, 80))
    overlay.save(OUT / "complete_overlay.png")
    for name, box in {
        "top_main": (410, 175, 615, 335),
        "bottom_main": (410, 1160, 615, 1315),
        "top_left": (65, 280, 225, 430),
        "top_right": (800, 280, 960, 430),
        "bottom_left": (65, 1050, 225, 1215),
        "bottom_right": (800, 1050, 960, 1215),
    }.items():
        crop = overlay.crop(box)
        crop.resize((crop.width * 3, crop.height * 3)).save(OUT / f"{name}_overlay.png")
    print(f"points={len(outline)}, closes={math.dist(outline[-1], outline[0]):.2f} px")
    for i, (entry, exit_point) in enumerate(zip((cut(CORNERS[j], CORNERS[(j-1)%6], CENTERS[j], RADII[j]) for j in range(6)), (cut(CORNERS[j], CORNERS[(j+1)%6], CENTERS[j], RADII[j]) for j in range(6)))):
        print(f"tower {i}: center={CENTERS[i]} r={RADII[i]} entry={entry} exit={exit_point}")


if __name__ == "__main__":
    render()

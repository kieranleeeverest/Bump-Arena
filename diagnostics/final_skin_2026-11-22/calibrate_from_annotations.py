from __future__ import annotations

import csv
import importlib.util
from pathlib import Path

from PIL import Image, ImageDraw


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fit", HERE / "fit_preview.py")
fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit)

OLD_CORNERS = [(138, 340), (512, 266), (886, 340), (886, 1134), (512, 1224), (138, 1134)]
NEW_CORNERS = [(120, 347), (512, 243), (904, 347), (904, 1121), (512, 1230), (120, 1121)]
SCALE = 540 / 1024
OFFSET_Y = 75

# Original-image coordinates read from the user's annotated source-pixel grids.
# The bright laser has a soft edge; these are manual reference estimates.
SAMPLES = {
    "left_vertical": [(120, 500), (120, 700), (119, 900), (120, 1050)],
    "right_vertical": [(904, 500), (904, 700), (905, 900), (904, 1050)],
    "top_left": [(200, 326), (300, 299), (400, 273)],
    "top_right": [(624, 273), (724, 299), (824, 326)],
    "bottom_left": [(200, 1143), (300, 1171), (400, 1199)],
    "bottom_right": [(624, 1199), (724, 1171), (824, 1143)],
}


def value_on_line(section, group, x):
    corners = OLD_CORNERS if section == "old" else NEW_CORNERS
    if group == "left_vertical":
        return corners[0][0], None
    if group == "right_vertical":
        return corners[2][0], None
    edge_indices = {"top_left": (0, 1), "top_right": (1, 2), "bottom_right": (3, 4), "bottom_left": (4, 5)}
    a, b = (corners[i] for i in edge_indices[group])
    y = a[1] + (x - a[0]) * (b[1] - a[1]) / (b[0] - a[0])
    return x, y


def draw_grid_crop(image, box, multiplier, label):
    x0, y0, x1, y1 = box
    crop = image.crop(box).resize(((x1 - x0) * multiplier, (y1 - y0) * multiplier))
    d = ImageDraw.Draw(crop)
    x_step = 10 if label in ("left", "right") else 20
    for x in range((x0 // x_step + 1) * x_step, x1, x_step):
        xx = (x - x0) * multiplier
        d.line((xx, 0, xx, crop.height), fill=(241, 179, 65), width=1)
        d.text((xx + 2, 1), str(x), fill=(255, 234, 140))
    if label not in ("left", "right"):
        for y in range((y0 // 10 + 1) * 10, y1, 10):
            yy = (y - y0) * multiplier
            d.line((0, yy, crop.width, yy), fill=(241, 179, 65), width=1)
            d.text((2, yy + 2), str(y), fill=(255, 234, 140))
    crop.save(HERE / f"calibration_{label}_grid.png")


def main():
    fit.CORNERS = OLD_CORNERS
    fit.SIDE_BLEND = 5.0
    old_outline, _ = fit.build()
    fit.CORNERS = NEW_CORNERS
    fit.SIDE_BLEND = 6.0
    new_outline, new_joints = fit.build()
    original = Image.open(fit.SOURCE).convert("RGB")
    compare = original.copy()
    d = ImageDraw.Draw(compare)
    d.line(old_outline + [old_outline[0]], fill=(255, 105, 80), width=3, joint="curve")
    d.line(new_outline + [new_outline[0]], fill=(85, 255, 216), width=3, joint="curve")
    for x, y in new_joints:
        d.ellipse((x - 2, y - 2, x + 2, y + 2), fill=(255, 226, 85))
    for (x, y), radius in zip(fit.CENTERS, fit.RADII):
        d.ellipse((x - radius, y - radius, x + radius, y + radius), outline=(91, 184, 255), width=2)
        d.ellipse((x - 2, y - 2, x + 2, y + 2), fill=(255, 226, 85))
    d.rectangle((15, 20, 430, 87), fill=(12, 8, 24))
    d.text((25, 29), "ORANGE = old screenshot boundary", fill=(255, 105, 80))
    d.text((25, 49), "MINT = new fitted physical boundary", fill=(85, 255, 216))
    d.text((25, 69), "BLUE = unchanged tower circles", fill=(91, 184, 255))
    compare.save(HERE / "calibration_full_old_new.png")
    for label, box, multiplier in [
        ("left", (62, 490, 223, 700), 4),
        ("right", (800, 490, 961, 700), 4),
        ("top_left", (180, 235, 422, 380), 3),
        ("top_right", (602, 235, 844, 380), 3),
        ("bottom_left", (180, 1080, 422, 1225), 3),
        ("bottom_right", (602, 1080, 844, 1225), 3),
    ]:
        draw_grid_crop(compare, box, multiplier, label)
    with (HERE / "calibration_samples.csv").open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.writer(stream)
        writer.writerow(["boundary", "manual_image_x", "manual_image_y", "world_x", "world_y", "old_image_axis", "new_image_axis", "old_to_new_image_px", "manual_to_new_residual_image_px"])
        for group, points in SAMPLES.items():
            for x, y in points:
                old_x, old_y = value_on_line("old", group, x)
                new_x, new_y = value_on_line("new", group, x)
                if group.endswith("vertical"):
                    old_axis, new_axis, reference = old_x, new_x, x
                else:
                    old_axis, new_axis, reference = old_y, new_y, y
                writer.writerow([group, x, y, round(x * SCALE, 3), round(OFFSET_Y + y * SCALE, 3), round(old_axis, 3), round(new_axis, 3), round(new_axis - old_axis, 3), round(abs(new_axis - reference), 3)])
    print("CALIBRATION_PREVIEW old_points=%d new_points=%d scale=%.8f offset_y=%d" % (len(old_outline), len(new_outline), SCALE, OFFSET_Y))


if __name__ == "__main__":
    main()

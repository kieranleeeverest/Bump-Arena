"""Render a soft, turbulent fire orb as an animated Blender billboard.

Run with the blue orb scene as input. The generated RGBA image is also usable
directly as a Godot sprite with Add blending on a dark battlefield.
"""
import argparse
import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def clamp(x):
    return max(0.0, min(1.0, x))


def field(x, y):
    r = math.hypot(x, y)
    a = math.atan2(y, x)
    # A distorted, glowing center and several independent streams of hot gas.
    distortion = 0.035 * math.sin(7 * a + 12 * r) + 0.025 * math.sin(11 * a - 19 * r)
    rr = r + distortion
    grain = 0.5 + 0.25 * math.sin(19*x + 12*y + 2*math.sin(11*y)) * math.sin(22*y - 9*x)
    grain += 0.18 * math.sin(39*x - 27*y) * math.sin(25*y + 13*x)
    core = math.exp(-((rr / 0.245) ** 2) * 1.7) * (0.84 + 0.16 * grain)
    hot_center = math.exp(-(((x + 0.018)/0.13)**2 + ((y - 0.16)/0.13)**2) * 1.2)

    inner = 0.0
    outer = 0.0
    for k in range(7):
        phase = k * 2.39996
        rad = 0.31 + 0.073 * k
        wave = 0.030 * math.sin(6*a + phase + 10*r)
        wave += 0.022 * math.sin(13*a - phase + 14*r)
        band = math.exp(-((r - rad - wave) / (0.028 + 0.004*(k % 3)))**2)
        # Some portions vanish; the remainder forms incomplete curls.
        gaps = clamp((math.sin(4*a + phase + 2*math.sin(3*a)) + 0.22) * 1.5)
        flutter = 0.60 + 0.4 * math.sin(17*a + 9*r + phase)**2
        if k < 3:
            inner += band * gaps * flutter * 0.37
        else:
            outer += band * gaps * flutter * (0.30 if k < 5 else 0.22)

    # Loose hooked tongues extend beyond the circular silhouette.
    tongues = 0.0
    for k in range(15):
        angle = 2 * math.pi * k / 15 + 0.14 * math.sin(k * 7.1)
        delta = math.atan2(math.sin(a - angle), math.cos(a - angle))
        reach = 0.61 + 0.13 * (0.5 + 0.5*math.sin(k * 13.7))
        bend = 0.27 * (r - 0.48) * (1 if k % 3 else -1)
        angular = math.exp(-((delta - bend) / (0.035 + 0.012*(k % 3)))**2)
        radial = clamp((r - 0.49)/0.07) * clamp((reach - r)/0.13)
        tongues += angular * radial * (0.25 + 0.11*(k % 4))

    cloud = math.exp(-((rr - 0.37)/0.21)**2) * clamp((grain - 0.20) * 0.7)
    cloud *= 0.48
    hot = hot_center * 1.4 + core * 0.95 + inner * 0.40
    flame = inner * 0.8 + outer * 0.8 + tongues + cloud
    ember = outer * 0.55 + tongues * 0.35
    # Black and transparent areas remain transparent for game compositing.
    alpha = clamp(core * 0.9 + flame * 0.63 + ember * 0.30)
    red = clamp(0.18 * ember + 0.88 * flame + 1.2 * hot)
    green = clamp(0.016 * ember + 0.20 * flame + 0.75 * hot)
    blue = clamp(0.001 * ember + 0.012 * flame + 0.13 * hot)
    return red, green, blue, alpha


def build(out):
    scene = bpy.context.scene
    for obj in bpy.data.objects:
        if obj.type != 'CAMERA':
            obj.hide_render = True
    scene.render.film_transparent = True
    scene.render.resolution_x = 768
    scene.render.resolution_y = 768
    scene.camera.data.ortho_scale = 2.25
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.look = 'Medium High Contrast'

    size = 768
    image = bpy.data.images.new('Fire orb RGBA procedural', width=size, height=size,
                                alpha=True, float_buffer=True)
    pixels = [0.0] * (size * size * 4)
    rng = random.Random(2026)
    sparks = [(rng.uniform(-0.91, 0.91), rng.uniform(-0.86, 0.55),
               rng.uniform(0.003, 0.010)) for _ in range(25)]
    for row in range(size):
        y = (row + 0.5) / size * 2 - 1
        for col in range(size):
            x = (col + 0.5) / size * 2 - 1
            rgba = field(x, y)
            # Tiny scattered orange embers, mainly below the fire vortex.
            spark = 0.0
            if x*x + y*y > 0.42:
                for sx, sy, radius in sparks:
                    if abs(x - sx) < radius * 3 and abs(y - sy) < radius * 3:
                        spark += math.exp(-((x-sx)**2 + (y-sy)**2) / radius**2)
            if spark:
                rgba = (clamp(rgba[0] + spark), clamp(rgba[1] + spark * 0.36),
                        clamp(rgba[2] + spark * 0.02), clamp(rgba[3] + spark))
            index = (row * size + col) * 4
            pixels[index:index + 4] = rgba
    image.pixels.foreach_set(pixels)
    image.update()
    out.mkdir(parents=True, exist_ok=True)
    image.filepath_raw = str(out / 'fire_texture_rgba.png')
    image.file_format = 'PNG'
    image.save()
    image.pack()

    material = bpy.data.materials.new('Fire vortex - RGBA emission')
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    tex = nodes.new('ShaderNodeTexImage')
    tex.image = image
    transparent = nodes.new('ShaderNodeBsdfTransparent')
    glow = nodes.new('ShaderNodeEmission')
    glow.inputs['Strength'].default_value = 1.35
    mix = nodes.new('ShaderNodeMixShader')
    output = nodes.new('ShaderNodeOutputMaterial')
    links = material.node_tree.links
    links.new(tex.outputs['Color'], glow.inputs['Color'])
    links.new(tex.outputs['Alpha'], mix.inputs[0])
    links.new(transparent.outputs[0], mix.inputs[1])
    links.new(glow.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], output.inputs['Surface'])

    camera = scene.camera
    rotation = camera.rotation_euler.to_quaternion()
    right = rotation @ Vector((1, 0, 0))
    up = rotation @ Vector((0, 1, 0))
    verts = [right * -1 + up * -1, right - up, right + up, -right + up]
    mesh = bpy.data.meshes.new('Fire plane')
    mesh.from_pydata(verts, [], [(0, 1, 2, 3)])
    mesh.update()
    uv = mesh.uv_layers.new()
    for loop, coordinate in zip(mesh.polygons[0].loop_indices,
                                ((0, 0), (1, 0), (1, 1), (0, 1))):
        uv.data[loop].uv = coordinate
    obj = bpy.data.objects.new('Animated fire vortex billboard', mesh)
    scene.collection.objects.link(obj)
    obj.data.materials.append(material)
    # Slow orbital movement, enough to keep the asset alive between impacts.
    for frame, angle, scale in ((1, 0, 1), (13, 0.04, 1.025),
                                (25, 0.09, 0.99), (37, 0.13, 1.02),
                                (49, 0.17, 1)):
        obj.rotation_mode = 'AXIS_ANGLE'
        obj.rotation_axis_angle = (angle, *(rotation @ Vector((0, 0, 1))))
        obj.scale = (scale,) * 3
        obj.keyframe_insert(data_path='rotation_axis_angle', frame=frame)
        obj.keyframe_insert(data_path='scale', frame=frame)

    scene.frame_set(1)
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.filepath = str(out / 'fire_reference_preview.png')
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'fire_reference_orb.blend'))
    bpy.ops.render.render(write_still=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    build(args.out.resolve())

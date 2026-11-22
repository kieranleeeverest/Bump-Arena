"""Create a turbulent orange fire orb from the existing blue orb scene.

blender blue_energy_orb.blend --background --python make_reference_fire.py -- --out DIR
"""
import argparse
import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def emission(name, color, strength):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    glow = nodes.new('ShaderNodeEmission')
    glow.inputs['Color'].default_value = (*color, 1)
    glow.inputs['Strength'].default_value = strength
    output = nodes.new('ShaderNodeOutputMaterial')
    mat.node_tree.links.new(glow.outputs[0], output.inputs['Surface'])
    return mat


def ribbon(scene, name, points, widths, material, right, up, depth=None):
    depth = Vector((0, 0, 0)) if depth is None else depth
    vertices, faces = [], []
    for k, ((x, y), w) in enumerate(zip(points, widths)):
        before = points[max(k - 1, 0)]
        after = points[min(k + 1, len(points) - 1)]
        dx, dy = after[0] - before[0], after[1] - before[1]
        length = max(math.hypot(dx, dy), 1e-6)
        nx, ny = -dy / length, dx / length
        for side in (-1, 1):
            vertices.append(right * (x + side * nx * w) + up * (y + side * ny * w) + depth)
        if k:
            a = 2 * k
            faces.extend(((a - 2, a - 1, a), (a - 1, a + 1, a)))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    mesh.materials.append(material)
    return obj


def build(out):
    scene = bpy.context.scene
    rng = random.Random(1937)
    for obj in bpy.data.objects:
        if obj.name.startswith(('Energy orbit', 'Orbit spark')):
            obj.hide_render = True

    # Hot molten center: broad yellow patches on an orange, rotating body.
    core = bpy.data.materials['Core - procedural turbulent surface']
    nodes = core.node_tree.nodes
    noise = next(n for n in nodes if n.type == 'TEX_NOISE')
    noise.inputs['Scale'].default_value = 6.5
    noise.inputs['Detail'].default_value = 5.0
    ramp = next(n for n in nodes if n.type == 'VALTORGB')
    ramp.color_ramp.elements[0].position = 0.25
    ramp.color_ramp.elements[0].color = (0.16, 0.004, 0.0002, 1)
    ramp.color_ramp.elements[1].position = 0.73
    ramp.color_ramp.elements[1].color = (1.0, 0.42, 0.016, 1)
    mid = ramp.color_ramp.elements.new(0.49)
    mid.color = (0.80, 0.08, 0.001, 1)
    shader = next(n for n in nodes if n.type == 'EMISSION')
    shader.inputs['Strength'].default_value = 1.25
    mix = next(n for n in nodes if n.type == 'MIX_RGB')
    mix.inputs[2].default_value = (1.0, 0.25, 0.008, 1)
    bpy.data.objects['Energy core - no eye'].scale = (0.66,) * 3

    camera = scene.camera
    camera.data.ortho_scale = 2.55
    right = camera.rotation_euler.to_quaternion() @ Vector((1, 0, 0))
    up = camera.rotation_euler.to_quaternion() @ Vector((0, 1, 0))
    mats = {
        'ember': emission('Dark red ember edges', (0.40, 0.006, 0.0001), 0.65),
        'red': emission('Red orange curling flame', (0.85, 0.022, 0.0001), 0.85),
        'orange': emission('Bright orange flame', (1.0, 0.10, 0.001), 1.1),
        'gold': emission('Golden flame accents', (1.0, 0.31, 0.006), 1.55),
        'hot': emission('Yellow hot spark', (1.0, 0.56, 0.025), 2.0),
    }

    # A halo of disconnected, turbulent, curling strokes instead of clean Saturn rings.
    for i in range(27):
        base = rng.random() * math.tau
        span = rng.uniform(0.23, 1.15) * rng.choice((-1, 1))
        radius = rng.uniform(0.39, 0.82)
        phase = rng.random() * math.tau
        thick = rng.uniform(0.005, 0.018) if i % 4 else rng.uniform(0.016, 0.034)
        shade = rng.choices(('ember', 'red', 'orange', 'gold'), weights=(9, 18, 13, 4))[0]
        points, widths = [], []
        for j in range(25):
            t = j / 24
            a = base + span * t
            r = radius + 0.023 * math.sin(t * 8 + phase) + 0.013 * math.sin(t * 17 + i)
            points.append((r * math.cos(a), r * math.sin(a)))
            widths.append(0.001 + thick * math.sin(math.pi * t) ** 0.8 *
                          (0.72 + 0.28 * math.sin(11 * t + phase) ** 2))
        obj = ribbon(scene, 'Curling flame %02d' % i, points, widths,
                     mats[shade], right, up)
        # Each strand gently breathes at a different phase.
        for frame, scale in ((1, 1.0), (13, 1.02 + 0.03 * math.sin(i)),
                             (25, 0.99), (37, 1.02), (49, 1.0)):
            obj.scale = (scale,) * 3
            obj.keyframe_insert(data_path='scale', frame=frame)

    # Broken flames lift from the central body and bend with the circulation.
    for i in range(17):
        angle = rng.random() * math.tau
        start = rng.uniform(0.25, 0.45)
        length = rng.uniform(0.11, 0.37)
        curl = rng.uniform(-0.55, 0.55)
        thick = rng.uniform(0.009, 0.032)
        shade = rng.choices(('red', 'orange', 'gold', 'hot'), (5, 11, 7, 1))[0]
        points, widths = [], []
        for j in range(17):
            t = j / 16
            a = angle + curl * t * t + 0.06 * math.sin(t * 7 + i)
            r = start + length * t
            points.append((r * math.cos(a), r * math.sin(a)))
            widths.append(0.0005 + thick * math.sin(math.pi * (0.08 + 0.9 * t)) *
                          (1 - t) ** 0.8)
        ribbon(scene, 'Rising flame %02d' % i, points, widths,
               mats[shade], right, up, depth=right * 0.002)

    # Irregular bright surface scraps break up the spherical silhouette.
    for i in range(10):
        a = rng.random() * math.tau
        radius = rng.uniform(0.22, 0.37)
        length = rng.uniform(0.08, 0.28)
        points, widths = [], []
        for j in range(13):
            t = j / 12
            theta = a + (t - 0.5) * length / radius
            rr = radius + 0.025 * math.sin(t * 10 + i)
            points.append((rr * math.cos(theta), rr * math.sin(theta)))
            widths.append(0.001 + rng.uniform(0.018, 0.045) * math.sin(math.pi * t))
        ribbon(scene, 'Molten fragment %02d' % i, points, widths,
               mats['gold' if i % 3 == 0 else 'orange'], right, up,
               depth=right * 0.004)

    # Sparse detached embers, concentrated below the orb like the reference.
    for i in range(20):
        x = rng.uniform(-0.95, 0.95)
        y = rng.uniform(-1.0, -0.32) if i < 14 else rng.uniform(-0.85, 0.85)
        if x * x + y * y < 0.55 ** 2:
            continue
        bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=6,
                                             radius=rng.uniform(0.003, 0.010))
        dot = bpy.context.object
        dot.name = 'Floating ember %02d' % i
        dot.location = right * x + up * y
        dot.data.materials.append(mats['gold' if i % 5 == 0 else 'orange'])

    scene.render.resolution_x = 768
    scene.render.resolution_y = 768
    scene.cycles.samples = 48
    scene.frame_set(1)
    out.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(out / 'fire_reference_preview.png')
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'fire_reference_orb.blend'))
    bpy.ops.render.render(write_still=True)
    print('Saved:', out)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    build(args.out.resolve())

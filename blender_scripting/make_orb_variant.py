"""Blender 5.3: open the blue orb .blend and create a palette/material variant.
Usage: blender blue_energy_orb.blend --background --python make_orb_variant.py -- --variant steel|fire|red --out DIR
"""
import argparse
import math
import random
import sys
from pathlib import Path
import bpy
from mathutils import Vector


def recolor_emission(material_name, color, strength):
    material = bpy.data.materials[material_name]
    node = next(n for n in material.node_tree.nodes if n.type == 'EMISSION')
    node.inputs['Color'].default_value = (*color, 1)
    node.inputs['Strength'].default_value = strength


def set_core_emission(dark, light, rim):
    material = bpy.data.materials['Core - procedural turbulent surface']
    ramp = next(n for n in material.node_tree.nodes if n.type == 'VALTORGB')
    mix = next(n for n in material.node_tree.nodes if n.type == 'MIX_RGB')
    ramp.color_ramp.elements[0].color = (*dark, 1)
    ramp.color_ramp.elements[1].color = (*light, 1)
    mix.inputs[2].default_value = (*rim, 1)


def steel(scene):
    # Reflective silver body with soft warm studio reflections.
    material = bpy.data.materials['Core - procedural turbulent surface']
    nodes = material.node_tree.nodes
    nodes.clear()
    shader = nodes.new('ShaderNodeBsdfPrincipled')
    shader.inputs['Base Color'].default_value = (0.52, 0.56, 0.61, 1)
    shader.inputs['Metallic'].default_value = 0.86
    shader.inputs['Roughness'].default_value = 0.27
    shader.inputs['Coat Weight'].default_value = 0.25
    output = nodes.new('ShaderNodeOutputMaterial')
    material.node_tree.links.new(shader.outputs['BSDF'], output.inputs['Surface'])
    for name, color, power in [
        ('Steel softbox', (0.70, 0.85, 1.0), 420),
        ('Warm rim light', (1.0, 0.63, 0.31), 300),
    ]:
        light = bpy.data.lights.new(name, 'AREA')
        light.energy = power
        light.color = color
        light.shape = 'DISK'
        light.size = 3.0
        obj = bpy.data.objects.new(name, light)
        scene.collection.objects.link(obj)
        obj.location = (3, -3, 4) if 'softbox' in name else (-3, 1, 1)
        obj.rotation_euler = (-obj.location).to_track_quat('-Z', 'Y').to_euler()
    recolor_emission('Cyan plasma', (0.92, 0.74, 0.40), 3.0)
    recolor_emission('Icy highlights', (1.0, 0.91, 0.70), 6.0)
    recolor_emission('Blue outer filaments', (0.40, 0.45, 0.53), 2.0)
    for obj in bpy.data.objects:
        if obj.name.startswith('Orbit pivot'):
            obj.scale = (1.14, 0.75, 1.0)
    scene.camera.data.ortho_scale = 3.15


def fire(scene):
    set_core_emission((0.05, 0.001, 0.0), (1.0, 0.10, 0.005), (1.0, 0.34, 0.025))
    recolor_emission('Cyan plasma', (1.0, 0.12, 0.005), 3.2)
    recolor_emission('Icy highlights', (1.0, 0.72, 0.045), 5.0)
    recolor_emission('Blue outer filaments', (0.7, 0.018, 0.002), 1.7)
    for obj in bpy.data.objects:
        if obj.name.startswith('Energy orbit'):
            index = int(obj.name.rsplit(' ', 1)[1].split('.')[0])
            obj.hide_render = index % 3 != 0
        elif obj.name.startswith('Orbit spark'):
            obj.hide_render = True

    def flame_material(name, color, strength):
        material = bpy.data.materials.new(name)
        material.use_nodes = True
        nodes = material.node_tree.nodes
        nodes.clear()
        glow = nodes.new('ShaderNodeEmission')
        glow.inputs['Color'].default_value = (*color, 1)
        glow.inputs['Strength'].default_value = strength
        output = nodes.new('ShaderNodeOutputMaterial')
        material.node_tree.links.new(glow.outputs[0], output.inputs['Surface'])
        return material

    orange = flame_material('Soft orange flame', (1.0, 0.10, 0.008), 1.8)
    gold = flame_material('Flame inner glint', (1.0, 0.32, 0.025), 2.5)
    view_right = scene.camera.rotation_euler.to_quaternion() @ Vector((1, 0, 0))
    view_up = scene.camera.rotation_euler.to_quaternion() @ Vector((0, 1, 0))
    rng = random.Random(72)
    for i in range(13):
        angle = math.tau * i / 13 + rng.uniform(-0.09, 0.09)
        length = rng.uniform(0.17, 0.28)
        curl = rng.choice((-1, 1)) * rng.uniform(0.13, 0.30)
        vertices = []
        faces = []
        for j in range(13):
            t = j / 12
            r = 0.43 + length * t
            a = angle + curl * t * t + 0.035 * math.sin(t * 5 + i)
            direction = view_right * math.cos(a) + view_up * math.sin(a)
            tangent = view_right * -math.sin(a) + view_up * math.cos(a)
            width = (0.012 + 0.025 * math.sin(math.pi * t)) * (1 - t) ** 0.7 + 0.0005
            center = direction * r
            vertices.extend((center - tangent * width, center + tangent * width))
            if j:
                k = 2 * j
                faces.extend(((k - 2, k - 1, k), (k - 1, k + 1, k)))
        mesh = bpy.data.meshes.new('Curved tapered flame mesh')
        mesh.from_pydata(vertices, [], faces)
        mesh.update()
        obj = bpy.data.objects.new('Flame tongue %02d' % i, mesh)
        scene.collection.objects.link(obj)
        mesh.materials.append(gold if i % 4 == 0 else orange)
        for frame, size in ((1, 1.0), (13, 1.04), (25, 0.96), (37, 1.03), (49, 1.0)):
            obj.scale = (size, size, size)
            obj.keyframe_insert(data_path='scale', frame=frame)
    scene.camera.data.ortho_scale = 3.1


def red(scene):
    set_core_emission((0.07, 0.001, 0.015), (0.38, 0.008, 0.035), (1.0, 0.04, 0.15))
    recolor_emission('Cyan plasma', (1.0, 0.018, 0.045), 7)
    recolor_emission('Icy highlights', (1.0, 0.26, 0.31), 11)
    recolor_emission('Blue outer filaments', (0.45, 0.002, 0.02), 4)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=('steel', 'fire', 'red'), required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
    scene = bpy.context.scene
    {'steel': steel, 'fire': fire, 'red': red}[args.variant](scene)
    target = args.out.resolve()
    target.mkdir(parents=True, exist_ok=True)
    scene.frame_set(1)
    scene.render.filepath = str(target / (args.variant + '_preview.png'))
    bpy.ops.wm.save_as_mainfile(filepath=str(target / (args.variant + '_orb.blend')))
    bpy.ops.render.render(write_still=True)
    print('Saved variant:', args.variant, target)


if __name__ == '__main__':
    main()

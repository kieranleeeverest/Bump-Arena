"""Run in Blender's Scripting workspace, or:
blender --background --python create_energy_orb.py -- --out OUTPUT_FOLDER
Add --animate to render all 48 frames. Black-background renders use Add blend in Godot.
"""
import argparse
import math
import random
import sys
from pathlib import Path

import bpy


def emission(name, color, strength):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    output = nodes.new('ShaderNodeOutputMaterial')
    shader = nodes.new('ShaderNodeEmission')
    shader.inputs['Color'].default_value = (*color, 1)
    shader.inputs['Strength'].default_value = strength
    material.node_tree.links.new(shader.outputs[0], output.inputs['Surface'])
    return material


def loop_rotation(obj, axis, turns=1):
    obj.rotation_mode = 'XYZ'
    original = obj.rotation_euler[axis]
    obj.keyframe_insert(data_path='rotation_euler', frame=1)
    obj.rotation_euler[axis] = original + math.tau * turns
    obj.keyframe_insert(data_path='rotation_euler', frame=49)
    # Linear interpolation works across legacy and newer action-slot APIs.
    action = obj.animation_data.action
    curves = []
    if hasattr(action, 'fcurves'):
        curves.extend(action.fcurves)
    elif hasattr(action, 'layers'):
        for layer in action.layers:
            for strip in layer.strips:
                for bag in getattr(strip, 'channelbags', []):
                    curves.extend(bag.fcurves)
    for curve in curves:
        for point in curve.keyframe_points:
            point.interpolation = 'LINEAR'


def build(output, animate=False):
    # Uses a new scene; other scenes in an already-open .blend are retained.
    scene = bpy.data.scenes.new('Energy Orb - Blue')
    bpy.context.window.scene = scene
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 48
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 768
    scene.render.resolution_y = 768
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.film_transparent = False
    scene.render.fps = 24
    scene.frame_start, scene.frame_end = 1, 48
    scene.world = bpy.data.worlds.new('Black for additive compositing')
    scene.world.use_nodes = True
    world_nodes = scene.world.node_tree.nodes
    world_nodes.clear()
    background = world_nodes.new('ShaderNodeBackground')
    world_output = world_nodes.new('ShaderNodeOutputWorld')
    background.inputs[0].default_value = (0, 0, 0, 1)
    background.inputs[1].default_value = 0
    scene.world.node_tree.links.new(background.outputs[0], world_output.inputs[0])

    cyan = emission('Cyan plasma', (0.005, 0.32, 1.0), 7)
    white = emission('Icy highlights', (0.12, 0.70, 1.0), 12)
    blue = emission('Blue outer filaments', (0.006, 0.025, 0.7), 4)

    core = bpy.data.materials.new('Core - procedural turbulent surface')
    core.use_nodes = True
    nodes, links = core.node_tree.nodes, core.node_tree.links
    nodes.clear()
    tex = nodes.new('ShaderNodeTexNoise')
    tex.inputs['Scale'].default_value = 9
    tex.inputs['Detail'].default_value = 4
    ramp = nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].position = 0.48
    ramp.color_ramp.elements[0].color = (0.001, 0.015, 0.08, 1)
    ramp.color_ramp.elements[1].position = 0.73
    ramp.color_ramp.elements[1].color = (0.004, 0.045, 0.16, 1)
    shader = nodes.new('ShaderNodeEmission')
    shader.inputs['Strength'].default_value = 4.0
    out = nodes.new('ShaderNodeOutputMaterial')
    links.new(tex.outputs['Fac'], ramp.inputs[0])
    fresnel = nodes.new('ShaderNodeFresnel')
    fresnel.inputs['IOR'].default_value = 1.35
    rim = nodes.new('ShaderNodeMixRGB')
    rim.blend_type = 'MIX'
    rim.inputs[2].default_value = (0.02, 0.65, 1.0, 1)
    links.new(fresnel.outputs[0], rim.inputs[0])
    links.new(ramp.outputs[0], rim.inputs[1])
    links.new(rim.outputs[0], shader.inputs['Color'])
    links.new(shader.outputs[0], out.inputs['Surface'])
    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=0.46)
    sphere = bpy.context.object
    sphere.name = 'Energy core - no eye'
    sphere.data.materials.append(core)
    for polygon in sphere.data.polygons:
        polygon.use_smooth = True
    loop_rotation(sphere, 2)

    for i in range(14):
        pivot = bpy.data.objects.new('Orbit pivot %02d' % i, None)
        scene.collection.objects.link(pivot)
        pivot.rotation_euler = (-0.20 + (i % 5) * 0.09, math.sin(i * 2.1) * 0.15, i * 1.72)
        curve = bpy.data.curves.new('Orbit filament', 'CURVE')
        curve.dimensions = '3D'
        curve.bevel_depth = 0.0035 if i % 3 else 0.008
        curve.bevel_resolution = 3
        spline = curve.splines.new('POLY')
        spline.points.add(127)
        radius = 0.53 + i * 0.043
        for j, point in enumerate(spline.points):
            fraction = j / 127
            angle = math.tau * fraction * (0.62 + (i % 3) * 0.11)
            wave_radius = radius + 0.025 * math.sin(angle * 5 + i)
            point.co = (wave_radius * math.cos(angle), wave_radius * math.sin(angle), 0.035 * math.sin(angle * 3 + i), 1)
            point.radius = 0.08 + 0.92 * math.sin(math.pi * fraction) ** 0.6
        spline.use_cyclic_u = False
        ring = bpy.data.objects.new('Energy orbit %02d' % i, curve)
        scene.collection.objects.link(ring)
        ring.parent = pivot
        curve.materials.append(cyan if i % 2 else blue)
        loop_rotation(pivot, 2, 1 if i % 2 else -1)

        rng = random.Random(80 + i)
        for j in range(2):
            angle = rng.uniform(0, math.tau)
            bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, radius=rng.uniform(0.006, 0.014))
            dot = bpy.context.object
            dot.name = 'Orbit spark'
            dot.parent = pivot
            dot.location = (radius * math.cos(angle), radius * math.sin(angle), 0)
            dot.data.materials.append(white if j % 3 == 0 else cyan)

    bpy.ops.object.camera_add(location=(0, -6, 4))
    camera = bpy.context.object
    camera.rotation_euler = (-camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.type = 'ORTHO'
    camera.data.ortho_scale = 3.0
    scene.camera = camera

    if hasattr(scene, 'compositing_node_group'):
        tree = bpy.data.node_groups.new('Orb compositor', 'CompositorNodeTree')
        scene.compositing_node_group = tree
        tree.interface.new_socket(name='Image', in_out='OUTPUT', socket_type='NodeSocketColor')
    else:
        scene.use_nodes = True
        tree = scene.node_tree
    nodes, links = tree.nodes, tree.links
    nodes.clear()
    render = nodes.new('CompositorNodeRLayers')
    render.scene = scene
    glare = nodes.new('CompositorNodeGlare')
    if hasattr(glare, 'glare_type'):
        glare.glare_type = 'FOG_GLOW'
        glare.quality = 'HIGH'
    else:
        glare.inputs['Type'].default_value = 'Fog Glow'
        glare.inputs['Quality'].default_value = 'High'
    if hasattr(glare, 'threshold'):
        glare.threshold = 0.8
    elif glare.inputs.get('Threshold'):
        glare.inputs['Threshold'].default_value = 0.8
    if hasattr(glare, 'size'):
        glare.size = 8
    elif glare.inputs.get('Size'):
        glare.inputs['Size'].default_value = 0.65
    if glare.inputs.get('Strength'):
        glare.inputs['Strength'].default_value = 3.0
    composite = nodes.new('NodeGroupOutput' if hasattr(scene, 'compositing_node_group') else 'CompositorNodeComposite')
    links.new(render.outputs['Image'], glare.inputs['Image'])
    links.new(glare.outputs['Image'], composite.inputs['Image'])

    output.mkdir(parents=True, exist_ok=True)
    scene.frame_set(1)
    scene.render.filepath = str(output / 'blue_orb_preview.png')
    bpy.ops.wm.save_as_mainfile(filepath=str(output / 'blue_energy_orb.blend'))
    bpy.ops.render.render(write_still=True)
    if animate:
        frames = output / 'frames'
        frames.mkdir(exist_ok=True)
        scene.render.filepath = str(frames / 'blue_orb_')
        bpy.ops.render.render(animation=True)
    print('Energy orb saved to:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    text = getattr(getattr(bpy.context, 'space_data', None), 'text', None)
    script_path = Path(bpy.path.abspath(text.filepath)) if text and text.filepath else Path(__file__).resolve()
    base = script_path.parent if script_path.is_file() else Path(bpy.path.abspath('//'))
    default = base / 'energy_orb_output'
    parser.add_argument('--out', type=Path, default=default)
    parser.add_argument('--animate', action='store_true')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
    build(args.out.resolve(), args.animate)

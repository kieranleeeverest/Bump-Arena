"""Import the reference-inspired fire sprite into Blender and render a preview.

blender blue_energy_orb.blend --background --python import_fire_art.py -- --image fire_art.png --out DIR
"""
import argparse
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def build(image_path, out):
    scene = bpy.context.scene
    for obj in bpy.data.objects:
        if obj.type != 'CAMERA':
            obj.hide_render = True
    scene.render.film_transparent = False
    scene.render.resolution_x = 768
    scene.render.resolution_y = 768
    scene.camera.data.ortho_scale = 2.45

    picture = bpy.data.images.load(str(image_path), check_existing=True)
    picture.pack()
    material = bpy.data.materials.new('Fire orb painted RGBA')
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    tex = nodes.new('ShaderNodeTexImage')
    tex.image = picture
    transparent = nodes.new('ShaderNodeBsdfTransparent')
    emission = nodes.new('ShaderNodeEmission')
    emission.inputs['Strength'].default_value = 1.0
    mix = nodes.new('ShaderNodeMixShader')
    output = nodes.new('ShaderNodeOutputMaterial')
    links = material.node_tree.links
    links.new(tex.outputs['Color'], emission.inputs['Color'])
    links.new(tex.outputs['Alpha'], mix.inputs[0])
    links.new(transparent.outputs[0], mix.inputs[1])
    links.new(emission.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], output.inputs['Surface'])

    rotation = scene.camera.rotation_euler.to_quaternion()
    right = rotation @ Vector((1, 0, 0))
    up = rotation @ Vector((0, 1, 0))
    mesh = bpy.data.meshes.new('Fire artwork plane')
    mesh.from_pydata([-right-up, right-up, right+up, -right+up], [], [(0, 1, 2, 3)])
    mesh.update()
    uv = mesh.uv_layers.new()
    for loop, coord in zip(mesh.polygons[0].loop_indices,
                           ((0, 0), (1, 0), (1, 1), (0, 1))):
        uv.data[loop].uv = coord
    orb = bpy.data.objects.new('Fire orb - painterly vortex', mesh)
    scene.collection.objects.link(orb)
    orb.data.materials.append(material)
    # A slow rise and pulse keeps the sprite moving without distorting the flame shape.
    for frame, scale, rise in ((1, 1.0, 0), (13, 1.018, 0.012),
                               (25, 0.995, 0), (37, 1.017, -0.012),
                               (49, 1.0, 0)):
        orb.scale = (scale,) * 3
        orb.location = up * rise
        orb.keyframe_insert(data_path='scale', frame=frame)
        orb.keyframe_insert(data_path='location', frame=frame)

    out.mkdir(parents=True, exist_ok=True)
    scene.frame_set(1)
    scene.render.filepath = str(out / 'fire_blender_preview.png')
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'fire_blender.blend'))
    bpy.ops.render.render(write_still=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    build(args.image.resolve(), args.out.resolve())

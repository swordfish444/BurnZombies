"""Shared helpers for the BurnZombies promo scenes (Blender 5.2, run headless)."""
import bpy, math, random, os
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = os.path.join(HERE, "art", "logo")
ANTON = os.path.normpath(os.path.join(HERE, "..", "..", "Sources", "BurnApp", "Resources", "Anton-Regular.ttf"))

# Brand palette (sRGB hex) from docs/BRAND.md and EmberSkull.png
ORANGE = "#FF5722"
FLAME_DARK = "#E8380C"
IVORY = "#FAF4E2"
CREAM = "#F6EFDC"
CHARCOAL = "#141414"
INK = "#140A08"


def srgb(hexstr, a=1.0):
    h = hexstr.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return (*lin, a)


def reset(fps=30, res=(1920, 1080), frames=(1, 120), engine="CYCLES", samples=128):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    if engine == "CYCLES":
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"; prefs.get_devices()
        for d in prefs.devices:
            d.use = d.type == "METAL"
        sc.render.engine = "CYCLES"
        cy = sc.cycles
        cy.device = "GPU"; cy.samples = samples
        cy.use_adaptive_sampling = True; cy.adaptive_threshold = 0.02
        cy.use_denoising = True; cy.denoiser = "OPENIMAGEDENOISE"; cy.denoising_use_gpu = True
        cy.max_bounces = 8; cy.diffuse_bounces = 3; cy.glossy_bounces = 4
        cy.transmission_bounces = 8; cy.transparent_max_bounces = 24
        cy.sample_clamp_indirect = 8.0; cy.caustics_reflective = False; cy.caustics_refractive = False
        sc.render.use_persistent_data = True
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.fps = fps
    sc.frame_start, sc.frame_end = frames
    sc.eevee.taa_render_samples = 64
    sc.eevee.use_raytracing = True
    sc.eevee.use_shadows = True
    if engine == "CYCLES":
        sc.view_settings.view_transform = "AgX"
        for look in ("AgX - Medium High Contrast", "Medium High Contrast"):
            try:
                sc.view_settings.look = look
                break
            except TypeError:
                pass
    else:
        sc.view_settings.view_transform = "Standard"
        sc.view_settings.look = "None"
    world = bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = srgb("#0c0b0b")
    bg.inputs["Strength"].default_value = 1.0
    return sc


def mat(name, base=None, rough=0.4, emit=None, emit_strength=0.0, sss=0.0, metal=0.0, spec=0.5, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    if base:
        p.inputs["Base Color"].default_value = srgb(base)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    p.inputs["Specular IOR Level"].default_value = spec
    if sss:
        p.inputs["Subsurface Weight"].default_value = sss
        p.inputs["Subsurface Radius"].default_value = (0.9, 0.5, 0.35)
        p.inputs["Subsurface Scale"].default_value = 0.05
    if emit:
        p.inputs["Emission Color"].default_value = srgb(emit)
        p.inputs["Emission Strength"].default_value = emit_strength
    if alpha < 1.0:
        p.inputs["Alpha"].default_value = alpha
    return m


def bloom(sc, threshold=0.9, strength=0.6, size=0.7, quality="High"):
    ng = bpy.data.node_groups.new("Comp", "CompositorNodeTree")
    sc.compositing_node_group = ng
    ng.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    rl = ng.nodes.new("CompositorNodeRLayers")
    gl = ng.nodes.new("CompositorNodeGlare")
    gl.inputs["Type"].default_value = "Bloom"
    gl.inputs["Quality"].default_value = quality
    gl.inputs["Threshold"].default_value = threshold
    gl.inputs["Strength"].default_value = strength
    gl.inputs["Size"].default_value = size
    out = ng.nodes.new("NodeGroupOutput")
    lens = ng.nodes.new("CompositorNodeLensdist")
    lens.inputs["Dispersion"].default_value = 0.01
    ng.links.new(rl.outputs["Image"], gl.inputs["Image"])
    ng.links.new(gl.outputs[0], lens.inputs["Image"])
    ng.links.new(lens.outputs["Image"], out.inputs[0])
    return gl


def dust(name, count, lo, hi, seed=7, radius=(0.004, 0.016), strength=3.0, color="#FFB27A", drift=0.5, speed=0.02, rise=0.004):
    """Floating motes (Cycles point spheres) drifting in a slow noise field and rising like embers."""
    rnd = random.Random(seed)
    me = bpy.data.meshes.new(name)
    me.from_pydata([(rnd.uniform(lo[0], hi[0]), rnd.uniform(lo[1], hi[1]), rnd.uniform(lo[2], hi[2])) for _ in range(count)], [], [])
    obj = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(obj)
    ng = bpy.data.node_groups.new(f"{name}GN", "GeometryNodeTree")
    ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    N, L = ng.nodes, ng.links
    gin = N.new("NodeGroupInput"); gout = N.new("NodeGroupOutput")
    rr = N.new("FunctionNodeRandomValue"); rr.inputs["Min"].default_value = radius[0]; rr.inputs["Max"].default_value = radius[1]; rr.inputs["Seed"].default_value = seed
    tp = N.new("GeometryNodeMeshToPoints"); L.new(gin.outputs[0], tp.inputs["Mesh"]); L.new(rr.outputs["Value"], tp.inputs["Radius"])
    pos = N.new("GeometryNodeInputPosition"); tm = N.new("GeometryNodeInputSceneTime")
    nz = N.new("ShaderNodeTexNoise"); nz.noise_dimensions = "4D"; nz.inputs["Scale"].default_value = 0.35
    L.new(pos.outputs[0], nz.inputs["Vector"])
    w = N.new("ShaderNodeMath"); w.operation = "MULTIPLY"; w.inputs[1].default_value = speed
    L.new(tm.outputs["Frame"], w.inputs[0]); L.new(w.outputs[0], nz.inputs["W"])
    c = N.new("ShaderNodeVectorMath"); c.operation = "SUBTRACT"; c.inputs[1].default_value = (0.5, 0.5, 0.5)
    L.new(nz.outputs["Color"], c.inputs[0])
    a = N.new("ShaderNodeVectorMath"); a.operation = "SCALE"; a.inputs["Scale"].default_value = drift * 2
    L.new(c.outputs[0], a.inputs[0])
    up = N.new("ShaderNodeMath"); up.operation = "MULTIPLY"; up.inputs[1].default_value = rise
    L.new(tm.outputs["Frame"], up.inputs[0])
    cmb = N.new("ShaderNodeCombineXYZ"); L.new(up.outputs[0], cmb.inputs["Z"])
    add = N.new("ShaderNodeVectorMath"); add.operation = "ADD"; L.new(a.outputs[0], add.inputs[0]); L.new(cmb.outputs[0], add.inputs[1])
    sp = N.new("GeometryNodeSetPosition"); L.new(tp.outputs[0], sp.inputs["Geometry"]); L.new(add.outputs[0], sp.inputs["Offset"])
    sm = N.new("GeometryNodeSetMaterial"); sm.inputs["Material"].default_value = emissive(f"{name}Mat", color, strength)
    L.new(sp.outputs[0], sm.inputs["Geometry"]); L.new(sm.outputs[0], gout.inputs[0])
    mod = obj.modifiers.new("GN", "NODES"); mod.node_group = ng
    return obj


def import_svg(path):
    before = set(bpy.data.objects)
    bpy.ops.import_curve.svg(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    for c in list(bpy.data.collections):
        if c.name.endswith(".svg"):
            for o in c.objects:
                c.objects.unlink(o)
                if o.name not in bpy.context.scene.collection.objects:
                    bpy.context.scene.collection.objects.link(o)
            bpy.data.collections.remove(c)
    # join multiple curves of one layer into one object
    if len(new) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for o in new:
            o.select_set(True)
        bpy.context.view_layer.objects.active = new[0]
        bpy.ops.object.join()
    return new[0]


def mascot(parent_name="Mascot", flicker=True, embers=24, frames=(1, 600)):
    """3D version of EmberSkull.png: layered, puffy, flames that sway, embers that rise.
    Returns the root empty. Mascot is ~2.0 units tall, centered at origin, facing -Y."""
    layers = [
        # name, extrude, bevel, offset, z(depth toward camera), material
        ("flame", 0.05, 0.03, 0.0, 0.00, "flame"),
        ("flame_dark", 0.012, 0.012, 0.0, 0.075, "flame_dark"),
        ("skull", 0.08, 0.06, -0.045, 0.15, "ivory"),
        ("features", 0.02, 0.02, -0.012, 0.27, "ink"),
        ("smile", 0.01, 0.01, 0.0, 0.265, "white"),
    ]
    mats = {
        "flame": mat("Flame", base="#F23E0A", rough=0.62, emit="#FF2E00", emit_strength=0.3, spec=0.25),
        "flame_dark": mat("FlameDark", base="#C8260A", rough=0.62, emit="#A81C04", emit_strength=0.3, spec=0.25),
        "ivory": mat("Ivory", base=IVORY, rough=0.32, sss=0.25, spec=0.6),
        "ink": mat("Ink", base=INK, rough=0.18, spec=0.8),
        "white": mat("SmileWhite", base="#FFFFFF", rough=0.25, emit="#FFFFFF", emit_strength=0.4),
    }
    objs = {}
    for name, ext, bev, off, z, mname in layers:
        o = import_svg(os.path.join(LOGO, name + ".svg"))
        o.name = "M_" + name
        objs[name] = o
    # normalise: SVG import units are tiny; scale so the flame silhouette height = 2.0
    ref = objs["flame"]
    bpy.context.view_layer.update()
    def bbox(o):
        pts = []
        for s in o.data.splines:
            for p in s.bezier_points:
                pts.append(o.matrix_world @ p.co)
        xs = [p.x for p in pts]; ys = [p.y for p in pts]
        return min(xs), max(xs), min(ys), max(ys)
    x0, x1, y0, y1 = bbox(ref)
    scale = 2.0 / (y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    root = bpy.data.objects.new(parent_name, None)
    bpy.context.scene.collection.objects.link(root)
    for name, ext, bev, off, z, mname in layers:
        o = objs[name]
        # bake transform into points
        for s in o.data.splines:
            for p in s.bezier_points:
                for attr in ("co", "handle_left", "handle_right"):
                    v = o.matrix_world @ getattr(p, attr)
                    setattr(p, attr, Vector(((v.x - cx) * scale, (v.y - cy) * scale, 0)))
        o.matrix_world = __import__("mathutils").Matrix.Identity(4)
        cu = o.data
        cu.dimensions = "2D"
        cu.fill_mode = "BOTH"
        cu.resolution_u = 18
        cu.extrude = ext
        cu.bevel_depth = bev
        cu.bevel_resolution = 6
        cu.offset = off
        cu.materials.clear()
        cu.materials.append(mats[mname])
        # stand it up: SVG XY -> world XZ, facing -Y (toward a camera on -Y)
        o.rotation_euler = (math.radians(90), 0, 0)
        o.location = (0, -z, 0)
        o.parent = root
    if flicker:
        # flames sway: convert flame layers to mesh, weight by height, displace with scrolling noise
        drv = bpy.data.objects.new("FlameNoise", None)
        bpy.context.scene.collection.objects.link(drv)
        drv.parent = root
        f0, f1 = frames
        drv.location = (0, 0, 0)
        drv.keyframe_insert("location", frame=f0)
        drv.location = (0.0, 0.0, -0.045 * (f1 - f0))  # noise scrolls downward = flames lick upward
        drv.keyframe_insert("location", frame=f1)
        for fc in drv.animation_data.action.fcurves if hasattr(drv.animation_data.action, 'fcurves') else []:
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"
        _linearize(drv)
        tex = bpy.data.textures.new("FlameClouds", "CLOUDS")
        tex.noise_scale = 0.55
        tex.noise_depth = 1
        for name in ("flame", "flame_dark"):
            o = objs[name]
            bpy.context.view_layer.objects.active = o
            bpy.ops.object.select_all(action="DESELECT")
            o.select_set(True)
            bpy.ops.object.convert(target="MESH")
            vg = o.vertex_groups.new(name="height")
            zs = [v.co.y for v in o.data.vertices]  # local Y is up before rotation
            lo, hi = min(zs), max(zs)
            for v in o.data.vertices:
                t = (v.co.y - lo) / (hi - lo + 1e-6)
                vg.add([v.index], max(0.0, t - 0.25) ** 1.4, "REPLACE")
            for axis, strength in (("X", 0.22), ("Y", 0.10)):
                d = o.modifiers.new("sway" + axis, "DISPLACE")
                d.texture = tex
                d.texture_coords = "OBJECT"
                d.texture_coords_object = drv
                d.direction = axis
                d.strength = strength
                d.mid_level = 0.5
                d.vertex_group = "height"
            o.data.shade_smooth() if hasattr(o.data, "shade_smooth") else None
    if embers:
        add_embers(root, n=embers, frames=frames)
    return root, objs, mats


def _linearize(obj):
    ad = obj.animation_data
    if not ad or not ad.action:
        return
    act = ad.action
    curves = []
    if hasattr(act, "fcurves"):
        curves = list(act.fcurves)
    else:  # layered actions (Blender 4.4+/5.x)
        for layer in act.layers:
            for strip in layer.strips:
                for cb in strip.channelbags:
                    curves += list(cb.fcurves)
    for fc in curves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"


def add_embers(root, n=24, frames=(1, 600), seed=7, spread=1.3, height=2.6):
    rnd = random.Random(seed)
    em = mat("Ember", base="#FFB060", emit="#FF7A2A", emit_strength=14.0)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=1)
    proto = bpy.context.active_object
    proto.data.materials.append(em)
    proto.name = "EmberProto"
    proto.hide_render = True
    proto.hide_viewport = True
    f0, f1 = frames
    for i in range(n):
        e = bpy.data.objects.new(f"Ember{i}", proto.data)
        bpy.context.scene.collection.objects.link(e)
        e.parent = root
        t = f0 - rnd.randint(0, 80)
        while t < f1:
            life = rnd.randint(40, 90)
            r = rnd.uniform(0.012, 0.035)
            x0 = rnd.uniform(-spread, spread) * 0.6
            y0 = rnd.uniform(-0.4, 0.3)
            sway = rnd.uniform(0.05, 0.25)
            ph = rnd.uniform(0, 6.28)
            for k in list(range(0, life, 3)) + [life]:
                u = k / life
                e.location = (x0 + sway * math.sin(ph + u * 6), y0, -0.2 + u * height)
                s_ = r * min(1.0, 6 * u) * (1 - u) ** 0.6
                e.scale = (s_, s_, s_)
                e.keyframe_insert("location", frame=t + k)
                e.keyframe_insert("scale", frame=t + k)
            t += life + 2  # 2-frame gap at size 0 so the jump back down never streaks
    return em


def camera(loc=(0, -7, 0.4), look=(0, 0, 0.1), lens=50):
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = lens
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = loc
    point_at(cam, look)
    bpy.context.scene.camera = cam
    return cam


def point_at(obj, target):
    d = Vector(target) - obj.location
    obj.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def light(kind, name, loc, energy, color="#FFFFFF", size=1.0, look=(0, 0, 0)):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = srgb(color)[:3]
    if kind == "AREA":
        ld.size = size
    elif kind in ("POINT", "SPOT"):
        ld.shadow_soft_size = size
    lo = bpy.data.objects.new(name, ld)
    bpy.context.scene.collection.objects.link(lo)
    lo.location = loc
    point_at(lo, look)
    return lo


def text(body, size=1.0, extrude=0.05, bevel=0.01, material=None, align="CENTER", font=ANTON, name=None):
    cu = bpy.data.curves.new(name or ("T_" + body[:12]), "FONT")
    cu.body = body
    cu.font = bpy.data.fonts.load(font, check_existing=True)
    cu.size = size
    cu.extrude = extrude
    cu.bevel_depth = bevel
    cu.bevel_resolution = 3
    cu.align_x = align
    cu.align_y = "CENTER"
    o = bpy.data.objects.new(name or ("T_" + body[:12]), cu)
    bpy.context.scene.collection.objects.link(o)
    o.rotation_euler = (math.radians(90), 0, 0)
    if material:
        cu.materials.append(material)
    return o


def render_still(path, frame=1):
    sc = bpy.context.scene
    sc.frame_set(frame)
    sc.render.image_settings.file_format = "PNG"
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------- animation helpers
def fcurves(idblock):
    ad = idblock.animation_data
    if not ad or not ad.action:
        return []
    act = ad.action
    if hasattr(act, "fcurves"):
        try:
            if len(act.fcurves):
                return list(act.fcurves)
        except Exception:
            pass
    out = []
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                out += list(cb.fcurves)
    return out


def keys(target, path, frames_values, interp="BEZIER", easing="AUTO", index=-1, owner=None):
    """Insert keyframes [(frame, value)] on target.path and set their interpolation."""
    owner = owner or target
    for f, v in frames_values:
        if index >= 0:
            getattr(target, path)[index] = v
        elif isinstance(v, (tuple, list)):
            setattr(target, path, v) if not path.startswith("[") else target.__setitem__(path[2:-2], v)
        else:
            if path.startswith("["):
                target[path[2:-2]] = v
            else:
                setattr(target, path, v)
        target.keyframe_insert(path, frame=f, index=index)
    fset = {round(f, 3) for f, _ in frames_values}
    idb = target.id_data if hasattr(target, "id_data") else target
    for fc in fcurves(idb):
        if fc.data_path.endswith(path) or fc.data_path == path:
            for kp in fc.keyframe_points:
                if round(kp.co.x, 3) in fset:
                    kp.interpolation = interp
                    kp.easing = easing


def pop_in(obj, frame, scale=1.0, drop=0.5, dur=9):
    """Scale from 0 with overshoot and drop in from above."""
    s = scale
    base = obj.location.copy()
    keys(obj, "scale", [(frame - 1, (0, 0, 0))], interp="CONSTANT")
    keys(obj, "scale", [(frame, (s * 0.2, s * 0.2, s * 0.2))], interp="BACK", easing="EASE_OUT")
    keys(obj, "scale", [(frame + dur, (s, s, s))], interp="LINEAR")
    obj.location = (base.x, base.y, base.z + drop)
    keys(obj, "location", [(frame, (base.x, base.y, base.z + drop))], interp="BOUNCE", easing="EASE_OUT")
    keys(obj, "location", [(frame + dur + 3, (base.x, base.y, base.z))], interp="BEZIER")


def ensure_prop(obj, name, value=0.0):
    obj[name] = value
    return obj


# ---------------------------------------------------------------- materials
def burnable(name, base, rough=0.45, emit=None, emit_strength=0.0, edge="#FF8A2A", char="#120A06", spec=0.5, sss=0.0):
    """Principled material that chars, glows at the edge and disappears as object['burn'] goes 0->1."""
    m = mat(name, base=base, rough=rough, emit=emit, emit_strength=emit_strength, spec=spec, sss=sss)
    nt = m.node_tree; N = nt.nodes; L = nt.links
    out = N["Material Output"]; p = N["Principled BSDF"]
    at = N.new("ShaderNodeAttribute"); at.attribute_type = "OBJECT"; at.attribute_name = "burn"
    tc = N.new("ShaderNodeTexCoord")
    nz0 = N.new("ShaderNodeTexNoise"); nz0.inputs["Scale"].default_value = 3.2; nz0.inputs["Detail"].default_value = 6
    L.new(tc.outputs["Object"], nz0.inputs["Vector"])
    # the noise clusters around 0.5: stretch 0.32-0.68 to 0-1 so the burn front moves evenly through the whole burn
    nz = N.new("ShaderNodeMapRange"); nz.inputs["From Min"].default_value = 0.32; nz.inputs["From Max"].default_value = 0.68
    nz.clamp = True; L.new(nz0.outputs["Fac"], nz.inputs["Value"])
    # t = burn*1.4 - 0.35: nothing burns or chars at burn = 0, everything is gone at burn = 1
    t = N.new("ShaderNodeMath"); t.operation = "MULTIPLY_ADD"; t.inputs[1].default_value = 1.4; t.inputs[2].default_value = -0.35
    L.new(at.outputs["Fac"], t.inputs[0])
    gone = N.new("ShaderNodeMath"); gone.operation = "LESS_THAN"
    L.new(nz.outputs["Result"], gone.inputs[0]); L.new(t.outputs[0], gone.inputs[1])
    t2 = N.new("ShaderNodeMath"); t2.operation = "ADD"; t2.inputs[1].default_value = 0.09; L.new(t.outputs[0], t2.inputs[0])
    edge_m = N.new("ShaderNodeMath"); edge_m.operation = "LESS_THAN"
    L.new(nz.outputs["Result"], edge_m.inputs[0]); L.new(t2.outputs[0], edge_m.inputs[1])
    edge_only = N.new("ShaderNodeMath"); edge_only.operation = "SUBTRACT"; edge_only.use_clamp = True
    L.new(edge_m.outputs[0], edge_only.inputs[0]); L.new(gone.outputs[0], edge_only.inputs[1])
    # char band: darken base colour within 0.22 of the front
    t3 = N.new("ShaderNodeMath"); t3.operation = "ADD"; t3.inputs[1].default_value = 0.3; L.new(t.outputs[0], t3.inputs[0])
    charf = N.new("ShaderNodeMapRange"); charf.inputs["From Min"].default_value = 0.0; charf.inputs["From Max"].default_value = 0.3
    d = N.new("ShaderNodeMath"); d.operation = "SUBTRACT"; L.new(t3.outputs[0], d.inputs[0]); L.new(nz.outputs["Result"], d.inputs[1])
    L.new(d.outputs[0], charf.inputs["Value"])
    mixc = N.new("ShaderNodeMix"); mixc.data_type = "RGBA"
    L.new(charf.outputs["Result"], mixc.inputs["Factor"])
    mixc.inputs["A"].default_value = srgb(base); mixc.inputs["B"].default_value = srgb(char)
    L.new(mixc.outputs["Result"], p.inputs["Base Color"])
    em = N.new("ShaderNodeEmission"); em.inputs["Color"].default_value = srgb(edge); em.inputs["Strength"].default_value = 18.0
    m1 = N.new("ShaderNodeMixShader"); L.new(edge_only.outputs[0], m1.inputs["Fac"])
    L.new(p.outputs["BSDF"], m1.inputs[1]); L.new(em.outputs["Emission"], m1.inputs[2])
    tr = N.new("ShaderNodeBsdfTransparent")
    m2 = N.new("ShaderNodeMixShader"); L.new(gone.outputs[0], m2.inputs["Fac"])
    L.new(m1.outputs["Shader"], m2.inputs[1]); L.new(tr.outputs["BSDF"], m2.inputs[2])
    L.new(m2.outputs["Shader"], out.inputs["Surface"])
    if hasattr(m, "surface_render_method"):
        m.surface_render_method = "DITHERED"
    return m


def emissive(name, color, strength=1.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial"); e = nt.nodes.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = srgb(color); e.inputs["Strength"].default_value = strength
    nt.links.new(e.outputs[0], o.inputs["Surface"])
    return m


def fade_emissive(name, color, strength=1.0):
    """Emission mixed with transparency by object['alpha'] (1 = visible)."""
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear(); N = nt.nodes; L = nt.links
    o = N.new("ShaderNodeOutputMaterial"); e = N.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = srgb(color); e.inputs["Strength"].default_value = strength
    tr = N.new("ShaderNodeBsdfTransparent"); mx = N.new("ShaderNodeMixShader")
    at = N.new("ShaderNodeAttribute"); at.attribute_type = "OBJECT"; at.attribute_name = "alpha"
    L.new(at.outputs["Fac"], mx.inputs["Fac"]); L.new(tr.outputs[0], mx.inputs[1]); L.new(e.outputs[0], mx.inputs[2])
    L.new(mx.outputs[0], o.inputs["Surface"])
    if hasattr(m, "surface_render_method"):
        m.surface_render_method = "BLENDED"
    return m


# ---------------------------------------------------------------- layered icons from SVG
def svg_icon(name, layers, height=1.0, ref=None):
    """layers: [(svg_path, extrude, bevel, offset, depth, material)], first layer (or ref) sets the scale.
    Returns (root_empty, [part objects]). Icon stands upright facing -Y, centred, `height` tall."""
    from mathutils import Matrix
    parts = []
    for path, ext, bev, off, z, m in layers:
        o = import_svg(path); parts.append((o, ext, bev, off, z, m))
    refo = parts[0][0] if ref is None else parts[ref][0]
    pts = [refo.matrix_world @ p.co for s in refo.data.splines for p in s.bezier_points]
    x0, x1 = min(p.x for p in pts), max(p.x for p in pts); y0, y1 = min(p.y for p in pts), max(p.y for p in pts)
    sc = height / (y1 - y0); cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    root = bpy.data.objects.new(name, None); bpy.context.scene.collection.objects.link(root)
    out = []
    for o, ext, bev, off, z, m in parts:
        for s in o.data.splines:
            for p in s.bezier_points:
                for attr in ("co", "handle_left", "handle_right"):
                    v = o.matrix_world @ getattr(p, attr)
                    setattr(p, attr, Vector(((v.x - cx) * sc, (v.y - cy) * sc, 0)))
        o.matrix_world = Matrix.Identity(4)
        cu = o.data; cu.dimensions = "2D"; cu.fill_mode = "BOTH"; cu.resolution_u = 14
        cu.extrude = ext; cu.bevel_depth = bev; cu.bevel_resolution = 4; cu.offset = off
        cu.materials.clear(); cu.materials.append(m)
        o.rotation_euler = (math.radians(90), 0, 0); o.location = (0, -z, 0)
        o.parent = root; o.name = f"{name}_{os.path.basename(cu.name)}"
        out.append(o)
    return root, out


def clone_icon(root, parts, name):
    """Linked duplicate of an icon (shares curve data); returns (root, parts)."""
    r2 = bpy.data.objects.new(name, None); bpy.context.scene.collection.objects.link(r2)
    out = []
    for p in parts:
        q = bpy.data.objects.new(f"{name}_{p.name}", p.data)
        bpy.context.scene.collection.objects.link(q)
        q.rotation_euler = p.rotation_euler; q.location = p.location; q.scale = p.scale
        q.parent = r2; out.append(q)
    return r2, out

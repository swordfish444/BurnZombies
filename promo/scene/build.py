"""BurnZombies promo: one stage, five shots, ~21 s at 30 fps.
Usage: blender -b --factory-startup -P build.py -- [--stills 30,120,...] [--preview] [--render OUTDIR] [--save file.blend]
"""
import sys, os, math, random, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy
from mathutils import Vector
import bzkit as K

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default
PREVIEW = "--preview" in argv

FPS = 30
def F(sec):  # seconds -> frame
    return int(round(sec * FPS)) + 1

PROMO = os.path.dirname(HERE)
BUILD = os.path.join(PROMO, "build")
os.makedirs(BUILD, exist_ok=True)
T = json.load(open(os.path.join(PROMO, "timeline.json")))
END = F(T["end"])
ENGINE = "EEVEE" if "--eevee" in argv else "CYCLES"
sc = K.reset(fps=FPS, frames=(1, END), engine=ENGINE, samples=int(arg("--samples", 128)))
if PREVIEW:
    sc.render.resolution_percentage = int(arg("--scale", 50))
    sc.eevee.taa_render_samples = 16
    if ENGINE == "CYCLES":
        sc.cycles.samples = int(arg("--samples", 32))
sc.render.use_motion_blur = True
sc.render.motion_blur_shutter = 0.5
rnd = random.Random(11)

# ------------------------------------------------------------------ stage
import bmesh
def cyclorama():
    me = bpy.data.meshes.new("Cyc"); bm = bmesh.new()
    W, Y0, Y1, R, H = 60, -30, 9, 6, 30
    prof = [(Y0, 0)] + [(Y1 + R * math.sin(a), R - R * math.cos(a)) for a in [i * math.pi / 2 / 16 for i in range(17)]] + [(Y1 + R, H)]
    rows = []
    for x in (-W / 2, W / 2):
        rows.append([bm.verts.new((x, y, z)) for y, z in prof])
    for i in range(len(prof) - 1):
        bm.faces.new((rows[0][i], rows[1][i], rows[1][i + 1], rows[0][i + 1]))
    bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new("Cyc", me); sc.collection.objects.link(o)
    for p in me.polygons: p.use_smooth = True
    m = K.mat("Stage", base="#1A1716", rough=0.55, spec=0.35)
    me.materials.append(m)
    return o
cyclorama()

# ------------------------------------------------------------------ laptop
def rounded_box(name, size, bevel, mat, loc=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.active_object; o.name = name
    o.scale = size; bpy.ops.object.transform_apply(scale=True)
    b = o.modifiers.new("bev", "BEVEL"); b.width = bevel; b.segments = 6; b.limit_method = "NONE"
    o.data.materials.append(mat)
    for p in o.data.polygons: p.use_smooth = True
    return o

alu = K.mat("Alu", base="#3A3B40", rough=0.32, metal=0.85, spec=0.6)
bezel = K.mat("Bezel", base="#0B0B0D", rough=0.25, spec=0.6)
laptop = bpy.data.objects.new("Laptop", None); sc.collection.objects.link(laptop)
laptop.location = (0, 0.9, 0)
base = rounded_box("LapBase", (2.9, 2.0, 0.07), 0.03, alu, (0, 0, 0.035)); base.parent = laptop
hinge = bpy.data.objects.new("Hinge", None); sc.collection.objects.link(hinge)
hinge.parent = laptop; hinge.location = (0, 0.98, 0.07); hinge.rotation_euler = (math.radians(-12), 0, 0)
lid = rounded_box("LapLid", (2.9, 0.05, 1.9), 0.025, alu, (0, 0, 0.95)); lid.parent = hinge
bez = rounded_box("LapBezel", (2.84, 0.01, 1.84), 0.02, bezel, (0, -0.028, 0.95)); bez.parent = hinge
img = bpy.data.images.load(os.path.join(HERE, "art", "screen.png"))
scr_m = bpy.data.materials.new("Screen"); scr_m.use_nodes = True
nt = scr_m.node_tree; nt.nodes.clear()
o_ = nt.nodes.new("ShaderNodeOutputMaterial"); em_ = nt.nodes.new("ShaderNodeEmission"); tx_ = nt.nodes.new("ShaderNodeTexImage")
tx_.image = img; em_.inputs["Strength"].default_value = 1.6
nt.links.new(tx_.outputs["Color"], em_.inputs["Color"]); nt.links.new(em_.outputs[0], o_.inputs["Surface"])
bpy.ops.mesh.primitive_plane_add(size=1)
scr = bpy.context.active_object; scr.name = "LapScreen"
scr.scale = (2.7, 1.69, 1); bpy.ops.object.transform_apply(scale=True)
scr.rotation_euler = (math.radians(90), 0, 0); scr.location = (0, -0.035, 1.0); scr.parent = hinge
scr.data.materials.append(scr_m)
# keyboard deck hint
kb = rounded_box("Keys", (2.5, 1.0, 0.01), 0.004, bezel, (0, 0.25, 0.071)); kb.parent = laptop
pad = rounded_box("Pad", (1.0, 0.62, 0.005), 0.003, K.mat("Pad", base="#2C2D31", rough=0.4, metal=0.6), (0, -0.62, 0.071)); pad.parent = laptop
screen_light = K.light("AREA", "ScreenGlow", (0, 0.3, 1.2), 160, "#9CC4FF", size=2.6, look=(0, -3, 0.4))

# ------------------------------------------------------------------ materials for junk
zg = {
    "head": K.burnable("ZHead", base="#7FA35C", rough=0.5, sss=0.1),
    "whites": K.burnable("ZWhite", base="#EFEBD8", rough=0.3),
    "lid": K.burnable("ZLid", base="#5E7F45", rough=0.5),
    "pupils": K.burnable("ZPupil", base="#16140F", rough=0.2),
    "mouth": K.burnable("ZMouth", base="#2A1712", rough=0.4),
    "teeth": K.burnable("ZTeeth", base="#EFE6CC", rough=0.3),
    "stitch": K.burnable("ZStitch", base="#2E3A22", rough=0.4),
}
I = os.path.join(HERE, "art", "icons")
z_layers = [
    (f"{I}/z_head.svg", 0.07, 0.06, -0.05, 0.0, zg["head"]),
    (f"{I}/z_whites.svg", 0.02, 0.02, -0.012, 0.11, zg["whites"]),
    (f"{I}/z_lid.svg", 0.02, 0.018, -0.01, 0.135, zg["lid"]),
    (f"{I}/z_pupils.svg", 0.012, 0.012, -0.006, 0.15, zg["pupils"]),
    (f"{I}/z_mouth.svg", 0.015, 0.015, -0.01, 0.11, zg["mouth"]),
    (f"{I}/z_teeth.svg", 0.012, 0.012, -0.004, 0.13, zg["teeth"]),
    (f"{I}/z_stitch.svg", 0.012, 0.01, 0.0, 0.11, zg["stitch"]),
]
zroot, zparts = K.svg_icon("ZombieProto", z_layers, height=0.62)
zroot.location = (0, 0, -50)  # park prototype off stage

fg = {
    "back": K.burnable("FBack", base="#3E86D6", rough=0.38),
    "front": K.burnable("FFront", base="#64A8F0", rough=0.33),
    "branch": K.burnable("FBranch", base="#2D64AE", rough=0.35),
}
f_layers = [
    (f"{I}/f_back.svg", 0.05, 0.04, -0.03, 0.0, fg["back"]),
    (f"{I}/f_front.svg", 0.05, 0.045, -0.035, 0.09, fg["front"]),
    (f"{I}/f_branch.svg", 0.012, 0.012, -0.004, 0.185, fg["branch"]),
]
froot, fparts = K.svg_icon("FolderProto", f_layers, height=0.62)
froot.location = (0, 0, -50)

crate_m = K.burnable("Crate", base="#2D3139", rough=0.5, spec=0.4)
crate_lbl = K.burnable("CrateLabel", base="#D9D3C2", rough=0.4)

# ------------------------------------------------------------------ junk placement
def burn_keys(parts, f0, f1):
    for p in parts:
        p["burn"] = 0.0
        K.keys(p, '["burn"]', [(f0, 0.0)], interp="LINEAR")
        K.keys(p, '["burn"]', [(f1, 1.0)], interp="LINEAR")

junk = []  # (kind, root, parts, position)
EVENTS = {"spawn": [], "burn": []}
def place(kind, pos, rot_z, scale, spawn_t):
    EVENTS["spawn"].append({"t": round(spawn_t, 3), "kind": "zombie" if kind == "zombie" else ("folder" if kind == "folder" else "crate"), "x": pos[0]})
    if kind == "zombie":
        r, parts = K.clone_icon(zroot, zparts, f"Zombie{len(junk)}")
    elif kind == "folder":
        r, parts = K.clone_icon(froot, fparts, f"Folder{len(junk)}")
    else:
        r = bpy.data.objects.new(f"Crate{len(junk)}", None); sc.collection.objects.link(r)
        s = scale
        box = rounded_box(f"CrateBox{len(junk)}", (0.62, 0.62, 0.62), 0.03, crate_m, (0, 0, 0.31)); box.parent = r
        lbl = K.text(kind, size=0.14, extrude=0.008, bevel=0.002, material=crate_lbl, name=f"CrateTxt{len(junk)}")
        lbl.parent = r; lbl.location = (0, -0.318, 0.31)
        parts = [box, lbl]
        scale = 1.0 * s
    z_off = 0.31 * scale if kind in ("zombie", "folder") else 0.0
    r.location = (pos[0], pos[1], pos[2] + z_off)
    r.rotation_euler = (0, 0, math.radians(rot_z))
    r.scale = (scale, scale, scale)
    K.pop_in(r, F(spawn_t), scale=scale, drop=0.7, dur=8)
    junk.append((kind, r, parts, Vector(pos), scale))
    return r

# zombies: front-left horde
zpos = [(-2.0, -1.4), (-2.7, -0.7), (-1.45, -2.2), (-3.3, -1.7), (-2.35, -2.75), (-1.1, -0.9), (-3.6, -0.3), (-3.0, -2.6), (-1.7, -3.3)]
for i, (x, y) in enumerate(zpos):
    place("zombie", (x, y, 0), rnd.uniform(-25, 25) + 12, rnd.uniform(0.85, 1.15), T["spawn0"] + i * 0.24 + rnd.uniform(0, 0.1))
# folders: front-right piles
fpos = [(1.6, -1.3, 0), (2.25, -1.05, 0), (1.95, -1.25, 0.42), (2.9, -1.8, 0), (1.3, -2.3, 0), (2.5, -2.6, 0), (3.4, -0.6, 0), (2.85, -0.5, 0.0), (3.2, -1.25, 0.4), (1.9, -3.2, 0)]
for i, p in enumerate(fpos):
    place("folder", p, rnd.uniform(-30, 30) - 10, rnd.uniform(0.9, 1.1), T["spawn0"] + 0.1 + i * 0.22 + rnd.uniform(0, 0.1))
# crates: behind, stacked
cpos = [(-2.6, 0.9, 0, "NODE_MODULES"), (-3.35, 1.4, 0, "DERIVEDDATA"), (-2.9, 1.15, 0.64, ".NEXT"), (2.7, 0.95, 0, "TARGET"),
        (3.45, 1.45, 0, "NODE_MODULES"), (3.05, 1.2, 0.64, "BUILD"), (-4.2, 0.4, 0, "DIST"), (4.25, 0.2, 0, ".GRADLE")]
for i, (x, y, z, lbl) in enumerate(cpos):
    place(lbl, (x, y, z), rnd.uniform(-18, 18), rnd.uniform(0.9, 1.1), T["spawn0"] + 0.2 + i * 0.28 + rnd.uniform(0, 0.08))

# zombie shamble: sway + hop until burned
for kind, r, parts, pos, jsc in junk:
    if kind != "zombie":
        continue
    ph = rnd.uniform(0, 6.28); base_rot = r.rotation_euler.z; base_z = r.location.z
    f_start = F(T["spawn0"]) + 12
    f_stop = F(T["burn_zombies"]) + 20
    for f in range(f_start, f_stop, 4):
        u = (f - f_start) / FPS
        r.rotation_euler = (0, math.radians(6 * math.sin(ph + u * 5.5)), base_rot + math.radians(9 * math.sin(ph + u * 3.1)))
        r.keyframe_insert("rotation_euler", frame=f)

# ------------------------------------------------------------------ gauge
gauge = bpy.data.objects.new("Gauge", None); sc.collection.objects.link(gauge)
gauge.location = (0, 3.4, 3.55)
gm = bpy.data.materials.new("GaugeMat"); gm.use_nodes = True
nt = gm.node_tree; N = nt.nodes; L = nt.links; N.clear()
o_ = N.new("ShaderNodeOutputMaterial"); tc = N.new("ShaderNodeTexCoord"); sx = N.new("ShaderNodeSeparateXYZ")
L.new(tc.outputs["Object"], sx.inputs[0])
mr = N.new("ShaderNodeMapRange"); mr.inputs["From Min"].default_value = -2.6; mr.inputs["From Max"].default_value = 2.6
L.new(sx.outputs["X"], mr.inputs["Value"])
at = N.new("ShaderNodeAttribute"); at.attribute_type = "OBJECT"; at.attribute_name = "fill"
lt = N.new("ShaderNodeMath"); lt.operation = "LESS_THAN"; L.new(mr.outputs["Result"], lt.inputs[0]); L.new(at.outputs["Fac"], lt.inputs[1])
ramp = N.new("ShaderNodeValToRGB"); L.new(at.outputs["Fac"], ramp.inputs["Fac"])
cr = ramp.color_ramp
cr.elements[0].position = 0.5; cr.elements[0].color = K.srgb("#F3EBD6")
cr.elements[1].position = 0.95; cr.elements[1].color = K.srgb("#FF2A14")
mid = cr.elements.new(0.78); mid.color = K.srgb("#FF6A1E")
fill_em = N.new("ShaderNodeEmission"); fill_em.inputs["Strength"].default_value = 0.85; L.new(ramp.outputs["Color"], fill_em.inputs["Color"])
track = N.new("ShaderNodeBsdfPrincipled"); track.inputs["Base Color"].default_value = K.srgb("#2A2624"); track.inputs["Roughness"].default_value = 0.4
mx = N.new("ShaderNodeMixShader"); L.new(lt.outputs[0], mx.inputs["Fac"]); L.new(track.outputs[0], mx.inputs[1]); L.new(fill_em.outputs[0], mx.inputs[2])
L.new(mx.outputs[0], o_.inputs["Surface"])
bar = rounded_box("GaugeBar", (5.2, 0.3, 0.3), 0.149, gm, (0, 0, 0)); bar.parent = gauge
bar.modifiers["bev"].segments = 10
frame_m = K.mat("GaugeFrame", base="#0F0E0E", rough=0.3)
cream = K.emissive("CreamText", "#F6EFDC", 1.2)
cream_dim = K.emissive("CreamDim", "#BDB5A3", 0.9)
orange_t = K.emissive("OrangeText", "#FF5A1F", 2.4)
lbl_hd = K.text("MACINTOSH HD", size=0.3, extrude=0.0, bevel=0.0, material=cream_dim, align="LEFT", name="GaugeLbl")
lbl_hd.parent = gauge; lbl_hd.location = (-2.6, 0, 0.42)
pct = K.text("40% FULL", size=0.3, extrude=0.0, bevel=0.0, material=cream, align="RIGHT", name="GaugePct")
pct.parent = gauge; pct.location = (2.6, 0, 0.42)
bar["fill"] = 0.4
K.keys(bar, '["fill"]', [(F(0), 0.42)], interp="LINEAR")
K.keys(bar, '["fill"]', [(F(T["gauge_full"]), 0.98)], interp="SINE", easing="EASE_IN_OUT")
K.keys(bar, '["fill"]', [(F(T["counter0"]), 0.98)], interp="EXPO", easing="EASE_OUT")
K.keys(bar, '["fill"]', [(F(T["counter1"]), 0.31)], interp="LINEAR")
K.keys(gauge, "scale", [(F(T["shots"]["E"]) - 1, (1, 1, 1)), (F(T["shots"]["E"]), (0, 0, 0))], interp="CONSTANT")
gauge_glow = K.light("POINT", "GaugeGlow", (1.5, 3.0, 3.4), 0, "#FF3A1A", size=1.0)
K.keys(gauge_glow.data, "energy", [(F(T["gauge_full"]) - 40, 0), (F(T["gauge_full"]), 900), (F(T["counter0"]), 900), (F(T["counter1"]), 0)], interp="SINE")

# ------------------------------------------------------------------ mascot
mroot, mobjs, mmats = K.mascot(frames=(1, END), embers=26)
mroot.scale = (0.95, 0.95, 0.95)
land = Vector((0, -1.75, 0.95))
fall0, imp = F(T["drop"]), F(T["impact"])
K.keys(mroot, "location", [(1, (land.x, land.y, 14)), (fall0, (land.x, land.y, 9))], interp="CONSTANT")
K.keys(mroot, "location", [(fall0, (land.x, land.y, 9))], interp="QUAD", easing="EASE_IN")
K.keys(mroot, "location", [(imp, tuple(land))], interp="BEZIER")
s = 0.95
K.keys(mroot, "scale", [(fall0, (s * 0.88, s * 0.88, s * 1.16)), (imp, (s * 0.88, s * 0.88, s * 1.16))], interp="LINEAR")
K.keys(mroot, "scale", [(imp + 1, (s * 1.22, s * 1.22, s * 0.74))], interp="BACK", easing="EASE_OUT")
K.keys(mroot, "scale", [(imp + 9, (s, s, s))], interp="BEZIER")
# idle bob after landing
for f in range(imp + 12, END, 12):
    u = (f - imp) / FPS
    mroot.location = (land.x, land.y, land.z + 0.05 * math.sin(u * 3.2))
    mroot.keyframe_insert("location", frame=f)
# "We burn" flare
flare = F(T.get("flare", T["we_burn"]))
K.keys(mroot, "scale", [(flare - 1, (s, s, s)), (flare + 4, (s * 1.08, s * 1.08, s * 1.08)), (flare + 14, (s, s, s))], interp="BACK", easing="EASE_OUT")
fl = mmats["flame"].node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
K.keys(fl, "default_value", [(flare - 1, 0.35), (flare + 3, 1.3), (flare + 20, 0.45)], interp="SINE")
mlight = K.light("POINT", "MascotGlow", (0, -1.2, 1.6), 0, "#FF6A24", size=0.7)
K.keys(mlight.data, "energy", [(imp - 1, 0), (imp, 5200), (imp + 30, 520)], interp="EXPO", easing="EASE_OUT")
mlight.parent = None
for f in range(imp + 30, END, 3):  # flicker
    mlight.data.energy = 520 + 140 * math.sin(f * 1.7) + 90 * math.sin(f * 0.53)
    mlight.data.keyframe_insert("energy", frame=f)

# fire ring shockwave
bpy.ops.mesh.primitive_torus_add(major_radius=1.0, minor_radius=0.06, major_segments=96, minor_segments=12, location=(land.x, land.y, 0.06))
ring = bpy.context.active_object; ring.name = "FireRing"
ring_m = K.fade_emissive("RingMat", "#FF8A2A", 18.0); ring.data.materials.append(ring_m)
ring["alpha"] = 0.0
K.keys(ring, '["alpha"]', [(imp - 1, 0.0), (imp, 1.0)], interp="CONSTANT")
K.keys(ring, '["alpha"]', [(imp + 26, 0.0)], interp="LINEAR")
K.keys(ring, "scale", [(imp, (0.3, 0.3, 1.0))], interp="EXPO", easing="EASE_OUT")
K.keys(ring, "scale", [(imp + 26, (9.5, 9.5, 0.4))], interp="LINEAR")

# ------------------------------------------------------------------ burning the junk
ember_m = K.mat("JunkEmber", base="#FFB060", emit="#FF7A2A", emit_strength=16.0)
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1); eproto = bpy.context.active_object
eproto.data.materials.append(ember_m); eproto.hide_render = True; eproto.hide_viewport = True
def embers_from(pos, f0, n=5, h=2.2):
    for k in range(n):
        e = bpy.data.objects.new("JE", eproto.data); sc.collection.objects.link(e)
        st = f0 + rnd.randint(0, 14); life = rnd.randint(28, 50); r = rnd.uniform(0.015, 0.035)
        x0, y0 = pos.x + rnd.uniform(-0.25, 0.25), pos.y + rnd.uniform(-0.2, 0.2); sw = rnd.uniform(0.1, 0.35); ph = rnd.uniform(0, 6)
        K.keys(e, "scale", [(st - 1, (0, 0, 0))], interp="CONSTANT")
        for kk in range(0, life + 1, 4):
            u = kk / life
            e.location = (x0 + sw * math.sin(ph + u * 5), y0, 0.3 + u * h)
            e.scale = (r * (1 - u) ** 0.7,) * 3
            e.keyframe_insert("location", frame=st + kk); e.keyframe_insert("scale", frame=st + kk)

center = Vector((land.x, land.y, 0))
for kind, r, parts, pos, jsc in junk:
    d = (pos - center).length
    if kind == "zombie":
        b0 = F(T["burn_zombies"]) + int(d * 2.2)
        dur = 22
    elif kind == "folder":
        b0 = F(T["burn_folders"]) + int(d * 2.0)
        dur = 22
    else:
        b0 = F(T["burn_crates"]) + int(d * 1.6)
        dur = 26
    burn_keys(parts, b0, b0 + dur)
    EVENTS["burn"].append({"t": round((b0 - 1) / FPS, 3), "kind": kind if kind in ("zombie", "folder") else "crate", "x": pos.x})
    embers_from(pos, b0, n=6)
    # hide after burning so nothing lingers
    K.keys(r, "scale", [(b0 + dur + 1, (jsc, jsc, jsc)), (b0 + dur + 2, (0, 0, 0))], interp="CONSTANT")

# backup glint on folders before they burn: cream rim pulse + chip
bk = F(T["backup"])
# chip in world space above the folder pile, facing camera C
chip = bpy.data.objects.new("BackupChip", None); sc.collection.objects.link(chip)
chip.location = (2.35, -1.6, 1.45)
chip_bg_m = K.fade_emissive("ChipBG", "#F6EFDC", 1.4)
chip_txt_m = K.fade_emissive("ChipTxt", "#1A1210", 1.0)
chip_bg = rounded_box("ChipBG", (2.35, 0.04, 0.42), 0.02, chip_bg_m, (0, 0, 0)); chip_bg.parent = chip
chip_bg.modifiers["bev"].width = 0.2; chip_bg.modifiers["bev"].segments = 8
chip_txt = K.text("BACKED UP FIRST", size=0.24, extrude=0.0, bevel=0.0, material=chip_txt_m, name="ChipTxt")
chip_txt.parent = chip; chip_txt.location = (0.12, -0.03, -0.005)
# check mark
ck = bpy.data.curves.new("Check", "CURVE"); ck.dimensions = "3D"; ck.bevel_depth = 0.028; ck.bevel_resolution = 3
sp = ck.splines.new("POLY"); sp.points.add(2)
for i, (x, z) in enumerate([(-0.98, 0.0), (-0.9, -0.08), (-0.76, 0.1)]):
    sp.points[i].co = (x, -0.04, z, 1)
cko = bpy.data.objects.new("CheckMark", ck); sc.collection.objects.link(cko); cko.parent = chip
ck.materials.append(K.fade_emissive("CheckMat", "#E8541C", 2.0))
for o in (chip_bg, chip_txt, cko):
    o["alpha"] = 0.0
    K.keys(o, '["alpha"]', [(bk - 1, 0.0)], interp="CONSTANT")
    K.keys(o, '["alpha"]', [(bk + 6, 1.0)], interp="SINE")
    K.keys(o, '["alpha"]', [(F(T["chip_out"]), 1.0)], interp="SINE")
    K.keys(o, '["alpha"]', [(F(T["chip_out"]) + 8, 0.0)], interp="LINEAR")
K.keys(chip, "scale", [(bk - 1, (0.6, 0.6, 0.6)), (bk + 8, (1, 1, 1))], interp="BACK", easing="EASE_OUT")

# folders flash cream (saved) just before burning
fb = fg["front"].node_tree.nodes["Principled BSDF"]
fb.inputs["Emission Color"].default_value = K.srgb("#F6EFDC")
K.keys(fb.inputs["Emission Strength"], "default_value", [(bk - 1, 0.0), (bk + 4, 1.6), (bk + 18, 0.0)], interp="SINE")

# ------------------------------------------------------------------ atmosphere
K.dust("EmberDustNear", 70, (-5, -10, 0.4), (5, -4.2, 4.5), seed=3, radius=(0.008, 0.02), strength=3.0, color="#FF9A55", drift=0.6, rise=0.005)
K.dust("EmberDustFar", 12, (-8, 1.5, 0.5), (8, 6, 6.0), seed=4, radius=(0.01, 0.025), strength=2.0, color="#FF8A45", drift=0.8, rise=0.006)

# ------------------------------------------------------------------ lights
K.light("AREA", "Key", (-5, -6, 7), 1400, "#FFF1E2", size=6, look=(0, 0, 0.5))
K.light("AREA", "Rim", (4, 5, 6), 900, "#FF7A3A", size=5, look=(0, -1, 0.8))
K.light("AREA", "Fill", (6, -5, 2), 260, "#C9D8FF", size=6, look=(0, 0, 0.5))
K.bloom(sc, threshold=1.0, strength=0.6, size=0.75)

# ------------------------------------------------------------------ cameras
def cam(name, lens=40, fstop=None, focus=None):
    cd = bpy.data.cameras.new(name); cd.lens = lens; cd.sensor_width = 36
    co = bpy.data.objects.new(name, cd); sc.collection.objects.link(co)
    if fstop:
        cd.dof.use_dof = True; cd.dof.aperture_fstop = fstop
        if focus is not None:
            cd.dof.focus_distance = focus
    return co

def move(co, track, keyset, interp="BEZIER", easing="AUTO"):
    """keyset: [(sec, loc)] ; camera tracks `track` (empty)."""
    for t_, loc in keyset:
        co.location = loc; co.keyframe_insert("location", frame=F(t_))
    for fc in K.fcurves(co):
        for kp in fc.keyframe_points:
            kp.interpolation = interp; kp.easing = easing
    c = co.constraints.new("TRACK_TO"); c.target = track; c.track_axis = "TRACK_NEGATIVE_Z"; c.up_axis = "UP_Y"

def target(name, keyset):
    e = bpy.data.objects.new(name, None); sc.collection.objects.link(e)
    for t_, loc in keyset:
        e.location = loc; e.keyframe_insert("location", frame=F(t_))
    return e

C = T["shots"]
camA = cam("CamA", lens=38, fstop=4.0, focus=3.0)
tA = target("tA", [(0, (0, 1.95, 1.0)), (C["B1"], (0, 0.2, 0.75))])
move(camA, tA, [(0, (0.0, -1.3, 1.25)), (C["B1"], (0.6, -8.8, 3.4))], interp="CUBIC", easing="EASE_IN_OUT")
camA.data.dof.focus_object = tA

camB1 = cam("CamB1", lens=45, fstop=2.8)
tB1 = target("tB1", [(C["B1"], (-2.1, -1.4, 0.35)), (C["B2"], (-2.4, -1.4, 0.35))])
move(camB1, tB1, [(C["B1"], (-0.3, -4.8, 0.75)), (C["B2"], (-1.0, -4.9, 0.8))], interp="LINEAR")
camB1.data.dof.focus_object = tB1

camB2 = cam("CamB2", lens=45, fstop=2.8)
tB2 = target("tB2", [(C["B2"], (2.2, -1.5, 0.35)), (C["B3"], (2.3, -1.4, 0.4))])
move(camB2, tB2, [(C["B2"], (0.6, -4.7, 0.95)), (C["B3"], (1.1, -4.3, 0.85))], interp="LINEAR")
camB2.data.dof.focus_object = tB2

camB3 = cam("CamB3", lens=32, fstop=4.0)
tB3 = target("tB3", [(C["B3"], (-1.2, 1.0, 0.9)), (C["C"], (0.0, 2.6, 3.0))])
move(camB3, tB3, [(C["B3"], (-3.0, -4.6, 1.1)), (C["C"], (-1.9, -5.6, 1.4))], interp="CUBIC", easing="EASE_IN_OUT")
camB3.data.dof.focus_object = tB3

camC = cam("CamC", lens=32, fstop=5.6)
tC = target("tC", [(C["C"], (0, -0.6, 1.1)), (C["C2"], (0, -0.45, 1.15))])
move(camC, tC, [(C["C"], (0, -10.8, 3.6)), (C["C2"], (0, -9.9, 3.4))], interp="LINEAR")
camC.data.dof.focus_object = tC
# impact shake on C
for k, amp in enumerate([0.12, -0.09, 0.07, -0.05, 0.03, -0.015, 0]):
    f = imp + k * 2
    camC.delta_location = (amp * 0.6, 0, amp); camC.keyframe_insert("delta_location", frame=f)

camC2 = cam("CamC2", lens=40, fstop=4.0)
tC2 = target("tC2", [(C["C2"], (2.0, -1.45, 0.75)), (C["D"], (2.1, -1.4, 0.85))])
move(camC2, tC2, [(C["C2"], (4.3, -5.9, 1.55)), (C["D"], (3.8, -5.2, 1.5))], interp="LINEAR")
camC2.data.dof.focus_object = tC2

camD = cam("CamD", lens=35, fstop=4.0)
tD = target("tD", [(C["D"], (0, 3.4, 2.75)), (C["E"], (0, 3.4, 2.9))])
move(camD, tD, [(C["D"], (0, -5.4, 3.0)), (C["E"], (0, -4.6, 3.1))], interp="LINEAR")
camD.data.dof.focus_object = tD

camE = cam("CamE", lens=50, fstop=2.8)
tE = target("tE", [(C["E"], (0, -1.75, 1.05)), (T["end"], (0, -1.75, 1.15))])
move(camE, tE, [(C["E"], (0.0, -11.2, 1.55)), (T["end"], (0.0, -9.9, 1.45))], interp="CUBIC", easing="EASE_OUT")
camE.data.dof.focus_object = mroot

for name, co in (("A", camA), ("B1", camB1), ("B2", camB2), ("B3", camB3), ("C", camC), ("C2", camC2), ("D", camD), ("E", camE)):
    t0 = 0 if name == "A" else C[name]
    m = sc.timeline_markers.new(name, frame=F(t0)); m.camera = co
sc.camera = camA

# per-frame text bodies
GB_FINAL = 685.6
def upd(scene, *_):
    f = scene.frame_current
    # gauge %
    v = 0.4
    for fc in K.fcurves(bar):
        if fc.data_path == '["fill"]':
            v = fc.evaluate(f)
    pct.data.body = f"{int(round(v * 100))}% FULL"
bpy.app.handlers.frame_change_pre.clear()
bpy.app.handlers.frame_change_pre.append(upd)

json.dump(EVENTS, open(os.path.join(BUILD, "events.json"), "w"), indent=1)

# ------------------------------------------------------------------ outputs
save = arg("--save")
if save:
    bpy.ops.wm.save_as_mainfile(filepath=save)
stills = arg("--stills")
if stills:
    os.makedirs(os.path.join(BUILD, "stills"), exist_ok=True)
    for s_ in stills.split(","):
        t_ = float(s_)
        K.render_still(os.path.join(BUILD, "stills", f"t{t_:05.2f}.png"), frame=F(t_))
outdir = arg("--render")
if outdir:
    sc.render.image_settings.file_format = "PNG"
    sc.render.filepath = os.path.join(outdir, "f_")
    fr = arg("--frames")
    if fr:
        a_, b_ = fr.split("-"); sc.frame_start, sc.frame_end = int(a_), int(b_)
    bpy.ops.render.render(animation=True)

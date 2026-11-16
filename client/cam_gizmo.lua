-- ============================================
-- CAMERA GIZMO — a camera drawn in the world
-- ============================================
--
-- A small body behind the lens and its VIEW, a 16:9 frame as wide as its lens, with a notch on the frame's top edge
-- for which way is up. Less of it the further away: past MID the frame and its four lines alone, past NEAR no faces.
-- The Camera Creator draws its keys with it (tools/camera.lua, which numbers them), and the Director's world builder
-- the other builders' cameras (client/director_room.lua).

CamGizmo = {}

CamGizmo.DIST, CamGizmo.MAX_H, CamGizmo.ASPECT = 1.0, 0.6, 16 / 9
CamGizmo.BODY = { front = 0.06, back = 0.42, hw = 0.13, hh = 0.1 }
CamGizmo.NEAR, CamGizmo.MID, CamGizmo.FAR = 35.0, 120.0, 300.0

local function line(a, b, r, g, bl, al) DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, al) end
local function quad(a, b, c, d, r, g, bl, al)
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, al)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, d.x, d.y, d.z, r, g, bl, al)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, r, g, bl, al)
    DrawPoly(d.x, d.y, d.z, c.x, c.y, c.z, a.x, a.y, a.z, r, g, bl, al)
end

--- A camera `p` = { x, y, z, pitch, yaw, fov } as points: its place `p`, its axes f (forward), r, u; the frame's
--- middle `c`, half height `hh` and half width `hw`, its corners tl tr br bl and notch nl tip nr; the body's front
--- corners f1..f4 and back k1..k4, its back's middle `bk`; and a sphere round it all (cx, cy, cz, radius) to cull by.
function CamGizmo.geom(p)
    local pitch, yaw = math.rad(p.pitch), math.rad(p.yaw)
    local cp, sp, cy, sy = math.cos(pitch), math.sin(pitch), math.cos(yaw), math.sin(yaw)
    local pos = vector3(p.x, p.y, p.z)
    local f = vector3(-sy * cp, cy * cp, sp)
    local r = vector3(cy, sy, 0.0)
    local u = vector3(sy * sp, -cy * sp, cp)
    local t = math.tan(math.rad((p.fov or 50.0) * 0.5))
    local d = math.min(CamGizmo.DIST, CamGizmo.MAX_H / math.max(t, 0.01))
    local hh = d * t
    local hw = hh * CamGizmo.ASPECT
    local c = pos + f * d
    local nb = hw * 0.16
    local top = c + u * hh
    local bd = CamGizmo.BODY
    local fr, bk = pos - f * bd.front, pos - f * bd.back
    local rw, uh = r * bd.hw, u * bd.hh
    local half = (d + bd.back) * 0.5
    local mid = pos + f * ((d - bd.back) * 0.5)
    return {
        p = pos, f = f, r = r, u = u, c = c, hh = hh, hw = hw, bk = bk,
        tl = c - r * hw + u * hh, tr = c + r * hw + u * hh, br = c + r * hw - u * hh, bl = c - r * hw - u * hh,
        nl = top - r * nb, tip = top + u * (nb * 1.1), nr = top + r * nb,
        f1 = fr - rw + uh, f2 = fr + rw + uh, f3 = fr + rw - uh, f4 = fr - rw - uh,
        k1 = bk - rw + uh, k2 = bk + rw + uh, k3 = bk + rw - uh, k4 = bk - rw - uh,
        cx = mid.x, cy = mid.y, cz = mid.z, radius = math.sqrt(half * half + hw * hw + hh * hh) + 0.1,
    }
end

--- Draws camera `g` (CamGizmo.geom) in colour `rgb` { r, g, b }, seen from `dist` metres.
function CamGizmo.draw(g, rgb, dist)
    local R, G, B = rgb[1], rgb[2], rgb[3]
    local p = g.p
    local tl, tr, br, bl = g.tl, g.tr, g.br, g.bl
    line(tl, tr, R, G, B, 230); line(tr, br, R, G, B, 230); line(br, bl, R, G, B, 230); line(bl, tl, R, G, B, 230)
    line(p, tl, R, G, B, 130); line(p, tr, R, G, B, 130); line(p, br, R, G, B, 130); line(p, bl, R, G, B, 130)
    if dist > CamGizmo.MID then return end
    local f1, f2, f3, f4, k1, k2, k3, k4 = g.f1, g.f2, g.f3, g.f4, g.k1, g.k2, g.k3, g.k4
    line(g.nl, g.tip, R, G, B, 230); line(g.tip, g.nr, R, G, B, 230)
    line(f1, f2, R, G, B, 255); line(f2, f3, R, G, B, 255); line(f3, f4, R, G, B, 255); line(f4, f1, R, G, B, 255)
    line(k1, k2, R, G, B, 255); line(k2, k3, R, G, B, 255); line(k3, k4, R, G, B, 255); line(k4, k1, R, G, B, 255)
    line(f1, k1, R, G, B, 255); line(f2, k2, R, G, B, 255); line(f3, k3, R, G, B, 255); line(f4, k4, R, G, B, 255)
    if dist > CamGizmo.NEAR then return end
    quad(tl, tr, br, bl, R, G, B, 28)
    quad(k1, k2, k3, k4, R, G, B, 150)
    quad(f1, k1, k4, f4, R, G, B, 110)
    quad(f2, k2, k3, f3, R, G, B, 110)
    quad(f1, f2, k2, k1, R, G, B, 130)
    quad(f4, f3, k3, k4, R, G, B, 90)
    line(f1, p, R, G, B, 200); line(f2, p, R, G, B, 200); line(f3, p, R, G, B, 200); line(f4, p, R, G, B, 200)
end

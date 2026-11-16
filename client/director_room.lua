-- ============================================
-- DIRECTOR ROOM, the game's half — the others with the same scenario open
-- ============================================
--
-- The server's room (server/director/room.lua) says who else has this scenario open, each in a colour of their own,
-- what each says of themselves, and every change made to the scenario. This hands it all to the page
-- (html/js/director/room.js puts the changes on its copy and draws the others' pointers and picks), and draws in the
-- world builder what the others do there (FurnishBuilder.frame calls DirectorRoom.frame): each one's camera where they
-- look from and their name over it, the spot their pointer is on, a tag over the thing they are working on, and a
-- thing they are moving where it is as they move it. This game is drawn as it always is.
--
-- What this game says of itself goes the other way: the page's part (where it is, the variant open, the pointer on
-- the blueprint, the picked cards, the thing and field it is on, what it drags: directorPresence) and the world
-- builder's (its camera, the spot under its pointer, the thing it is moving and where), added here. Sent at most every
-- SEND_MS, and only while someone else is in the room. The page's changes go to the server as they are made
-- (directorRoomOps): a big batch as a latent event, one at a time, so they arrive in order.
--
-- Another's camera comes every 100 ms or so, a third of a second late on a slow link: each new pose is eased to over
-- EASE_MS from where it was drawn, so it glides instead of jumping.

DirectorRoom = {}

--- Each member's colour, by the server's number for them (the page is handed these too).
local COLOURS = {
    { 251, 146, 60 },    -- orange
    { 167, 139, 250 },   -- violet
    { 45, 212, 191 },    -- teal
    { 244, 114, 182 },   -- pink
    { 250, 204, 21 },    -- yellow
    { 34, 211, 238 },    -- cyan
    { 163, 230, 53 },    -- lime
    { 248, 113, 113 },   -- red
}
local SEND_MS = 100
local EASE_MS = 150
local AIM_MS = 100                               -- this game's pointer in the world, asked this often
local AIM_REACH = 300.0
local HOLD_MS = 300                              -- a thing moved this recently is being moved
local CAM_MOVED_M, CAM_TURNED_DEG = 0.03, 0.4    -- this game's camera, moved enough to say so
local TAG_LIFT = 0.42                            -- another's name, this far over their camera
local DOT_M = 0.14                               -- another's pointer in the world, across
local WHERE = { page = true, builder = true, test = true, away = true }
local MAX_SEL = 40
local BIG = 6000                                 -- a batch of changes this big (bytes) goes as a latent event
local UPLOAD_BPS = 500000

local key = nil       -- the scenario whose room this game is in
local members = {}    -- [src] = { name, colour, rgb, state, cam = { from, to, at }, tag, thingTag }
local others = 0      -- how many of them are not this game
local mine = { where = 'away', variant = 'v1', cursor = false, cx = 0.0, cy = 0.0, sel = {}, thing = '', field = '', drag = '' }
local camPose = nil   -- this game's world builder camera, as last measured: { x, y, z, pitch, yaw, fov }
local aimAt = nil     -- the spot under this game's pointer in the world builder: { x, y, z }
local hold = nil      -- the thing this game is moving in the world builder: { id, x, y, z, h }
local lastSend, sendQueued = 0, false

local function myId() return GetPlayerServerId(PlayerId()) end

local function ref(v, max)
    return type(v) == 'string' and #v <= max and v:match('^[%w_%-%.:|~]+$') and v or ''
end

-- ============================================
-- Saying where this game is
-- ============================================

local function send()
    sendQueued = false
    if not key or others == 0 then return end
    lastSend = GetGameTimer()
    local builder = mine.where == 'builder'
    local cam = builder and camPose or nil
    local aim = builder and aimAt or nil
    -- (What this game moves in the world is its drag, and where it is.)
    local drag = builder and hold and ('thing:' .. hold.id) or mine.drag
    local thing = builder and FurnishBuilder.selectedId() or nil
    thing = type(thing) == 'string' and ref(thing, 160) ~= '' and ('thing:' .. thing) or mine.thing
    TriggerServerEvent('whip_core:server:directorPresence', mine.where, mine.variant, mine.cursor, mine.cx, mine.cy,
        mine.sel, cam ~= nil, cam or {}, aim ~= nil, aim or {}, thing, mine.field, drag, builder and hold ~= nil,
        builder and hold or {})
end

--- Something this game says changed: sent now, or once SEND_MS has passed since the last (one send for many changes).
local function said()
    if not key or others == 0 or sendQueued then return end
    local wait = SEND_MS - (GetGameTimer() - lastSend)
    if wait <= 0 then send() return end
    sendQueued = true
    SetTimeout(wait, send)
end

RegisterNUICallback('directorPresence', function(d, cb)
    cb('ok')
    if type(d) ~= 'table' then return end
    mine.where = WHERE[d.where] and d.where or 'away'
    mine.variant = type(d.variant) == 'string' and #d.variant <= 8 and d.variant:match('^v%d+$') and d.variant or 'v1'
    local x, y = tonumber(d.cx), tonumber(d.cy)
    mine.cursor = d.cursor == true and x ~= nil and y ~= nil and x == x and y == y
    mine.cx, mine.cy = mine.cursor and x or 0.0, mine.cursor and y or 0.0
    local sel = {}
    for _, id in ipairs(type(d.sel) == 'table' and d.sel or {}) do
        if #sel >= MAX_SEL then break end
        if type(id) == 'string' and #id <= 64 and id:match('^[%w_%-]+$') then sel[#sel + 1] = id end
    end
    mine.sel = sel
    mine.thing, mine.field, mine.drag = ref(d.thing, 160), ref(d.field, 200), ref(d.drag, 160)
    said()
end)

-- ============================================
-- The scenario's changes, up and down
-- ============================================

-- The page's batch of changes (room.js): to the server, in order. A big one goes latent; the page sends the next only
-- once this one is answered (directorRoomAck), so a latent one is never overtaken.
RegisterNUICallback('directorRoomOps', function(d, cb)
    cb('ok')
    if type(d) ~= 'table' or type(d.key) ~= 'string' or type(d.ops) ~= 'table' then return end
    local roomId, epoch, n = math.tointeger(tonumber(d.roomId)), math.tointeger(tonumber(d.epoch)), math.tointeger(tonumber(d.n))
    if not (roomId and epoch and n) then return end
    local size = 0
    for _, op in ipairs(d.ops) do size = size + (type(op) == 'table' and type(op.v) == 'string' and #op.v or 0) + 64 end
    if size > BIG then
        TriggerLatentServerEvent('whip_core:server:directorRoomOps', UPLOAD_BPS, d.key, roomId, epoch, n, d.quiet == true, d.ops)
    else
        TriggerServerEvent('whip_core:server:directorRoomOps', d.key, roomId, epoch, n, d.quiet == true, d.ops)
    end
end)

-- Another's changes; this game's own batch numbered; the scenario as the room has it, whole; and a save of it.
RegisterNetEvent('whip_core:client:directorRoomOps', function(k, roomId, seq, src, ops, quiet)
    SendNUIMessage({ action = 'directorRoomOps', key = k, roomId = roomId, seq = seq, src = src, ops = ops, quiet = quiet == true })
end)

RegisterNetEvent('whip_core:client:directorRoomAck', function(k, roomId, seq, n, orders)
    SendNUIMessage({ action = 'directorRoomAck', key = k, roomId = roomId, seq = seq, n = n,
                     ops = type(orders) == 'table' and orders or {} })
end)

RegisterNetEvent('whip_core:client:directorRoomReset', function(k, roomId, seq, doc, dirty, epoch, why, baseRev)
    SendNUIMessage({ action = 'directorRoomReset', key = k, roomId = roomId, seq = seq, doc = doc, dirty = dirty == true,
                     epoch = epoch, why = type(why) == 'string' and why or nil, baseRev = baseRev })
end)

RegisterNetEvent('whip_core:client:directorRoomSaved', function(k, roomId, seq, rev, by, problems)
    SendNUIMessage({ action = 'directorRoomSaved', key = k, roomId = roomId, seq = seq, rev = rev,
                     by = type(by) == 'string' and by or 'Someone', problems = problems })
end)

-- ============================================
-- The others
-- ============================================

--- A pose from the wire, or nil.
local function poseOf(c)
    if type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (x and y and z) then return nil end
    return { x = x, y = y, z = z, pitch = tonumber(c.pitch) or 0.0, yaw = tonumber(c.yaw) or 0.0, fov = tonumber(c.fov) or 50.0 }
end

--- An angle's way from `a` to `b`, the short way round.
local function turn(a, b) return (b - a + 180.0) % 360.0 - 180.0 end

--- Where a member's camera is drawn now: eased from where it was to where it was said to be.
local function poseNow(cam, now)
    local t = math.min(1.0, (now - cam.at) / EASE_MS)
    if t >= 1.0 then return cam.to end
    local a, b = cam.from, cam.to
    return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t,
             pitch = a.pitch + (b.pitch - a.pitch) * t, yaw = a.yaw + turn(a.yaw, b.yaw) * t, fov = a.fov + (b.fov - a.fov) * t }
end

local function text(v) return type(v) == 'string' and v ~= '' and v or nil end

--- What a member says of themselves, read: the page's part kept as said, the camera eased to.
local function take(m, s)
    s = type(s) == 'table' and s or {}
    local builder = s.where == 'builder'
    m.state = { where = WHERE[s.where] and s.where or 'away', variant = type(s.variant) == 'string' and s.variant or 'v1',
                cursor = type(s.cursor) == 'table' and tonumber(s.cursor.x) and tonumber(s.cursor.y)
                    and { x = tonumber(s.cursor.x), y = tonumber(s.cursor.y) } or nil,
                sel = type(s.sel) == 'table' and s.sel or {},
                thing = text(s.thing), field = text(s.field), drag = text(s.drag) }
    m.aim = builder and poseOf(s.aim) or nil
    local h = builder and poseOf(s.hold) or nil
    m.hold = h and m.state.drag and m.state.drag:sub(1, 6) == 'thing:' and { id = m.state.drag:sub(7), x = h.x, y = h.y, z = h.z,
                                                                             h = tonumber(s.hold.h) or 0.0 } or nil
    local to = builder and poseOf(s.cam) or nil
    if not to then m.cam = nil return end
    local now = GetGameTimer()
    m.cam = { from = m.cam and poseNow(m.cam, now) or to, to = to, at = now }
end

--- The room, to the page: { key, members = { { src, name, colour, rgb, me, state } } } in the server's order.
local function tellPage(order)
    local list = {}
    local me = myId()
    for _, src in ipairs(order) do
        local m = members[src]
        if m then
            list[#list + 1] = { src = src, name = m.name, colour = m.colour, rgb = m.rgb, me = src == me, state = m.state }
        end
    end
    SendNUIMessage({ action = 'directorRoom', key = key, members = list })
end

--- The whole room (someone came, went, or moved between the page, the builder and a test). An empty list: this game
--- is out of it (the Director closed, the scenario deleted).
RegisterNetEvent('whip_core:client:directorRoom', function(k, list)
    if type(list) ~= 'table' or type(k) ~= 'string' then return end
    if #list == 0 then
        if k ~= key then return end
        key, members, others, camPose, aimAt, hold = nil, {}, 0, nil, nil, nil
        SendNUIMessage({ action = 'directorRoom', key = k, members = {} })
        return
    end
    local me = myId()
    local was = others
    key = k
    local now, order, n = {}, {}, 0
    for _, m in ipairs(list) do
        local src = type(m) == 'table' and math.tointeger(tonumber(m.src)) or nil
        if src then
            local e = members[src] or {}
            e.name = type(m.name) == 'string' and m.name ~= '' and m.name or 'Someone'
            e.colour = math.tointeger(tonumber(m.colour)) or 1
            e.rgb = COLOURS[e.colour] or COLOURS[1]
            take(e, m.state)
            now[src] = e
            order[#order + 1] = src
            if src ~= me then n = n + 1 end
        end
    end
    members, others = now, n
    tellPage(order)
    -- Someone new: they hear what this game says now, not only once it next changes.
    if others > was then said() end
end)

--- One member said something of themselves.
RegisterNetEvent('whip_core:client:directorPresence', function(k, src, s)
    src = math.tointeger(tonumber(src))
    local m = k == key and src and members[src] or nil
    if not m then return end
    take(m, s)
    SendNUIMessage({ action = 'directorPeer', key = key, src = src, state = m.state })
end)

AddEventHandler('whip_core:player:logout', function()
    key, members, others, camPose, aimAt, hold = nil, {}, 0, nil, nil, nil
end)

--- Is thing `id` being moved in the world builder by someone else? Their name, or nil (the builder leaves it to them:
--- client/furnish_builder.lua FurnishBuilder.lockedOut).
function DirectorRoom.heldBy(id)
    if not key or others == 0 or id == nil then return nil end
    local me = myId()
    for src, m in pairs(members) do
        if src ~= me and m.hold and m.hold.id == id then return m.name end
    end
    return nil
end

-- ============================================
-- In the world builder, every frame (FurnishBuilder.frame, between WorldMarks.begin and finish)
-- ============================================

local sqrt, abs = math.sqrt, math.abs
local aimNext = 0

--- This game's camera, said when it moved.
local function measureCamera()
    if not FreeCam.isActive() then return end
    local c, r = FreeCam.getCoord(), FreeCam.getRot()
    local fov = FreeCam.getFov()
    local p = camPose
    if not p or abs(c.x - p.x) > CAM_MOVED_M or abs(c.y - p.y) > CAM_MOVED_M or abs(c.z - p.z) > CAM_MOVED_M
        or abs(r.x - p.pitch) > CAM_TURNED_DEG or abs(turn(p.yaw, r.z)) > CAM_TURNED_DEG or abs(fov - p.fov) > 0.5 then
        camPose = { x = c.x, y = c.y, z = c.z, pitch = r.x, yaw = r.z % 360.0, fov = fov }
        said()
    end
end

--- The spot in the world under this game's pointer (the centre dot on a pad), every AIM_MS: said when it moved.
local function measureAim(now)
    if now < aimNext or not FreeCam.isActive() then return end
    aimNext = now + AIM_MS
    local nx, ny = 0.5, 0.5
    if not WhipPadActive then
        local w, h = GetActiveScreenResolution()
        local cx, cy = GetNuiCursorPosition()
        if not (w and h and w > 0 and h > 0 and cx and cy) then return end
        nx, ny = cx / w, cy / h
    end
    local spot = nil
    if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
        local c, r = FreeCam.getCoord(), FreeCam.getRot()
        local w, h = GetActiveScreenResolution()
        local kx, ky = FurnishView.kFromFov(FreeCam.getFov(), (w and h and h > 0) and w / h or (16 / 9))
        local dx, dy, dz = FurnishView.rayAt(nx, ny, r.x, r.z, kx, ky)
        local ray = StartShapeTestRay(c.x, c.y, c.z, c.x + dx * AIM_REACH, c.y + dy * AIM_REACH, c.z + dz * AIM_REACH, 1 + 16,
            PlayerPedId(), 0)
        local _, hit, at = GetShapeTestResult(ray)
        if hit == 1 or hit == true then spot = { x = at.x, y = at.y, z = at.z } end
    end
    local a = aimAt
    local moved = (spot == nil) ~= (a == nil)
        or (spot and (abs(spot.x - a.x) > 0.05 or abs(spot.y - a.y) > 0.05 or abs(spot.z - a.z) > 0.05))
    if moved then
        aimAt = spot
        said()
    end
end

--- The thing this game is moving: the selection, while its place keeps changing.
local holdWas = { id = nil, x = 0.0, y = 0.0, z = 0.0, h = 0.0, at = 0 }
local function measureHold(now)
    local id = FurnishBuilder.selectedId()
    local it = id and FurnishBuilder.itemOf(id)
    local w = holdWas
    if it and w.id == id and (abs(it.x - w.x) > 0.005 or abs(it.y - w.y) > 0.005 or abs(it.z - w.z) > 0.005
            or abs(turn(w.h, it.rz or 0.0)) > 0.2) then
        w.at = now
    end
    if it then w.id, w.x, w.y, w.z, w.h = id, it.x, it.y, it.z, (it.rz or 0.0) % 360.0 else w.id = nil end
    local moving = it ~= nil and now - w.at < HOLD_MS
    if moving then
        if not hold or hold.id ~= id or abs(hold.x - it.x) > 0.02 or abs(hold.y - it.y) > 0.02 or abs(hold.z - it.z) > 0.02
            or abs(turn(hold.h, w.h)) > 0.5 then
            hold = { id = id, x = it.x, y = it.y, z = it.z, h = w.h }
            said()
        end
    elseif hold then
        hold = nil
        said()
    end
end

--- Another's tag over the thing they are on: their name, what they do to it.
local function thingTag(src, m)
    local id = m.state.thing and m.state.thing:match('^thing:(.+)$')
    local it = id and FurnishBuilder.itemOf(id)
    if not it then return end
    local top = FurnishBuilder.topOf(it)
    local tag = m.thingTag or { kind = 'npc', glyph = 'target', first = true }
    m.thingTag = tag
    local moving = m.hold and m.hold.id == id
    tag.key, tag.name, tag.tint = 'roomthing:' .. src, m.name, m.rgb
    tag.detail = moving and 'Moving it' or (m.state.where == 'builder' and 'Working on it' or 'Its page open')
    tag.glyph = moving and 'place' or 'target'
    tag.x, tag.y, tag.z = it.x, it.y, (top or it.z) + WorldMarks.FLOAT_LIFT + 0.35
    WorldMarks.add(tag)
end

--- This game's camera, pointer and held thing, said when they move; the others' drawn.
function DirectorRoom.frame()
    if not key or others == 0 or not DirectorEditorOpen then return end
    local now = GetGameTimer()
    measureCamera()
    measureAim(now)
    measureHold(now)
    local eye = GetFinalRenderedCamCoord()
    local me = myId()
    for src, m in pairs(members) do
        if src ~= me then
            -- Their camera, and their name over it.
            if m.cam then
                local p = poseNow(m.cam, now)
                local g = CamGizmo.geom(p)
                local dx, dy, dz = g.cx - eye.x, g.cy - eye.y, g.cz - eye.z
                local d = sqrt(dx * dx + dy * dy + dz * dz)
                if d <= CamGizmo.FAR then
                    CamGizmo.draw(g, m.rgb, d)
                    local tag = m.tag or { kind = 'npc', glyph = 'camera', detail = 'In the world builder', first = true }
                    m.tag = tag
                    tag.key, tag.name, tag.tint = 'room:' .. src, m.name, m.rgb
                    tag.x, tag.y, tag.z = p.x, p.y, p.z + TAG_LIFT
                    WorldMarks.add(tag)
                end
            end
            -- The spot their pointer is on.
            local a = m.aim
            if a then
                DrawMarker(28, a.x, a.y, a.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, DOT_M, DOT_M, DOT_M,
                    m.rgb[1], m.rgb[2], m.rgb[3], 230, false, false, 2, false, nil, nil, false)
            end
            -- What they move, where they have it now (the scenario has it once they let go).
            if m.hold then FurnishBuilder.follow(m.hold.id, m.hold.x, m.hold.y, m.hold.z, m.hold.h, true) end
            if m.state.thing then thingTag(src, m) end
        end
    end
end

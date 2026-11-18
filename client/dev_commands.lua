-- Developer-mode commands: run only while developer mode is on (/w); anyone else is told so. The client twin of
-- server/commands.lua's devCommand; the server re-checks anything it does behind one.
-- Satellites can't register a command through whip_core (it would outlive them), so they ask HasDevTools() in their own handler.

--- Register a client command that works only with developer mode on.
---@param name string
---@param fn fun(source: number, args: table, raw: string)
function DevCommand(name, fn)
    RegisterCommand(name, function(source, args, raw)
        if not (DevToolsOn and DevToolsOn()) then
            UI.Notify('/' .. name .. ' is a developer tool: turn developer mode on in /w', 'error')
            return
        end
        return fn(source, args, raw)
    end, false)
end

--- For satellites: is developer mode on for this player? Only for what a client tool shows; the server's HasDevTools(source) is authoritative.
exports('HasDevTools', function()
    return (DevToolsOn and DevToolsOn()) == true
end)

-- ============================================
-- Noclip, God Mode, Invisible
-- ============================================
--
-- The /w tools of the same names, switched the way their rows switch them (SetDevTool, tools/core.lua), so the menu
-- shows what a command turned on, and turning developer mode off turns them off.

--- A /w tool on if it is off, off if it is on, and said.
---@param name string
local function flipTool(name)
    local on = SetDevTool(name, not DevToolActive(name))
    UI.Notify(('%s %s'):format(name, on and 'on' or 'off'), 'info')
end

DevCommand('noclip', function() flipTool('Noclip') end)
DevCommand('god', function() flipTool('God Mode') end)
DevCommand('invis', function() flipTool('Invisible') end)

-- ============================================
-- Teleports: /tpm, /tpc, /back
-- ============================================
--
-- To the map's waypoint, to coordinates, and back to where the last teleport took you from. Every teleport this game
-- is given remembers where it left, the Player Manager's and /tp's as well (pmTeleport, below), so /back goes there;
-- /back is a teleport too, so a second one goes back again.

--- Where the last teleport left from: { x, y, z, heading }, or nil before the first.
local lastSpot = nil

local function rememberSpot()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    lastSpot = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) }
end

--- Heights the waypoint's ground is looked for from, highest first: the map gives no height.
local PROBE_HEIGHTS = { 1000.0, 600.0, 300.0, 150.0, 50.0 }
local COLLISION_WAIT_MS = 1500

--- Wait (bounded) for the world's collision around the player to load.
local function waitForCollision(x, y, z)
    local ped, untilT = PlayerPedId(), GetGameTimer() + COLLISION_WAIT_MS
    RequestCollisionAtCoord(x, y, z)
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < untilT do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end
end

--- The height to stand at x, y: the ground, or the water's surface over it. Moves the player (and the car they drive)
--- up there to load it. nil when no ground was found.
local function groundAt(x, y)
    local ped = PlayerPedId()
    for _, h in ipairs(PROBE_HEIGHTS) do
        SetPedCoordsKeepVehicle(ped, x, y, h)
        waitForCollision(x, y, h)
        local found, gz = GetGroundZFor_3dCoord(x, y, h, false)
        if found then
            local wet, wz = GetWaterHeight(x, y, h)
            return (wet and wz > gz) and wz or gz
        end
    end
    return nil
end

local teleporting = false

--- Move there, with the car you drive, behind a short fade; no `z`: onto the ground under x, y. Remembers where it
--- left first. Waits: call it from a thread.
---@param x number
---@param y number
---@param z number|nil
---@param heading number|nil
local function teleport(x, y, z, heading)
    if teleporting then return end
    if DevToolActive('Noclip') then
        UI.Notify('Turn Noclip off first: it lands you where it stops', 'error')
        return
    end
    teleporting = true
    local from = lastSpot
    rememberSpot()
    local back = lastSpot
    ---@cast back -nil

    DoScreenFadeOut(250)
    local untilT = GetGameTimer() + 1000
    while not IsScreenFadedOut() and GetGameTimer() < untilT do Wait(0) end

    local ped = PlayerPedId()
    PedHold.set('devTeleport', { frozen = true })
    local ok, err = pcall(function()
        if not z then
            z = groundAt(x, y)
            if not z then
                -- Nowhere to stand: back where it started, and /back as it was.
                SetPedCoordsKeepVehicle(ped, back.x, back.y, back.z)
                lastSpot = from
                UI.Notify('No ground was found there', 'error')
                return
            end
        end
        SetPedCoordsKeepVehicle(ped, x, y, z)
        if heading then
            local veh = GetVehiclePedIsIn(ped, false)
            SetEntityHeading(veh ~= 0 and veh or ped, heading + 0.0)
        end
        waitForCollision(x, y, z)
    end)
    if not ok then print(('[whip_core:dev] the teleport failed: %s'):format(tostring(err))) end
    -- Let go and fade back in whatever happened, so the screen always comes back.
    PedHold.release('devTeleport')
    DoScreenFadeIn(250)
    teleporting = false
end

-- /tpm: to the waypoint on the map.
DevCommand('tpm', function()
    local wp = GetFirstBlipInfoId(8)
    if not DoesBlipExist(wp) then
        UI.Notify('Set a waypoint on the map first', 'error')
        return
    end
    local c = GetBlipInfoIdCoord(wp)
    CreateThread(function() teleport(c.x, c.y, nil, nil) end)
end)

-- /tpc <x> <y> <z>: to coordinates. What the Coords tool copies works too: vector4(x, y, z, heading).
DevCommand('tpc', function(_, _, raw)
    local text = tostring(raw or ''):gsub('^%S+', ''):gsub('vector%d', '')
    local n = {}
    for v in text:gmatch('-?%d+%.?%d*') do n[#n + 1] = tonumber(v) end
    if not (n[1] and n[2] and n[3]) then
        UI.Notify('Usage: /tpc <x> <y> <z>', 'error')
        return
    end
    CreateThread(function() teleport(n[1], n[2], n[3], n[4]) end)
end)

-- /back: to where you were before your last teleport.
DevCommand('back', function()
    local s = lastSpot
    if not s then
        UI.Notify('No teleport to go back from yet', 'error')
        return
    end
    CreateThread(function() teleport(s.x, s.y, s.z, s.heading) end)
end)

-- The Player Manager's Teleport and Bring, and /tp and /bring: the server says where. Remembered for /back.
RegisterNetEvent('whip_core:client:pmTeleport', function(x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return end
    rememberSpot()
    SetEntityCoordsNoOffset(PlayerPedId(), x, y, z + 1.0, false, false, false)
end)

-- /whiperrors [resource]: this game's error log, grouped by resource, in F8 (the server console's is whiperrors there).
DevCommand('whiperrors', function(_, args)
    local only = args[1]
    local logged = ErrorTap.read({ max = 200 })
    local by, order = {}, {}
    for _, e in ipairs(logged and logged.entries or {}) do
        local res = tostring(e.resource or '?')
        if not only or res == only then
            if not by[res] then by[res] = {}; order[#order + 1] = res end
            table.insert(by[res], e)
        end
    end
    if #order == 0 then print(only and ('[whip] no errors from %s in this game'):format(only) or '[whip] no errors in this game') return end
    table.sort(order, function(a, b) return #by[a] > #by[b] end)
    for _, res in ipairs(order) do
        local list = by[res]
        print(('[whip] ^1%s^0: %d'):format(res, #list))
        for i = math.max(1, #list - 4), #list do
            local text = tostring(list[i].text):gsub('\n.*', '')
            print('[whip]     ' .. text:sub(1, 300))
        end
    end
    UI.Notify('Errors printed in F8', 'info')
end)

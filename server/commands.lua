-- ============================================
-- Admin / Debug Commands — server/commands.lua
-- ============================================
--
-- ONE KIND. Every command here answers to the server console and to whip.devtools with developer mode on,
-- the one permission the rest of whip's admin tools use (devCommand below). What one prints goes to the
-- console, or to the chat of the admin who typed it (linesTo).

--- The in-game admin commands: [name] = true. whip_chat asks (GetCommandAce) so it only suggests
--- them to players who may run them.
local DEV_COMMANDS = {}

--- An admin command a player can type: allowed to the console and to whip.devtools.
---
--- One permission: FiveM lets the command through (not `RegisterCommand(..., true)`, which gates on
--- its own `command.<name>` ACE) and the handler asks whip.devtools, and says so when refused.
---@param name string
---@param fn fun(source: number, args: table, raw: string)
local function devCommand(name, fn)
    DEV_COMMANDS[name] = true
    RegisterCommand(name, function(source, args, raw)
        if source ~= 0 and not DevTools.isAllowed(source) then
            ShowError(source, 'That command needs whip.devtools')
            return
        end
        return fn(source, args, raw)
    end, false)
end

--- Answer whoever ran the command: the console gets a print, a player a toast.
---@param source number
---@param msg string
---@param kind string|nil  'success' | 'error' | 'info' (default 'info')
local function reply(source, msg, kind)
    if source == 0 then
        print('[whip_core] ' .. msg)
    else
        NotifyPlayer(source, msg, kind or 'info')
    end
end

--- The ACE a whip_core command needs beyond FiveM's own, or nil. For chat suggestions (whip_chat).
---@param name string
---@return string|nil
exports('GetCommandAce', function(name)
    return DEV_COMMANDS[name] and 'whip.devtools' or nil
end)

--- Where a command's lines go: the server console, or the chat of the admin who typed it.
---@param source number
---@return fun(line: string)
local function linesTo(source)
    if source == 0 then return function(line) print('[whip_core] ' .. line) end end
    return function(line) TriggerClientEvent('chat:addMessage', source, { args = { '[whip_core]', line } }) end
end

-- /whip_players — List all active players
devCommand('whip_players', function(source)
    local say = linesTo(source)
    local count, phantoms = 0, 0
    for src, player in pairs(Players) do
        if player.phantom then
            -- Counted, not listed. Printing five hundred fake rows would bury the real ones, and
            -- during a load test the useful figure is simply how many are in there.
            phantoms = phantoms + 1
        else
            count = count + 1
            say(('[%d] %s (userId: %d, charId: %d, cash: $%d)'):format(
                src, player.fullName, player.userId, player.charId, player:getCash()
            ))
        end
    end
    say(('Total active players: %d'):format(count))
    if phantoms > 0 then
        say(('...plus %d load-test phantoms (/testloadstop clears them)'):format(phantoms))
    end
end)

-- /whip_pending — List pending players (connected but no character selected)
devCommand('whip_pending', function(source)
    local say = linesTo(source)
    local count = 0
    for src, data in pairs(PendingPlayers) do
        count = count + 1
        say(('[%d] userId: %d, license: %s'):format(src, data.userId, data.license))
    end
    say(('Total pending players: %d'):format(count))
end)

-- /whip_save — Force save all players
devCommand('whip_save', function(source)
    local say = linesTo(source)
    local count = 0
    for _, player in pairs(Players) do
        -- SafeSavePlayer rather than player:save(), which is the difference between a save that is
        -- guarded and one that is not. It is the single funnel every other teardown path already
        -- uses: it pcalls, it saves the inventory as well as the row, and it refuses load-test
        -- phantoms — which have no character row and would otherwise be written here.
        if not player.phantom then
            SafeSavePlayer(player, 'whip_save')
            count = count + 1
        end
    end
    say(('Saved %d player(s)'):format(count))
end)

-- Cash is an item (banknotes, the key 'cash'), so there is no cash command:
--
--     whip_giveitem <charId> cash 500

-- /whip_bank <playerId> — Show a player's bank accounts
devCommand('whip_bank', function(source, args)
    local say = linesTo(source)
    local targetId = tonumber(args[1])
    if not targetId then
        say('Usage: whip_bank <playerId>')
        return
    end

    local player = Players[targetId]
    if not player then
        say('Player not found or not loaded')
        return
    end

    local accounts = Bank.GetCharacterAccounts(player.charId)
    say(('Bank accounts for %s (charId: %d):'):format(player.fullName, player.charId))
    for _, acc in ipairs(accounts) do
        say(('  [%d] %s (%s) — $%d — %s%s'):format(
            acc.accountId, acc.accountNumber, acc.type, acc.balance,
            acc.role,
            DbBool(acc.isDefault) and ' [DEFAULT]' or ''
        ))
    end
end)

-- Helper: find active player by charId, through the global index (PlayersByCharId).
---@return WhipPlayer|nil player
---@return number|nil source  set whenever player is
local function GetPlayerByCharId(charId)
    local player = PlayersByCharId and PlayersByCharId[charId] or nil
    if player then return player, player.source end
    return nil, nil
end

-- /whip_giveitem [charId] <item> [amount] — Give an item to a player; with no charId, to yourself
-- A number first is a charId; anything else is the item.
devCommand('whip_giveitem', function(source, args)
    local usage = 'Usage: whip_giveitem [charId] <item> [amount] — no charId gives it to you'

    local charId, item, amount
    if tonumber(args[1]) then
        charId, item, amount = tonumber(args[1]), args[2], tonumber(args[3]) or 1
    elseif args[1] then
        if source == 0 then
            reply(source, 'The console has no character: whip_giveitem <charId> <item> [amount]', 'error')
            return
        end
        local me = Players[source]
        if not me then
            reply(source, 'You have no character loaded', 'error')
            return
        end
        charId, item, amount = me.charId, args[1], tonumber(args[2]) or 1
    end

    if not charId or not item then
        reply(source, usage, 'error')
        return
    end

    local player, playerSrc = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end
    ---@cast playerSrc -nil

    if not player.inventory then
        reply(source, 'That player has no inventory loaded', 'error')
        return
    end

    if not Config.Items[item] then
        reply(source, 'Unknown item: ' .. item, 'error')
        return
    end

    -- A give: through Inventory.giveOrDrop, so a full inventory drops at their feet rather than making
    -- the console say "Failed" while the admin wonders where the item went. This also drops
    -- fifteen lines of hand-rolled sync — a serialize, a weights table built by naming
    -- containers, and a manual item:added — all of which Inventory.giveOrDrop does, and one of which
    -- (the weights literal) was a container list in disguise waiting to go stale.
    local ok, err, placement = Inventory.giveOrDrop(playerSrc, player, item, amount, nil, {
        container = 'player',
        reason    = 'admin command whip_giveitem, run by ' .. (source == 0 and 'the console' or (GetPlayerName(source) or ('#' .. source))),
    })
    if ok then
        reply(source, ('Gave %dx %s to %s (charId: %d)%s'):format(
            amount, item, player.fullName, charId,
            placement == 'ground' and ' — INVENTORY FULL, dropped at their feet' or ''), 'success')
    else
        reply(source, ('Failed: %s'):format(err or 'Unknown error'), 'error')
    end
end)

-- /whip_removeitem <charId> <item> [amount] — Remove an item from a player
devCommand('whip_removeitem', function(source, args)
    local charId = tonumber(args[1])
    local item = args[2]
    local amount = tonumber(args[3]) or 1

    if not charId or not item then
        reply(source, 'Usage: whip_removeitem <charId> <item> [amount]', 'error')
        return
    end

    local player, playerSrc = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end
    ---@cast playerSrc -nil

    -- The same path as the RemoveItem export: every container the player carries, and saved
    -- through the store. This removed from the main grid only and wrote with Inventory.save, which
    -- neither knows about an in-flight flush nor tells anyone else looking at the inventory.
    local ok, err = Inventory.removeItemAcrossContainers(player.inventory, item, amount)
    if ok then
        local why = 'admin command whip_removeitem, run by ' .. (source == 0 and 'the console' or (GetPlayerName(source) or ('#' .. source)))
        Log.lost(player.charId, item, amount, why)
        -- The push announces whip_core:item:removed (Inventory.announceChanges); this says why.
        Inventory.noteChangeReason(playerSrc, why, 'by whip_core')
        Inventory.syncAndFlush(playerSrc, player)
        reply(source, ('Removed %dx %s from %s (charId: %d)'):format(amount, item, player.fullName, charId), 'success')
    else
        reply(source, ('Failed: %s'):format(err or 'Unknown error'), 'error')
    end
end)

-- /whip_inventory <charId> — Show a player's inventory
devCommand('whip_inventory', function(source, args)
    local charId = tonumber(args[1])
    if not charId then
        reply(source, 'Usage: whip_inventory <charId>', 'error')
        return
    end

    local player = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end

    -- The full listing goes to the server console; an admin in game also gets it in one toast,
    -- shortened.
    print(('[whip_core] Inventory for %s (charId: %d):'):format(player.fullName, charId))
    local summary, count = {}, 0
    for container, slots in pairs(player.inventory) do
        if type(slots) == 'table' then
            local weight = Inventory.getWeight(player.inventory, container)
            local maxWeight = Config.MaxWeight[container] or 0
            print(('  %s (%.2f/%.2f kg):'):format(container, weight, maxWeight))
            for slot, data in pairs(slots) do
                local def = Config.Items[data.item]
                local name = def and def.name or data.item
                print(('    [%d] %s x%d'):format(slot, name, data.amount))
                count = count + 1
                if #summary < 12 then summary[#summary + 1] = ('%s x%d'):format(name, data.amount) end
            end
        end
    end
    if source ~= 0 then
        NotifyPlayer(source, ('%s: %s%s'):format(player.fullName,
            count == 0 and 'nothing' or table.concat(summary, ', '),
            count > #summary and (' (+%d more — full list in the server console)'):format(count - #summary) or ''),
            'info', 10000)
    end
end)

-- /whip_deposit <playerId> <amount> — Deposit into player's default account
devCommand('whip_deposit', function(source, args)
    local say = linesTo(source)
    local targetId = tonumber(args[1])
    local amount = tonumber(args[2])

    if not targetId or not amount then
        say('Usage: whip_deposit <playerId> <amount>')
        return
    end

    local player = Players[targetId]
    if not player then
        say('Player not found or not loaded')
        return
    end

    local account = Bank.GetDefaultAccount(player.charId)
    if not account then
        say('No default account found')
        return
    end

    -- A SYSTEM move: an admin is creating money, not the player moving theirs, so it goes through
    -- SystemDeposit (no player permission check) like every other system payment.
    local ok, err = Bank.SystemDeposit(account.accountId, amount, 'Admin deposit')
    if ok then
        say(('Deposited $%d into %s for %s'):format(amount, account.accountNumber, player.fullName))
        -- Money made in game by an admin: the console keeps who.
        if source ~= 0 then
            print(('[whip_core] %s [%d] deposited $%d into %s for %s via /whip_deposit')
                :format(GetPlayerName(source) or '?', source, amount, account.accountNumber, player.fullName))
        end
    else
        say(('Deposit failed: %s'):format(err))
    end
end)

-- ============================================
-- /whipsaves — saves the database keeps refusing
-- ============================================
--
-- A save that fails five times in a row is stuck: kept and retried every minute, never dropped
-- (stores.lua, quarantine). A poisoned row never lands and its character can't log back in, so fix
-- the cause, or discard it here as a last resort (its changes and everything saved with it are lost).

devCommand('whipsaves', function(source, args)
    if args[1] == 'drop' then
        local unit = tostring(args[2] or '')
        local dropped = Stores.discardStuck(unit)
        if #dropped == 0 then
            reply(source, ('"%s" is not a stuck save. /whipsaves lists them.'):format(unit), 'error')
            return
        end
        reply(source, ('Discarded the unsaved changes of %s.'):format(table.concat(dropped, ', ')), 'success')
        return
    end

    local stuck = Stores.stuckUnits()
    if #stuck == 0 then
        reply(source, 'No stuck saves.', 'success')
        return
    end
    local now = GetGameTimer()
    for _, s in ipairs(stuck) do
        reply(source, ('%s — %d failed saves over %d s: %s'):format(s.unit, s.fails, (now - (s.since or now)) // 1000, tostring(s.lastErr)))
    end
    reply(source, '/whipsaves drop <unit> discards one (and everything saved with it) for good.')
end)

-- ============================================
-- Ground Item Admin Commands
-- ============================================

-- /whip_clearground [radius] — Clear ground items near the calling player (or all within radius from console)
devCommand('whip_clearground', function(source, args)
    local radius = tonumber(args[1]) or 10.0

    if source == 0 then
        -- Console: need coords from first arg pair or just clear everything nearby a default
        print(('[whip_core] Use whip_clearallground to clear all, or run in-game with /whip_clearground [radius]'))
        return
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then
        reply(source, 'Could not find your ped', 'error')
        return
    end

    local coords = GetEntityCoords(ped)
    local count = GroundItems.clearNearby(coords.x, coords.y, coords.z, radius)
    local msg = ('Cleared %d ground item(s) within %.0fm'):format(count, radius)
    print(('[whip_core] %s (by player %d)'):format(msg, source))
    -- On the record, as the Ground Item Manager's delete buttons are: items leaving
    -- the game write a 'lost' row, or an admin's clear-out looks like items vanishing.
    local who = Players[source]
    Log.write(who and who.charId or nil, 'lost', {
        detail = ('%d ground item(s) within %.0fm cleared by admin command whip_clearground'):format(count, radius),
        x = coords.x, y = coords.y, z = coords.z,
    })
    reply(source, msg, 'success')
end)

-- /whip_clearallground — Clear ALL ground items server-wide (console or in-game)
devCommand('whip_clearallground', function(source)
    local count = GroundItems.clearAll()
    local msg = ('Cleared ALL %d ground item(s) server-wide'):format(count)
    if source ~= 0 then print(('[whip_core] %s (by player %d)'):format(msg, source)) end
    local who = source ~= 0 and Players[source] or nil
    Log.write(who and who.charId or nil, 'lost', {   -- as above
        detail = ('all %d ground item(s) cleared by admin command whip_clearallground, run by %s')
            :format(count, source == 0 and 'the console' or (GetPlayerName(source) or ('#' .. source))),
    })
    reply(source, msg, 'success')
end)

-- /whip_spawnground <item> [amount] — Debug: spawn a ground item at the calling player's feet
devCommand('whip_spawnground', function(source, args)
    if source == 0 then
        print('[whip_core] This command must be run in-game')
        return
    end

    local item   = args[1]
    -- A whole number, 1 or more, as CreateGroundItem holds it.
    local amount = Sanitize.amount(args[2], 1)

    if not item then
        reply(source, 'Usage: whip_spawnground <item> [amount]', 'error')
        return
    end
    if not amount then
        reply(source, Sanitize.AMOUNT_ERR, 'error')
        return
    end

    if not Config.Items[item] then
        reply(source, 'Unknown item: ' .. item, 'error')
        return
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    local coords  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- Offset slightly in front of the player
    local rad = heading * math.pi / 180.0
    local x = coords.x - math.sin(rad) * 1.0
    local y = coords.y + math.cos(rad) * 1.0
    local z = coords.z - 0.5

    local player = Players[source]
    local charId = player and player.charId or nil

    local data = GroundItems.create(item, amount, nil, x, y, z, heading, charId)
    if data then
        local msg = ('Spawned ground item: %s x%d (id: %d)'):format(item, amount, data.id)
        print(('[whip_core] %s'):format(msg))
        -- An item from nothing is a 'gained' row, as the CreateGroundItem export writes.
        Log.write(charId, 'gained', {
            itemKey = item, amount = amount,
            detail  = 'admin command whip_spawnground, run by ' .. (GetPlayerName(source) or ('#' .. source)) .. ' · on the ground',
            x = x, y = y, z = z,
        })
        reply(source, msg, 'success')
    else
        reply(source, 'Failed to spawn ground item', 'error')
    end
end)

-- /whip_givekey <charId> <vehicleId> — Give a vehicle key to a player
devCommand('whip_givekey', function(source, args)
    local charId    = tonumber(args[1])
    local vehicleId = tonumber(args[2])

    if not charId or not vehicleId then
        reply(source, 'Usage: whip_givekey <charId> <vehicleId>', 'error')
        return
    end

    local player, playerSrc = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end
    ---@cast playerSrc -nil

    local ok, msg = Vehicles.giveKey(playerSrc, player, vehicleId)
    reply(source, ('giveKey: %s'):format(tostring(msg)), ok and 'success' or 'error')
end)

-- /whip_groundcount — Show how many ground items exist
devCommand('whip_groundcount', function(source)
    local count = 0
    for _ in pairs(GroundItems.cache) do count = count + 1 end
    reply(source, ('Ground items in world: %d'):format(count), 'info')
end)

-- ============================================
-- Players, teleports, cars and the world
-- ============================================
--
-- The /w tools and the panels' buttons, typed. Each goes through the function its button uses (server/devtools.lua,
-- server/object_viewer.lua, server/time.lua), so a rule changed there holds here too. An id is the player's server
-- id, the # on their Player Manager page. In the console, the ones that act on a player need an id; the ones that act
-- on you (/car, /dv, /fix, /tp, /bring) are for in game. Noclip, God Mode, Invisible and the teleports of your own
-- (/tpm, /tpc, /back) are your game's (client/dev_commands.lua).

--- The player an id names: someone on the server, by server id. No id: the one typing, where `self` allows it (never
--- the console). Answers the id, or nil once it has said why.
---@param source number
---@param arg string|nil
---@param usage string
---@param self boolean|nil
---@return number|nil
local function targetOf(source, arg, usage, self)
    if arg == nil then
        if self and source ~= 0 then return source end
        reply(source, usage, 'error')
        return nil
    end
    local id = Sanitize.id(arg)
    if not id or not GetPlayerName(id) then
        reply(source, ('Nobody on the server has the id %s'):format(arg), 'error')
        return nil
    end
    return id
end

--- Typed in game? The console is told the command is for in game.
---@param source number
---@param name string
---@return boolean
local function inGame(source, name)
    if source ~= 0 then return true end
    reply(source, ('/%s is for in game'):format(name), 'error')
    return false
end

--- Who ran it, for the console's line.
---@param source number
---@return string
local function whoRan(source)
    if source == 0 then return 'the console' end
    local p = Players[source]
    return p and p.fullName or GetPlayerName(source) or ('player ' .. source)
end

-- /revive [id]: a downed player stood up; no id, you.
devCommand('revive', function(source, args)
    local target = targetOf(source, args[1], 'Usage: revive <id>', true)
    if not target then return end
    local player = Players[target]
    if not player then
        reply(source, 'They have no character loaded', 'error')
        return
    end
    if not player.isDead then
        reply(source, target == source and 'You are not down' or (player.fullName .. ' is not down'), 'error')
        return
    end
    MarkPlayerAlive(target, player, target == source and 'revive:self' or 'revive:admin')
    TriggerClientEvent('whip_core:client:revive', target)
    reply(source, target == source and 'You are back up' or ('Revived ' .. player.fullName), 'success')
    print(('[whip_core] %s [%d] revived by %s'):format(player.fullName, target, whoRan(source)))
end)

-- /heal [id]: health, armour, food and drink full, as the /w Restore Player Cores; down, revived first. No id, you.
devCommand('heal', function(source, args)
    local target = targetOf(source, args[1], 'Usage: heal <id>', true)
    if not target then return end
    local player = Players[target]
    local wasDown = player ~= nil and player.isDead
    local ok, why = DevTools.restore(target)
    if not ok then
        reply(source, why, 'error')
        return
    end
    ---@cast player -nil
    local done = wasDown and 'Revived, with health, armour, food and drink restored' or 'Health, armour, food and drink restored'
    reply(source, target == source and done or ('%s: %s'):format(player.fullName, done:lower()), 'success')
    if wasDown then print(('[whip_core] %s [%d] revived by %s (/heal)'):format(player.fullName, target, whoRan(source))) end
end)

-- /kick <id> [reason]: off the server, with a note on their account, as the panel's Kick: only someone below you.
devCommand('kick', function(source, args)
    local target = targetOf(source, args[1], 'Usage: kick <id> [reason]')
    if not target then return end
    local reason = Sanitize.string(table.concat(args, ' ', 2), 200)
    if reason == '' then reason = 'Kicked by admin' end
    local name = (Players[target] or {}).fullName or GetPlayerName(target)
    -- The note on their account is a database write.
    CreateThread(function()
        local ok, why = DevTools.kick(source, target, reason)
        reply(source, ok and ('Kicked ' .. tostring(name)) or why, ok and 'success' or 'error')
    end)
end)

-- /freeze <id>: frozen in place, or free again (the object viewer's Freeze on a player).
devCommand('freeze', function(source, args)
    local target = targetOf(source, args[1], 'Usage: freeze <id>')
    if not target then return end
    local player = Players[target]
    if not player then
        reply(source, 'They have no character loaded', 'error')
        return
    end
    local on = ObjectViewer.togglePlayerHold(target, 'frozen')
    reply(source, (on and 'Froze %s' or 'Unfroze %s'):format(player.fullName), 'success')
    print(('[whip_core] %s [%d] %s by %s'):format(player.fullName, target, on and 'frozen' or 'unfrozen', whoRan(source)))
end)

-- /tp <id>: you, to them (the panel's Teleport).
devCommand('tp', function(source, args)
    if not inGame(source, 'tp') then return end
    local target = targetOf(source, args[1], 'Usage: tp <id>')
    if not target then return end
    if target == source then
        reply(source, 'That id is yours', 'error')
        return
    end
    local ok, why = DevTools.teleportTo(source, target)
    if not ok then reply(source, why, 'error') end
end)

-- /bring <id>: them, to you (the panel's Bring).
devCommand('bring', function(source, args)
    if not inGame(source, 'bring') then return end
    local target = targetOf(source, args[1], 'Usage: bring <id>')
    if not target then return end
    if target == source then
        reply(source, 'That id is yours', 'error')
        return
    end
    local ok, why = DevTools.bring(source, target)
    if not ok then reply(source, why, 'error') end
end)

-- /fix: the car you are in, repaired (the /w Repair Vehicle).
devCommand('fix', function(source)
    if not inGame(source, 'fix') then return end
    local ok, why = DevTools.repairVehicleOf(source)
    reply(source, ok and 'Vehicle repaired' or why, ok and 'success' or 'error')
end)

--- How near a car must be for /dv when you are not in one, in metres.
local DV_REACH = 6.0

--- The car someone sits in, or else the nearest within DV_REACH in their routing bucket; nil for none.
---@param source number
---@return number|nil
local function carOf(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 then return veh end
    local at, bucket = GetEntityCoords(ped), GetPlayerRoutingBucket(source)
    local best, bestDist = nil, DV_REACH
    for _, v in ipairs(GetAllVehicles() --[[@as integer[] ]]) do
        if DoesEntityExist(v) and GetEntityRoutingBucket(v) == bucket then
            local d = #(GetEntityCoords(v) - at)
            if d <= bestDist then best, bestDist = v, d end
        end
    end
    return best
end

-- /dv: the car you are in, or the nearest within 6 m, out of the world (the object viewer's Remove): someone's own car
-- into its garage, a street or temporary one removed.
devCommand('dv', function(source)
    if not inGame(source, 'dv') then return end
    local veh = carOf(source)
    if not veh then
        reply(source, ('No car within %d m'):format(math.floor(DV_REACH)), 'error')
        return
    end
    local vehicleId = Vehicles.getEntityVehicleId(veh)
    local def = vehicleId and Vehicles.getDef(vehicleId)
    local owned = def and not def.session
    -- Putting an owned car away saves it.
    CreateThread(function()
        local ok, why = ObjectViewer.removeCar(source, veh)
        reply(source, ok and (owned and 'Sent back to its garage' or 'Vehicle removed') or why, ok and 'success' or 'error')
    end)
end)

--- Each admin's /car: [source] = vehicleId. A new /car takes the last one away, and so does leaving.
local adminCars = {}

--- Take an admin's /car away, if it is still there. Taking its key back waits.
---@param source number
local function dropAdminCar(source)
    local vehicleId = adminCars[source]
    adminCars[source] = nil
    if vehicleId and Vehicles.getDef(vehicleId) then Vehicles.cleanupSessionVehicle(vehicleId, 'despawned') end
end

-- /car <model>: a temporary car where you stand, with its key, and you in the driver's seat.
devCommand('car', function(source, args)
    if not inGame(source, 'car') then return end
    local model = args[1] and args[1]:lower()
    if not model or model == '' then
        reply(source, 'Usage: car <model>', 'error')
        return
    end
    if not Players[source] then
        reply(source, 'You have no character loaded', 'error')
        return
    end
    -- Taking the last one away and giving the new key both wait.
    CreateThread(function()
        dropAdminCar(source)
        local ped = GetPlayerPed(source)
        if not ped or ped == 0 or not Players[source] then return end
        -- (The last /car, just taken away, may still read as the one they sit in: it no longer exists.)
        local sitting = GetVehiclePedIsIn(ped, false)
        if sitting ~= 0 and DoesEntityExist(sitting) then
            reply(source, 'Get out of the car you are in first', 'error')
            return
        end
        local at = GetEntityCoords(ped)
        local vehicleId, err = Vehicles.spawnTempFor(model, { x = at.x, y = at.y, z = at.z, heading = GetEntityHeading(ped) }, {
            forSource     = source,
            keyInIgnition = true,
            locked        = false,
            idleDespawn   = false,   -- it goes with the next /car or when they leave, not when they walk off
            bucket        = GetPlayerRoutingBucket(source),
        }, GetCurrentResourceName())
        if not vehicleId then
            reply(source, ('No %s: %s'):format(model, tostring(err)), 'error')
            return
        end
        -- Asked again after the waits: they may have left, or typed /car again meanwhile.
        if not GetPlayerName(source) or adminCars[source] then
            Vehicles.cleanupSessionVehicle(vehicleId, 'despawned')
            return
        end
        adminCars[source] = vehicleId
        local entity = Vehicles.getEntity(vehicleId)
        if entity then SetPedIntoVehicle(GetPlayerPed(source), entity, -1) end
    end)
end)

AddEventHandler('playerDropped', function()
    local src = source
    if adminCars[src] then CreateThread(function() dropAdminCar(src) end) end
end)

-- /time <hour> [minute]: the server's clock, for everyone (the Time & Weather page's Set Time).
devCommand('time', function(source, args)
    local hour, minute = tonumber(args[1]), tonumber(args[2] or 0)
    if not hour or not minute or hour % 1 ~= 0 or minute % 1 ~= 0 or hour < 0 or hour > 23 or minute < 0 or minute > 59 then
        reply(source, 'Usage: time <hour 0-23> [minute 0-59]', 'error')
        return
    end
    if CoreReady ~= true then
        reply(source, NOT_READY, 'error')
        return
    end
    local ok, why = TimeWeather.setTime(hour, minute)
    if not ok then
        reply(source, why, 'error')
        return
    end
    DevTools.refresh('tw')
    reply(source, ('Time set to %02d:%02d'):format(hour, minute), 'success')
end)

-- /weather <type>: the server's weather, for everyone (the Time & Weather page's Set Weather).
devCommand('weather', function(source, args)
    local weather = args[1] and args[1]:upper()
    if not weather or not TimeWeather.isValidWeather(weather) then
        reply(source, 'Usage: weather <type>, one of ' .. table.concat(TimeWeather.getWeatherTypes(), ', '), 'error')
        return
    end
    if CoreReady ~= true then
        reply(source, NOT_READY, 'error')
        return
    end
    local ok, why = TimeWeather.setWeather(weather)
    if not ok then
        reply(source, why, 'error')
        return
    end
    DevTools.refresh('tw')
    reply(source, 'Weather set to ' .. weather, 'success')
end)

--- How long an announcement stays up (ms), and how many characters it may have.
local ANNOUNCE_MS, ANNOUNCE_MAX = 10000, 200

-- /announce <text>: to every player, in the announcement capsule at the top of the screen (html/js/ui.js §11), with
-- who sent it.
devCommand('announce', function(source, _, raw)
    -- The words as typed (quotes and all), after the command's name.
    local text = Sanitize.string(tostring(raw or ''):match('^%S+%s+(.-)%s*$') or '', ANNOUNCE_MAX * 2)
    if text == '' then
        reply(source, 'Usage: announce <text>', 'error')
        return
    end
    if (utf8.len(text) or #text) > ANNOUNCE_MAX then
        reply(source, ('An announcement is %d characters at most'):format(ANNOUNCE_MAX), 'error')
        return
    end
    TriggerClientEvent('whip_core:client:announce', -1, {
        text = text,
        from = source ~= 0 and GetPlayerName(source) or nil,
        ms   = ANNOUNCE_MS,
    })
    print(('[whip_core] Announcement by %s: %s'):format(whoRan(source), text))
end)

-- /whip_statebag [id] — Print all statebag values for a player
devCommand('whip_statebag', function(source, args)
    local say = linesTo(source)
    local id = tonumber(args[1])
    if not id then
        say('Usage: whip_statebag <serverId>')
        return
    end

    local name = GetPlayerName(id)
    if not name then
        say(('No player with source %d'):format(id))
        return
    end

    -- Both columns on purpose: `bag` is what replicated (client-writable), `truth` is the
    -- Sentinel ledger (what the server wrote). A row where they differ is a live tamper
    -- the Sentinel hasn't corrected yet — or a Sentinel bug; either way you want to see it.
    local state = Player(id).state
    say(('Statebags for %s [%d]  (bag | truth):'):format(name, id))
    for _, key in ipairs({
        PLAYER_DEAD_KEY, PLAYER_JOB_KEY,
        PLAYER_ESCORTED_KEY, PLAYER_ESCORTER_KEY, PLAYER_DMGMOD_KEY, PLAYER_MELEEMOD_KEY,
        PLAYER_MOOD_KEY,
    }) do
        say(('  %-14s = %s | %s'):format(key, tostring(state[key]), tostring(Sentinel.getTruth(id, key))))
    end
end)

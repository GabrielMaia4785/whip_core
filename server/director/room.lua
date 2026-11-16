-- ============================================
-- DIRECTOR ROOMS — a scenario open by several builders at once
-- ============================================
--
-- Every builder with a scenario's draft open is in its ROOM: hub.lua's open and watch put them in, closing the
-- Director (or leaving the game) takes them out. A room gives each member a colour of their own, the lowest one free,
-- kept while they stay.
--
-- PRESENCE (whip_core:server:directorPresence) is what each says of themselves, passed on to the others:
--   where     'page' (the editor), 'builder' (the world builder), 'test' (a test is running) or 'away'
--   variant   the variant they have open ('v1', 'v2'...): their pointer and picks are on that variant's cards
--   cursor    where the pointer is on the blueprint, in the blueprint's own units, or none
--   sel       the cards they have picked
--   thing     the placed thing they are on (its page open, or selected in the world builder), or none
--   field     the field they are typing in or holding ('<data-t>|<data-k>'), or none
--   drag      what they are dragging ('card:<id>', 'thing:<id>'), or none
--   cam, aim  the world builder's camera { x, y, z, pitch, yaw, fov }, and the spot in the world under its pointer
-- Presence is never an edit: nothing in it changes the scenario.
--
-- THE SCENARIO ITSELF lives here while the room is open: the draft as it was opened, with every member's changes on
-- it, in the order they came. A change is a batch of OPS (html/js/director/doc.js: a path and what is there now),
-- sent by a page as it edits (whip_core:server:directorRoomOps). Each batch that applies gets the room's next number
-- (seq); its sender is told its number (directorRoomAck), and everyone else gets the ops (directorRoomOps). Every page
-- puts them on its copy in that order, so the last change to a place is the one everyone has.
--   One member's batch may not add or change a card they lack the permission for (cards_api.lua gatedChange, as a
--   save is held to it); refused, they are sent the room's scenario as it is (directorRoomReset).
--   Saving (hub.lua roomSave) writes the room's scenario as the next revision, whoever presses it; the rest are told
--   (directorRoomSaved). A draft saved some other way (History's restore, a pack, the console) starts the room again
--   from it, and every member is sent it.
--   A room whose last member left with changes nobody saved keeps them for ROOM_KEEP_MS, so one who comes back has
--   them; after that the next to open it starts from the saved draft (and a page that still has them sends them).
-- Each member's game draws what the others do (client/director_room.lua, html/js/director/room.js).

DirectorRoom = {}

local BUILD = 'director.build'
local COLOURS = 8                  -- client/director_room.lua's palette: a ninth member shares one
local MAX_SEL = 40                 -- picked cards passed on, at most
local ROOM_KEEP_MS = 30 * 60 * 1000
local MAX_OPS = 5000               -- ops in one batch
local MAX_BATCH = 1536 * 1024      -- text in one batch (bytes)
local MAX_DOC = 1536 * 1024        -- the room's scenario, about (store.lua refuses a bigger save anyway)
local MAX_DEPTH, MAX_ENTRIES = 16, 200000
local MAX_PATH, MAX_SEG = 24, 80
local SAVE_WAIT_MS = 8000          -- under the client's 10 s callback timeout
local BIG = 16 * 1024              -- a batch this big goes out as a latent event
local LATENT_BPS = 500000

-- [key] = { members = { [src] = { name, colour, state, epoch, lastN } }, doc, id, seq, baseRev, dirty, lastEdit,
--           saving, size, keepUntil }
local rooms = {}
local roomOf = {}   -- [src] = key
local nextId = 0

local function fresh() return { where = 'page', variant = 'v1', sel = {} } end

local function newId()
    nextId = nextId + 1
    return nextId
end

--- A deep copy of plain data.
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

--- A room's members as its games are told them: { { src, name, colour, state } }, by colour.
local function membersOf(room)
    local out = {}
    for src, m in pairs(room and room.members or {}) do
        out[#out + 1] = { src = src, name = m.name, colour = m.colour, state = m.state }
    end
    table.sort(out, function(a, b) return a.colour < b.colour or (a.colour == b.colour and a.src < b.src) end)
    return out
end

--- Is this member still to be told anything? (A builder whose access was taken away while the editor was open hears
--- no more, as hub.lua's live pulses.)
local function hears(src) return Players[src] ~= nil and Permissions.has(src, BUILD) end

local function tellRoom(key)
    local room = rooms[key]
    if not room then return end
    local members = membersOf(room)
    for src in pairs(room.members) do
        if hears(src) then TriggerClientEvent('whip_core:client:directorRoom', src, key, members) end
    end
end

--- An event to one game: latent when it carries a lot (`size` bytes), so it does not hold up the rest.
local function sendTo(src, event, size, ...)
    if size > BIG then TriggerLatentClientEvent(event, src, LATENT_BPS, ...) else TriggerClientEvent(event, src, ...) end
end

--- The room's scenario, sent whole to `src` (or every member): they start from it. `why`: what they are told.
local function sendReset(key, src, why)
    local room = rooms[key]
    if not room or not room.doc then return end
    local size = room.size or 0
    local function one(s)
        local m = room.members[s]
        if m and hears(s) then
            sendTo(s, 'whip_core:client:directorRoomReset', size, key, room.id, room.seq, room.doc, room.dirty == true,
                m.epoch, why, room.baseRev)
        end
    end
    if src then one(src) else for s in pairs(room.members) do one(s) end end
end

--- About how big the scenario is as text (measured, not guessed: once in a while it is written out).
local function measure(room)
    local ok, text = pcall(json.encode, room.doc)
    room.size = ok and type(text) == 'string' and #text or 0
    return room.size
end

-- ============================================
-- Coming and going
-- ============================================

--- `src` has the draft of scenario `key` open: in its room (out of any other), told who else is. Answers their
--- colour.
function DirectorRoom.join(key, src, name)
    local was = roomOf[src]
    local room = rooms[key]
    if was == key and room and room.members[src] then
        room.members[src].name = name
        tellRoom(key)
        return room.members[src].colour
    end
    if was then DirectorRoom.leave(src) end
    room = rooms[key]
    if not room then
        room = { members = {}, id = newId(), seq = 0, baseRev = 0, dirty = false, lastEdit = 0 }
        rooms[key] = room
    end
    room.keepUntil = nil
    local taken, n = {}, 0
    for _, m in pairs(room.members) do taken[m.colour] = true; n = n + 1 end
    local colour = nil
    for c = 1, COLOURS do
        if not taken[c] then colour = c break end
    end
    room.members[src] = { name = name, colour = colour or (n % COLOURS + 1), state = fresh(), epoch = 1, lastN = 0 }
    roomOf[src] = key
    tellRoom(key)
    return room.members[src].colour
end

--- The room has nobody in it: its scenario goes, unless it holds changes nobody saved (kept for ROOM_KEEP_MS).
local function emptied(key)
    local room = rooms[key]
    if not room or next(room.members) ~= nil then return end
    if not (room.doc and room.dirty) then rooms[key] = nil return end
    local until_ = GetGameTimer() + ROOM_KEEP_MS
    room.keepUntil = until_
    SetTimeout(ROOM_KEEP_MS + 1000, function()
        local r = rooms[key]
        if r == room and r.keepUntil == until_ and next(r.members) == nil then rooms[key] = nil end
    end)
end

--- `src` closed the Director (or left): out of their room, the rest told. `gone`: they left the game, so they are
--- told nothing.
function DirectorRoom.leave(src, gone)
    local key = roomOf[src]
    if not key then return end
    roomOf[src] = nil
    local room = rooms[key]
    if room then
        room.members[src] = nil
        if next(room.members) == nil then emptied(key) else tellRoom(key) end
    end
    if not gone and Players[src] then TriggerClientEvent('whip_core:client:directorRoom', src, key, {}) end
end

--- The scenario is gone (deleted): its room empties, and its members are told so.
function DirectorRoom.close(key)
    local room = rooms[key]
    if not room then return end
    rooms[key] = nil
    for src in pairs(room.members) do
        roomOf[src] = nil
        if Players[src] then TriggerClientEvent('whip_core:client:directorRoom', src, key, {}) end
    end
end

--- Who has scenario `key` open: { [src] = name }, a copy.
function DirectorRoom.members(key)
    local out = {}
    local room = rooms[key]
    for src, m in pairs(room and room.members or {}) do out[src] = m.name end
    return out
end

--- Is anyone in scenario `key`'s room?
function DirectorRoom.busy(key)
    local room = rooms[key]
    return room ~= nil and next(room.members) ~= nil
end

--- Everyone with a scenario open, each once: fn(src).
function DirectorRoom.each(fn)
    for src in pairs(roomOf) do fn(src) end
end

-- ============================================
-- The scenario in the room
-- ============================================

--- The scenario as the room has it, for `src` (a member) opening or coming back to it. `draftRev`: the draft now;
--- `load()` reads it (doc, or nil and why). A room that has none yet, or one of an older draft, starts from it.
--- `known` (coming back: { id, seq }): what their page has; the scenario comes only when that is not it.
--- Answers doc (nil: theirs is it) and info { id, seq, dirty, baseRev, colour, epoch, fresh }; or nil, nil and why.
function DirectorRoom.document(key, src, draftRev, load, known)
    local room = rooms[key]
    local m = room and room.members[src]
    if not m then return nil, nil, 'Not open' end
    local fresh_ = false
    if not room.doc or room.baseRev ~= draftRev then
        local doc, why = load()
        if not doc then return nil, nil, why end
        local replacing = room.doc ~= nil
        room.doc, room.baseRev, room.dirty = copy(doc), draftRev, false
        room.id, room.seq = newId(), 0
        measure(room)
        fresh_ = true
        -- (Others with the older one: they start again from this, as `src` does.)
        if replacing then
            for s in pairs(room.members) do if s ~= src then sendReset(key, s, 'The saved draft changed') end end
        end
    end
    local info = { id = room.id, seq = room.seq, dirty = room.dirty == true, baseRev = room.baseRev, colour = m.colour,
                   epoch = m.epoch, fresh = fresh_ or nil }
    if known and known.id == room.id and known.seq == room.seq then return nil, info end
    m.lastN = 0
    return room.doc, info
end

--- `src` throws away what the room holds that nobody saved (alone in it): the room starts from the saved draft the
--- next time it is opened.
function DirectorRoom.revert(key, src)
    local room = rooms[key]
    if not room or not room.members[src] then return false, 'Not open' end
    for s in pairs(room.members) do
        if s ~= src then return false, 'Others are still working on it: their changes stay' end
    end
    room.doc, room.dirty, room.id, room.seq = nil, false, newId(), 0
    return true
end

--- A draft was saved (store.lua DirectorStore.save). The room's own save: its revision now. Any other (History's
--- restore, a pack, the console): the room starts again from it, and every member is sent it.
function DirectorRoom.draftSaved(key, rev, doc)
    local room = rooms[key]
    if not room or not room.doc then return end
    if room.saving then room.baseRev = rev return end
    room.doc, room.baseRev, room.dirty = copy(doc), rev, false
    room.id, room.seq = newId(), 0
    measure(room)
    sendReset(key, nil, ('Revision %d was saved from elsewhere: this is it now'):format(rev))
end

-- ---- a batch of ops ----

local SEG = '^#?[%w_%-%.:]+$'

--- Is `v` plain data no deeper than MAX_DEPTH (json.decode's answer always is plain; this bounds it)?
local function bounded(v, depth, count)
    if type(v) ~= 'table' then return true end
    if depth > MAX_DEPTH then return false end
    for _, x in pairs(v) do
        count[1] = count[1] + 1
        if count[1] > MAX_ENTRIES or not bounded(x, depth + 1, count) then return false end
    end
    return true
end

--- The batch as sent, checked: { { p, v (decoded), text, d } }, its size; or nil and why.
local function readOps(raw)
    if type(raw) ~= 'table' or #raw == 0 or #raw > MAX_OPS then return nil, 'no ops, or too many' end
    local out, size, count = {}, 0, { 0 }
    for i = 1, #raw do
        local o = raw[i]
        if type(o) ~= 'table' or type(o.p) ~= 'table' or #o.p > MAX_PATH then return nil, 'a bad path' end
        local p = {}
        for j = 1, #o.p do
            local s = o.p[j]
            if type(s) ~= 'string' or #s > MAX_SEG or not (s:match(SEG) or (s == '@' and j == #o.p)) then
                return nil, 'a bad path'
            end
            p[j] = s
        end
        local op = { p = p }
        if o.d == true or o.d == 1 then
            op.d = true
        elseif type(o.v) == 'string' then
            size = size + #o.v
            if size > MAX_BATCH then return nil, 'too big' end
            local ok, v = pcall(json.decode, o.v)
            if not ok then return nil, 'a value that is not JSON' end
            if not bounded(v, 1, count) then return nil, 'a value too big or too deep' end
            -- (An order is a list of keys.)
            if p[#p] == '@' then
                if type(v) ~= 'table' then return nil, 'a bad order' end
                for _, k in ipairs(v) do if type(k) ~= 'string' then return nil, 'a bad order' end end
            end
            op.v, op.text = v, o.v
        else
            return nil, 'an op with no value'
        end
        out[i] = op
    end
    return out, size
end

--- A member's key in a keyed list: 'i' + its id, else 'k' + its k (doc.js memberKey); a whole number as JS writes it.
local function keyText(v)
    if math.type(v) == 'float' and v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
    return tostring(v)
end
local function memberKey(x)
    if type(x) ~= 'table' then return nil end
    if type(x.id) == 'string' or type(x.id) == 'number' then return 'i' .. keyText(x.id) end
    if type(x.k) == 'string' or type(x.k) == 'number' then return 'k' .. keyText(x.k) end
    return nil
end

local function stepIn(cur, seg)
    if type(cur) ~= 'table' then return nil end
    if seg:sub(1, 1) == '#' then
        local k = seg:sub(2)
        for _, x in ipairs(cur) do if memberKey(x) == k then return x end end
        return nil
    end
    return cur[seg]
end

--- One op on the room's scenario, in place (as doc.js applyOne: a missing object on the way is made, a path through a
--- member that is gone does nothing). Answers the scenario (a new one for an op on the whole).
local function applyOp(doc, op)
    local p = op.p
    if #p == 0 then return op.d and doc or copy(op.v) end
    local cur = doc
    for i = 1, #p - 1 do
        local seg = p[i]
        local nxt = stepIn(cur, seg)
        if nxt == nil and seg:sub(1, 1) ~= '#' and type(cur) == 'table' and not op.d then
            nxt = {}
            cur[seg] = nxt
        end
        if type(nxt) ~= 'table' then return doc end
        cur = nxt
    end
    local last = p[#p]
    if last == '@' then
        local at = {}
        for i, k in ipairs(op.v) do at[k] = i end
        local listed, rest = {}, {}
        for _, x in ipairs(cur) do
            if at[memberKey(x)] then listed[#listed + 1] = x else rest[#rest + 1] = x end
        end
        table.sort(listed, function(a, b) return at[memberKey(a)] < at[memberKey(b)] end)
        for i = #cur, 1, -1 do cur[i] = nil end
        for _, x in ipairs(listed) do cur[#cur + 1] = x end
        for _, x in ipairs(rest) do cur[#cur + 1] = x end
        return doc
    end
    if last:sub(1, 1) == '#' then
        local k = last:sub(2)
        local at = nil
        for i, x in ipairs(cur) do if memberKey(x) == k then at = i break end end
        if op.d then
            if at then table.remove(cur, at) end
        elseif at then
            cur[at] = copy(op.v)
        else
            cur[#cur + 1] = copy(op.v)
        end
        return doc
    end
    if op.d then cur[last] = nil else cur[last] = copy(op.v) end
    return doc
end

--- Does this op touch a card, or a list of them (the scenario, a variant)? The rest (things, settings, comments) name
--- none, and cannot be gated.
local function onCards(p)
    return #p == 0 or p[1] == 'nodes' or (p[1] == 'variants' and (#p < 3 or p[3] == 'nodes'))
end

--- Does this batch touch a card whose type is gated (a permission `src` lacks) or not on the server now (its maker
--- stopped)? Only such a batch is held to cards_api.lua's gatedChange; the rest (a moved card, most fields) need not be.
local function gated(src, doc, ops)
    local function guarded(t)
        if type(t) ~= 'string' then return false end
        local def = DirectorNodes.get(t)
        return def == nil or (def.permission ~= nil and not Permissions.has(src, def.permission))
    end
    for _, op in ipairs(ops) do
        local p = op.p
        if onCards(p) then
            -- A card's own path: ['nodes', '#i<id>', ...] or ['variants', '#i<v>', 'nodes', '#i<id>', ...].
            local at = (p[1] == 'nodes' and 2) or (p[1] == 'variants' and p[3] == 'nodes' and 4) or nil
            if not at or #p < at then return true end   -- (a whole list, a variant, the scenario: checked whole)
            local list = p[1] == 'nodes' and doc.nodes or stepIn(stepIn(doc.variants, p[2]) or {}, 'nodes')
            local card = stepIn(list, p[at])
            if card and guarded(card.type) then return true end
            if #p == at and type(op.v) == 'table' and guarded(op.v.type) then return true end
            if p[at + 1] == 'type' and guarded(op.v) then return true end
        end
    end
    return false
end

local function touchesCards(ops)
    for _, op in ipairs(ops) do if onCards(op.p) then return true end end
    return false
end

--- THE ORDER OF A LIST TWO PAGES ADDED TO AT ONCE: each put its own at its end, and the room has them in the order they
--- came. So after a batch that added to a keyed list (or ordered one), that list's order as the room has it goes with
--- it, to the others and back to its sender, and every page has the same. Answers those order ops, as wire ops.
local function ordersAfter(doc, ops)
    local out, seen = {}, {}
    for _, op in ipairs(ops) do
        local p, last = op.p, op.p[#op.p]
        if not op.d and #p > 0 and (last == '@' or last:sub(1, 1) == '#') then
            local list = {}
            for i = 1, #p - 1 do list[i] = p[i] end
            local at = table.concat(list, '\0')
            if not seen[at] then
                seen[at] = true
                local cur = doc
                for _, seg in ipairs(list) do cur = stepIn(cur, seg) if type(cur) ~= 'table' then break end end
                if type(cur) == 'table' then
                    local keys = {}
                    for i, x in ipairs(cur) do keys[i] = memberKey(x) or '' end
                    list[#list + 1] = '@'
                    out[#out + 1] = { p = list, v = json.encode(keys) }
                end
            end
        end
    end
    return out
end

SecureEvent('whip_core:server:directorRoomOps', {
    permission = BUILD,
    whileDead = true,
    rateLimit = 40,
    burst = 30,
    params = { { 'key', 'key', 64 }, { 'roomId', 'id' }, { 'epoch', 'id' }, { 'n', 'id' }, { 'quiet', 'bool', false },
               { 'ops', 'any' } },
}, function(source, _, key, roomId, epoch, n, quiet, raw)
    local room = rooms[key]
    local m = room and room.members[source]
    -- (Not in it, or a batch for an older scenario: one that started again since, or theirs refused since. Their page
    -- has been sent the scenario as it is.)
    if not m or roomOf[source] ~= key or not room.doc or room.id ~= roomId or m.epoch ~= epoch then return end
    local ops, size = readOps(raw)
    local why = nil
    if not ops then why = 'That change could not be read: ' .. tostring(size) end
    if not why and (room.size or 0) + size > MAX_DOC and measure(room) + size > MAX_DOC then
        why = 'The scenario would be too big'
    end
    local before = nil
    if not why and touchesCards(ops) and gated(source, room.doc, ops) then before = copy(room.doc) end
    if not why then
        local doc = room.doc
        for _, op in ipairs(ops) do doc = applyOp(doc, op) end
        room.doc = doc
        room.size = (room.size or 0) + size
        if before then
            why = Director.gatedChange(source, room.doc, before)
            if why then room.doc = before end
        end
    end
    if why then
        -- Refused: their page starts again from the room's (their later batches, made on top of this one, are
        -- dropped: the epoch).
        m.epoch = m.epoch + 1
        sendReset(key, source, why)
        return
    end
    room.seq = room.seq + 1
    m.lastN = n
    if not quiet then room.dirty, room.lastEdit = true, room.seq end
    local orders = ordersAfter(room.doc, ops)
    TriggerClientEvent('whip_core:client:directorRoomAck', source, key, room.id, room.seq, n, orders)
    -- To the others, as it came (each value's text, so nothing is lost on the way through Lua), the orders after.
    local wire = {}
    for i, op in ipairs(ops) do wire[i] = op.d and { p = op.p, d = 1 } or { p = op.p, v = op.text } end
    for _, o in ipairs(orders) do wire[#wire + 1] = o end
    for s in pairs(room.members) do
        if s ~= source and hears(s) then
            sendTo(s, 'whip_core:client:directorRoomOps', size, key, room.id, room.seq, source, wire, quiet == true)
        end
    end
end)

-- ---- saving ----

--- Saves the room's scenario for `src` (a member), once their batches up to `upTo` are in: the next revision, whoever
--- made the changes. `save(doc)` writes it (hub.lua: DirectorStore.save on the room's draft); `check(doc)` its
--- problems. Answers { rev, problems, seq, nothing }, or nil and why. Waits.
function DirectorRoom.save(key, src, upTo, save, check)
    local room = rooms[key]
    local m = room and room.members[src]
    if not m or not room.doc then return nil, 'It is not open here: open it again' end
    local deadline = GetGameTimer() + SAVE_WAIT_MS
    -- Their last changes first, and another's save under way.
    while (m.lastN < upTo or room.saving) and GetGameTimer() < deadline do Wait(100) end
    if rooms[key] ~= room or room.members[src] ~= m then return nil, 'It was closed meanwhile' end
    if m.lastN < upTo then return nil, 'Your last changes did not arrive in time: try again' end
    if room.saving then return nil, 'Another save of it is under way: try again' end
    if not room.dirty then return { rev = room.baseRev, seq = room.seq, nothing = true } end
    room.saving = true
    local seq = room.seq
    local ok, rev, why = pcall(save, copy(room.doc), room.baseRev)
    room.saving = false
    if not ok then return nil, 'The save failed: ' .. tostring(rev) end
    if not rev then return nil, why end
    -- (What came while it was writing is still not saved.)
    room.dirty = room.lastEdit > seq
    local problems = check(room.doc)
    local by = m.name
    for s in pairs(room.members) do
        if s ~= src and hears(s) then
            TriggerClientEvent('whip_core:client:directorRoomSaved', s, key, room.id, seq, rev, by, problems)
        end
    end
    return { rev = rev, problems = problems, seq = seq }
end

-- ============================================
-- What each member says of themselves
-- ============================================

local WHERE = { 'page', 'builder', 'test', 'away' }
local REF = '^[%w_%-%.:|~]+$'   -- a card, a thing, a point ('<thing>~<k>'), a field ('<data-t>|<data-k>')

local function vec()
    return { { 'x', 'number', -1e5, 1e5, 0 }, { 'y', 'number', -1e5, 1e5, 0 }, { 'z', 'number', -1e4, 1e5, 0 } }
end
local CAM = vec()
CAM[#CAM + 1] = { 'pitch', 'number', -90, 90, 0 }
CAM[#CAM + 1] = { 'yaw', 'number', -360, 360, 0 }
CAM[#CAM + 1] = { 'fov', 'number', 5, 130, 50 }
local HOLD = vec()
HOLD[#HOLD + 1] = { 'h', 'number', -360, 360, 0 }

-- (The page sends this at most every 100 ms while something in it changes: client/director_room.lua.)
SecureEvent('whip_core:server:directorPresence', {
    permission = BUILD,
    whileDead = true,
    rateLimit = 60,
    burst = 8,
    params = {
        { 'where', 'enum', WHERE, 'away' },
        { 'variant', 'key', 8 },
        { 'cursor', 'bool', false },
        { 'cx', 'number', -1e7, 1e7, 0 },
        { 'cy', 'number', -1e7, 1e7, 0 },
        { 'sel', 'list', { 'id', 'key', 64 }, MAX_SEL },
        { 'hasCam', 'bool', false },
        { 'cam', 'record', CAM },
        { 'hasAim', 'bool', false },
        { 'aim', 'record', vec() },
        { 'thing', 'string', 160, '' },
        { 'field', 'string', 200, '' },
        { 'drag', 'string', 160, '' },
        { 'hasHold', 'bool', false },
        { 'hold', 'record', HOLD },
    },
}, function(source, _, where, variant, cursor, cx, cy, sel, hasCam, cam, hasAim, aim, thing, field, drag, hasHold, hold)
    local key = roomOf[source]
    local room = key and rooms[key]
    local me = room and room.members[source]
    -- (Not in a room: the Director closed while this was on its way. Nothing to pass on.)
    if not me then return end
    local moved = me.state.where ~= where
    local inBuilder = where == 'builder'
    me.state = {
        where = where,
        variant = variant:match('^v%d+$') and variant or 'v1',
        cursor = cursor and { x = cx, y = cy } or nil,
        sel = sel,
        -- (Only the world builder has a camera to show, and a spot under its pointer.)
        cam = hasCam and inBuilder and cam or nil,
        aim = hasAim and inBuilder and aim or nil,
        thing = thing ~= '' and thing:match(REF) and thing or nil,
        field = field ~= '' and field:match(REF) and field or nil,
        drag = drag ~= '' and drag:match(REF) and drag or nil,
    }
    -- (Where the thing they move is now: the world builder's, with what it moves.)
    if hasHold and inBuilder and me.state.drag then me.state.hold = hold end
    -- Between the page, the builder and a test: everyone gets the whole room again, so one who just came into the
    -- world builder sees the others' cameras where they stand, not only once they move.
    if moved then tellRoom(key) return end
    for src in pairs(room.members) do
        if src ~= source and hears(src) then
            TriggerClientEvent('whip_core:client:directorPresence', src, key, source, me.state)
        end
    end
end)

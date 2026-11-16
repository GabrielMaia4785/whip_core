-- ============================================
-- Item: wallet (Wallet)
-- 3 slots — accepts: cash
-- ============================================

-- Registered inline: the manifest loads this directory last. whip_core's function, not its export:
-- see food.lua.
Panels.registerItem('wallet', {
    slots        = 3,
    label        = 'Wallet',
    storageKey   = 'slots',
    -- The item keys it takes. (This said `cash = { maxPerSlot = 10000 }`, and nothing enforces a
    -- per-item cap — panels.lua says so — so it read as a limit that was not there.)
    allowedItems = { 'cash' },
}, GetCurrentResourceName())

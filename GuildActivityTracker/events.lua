local addonName = ...
local GAT = _G[addonName]

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_SYSTEM")

-- =========================================================
-- Helpers safe API
-- =========================================================
local function RequestGuildRosterRefresh()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
        return true
    elseif GuildRoster then
        GuildRoster()
        return true
    end
    return false
end

-- =========================================================
-- Cache Online/Offline + Timestamps
-- =========================================================
GAT._onlineCache = GAT._onlineCache or {}

function GAT:RebuildOnlineCache()
    wipe(GAT._onlineCache)
    local n = GetNumGuildMembers()
    for i = 1, n do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            -- Aquí usamos Ambiguate "none" para guardar en caché con formato Nombre-Reino
            -- si el juego lo provee así.
            name = Ambiguate(name, "none") 
            GAT._onlineCache[name] = isOnline
        end
    end
    
    if GAT.db then
        GAT.db.rosterLastUpdateAt = time()
    end
end

function GAT:IsOnline(fullName)
    if not fullName then return false end
    -- Buscamos tal cual (Nombre-Reino)
    if GAT._onlineCache[fullName] ~= nil then return GAT._onlineCache[fullName] end
    -- Fallback: a veces el cache tiene el nombre corto si es del mismo reino
    local short = Ambiguate(fullName, "short")
    return (GAT._onlineCache and GAT._onlineCache[short]) and true or false
end

function GAT:GetRosterLastUpdateAt()
    return (GAT.db and GAT.db.rosterLastUpdateAt) or 0
end

-- =========================================================
-- Sync Helper
-- =========================================================
GAT._pendingRosterSync = false

function GAT:RequestRosterSync()
    GAT._pendingRosterSync = true
    local ok = RequestGuildRosterRefresh()
    if ok then
        if GAT.Print then GAT:Print("Sincronizando con el servidor...") end
    end
end

-- =========================================================
-- Eventos
-- =========================================================
frame:SetScript("OnEvent", function(self, event, msg, sender)
    if not GAT:IsInTargetGuild() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        return
    end
    if GAT.InCombat then return end

    if event == "GUILD_ROSTER_UPDATE" then
        if GAT.RebuildOnlineCache then GAT:RebuildOnlineCache() end
        
        if GAT.ScanRosterForRanks then GAT:ScanRosterForRanks() end

        if GAT.RefreshUI then GAT:RefreshUI() end
        
        if GAT.MissingWindow and GAT.MissingWindow:IsShown() and GAT.RefreshMissingList then
            GAT:RefreshMissingList()
        end
        return
    end

    if event == "CHAT_MSG_GUILD" then
        if not sender then return end
        
        local normalizedSender = (GAT.Normalize and GAT:Normalize(sender)) or sender
        if not normalizedSender then return end

        if GAT.IsSelf and GAT:IsSelf(normalizedSender) then return end
        if not GAT:IsInTargetGuild() then return end
        if GAT.IsFiltered and GAT:IsFiltered(normalizedSender) then return end

        if GAT.AddActivity then GAT:AddActivity(normalizedSender, msg) end
        if GAT.RefreshUI then GAT:RefreshUI() end
    end

    if event == "CHAT_MSG_SYSTEM" then
        if not GAT:IsInTargetGuild() then return end
        if GAT.ParseGuildSystemMessage then
            GAT:ParseGuildSystemMessage(msg)
        end
    end
end)

local GUILD_JOIN_PATTERN = "(.+) has joined the guild"
local GUILD_LEAVE_PATTERN = "(.+) has left the guild"
local GUILD_PROMOTE_PATTERN = "(.+) has been promoted to (.+)"
local GUILD_DEMOTE_PATTERN = "(.+) has been demoted to (.+)"
local GUILD_REMOVE_PATTERN = "(.+) has been kicked from the guild by (.+)"

local GUILD_JOIN_ES = "(.+) se ha unido a la hermandad"
local GUILD_LEAVE_ES = "(.+) ha abandonado la hermandad"
local GUILD_PROMOTE_ES = "(.+) ha sido ascendido a (.+)"
local GUILD_DEMOTE_ES = "(.+) ha sido degradado a (.+)"
local GUILD_REMOVE_ES = "(.+) ha sido expulsado de la hermandad por (.+)"

function GAT:ParseGuildSystemMessage(text)
    if not text or text == "" then return end
    if not self.db then return end
    self.db.guild_log = self.db.guild_log or {}

    local ts = time()
    local entry = nil

    local name

    name = text:match(GUILD_JOIN_PATTERN) or text:match(GUILD_JOIN_ES)
    if name then
        entry = { ts = ts, type = "join", player = name, text = text }
    end

    if not entry then
        name = text:match(GUILD_LEAVE_PATTERN) or text:match(GUILD_LEAVE_ES)
        if name then
            entry = { ts = ts, type = "leave", player = name, text = text }
        end
    end

    if not entry then
        local pName, rank = text:match(GUILD_PROMOTE_PATTERN)
        if not pName then pName, rank = text:match(GUILD_PROMOTE_ES) end
        if pName then
            entry = { ts = ts, type = "promote", player = pName, rank = rank, text = text }
        end
    end

    if not entry then
        local pName, rank = text:match(GUILD_DEMOTE_PATTERN)
        if not pName then pName, rank = text:match(GUILD_DEMOTE_ES) end
        if pName then
            entry = { ts = ts, type = "demote", player = pName, rank = rank, text = text }
        end
    end

    if not entry then
        local kicked, by = text:match(GUILD_REMOVE_PATTERN)
        if not kicked then kicked, by = text:match(GUILD_REMOVE_ES) end
        if kicked then
            entry = { ts = ts, type = "remove", player = kicked, by = by, text = text }
        end
    end

    if entry then
        table.insert(self.db.guild_log, entry)
        local maxEntries = 500
        while #self.db.guild_log > maxEntries do
            table.remove(self.db.guild_log, 1)
        end
    end
end

local addonName = ...
local GAT = _G[addonName]

-- =============================================================================
-- Helpers de nombre/fecha
-- =============================================================================
local function getRealm()
    if GetNormalizedRealmName then
        return GetNormalizedRealmName() or ""
    end
    return (GetRealmName() or ""):gsub(" ", "")
end

local function canonicalName(name)
    if not name or name == "" then return nil end
    if name:find("-") then return name end
    return name .. "-" .. getRealm()
end

local function parseLastSeen(tsOrStr)
    if type(tsOrStr) == "number" then return tsOrStr end
    if type(tsOrStr) ~= "string" then return 0 end
    local y, m, d, hh, mm, ap = tsOrStr:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)%s*(AM|PM)$")
    if y then
        local H = tonumber(hh)
        if ap == "AM" and H == 12 then H = 0 end
        if ap == "PM" and H ~= 12 then H = H + 12 end
        return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = H, min = tonumber(mm), sec = 0 })
    end
    local y2, m2, d2, HH, MM = tsOrStr:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
    if y2 then
        return time({ year = tonumber(y2), month = tonumber(m2), day = tonumber(d2), hour = tonumber(HH), min = tonumber(MM), sec = 0 })
    end
    return 0
end

local function lastSeenText(ts)
    if not ts or ts == 0 then return "" end
    return date("%Y-%m-%d %I:%M %p", ts)
end

-- =============================================================================
-- DB helpers
-- =============================================================================
function GAT:EnsureSyncDB()
    self.db = self.db or _G.GuildActivityTrackerDB or {}
    _G.GuildActivityTrackerDB = self.db
    self.db._sync = self.db._sync or {}
    local sd = self.db._sync

        -- clientId estable (evita duplicados en UI tras relogs)
    local stableId = nil
    if UnitGUID then stableId = UnitGUID("player") end
    if not stableId or stableId == "" then
        local n = UnitName and UnitName("player")
        if n then stableId = Ambiguate(n, "none") end
    end
    stableId = tostring(stableId or "")
    if stableId ~= "" then
        sd.clientId = stableId
        sd.clientIdV = 2
    else
        sd.clientId = sd.clientId or tostring(math.random(100000,999999)) .. tostring(time() % 100000)
    end
    sd.printCache = sd.printCache or {}
    sd.sessionNonce = sd.sessionNonce or 0
    sd.rev = tonumber(sd.rev or 0) or 0
    sd.peers = sd.peers or {}

    -- Cola de envíos + deltas pendientes
    sd.pending = sd.pending or { activity = {}, stats = {} }
    sd.outbox = sd.outbox or {}
    sd._sessionPrint = sd._sessionPrint or {}

    -- Backlog (compat: antes se llamaba pendingBacklog)
    sd.backlog = sd.backlog or sd.pendingBacklog or {}
    sd.pendingBacklog = sd.backlog
    sd.backlogSeq = sd.backlogSeq or sd.pendingBacklogSeq or 0
    sd.pendingBacklogSeq = sd.backlogSeq

    -- ACK / in-flight (compat: antes backlogInFlightKey)
    sd.backlogInFlight = sd.backlogInFlight or nil
    sd.backlogInFlightAt = sd.backlogInFlightAt or 0
    sd.backlogInFlightKey = sd.backlogInFlightKey or nil

    -- Dejó de usarse pero lo preservamos para no romper SavedVariables viejas
    sd.lastAppliedSeqByPeer = sd.lastAppliedSeqByPeer or {}
    sd.pendingSeq = sd.pendingSeq or 1

    return sd
end

function GAT:EnsureSortDefaults()
    self.db = self.db or _G.GuildActivityTrackerDB or {}
    _G.GuildActivityTrackerDB = self.db
    self.db.settings = self.db.settings or {}
    if self.db.settings.sortMode == nil then self.db.settings.sortMode = "count" end
    if self.db.settings.sortDir == nil then self.db.settings.sortDir = "desc" end
    if self.db.settings.enableAutoArchive == nil then self.db.settings.enableAutoArchive = false end
    if not self.db.settings.autoArchiveDays or self.db.settings.autoArchiveDays < 7 then
        self.db.settings.autoArchiveDays = 30
    end
end

function GAT:UpgradeDBIfNeeded()
    self.db = self.db or _G.GuildActivityTrackerDB or {}
    _G.GuildActivityTrackerDB = self.db
    self.db.data = self.db.data or {}
    self:EnsureSortDefaults()

    if self.db.chatBuffer and type(self.db.chatBuffer) == "table" then
        local now = time()
        local BUFFER_MAX_AGE = 7 * 86400
        local pruned = {}
        for _, entry in ipairs(self.db.chatBuffer) do
            if type(entry) == "table" and entry.ts and (now - entry.ts) < BUFFER_MAX_AGE then
                table.insert(pruned, entry)
            end
        end
        self.db.chatBuffer = pruned
    end

    for name, value in pairs(self.db.data) do
        if type(value) == "number" then
            self.db.data[name] = { total = value, lastSeen = "", lastSeenTS = 0, lastMessage = "", daily = {}, rankIndex = 99, rankName = "—" }
        elseif type(value) == "table" then
            value.total = value.total or 0
            value.lastSeen = value.lastSeen or ""
            value.daily = value.daily or {}
            value.rankIndex = value.rankIndex or 99
            value.rankName = value.rankName or "—"
            if type(value.lastSeenTS) ~= "number" then
                value.lastSeenTS = parseLastSeen(value.lastSeen or "")
            end
            value.lastSeen = lastSeenText(value.lastSeenTS or 0)
        end
    end
end

-- =============================================================================
-- Mutaciones principales
-- =============================================================================
local function mergeDaily(dest, src)
    dest.daily = dest.daily or {}
    if src.daily then
        for day, cnt in pairs(src.daily) do
            dest.daily[day] = (dest.daily[day] or 0) + (cnt or 0)
        end
    end
end

function GAT:MergeEntry(name, incoming, mode)
    if not name or not incoming then return end
    self.db = self.db or _G.GuildActivityTrackerDB or {}
    self.db.data = self.db.data or {}

    local entry = self.db.data[name]
    if type(entry) ~= "table" then
        local oldVal = type(entry) == "number" and entry or 0
        entry = { total = oldVal, lastSeen = "", lastSeenTS = 0, lastMessage = "", daily = {}, rankIndex = 99, rankName = "—" }
        self.db.data[name] = entry
    end

    if mode == "snapshot" then
        entry.total = incoming.total or entry.total or 0
        entry.rankIndex = incoming.rankIndex or entry.rankIndex
        entry.rankName = incoming.rankName or entry.rankName
        if incoming.lastSeenTS and (incoming.lastSeenTS > (entry.lastSeenTS or 0)) then
            entry.lastSeenTS = incoming.lastSeenTS
            entry.lastSeen = lastSeenText(incoming.lastSeenTS)
        end
        mergeDaily(entry, incoming)
        return
    end

    -- delta mode
    entry.total = (entry.total or 0) + (incoming.total or 0)
    mergeDaily(entry, incoming)
    if incoming.lastSeenTS and incoming.lastSeenTS > (entry.lastSeenTS or 0) then
        entry.lastSeenTS = incoming.lastSeenTS
        entry.lastSeen = lastSeenText(incoming.lastSeenTS)
        entry.lastMessage = incoming.lastMessage or entry.lastMessage
    end
    if (not entry.rankName or entry.rankName == "—") and incoming.rankName then
        entry.rankName = incoming.rankName
        entry.rankIndex = incoming.rankIndex
    end
end

function GAT:DeletePlayer(name)
    if not self:IsMasterBuild() then return end
    if self.db and self.db.data then
        self.db.data[name] = nil
    end
    if self.Sync_BroadcastDelete then
        self:Sync_BroadcastDelete(name)
    end
    if self.RefreshUI then self:RefreshUI() end
end

-- =============================================================================
-- Roster helpers
-- =============================================================================
function GAT:ScanRosterForRanks()
    if not self:IsInTargetGuild() then return end
    self.db = self.db or {}
    self.db.data = self.db.data or {}

    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local fullName, rankName, rankIndex = GetGuildRosterInfo(i)
        if not rankName and rankIndex then
            rankName = GuildControlGetRankName(rankIndex + 1)
        end
        if not rankName or rankName == "" then rankName = "Miembro" end
        if fullName then
            local normalized = canonicalName(fullName)
            if normalized and self.db.data[normalized] then
                self.db.data[normalized].rankName = rankName
                self.db.data[normalized].rankIndex = rankIndex
            end
        end
    end
end

-- =============================================================================
-- Activity ingestion
-- =============================================================================
function GAT:AddActivity(player, msg)
    if not self:IsInTargetGuild() then return end
    if self.Sync_ShouldCollectChat and (not self:Sync_ShouldCollectChat()) then
    -- Si el GM parece "online" pero está en silencio (heartbeat tardío),
    -- guardamos temporalmente mensajes para no perder actividad en la ventana de transición.
    if self.Sync_ShouldBufferChat and self.Sync_BufferChat and self:Sync_ShouldBufferChat() then
        self:Sync_BufferChat(player, msg)
    end
    return
end

    self.db = self.db or _G.GuildActivityTrackerDB or {}
    self.db.data = self.db.data or {}

    local fullPlayerName = canonicalName(player)
    if not fullPlayerName then return end

    local entry = self.db.data[fullPlayerName]
    if type(entry) ~= "table" then
        local oldVal = type(entry) == "number" and entry or 0
        entry = { total = oldVal, lastSeen = "", lastSeenTS = 0, lastMessage = "", daily = {}, rankIndex = 99, rankName = "—" }
        self.db.data[fullPlayerName] = entry
    end

    local now = time()
    local today = date("%Y-%m-%d")
    entry.total = (entry.total or 0) + 1
    entry.lastSeenTS = now
    entry.lastSeen = date("%Y-%m-%d %I:%M %p")
    entry.lastMessage = msg or entry.lastMessage or ""
    entry.daily[today] = (entry.daily[today] or 0) + 1

    self.db.chatBuffer = self.db.chatBuffer or {}
    table.insert(self.db.chatBuffer, {
        player = fullPlayerName,
        msg = (msg or ""):sub(1, 500),
        ts = now,
        ch = "GUILD",
    })
    local MAX_BUFFER = 5000
    if #self.db.chatBuffer > MAX_BUFFER then
        local overflow = #self.db.chatBuffer - MAX_BUFFER
        for i = 1, overflow do
            table.remove(self.db.chatBuffer, 1)
        end
    end

    if self.Sync_RecordDelta_Activity then
        self:Sync_RecordDelta_Activity(fullPlayerName, 1, now, today)
    end
end

-- =============================================================================
-- Hours/Day from GRM ActivityMetrics
-- =============================================================================
local function ScoreToHoursPerDay(score)
    if not score or score <= 0 then return 0 end
    if score <= 92 then return score / 4 end
    return 23 + (score - 92) / 8
end

local function GetHoursPerDayFromMetrics(playerName)
    if GAT and GAT.db and GAT.db._webSyncActivityScores then
        local score = GAT.db._webSyncActivityScores[playerName]
        if score and score > 0 then
            return ScoreToHoursPerDay(score)
        end
    end

    local guildKey = nil
    if GRM_Misc then
        if GRM_G and GRM_G.guildName and GRM_G.guildName ~= "" then
            guildKey = GRM_G.guildName
        else
            local gName, _, _, sName = GetGuildInfo("player")
            if gName and gName ~= "" then
                local realm = sName
                if not realm or realm == "" then
                    if GetNormalizedRealmName then
                        realm = GetNormalizedRealmName() or ""
                    else
                        realm = (GetRealmName() or ""):gsub(" ", "")
                    end
                else
                    realm = realm:gsub("-", ""):gsub("%s+", "")
                end
                guildKey = gName .. "-" .. realm
            end
        end

        if guildKey then
            local guildMisc = GRM_Misc[guildKey]
            if guildMisc and guildMisc.activityMetrics and guildMisc.activityMetrics.players then
                local pm = guildMisc.activityMetrics.players[playerName]
                if type(pm) == "table" and type(pm.daily_hour_marks) == "table" then
                    local SECONDS_PER_DAY = 86400
                    local cutoff = time() - (30 * SECONDS_PER_DAY)
                    local totalHours = 0
                    local daysCount = 0

                    for dayKey, hourMarks in pairs(pm.daily_hour_marks) do
                        if type(hourMarks) == "table" then
                            local y, m, d = dayKey:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
                            if y then
                                local dayEpoch = time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
                                if dayEpoch >= cutoff then
                                    daysCount = daysCount + 1
                                    local hoursInDay = 0
                                    for i = 1, 24 do
                                        if hourMarks[i] then hoursInDay = hoursInDay + 1 end
                                    end
                                    totalHours = totalHours + hoursInDay
                                end
                            end
                        end
                    end

                    if daysCount > 0 then
                        return totalHours / daysCount
                    end
                    return 0
                end
            end
        end
    end

    return nil
end

-- =============================================================================
-- Queries
-- =============================================================================
function GAT:GetSortedActivity()
    self:EnsureSortDefaults()
    local out = {}
    for name, entry in pairs(self.db.data or {}) do
        if type(entry) == "number" then
            entry = { total = entry, lastSeen = "", lastSeenTS = 0, rankIndex = 99, rankName = "—", daily = {} }
        end
        local hpd = GetHoursPerDayFromMetrics(name)
        table.insert(out, {
            name = name,
            count = entry.total or 0,
            hoursPerDay = hpd,
            lastSeen = entry.lastSeen or "",
            lastSeenTS = entry.lastSeenTS or parseLastSeen(entry.lastSeen or ""),
            rankIndex = entry.rankIndex or 99,
            rankName = entry.rankName or "—"
        })
    end

    local mode = self.db.settings.sortMode or "count"
    local dir = self.db.settings.sortDir or "desc"

    local function nameKey(n) return string.lower(tostring(n or "")) end
    local function onlineVal(n)
        if GAT.IsOnline and GAT:IsOnline(n) then return 1 else return 0 end
    end

    local function cmp(a, b)
        if mode == "online" then
            local ao, bo = onlineVal(a.name), onlineVal(b.name)
            if ao ~= bo then return dir == "asc" and ao < bo or ao > bo end
            if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
            return nameKey(a.name) < nameKey(b.name)
        elseif mode == "rank" then
            if a.rankIndex ~= b.rankIndex then
                return dir == "asc" and a.rankIndex > b.rankIndex or a.rankIndex < b.rankIndex
            end
            local ao, bo = onlineVal(a.name), onlineVal(b.name)
            if ao ~= bo then return ao > bo end
            return nameKey(a.name) < nameKey(b.name)
        elseif mode == "recent" then
            local av, bv = a.lastSeenTS or 0, b.lastSeenTS or 0
            if av ~= bv then return dir == "asc" and av < bv or av > bv end
            if a.count ~= b.count then return a.count > b.count end
            return nameKey(a.name) < nameKey(b.name)
        else
            local ac, bc = a.hoursPerDay or a.count or 0, b.hoursPerDay or b.count or 0
            if ac ~= bc then return dir == "asc" and ac < bc or ac > bc end
            local av, bv = a.lastSeenTS or 0, b.lastSeenTS or 0
            if av ~= bv then return av > bv end
            return nameKey(a.name) < nameKey(b.name)
        end
    end

    table.sort(out, cmp)
    return out
end

function GAT:GetPlayerData(name)
    local d = (self.db.data or {})[name]
    if type(d) == "table" then return d end
    return nil
end

-- =============================================================================
-- Resets
-- =============================================================================
function GAT:ResetData()
    if self.db and self.db.data then wipe(self.db.data) end
end

function GAT:ResetPlayer(name)
    if not self:IsMasterBuild() then return end
    if self.db and self.db.data then self.db.data[name] = nil end
end

-- =============================================================================
-- Auto archive
-- =============================================================================
local function dateKeyToTS(dateStr)
    local y, m, d = dateStr:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if y then
        return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
    end
    return 0
end

function GAT:RunAutoArchive()
    if not self.db or not self.db.settings or not self.db.settings.enableAutoArchive then
        return
    end
    local days = math.max(7, self.db.settings.autoArchiveDays or 30)
    local cutoff = time() - (days * 24 * 3600)

    local removedDays, recalcPlayers, deletedPlayers = 0, 0, 0

    if self.db.data then
        for name, entry in pairs(self.db.data) do
            if entry.daily and type(entry.daily) == "table" then
                local newTotal = 0
                local changed = false

                for dateStr, dailyCount in pairs(entry.daily) do
                    local ts = dateKeyToTS(dateStr)
                    if ts > 0 and ts < cutoff then
                        entry.daily[dateStr] = nil
                        removedDays = removedDays + 1
                        changed = true
                    else
                        newTotal = newTotal + dailyCount
                    end
                end

                if newTotal == 0 then
                    self.db.data[name] = nil
                    deletedPlayers = deletedPlayers + 1
                else
                    entry.total = newTotal
                    if changed then recalcPlayers = recalcPlayers + 1 end
                end
            end
        end
    end

    if deletedPlayers > 0 or removedDays > 0 then
        self:Print("Limpieza: Se borraron " .. deletedPlayers .. " jugadores inactivos y " .. removedDays .. " días antiguos.")
    end
end

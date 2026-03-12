local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

local WEB_SYNC_VERSION = 1

local function getDB()
    GAT.db = GAT.db or _G.GuildActivityTrackerDB or {}
    _G.GuildActivityTrackerDB = GAT.db
    return GAT.db
end

local function getWebSync()
    local db = getDB()
    return db.webSync
end

local function getLastProcessedTimestamp()
    local db = getDB()
    db._webSyncState = db._webSyncState or {}
    return db._webSyncState.lastProcessedTimestamp or 0
end

local function setLastProcessedTimestamp(ts)
    local db = getDB()
    db._webSyncState = db._webSyncState or {}
    db._webSyncState.lastProcessedTimestamp = ts
end

local function clearWebSync()
    local db = getDB()
    db.webSync = nil
end

local function log(msg)
    if GAT.Print then
        GAT:Print("|cff00ccff[WebSync]|r " .. tostring(msg))
    end
end

local function applyAltLinks(altLinks)
    if not altLinks or type(altLinks) ~= "table" then return end
    if not GRM or not GRM.AddAlt or not GRM.SetMain or not GRM.GetPlayer then
        log("GRM API not available, skipping alt links.")
        return
    end

    local groupsApplied = 0
    local errors = 0

    for _, group in pairs(altLinks) do
        if type(group) == "table" then
            local mainName = group.main
            local alts = group.alts

            if mainName and type(mainName) == "string" and mainName ~= "" then
                local ok, err = pcall(function()
                    local mainPlayer = GRM.GetPlayer(mainName)
                    if mainPlayer then
                        GRM.SetMain(mainName, time())

                        if alts and type(alts) == "table" then
                            for _, altName in ipairs(alts) do
                                if type(altName) == "string" and altName ~= "" and altName ~= mainName then
                                    local altPlayer = GRM.GetPlayer(altName)
                                    if altPlayer then
                                        GRM.AddAlt(mainName, altName, time())
                                    end
                                end
                            end
                        end

                        groupsApplied = groupsApplied + 1
                    end
                end)
                if not ok then
                    errors = errors + 1
                end
            end
        end
    end

    log("Alt links applied: " .. groupsApplied .. " groups" .. (errors > 0 and (" (" .. errors .. " errors)") or ""))
end

local function applyBanList(banList)
    if not banList or type(banList) ~= "table" then return end

    local db = getDB()
    db._webSyncBanList = db._webSyncBanList or {}

    local count = 0
    for _, entry in pairs(banList) do
        if type(entry) == "table" and entry.name and entry.name ~= "" then
            db._webSyncBanList[entry.name] = {
                name = entry.name,
                reason = entry.reason or "",
                bannedBy = entry.bannedBy or "WebSync",
                bannedAt = entry.bannedAt or time(),
                source = "web"
            }
            count = count + 1
        end
    end

    log("Ban list updated: " .. count .. " entries stored.")
end

local function applyNicknames(nicknames)
    if not nicknames or type(nicknames) ~= "table" then return end

    local applied = 0
    local skipped = 0

    local hasGRM = GRM and GRM.NN and GRM.NN.SetNickname and GRM.GetPlayer

    for _, entry in pairs(nicknames) do
        if type(entry) == "table" and entry.name and entry.name ~= "" and entry.nickname and entry.nickname ~= "" then
            if hasGRM then
                local ok, err = pcall(function()
                    local player = GRM.GetPlayer(entry.name)
                    if player then
                        GRM.NN.SetNickname(entry.name, entry.nickname, "WebSync", time(), true)
                        applied = applied + 1
                    else
                        skipped = skipped + 1
                    end
                end)
                if not ok then
                    skipped = skipped + 1
                end
            else
                skipped = skipped + 1
            end
        end
    end

    if not hasGRM and nicknames and next(nicknames) then
        local db = getDB()
        db._webSyncNicknames = db._webSyncNicknames or {}
        for _, entry in pairs(nicknames) do
            if type(entry) == "table" and entry.name and entry.nickname then
                db._webSyncNicknames[entry.name] = entry.nickname
            end
        end
        log("GRM nickname API not available, stored " .. tostring(skipped) .. " nicknames locally.")
    else
        log("Nicknames applied: " .. applied .. (skipped > 0 and (" (skipped " .. skipped .. ")") or ""))
    end
end

local function applyRosterMeta(rosterMeta)
    if not rosterMeta or type(rosterMeta) ~= "table" then return end

    local db = getDB()
    db.data = db.data or {}

    local updated = 0

    for name, meta in pairs(rosterMeta) do
        if type(name) == "string" and name ~= "" and type(meta) == "table" then
            local entry = db.data[name]
            if entry and type(entry) == "table" then
                if meta.rankName then entry.rankName = meta.rankName end
                if meta.rankIndex then entry.rankIndex = meta.rankIndex end
                updated = updated + 1
            end
        end
    end

    log("Roster meta updated: " .. updated .. " players.")
end

local function applyMessageCounts(messageCounts)
    if not messageCounts or type(messageCounts) ~= "table" then return end

    local db = getDB()
    db.data = db.data or {}

    local updated = 0
    local created = 0

    for name, info in pairs(messageCounts) do
        if type(name) == "string" and name ~= "" and type(info) == "table" then
            local serverTotal = tonumber(info.total) or 0
            local entry = db.data[name]
            if not entry or type(entry) ~= "table" then
                entry = { total = 0, lastSeen = "", lastSeenTS = 0, lastMessage = "", daily = {}, rankIndex = 99, rankName = "\226\128\148" }
                db.data[name] = entry
                created = created + 1
            end
            entry.total = serverTotal
            if info.lastMessage and info.lastMessage ~= "" then
                entry.lastMessage = info.lastMessage
            end
            local serverTS = tonumber(info.lastSeenTS or 0) or 0
            if serverTS > 0 and serverTS > (entry.lastSeenTS or 0) then
                entry.lastSeenTS = serverTS
                local d = date("*t", serverTS)
                entry.lastSeen = string.format("%02d/%02d/%04d %02d:%02d", d.month, d.day, d.year, d.hour, d.min)
            end
            updated = updated + 1
        end
    end

    log("Message counts synced: " .. updated .. " updated, " .. created .. " new entries.")
end

local function applyActivityScores(activityScores)
    if not activityScores or type(activityScores) ~= "table" then return end

    local db = getDB()
    db._webSyncActivityScores = db._webSyncActivityScores or {}

    local count = 0
    for name, score in pairs(activityScores) do
        if type(name) == "string" and name ~= "" then
            local val = tonumber(score)
            if val and val >= 0 then
                db._webSyncActivityScores[name] = val
                count = count + 1
            end
        end
    end

    log("Activity scores synced: " .. count .. " players.")
end

function GAT:ProcessWebSync()
    local webSync = getWebSync()
    if not webSync then return false end

    local syncTimestamp = tonumber(webSync.syncTimestamp or 0) or 0
    if syncTimestamp <= 0 then
        log("No valid syncTimestamp found, skipping.")
        clearWebSync()
        return false
    end

    local lastProcessed = getLastProcessedTimestamp()
    if syncTimestamp <= lastProcessed then
        clearWebSync()
        return false
    end

    log("Processing web sync data (timestamp: " .. tostring(syncTimestamp) .. ")...")

    if webSync.altLinks then
        applyAltLinks(webSync.altLinks)
    end

    if webSync.banList then
        applyBanList(webSync.banList)
    end

    if webSync.nicknames then
        applyNicknames(webSync.nicknames)
    end

    if webSync.rosterMeta then
        applyRosterMeta(webSync.rosterMeta)
    end

    if webSync.messageCounts then
        applyMessageCounts(webSync.messageCounts)
    end

    if webSync.activityScores then
        applyActivityScores(webSync.activityScores)
    end

    setLastProcessedTimestamp(syncTimestamp)
    clearWebSync()

    log("Web sync complete.")
    return true
end

function GAT:IsPlayerWebBanned(name)
    local db = getDB()
    if db._webSyncBanList and db._webSyncBanList[name] then
        return true, db._webSyncBanList[name]
    end
    return false, nil
end

function GAT:GetWebSyncNickname(name)
    local db = getDB()
    if db._webSyncNicknames and db._webSyncNicknames[name] then
        return db._webSyncNicknames[name]
    end
    return nil
end

function GAT:GetWebSyncActivityScore(name)
    local db = getDB()
    if db._webSyncActivityScores and db._webSyncActivityScores[name] then
        return db._webSyncActivityScores[name]
    end
    return nil
end

function GAT:GetWebSyncStatus()
    local lastProcessed = getLastProcessedTimestamp()
    local webSync = getWebSync()
    return {
        lastProcessedTimestamp = lastProcessed,
        pendingSyncTimestamp = webSync and tonumber(webSync.syncTimestamp or 0) or 0,
        hasPendingSync = webSync ~= nil
    }
end

local webSyncFrame = CreateFrame("Frame")
webSyncFrame:RegisterEvent("PLAYER_LOGIN")
webSyncFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(5, function()
            if GAT.ProcessWebSync then
                GAT:ProcessWebSync()
            end
        end)
    end
end)

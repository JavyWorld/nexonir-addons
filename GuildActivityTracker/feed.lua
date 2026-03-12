local addonName = ...
local GAT = _G[addonName]
if not GAT then return end

local SECONDS_PER_DAY = 86400
local RETENTION_DAYS = 30

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

function GAT:GenerateFeed()
    if not self:IsInTargetGuild() then return end
    if not self.db then return end

    local now = time()
    local cutoff30d = now - (RETENTION_DAYS * SECONDS_PER_DAY)
    local defaultRealm = getRealm()

    local feed = {
        schema_version = 2,
        generated_ts = now,
        generated_at = date("!%Y-%m-%dT%H:%M:%SZ", now),
        default_realm = defaultRealm,
        gat_version = GAT.VERSION,
    }

    local messageMap = {}
    local dailyActivity = {}
    local totalMessages = 0
    local recentMessages = 0
    local activeMembers30d = 0

    if self.db.data then
        for name, entry in pairs(self.db.data) do
            if type(entry) == "table" then
                local fullName = canonicalName(name) or name
                messageMap[fullName] = {
                    total = entry.total or 0,
                    lastMessage = entry.lastMessage or "",
                    lastSeenTS = entry.lastSeenTS or 0,
                }
                totalMessages = totalMessages + (entry.total or 0)

                local playerRecent = 0
                if entry.daily then
                    for dayKey, count in pairs(entry.daily) do
                        dailyActivity[dayKey] = (dailyActivity[dayKey] or 0) + count

                        local y, m, d = dayKey:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
                        if y then
                            local dayTs = time({year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=0, min=0, sec=0})
                            if dayTs >= cutoff30d then
                                playerRecent = playerRecent + count
                            end
                        end
                    end
                end

                recentMessages = recentMessages + playerRecent
                if playerRecent > 0 then
                    activeMembers30d = activeMembers30d + 1
                end
            end
        end
    end

    local memberCount = 0
    local onlineNow = 0
    local rosterData = {}

    if self.db.roster then
        for name, info in pairs(self.db.roster) do
            memberCount = memberCount + 1
            if info.is_online then
                onlineNow = onlineNow + 1
            end
            rosterData[name] = {
                rank = info.rank,
                level = info.level,
                class = info.class,
                is_online = info.is_online,
            }
        end
    end

    if memberCount == 0 then
        local numMembers = GetNumGuildMembers()
        for i = 1, numMembers do
            local name, rank, rankIndex, level, _, zone, _, _, isOnline, _, classFileName = GetGuildRosterInfo(i)
            if name then
                memberCount = memberCount + 1
                if isOnline then onlineNow = onlineNow + 1 end
                local fullName = Ambiguate(name, "none")
                rosterData[fullName] = {
                    rank = rank or "",
                    level = level or 0,
                    class = classFileName or "UNKNOWN",
                    is_online = isOnline and true or false,
                }
            end
        end
    end

    feed.summary = {
        member_count = memberCount,
        online_now = onlineNow,
        active_members_30d = activeMembers30d,
        total_messages = totalMessages,
        recent_messages_30d = recentMessages,
    }

    feed.message_counter_map = messageMap
    feed.daily_activity = dailyActivity
    feed.roster = rosterData

    if self.db.guild_log and #self.db.guild_log > 0 then
        feed.guild_log = self.db.guild_log
    end

    if self.db.chatBuffer and #self.db.chatBuffer > 0 then
        feed.chat_buffer = self.db.chatBuffer
    end

    if self.db.stats then
        local statsCutoff = now - (7 * SECONDS_PER_DAY)
        local prunedStats = {}
        for ts, onlineCount in pairs(self.db.stats) do
            local numTs = tonumber(ts)
            if numTs and numTs >= statsCutoff then
                prunedStats[tostring(numTs)] = onlineCount
            end
        end
        if next(prunedStats) then
            feed.stats = prunedStats
        end
    end

    if self.db.mythic then
        local mythicData = {}
        for name, info in pairs(self.db.mythic) do
            if info.score and info.score > 0 then
                mythicData[name] = {
                    score = info.score,
                    class = info.class,
                }
            end
        end
        if next(mythicData) then
            feed.mythic_scores = mythicData
        end
    end

    GuildRosterManagerGATFeed = feed
end

local feedTimer = CreateFrame("Frame")
local FEED_INTERVAL = 300
local lastFeedTime = 0

feedTimer:RegisterEvent("PLAYER_ENTERING_WORLD")
feedTimer:SetScript("OnEvent", function()
    C_Timer.After(15, function()
        if GAT.GenerateFeed then
            GAT:GenerateFeed()
            lastFeedTime = time()
        end
    end)
end)

feedTimer:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 30 then return end
    self.elapsed = 0

    local now = time()
    if now - lastFeedTime >= FEED_INTERVAL then
        if GAT.GenerateFeed and GAT.IsInTargetGuild and GAT:IsInTargetGuild() then
            GAT:GenerateFeed()
            lastFeedTime = now
        end
    end
end)

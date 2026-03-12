-- Guild activity metrics collector for promotions based on chat and connectivity.

local Activity = {};
GRM.ActivityMetrics = Activity;

local METRICS_SCHEMA_VERSION = 1;
local MAX_DAILY_RETENTION = 30; -- Keep a rolling month of activity.
local SECONDS_PER_DAY = 86400;
local HOURS_PER_DAY = 24;
local POINTS_PER_HOUR = 4;
local FINAL_HOUR_POINTS = 8;
local rosterSnapshotThrottle = 0;
local activityInCombat = false;
local activityDeferredSnapshot = false;

local function NormalizeRealmName(realmName)
    realmName = realmName or "";
    return string.gsub(string.gsub(realmName, "-", ""), "%s+", "");
end

local function GetCurrentRealmName()
    if GRM_G and GRM_G.realmName and GRM_G.realmName ~= "" then
        return GRM_G.realmName;
    end
    return NormalizeRealmName(GetRealmName());
end

local function GetGuildStorageKey()
    if GRM_G and GRM_G.guildName and GRM_G.guildName ~= "" then
        return GRM_G.guildName;
    end

    local guildName, _, _, serverName = GetGuildInfo("PLAYER");
    if guildName and guildName ~= "" then
        if serverName and serverName ~= "" then
            return guildName .. "-" .. NormalizeRealmName(serverName);
        end
        return guildName .. "-" .. GetCurrentRealmName();
    end

    return nil;
end

local function CanonicalizeName(rawName)
    if type(rawName) ~= "string" then
        return nil;
    end

    local trimmedName = GRM.Trim(rawName);
    if trimmedName == "" then
        return nil;
    end

    local playerName = trimmedName;
    local realmName = GetCurrentRealmName();
    local dashPos = string.find(trimmedName, "-", 1, true);

    if dashPos then
        playerName = string.sub(trimmedName, 1, dashPos - 1);
        realmName = NormalizeRealmName(string.sub(trimmedName, dashPos + 1));
        if realmName == "" then
            realmName = GetCurrentRealmName();
        end
    end

    if playerName == "" then
        return nil;
    end

    return playerName .. "-" .. realmName;
end

local function DateKeyToEpoch(dateKey)
    if type(dateKey) ~= "string" then
        return 0;
    end

    local year, month, day = dateKey:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$");
    if year then
        return time({
            year = tonumber(year),
            month = tonumber(month),
            day = tonumber(day),
            hour = 0,
            min = 0,
            sec = 0
        });
    end

    return 0;
end

local function PruneDailyMap(dailyMap, retentionInDays)
    if type(dailyMap) ~= "table" then
        return;
    end

    local cutoff = time() - (retentionInDays * SECONDS_PER_DAY);
    for dateKey in pairs(dailyMap) do
        local dateEpoch = DateKeyToEpoch(dateKey);
        if dateEpoch > 0 and dateEpoch < cutoff then
            dailyMap[dateKey] = nil;
        end
    end
end

local function SumRecentValues(dailyMap, days)
    if type(dailyMap) ~= "table" then
        return 0;
    end

    local cutoff = time() - (days * SECONDS_PER_DAY);
    local result = 0;
    for dateKey, count in pairs(dailyMap) do
        local dateEpoch = DateKeyToEpoch(dateKey);
        if dateEpoch > 0 and dateEpoch >= cutoff then
            result = result + math.max(0, math.floor(tonumber(count) or 0));
        end
    end

    return result;
end

local function EnsureDailyHourMarks(playerMetrics)
    if type(playerMetrics.daily_hour_marks) ~= "table" then
        playerMetrics.daily_hour_marks = {};
    end
    return playerMetrics.daily_hour_marks;
end

local function MarkHourlyPresence(playerMetrics, timestamp)
    local markTS = timestamp or time();
    local dayKey = date("%Y-%m-%d", markTS);
    local hourIndex = (tonumber(date("%H", markTS)) or 0) + 1;
    if hourIndex < 1 then
        hourIndex = 1;
    elseif hourIndex > HOURS_PER_DAY then
        hourIndex = HOURS_PER_DAY;
    end

    local dailyHourMarks = EnsureDailyHourMarks(playerMetrics);
    if type(dailyHourMarks[dayKey]) ~= "table" then
        dailyHourMarks[dayKey] = {};
    end

    dailyHourMarks[dayKey][hourIndex] = true;
end

local function CountActiveHoursInDay(hourMarks)
    if type(hourMarks) ~= "table" then
        return 0;
    end

    local count = 0;
    for i = 1, HOURS_PER_DAY do
        if hourMarks[i] then
            count = count + 1;
        end
    end
    return count;
end

local function CalculateDailyActivityScore(activeHours)
    local clampedHours = math.max(0, math.min(HOURS_PER_DAY, math.floor(tonumber(activeHours) or 0)));
    if clampedHours >= HOURS_PER_DAY then
        return ((HOURS_PER_DAY - 1) * POINTS_PER_HOUR) + FINAL_HOUR_POINTS; -- 100
    end
    return clampedHours * POINTS_PER_HOUR;
end

local function CalculateRecentActivityAverage(dailyHourMarks, days)
    if type(dailyHourMarks) ~= "table" then
        return 0, 0, 0;
    end

    local cutoff = time() - (days * SECONDS_PER_DAY);
    local totalScore = 0;
    local recordedDays = 0;

    for dayKey, hourMarks in pairs(dailyHourMarks) do
        local dayEpoch = DateKeyToEpoch(dayKey);
        if dayEpoch > 0 and dayEpoch >= cutoff then
            totalScore = totalScore + CalculateDailyActivityScore(CountActiveHoursInDay(hourMarks));
            recordedDays = recordedDays + 1;
        end
    end

    local averageScore = 0;
    if recordedDays > 0 then
        averageScore = totalScore / recordedDays;
    end

    return averageScore, recordedDays, totalScore;
end

local function EnsureMetricsDB()
    local guildKey = GetGuildStorageKey();
    if not guildKey then
        return nil;
    end

    GRM_Misc[guildKey] = GRM_Misc[guildKey] or {};
    local guildMisc = GRM_Misc[guildKey];

    guildMisc.activityMetrics = guildMisc.activityMetrics or {};
    local metrics = guildMisc.activityMetrics;

    metrics.schema_version = METRICS_SCHEMA_VERSION;
    metrics.players = metrics.players or {};
    metrics.onlineState = metrics.onlineState or {};
    metrics.summary = metrics.summary or {};
    if metrics.isDirty == nil then
        metrics.isDirty = true;
    end

    return metrics;
end

local function EnsurePlayerEntry(metrics, fullName)
    local playerMetrics = metrics.players[fullName];
    if type(playerMetrics) ~= "table" then
        playerMetrics = {
            total_messages = 0,
            daily_messages = {},
            total_connections = 0,
            daily_connections = {},
            daily_hour_marks = {},
            last_seen_ts = 0,
            last_message = "",
            is_online = false
        };
        metrics.players[fullName] = playerMetrics;
    end

    playerMetrics.total_messages = math.max(0, math.floor(tonumber(playerMetrics.total_messages) or 0));
    playerMetrics.total_connections = math.max(0, math.floor(tonumber(playerMetrics.total_connections) or 0));
    playerMetrics.daily_messages = playerMetrics.daily_messages or {};
    playerMetrics.daily_connections = playerMetrics.daily_connections or {};
    playerMetrics.daily_hour_marks = playerMetrics.daily_hour_marks or {};
    playerMetrics.last_seen_ts = tonumber(playerMetrics.last_seen_ts) or 0;
    playerMetrics.last_message = playerMetrics.last_message or "";

    return playerMetrics;
end

local function MarkMetricsDirty(metrics)
    if metrics then
        metrics.isDirty = true;
    end
end

local function RequestGuildRosterRefresh()
    if GRM and GRM.GuildRoster then
        GRM.GuildRoster();
    elseif C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster();
    elseif GuildRoster then
        GuildRoster();
    end
end

function Activity.RecordGuildChatMessage(sender, messageText)
    if not IsInGuild() then
        return;
    end
    if activityInCombat then return; end

    local metrics = EnsureMetricsDB();
    if not metrics then
        return;
    end

    local fullName = CanonicalizeName(sender);
    if not fullName then
        return;
    end

    local playerMetrics = EnsurePlayerEntry(metrics, fullName);
    local now = time();
    local dayKey = date("%Y-%m-%d");

    playerMetrics.total_messages = playerMetrics.total_messages + 1;
    playerMetrics.daily_messages[dayKey] = math.max(0, math.floor(tonumber(playerMetrics.daily_messages[dayKey]) or 0)) + 1;
    playerMetrics.last_seen_ts = now;
    MarkHourlyPresence(playerMetrics, now);
    if type(messageText) == "string" and messageText ~= "" then
        playerMetrics.last_message = messageText;
    end

    MarkMetricsDirty(metrics);
end

function Activity.RecordRosterSnapshot(forceScan)
    if not IsInGuild() then
        return;
    end
    if activityInCombat then
        activityDeferredSnapshot = true;
        return;
    end

    local now = time();
    if not forceScan and (now - rosterSnapshotThrottle) < 2 then
        return;
    end
    rosterSnapshotThrottle = now;

    local metrics = EnsureMetricsDB();
    if not metrics then
        return;
    end

    local previousOnlineState = metrics.onlineState or {};
    local nextOnlineState = {};
    local dayKey = date("%Y-%m-%d");
    local memberCount = GetNumGuildMembers();
    local onlineNow = 0;

    for i = 1, memberCount do
        local rosterName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i);
        if rosterName then
            local fullName = CanonicalizeName(Ambiguate(rosterName, "none"));
            if fullName then
                nextOnlineState[fullName] = isOnline and true or false;
                local playerMetrics = EnsurePlayerEntry(metrics, fullName);
                playerMetrics.is_online = isOnline and true or false;

                if isOnline then
                    onlineNow = onlineNow + 1;
                    playerMetrics.last_seen_ts = now;
                    MarkHourlyPresence(playerMetrics, now);

                    if not previousOnlineState[fullName] then
                        playerMetrics.total_connections = playerMetrics.total_connections + 1;
                        playerMetrics.daily_connections[dayKey] = math.max(0, math.floor(tonumber(playerMetrics.daily_connections[dayKey]) or 0)) + 1;
                    end
                end
            end
        end
    end

    metrics.onlineState = nextOnlineState;
    metrics.summary.member_count = memberCount;
    metrics.summary.online_now = onlineNow;
    metrics.last_roster_update_ts = now;
    MarkMetricsDirty(metrics);
end

function Activity.BuildFeed()
    local metrics = EnsureMetricsDB();
    if not metrics then
        return nil;
    end

    if not metrics.isDirty and type(metrics.feedCache) == "table" then
        return metrics.feedCache;
    end

    local generatedTS = time();
    local feed = {
        schema_version = 1,
        generated_ts = generatedTS,
        generated_at = date("!%Y-%m-%dT%H:%M:%SZ", generatedTS),
        default_realm = GetCurrentRealmName(),
        summary = {
            member_count = math.max(0, math.floor(tonumber(metrics.summary.member_count) or 0)),
            online_now = math.max(0, math.floor(tonumber(metrics.summary.online_now) or 0)),
            active_members_30d = 0,
            total_messages = 0,
            recent_messages_30d = 0,
            total_connections = 0,
            recent_connections_7d = 0,
            tracked_members_30d = 0,
            average_activity_30d = 0
        },
        message_counter_map = {},
        connection_counter_map = {},
        members = {}
    };

    local activeMembers30d = 0;
    local trackedMembers30d = 0;
    local aggregateAverage30d = 0;

    for fullName, playerMetrics in pairs(metrics.players) do
        if type(playerMetrics) == "table" then
            playerMetrics.daily_messages = playerMetrics.daily_messages or {};
            playerMetrics.daily_connections = playerMetrics.daily_connections or {};
            playerMetrics.daily_hour_marks = playerMetrics.daily_hour_marks or {};

            PruneDailyMap(playerMetrics.daily_messages, MAX_DAILY_RETENTION);
            PruneDailyMap(playerMetrics.daily_connections, MAX_DAILY_RETENTION);
            PruneDailyMap(playerMetrics.daily_hour_marks, MAX_DAILY_RETENTION);

            local totalMessages = math.max(0, math.floor(tonumber(playerMetrics.total_messages) or 0));
            local recentMessages30d = SumRecentValues(playerMetrics.daily_messages, 30);
            local totalConnections = math.max(0, math.floor(tonumber(playerMetrics.total_connections) or 0));
            local recentConnections7d = SumRecentValues(playerMetrics.daily_connections, 7);
            local averageActivity30d, daysRecorded30d = CalculateRecentActivityAverage(playerMetrics.daily_hour_marks, 30);
            local todayKey = date("%Y-%m-%d");
            local activeHoursToday = CountActiveHoursInDay(playerMetrics.daily_hour_marks[todayKey]);
            local todayActivityScore = CalculateDailyActivityScore(activeHoursToday);
            local isOnline = metrics.onlineState and metrics.onlineState[fullName] or false;

            if recentMessages30d > 0 then
                activeMembers30d = activeMembers30d + 1;
            end

            if daysRecorded30d > 0 then
                trackedMembers30d = trackedMembers30d + 1;
                aggregateAverage30d = aggregateAverage30d + averageActivity30d;
            end

            if totalMessages > 0 or recentMessages30d > 0 or totalConnections > 0 or recentConnections7d > 0 or isOnline then
                feed.message_counter_map[fullName] = totalMessages;
                feed.connection_counter_map[fullName] = totalConnections;
                table.insert(feed.members, {
                    name = fullName,
                    total_messages = totalMessages,
                    recent_messages_30d = recentMessages30d,
                    total_connections = totalConnections,
                    recent_connections_7d = recentConnections7d,
                    active_hours_today = activeHoursToday,
                    today_activity_score = todayActivityScore,
                    days_recorded_30d = daysRecorded30d,
                    average_daily_activity_30d = averageActivity30d,
                    is_online = isOnline and true or false,
                    last_seen_ts = tonumber(playerMetrics.last_seen_ts) or 0,
                    last_message = playerMetrics.last_message or ""
                });

                feed.summary.total_messages = feed.summary.total_messages + totalMessages;
                feed.summary.recent_messages_30d = feed.summary.recent_messages_30d + recentMessages30d;
                feed.summary.total_connections = feed.summary.total_connections + totalConnections;
                feed.summary.recent_connections_7d = feed.summary.recent_connections_7d + recentConnections7d;
            end
        end
    end

    feed.summary.active_members_30d = activeMembers30d;
    feed.summary.tracked_members_30d = trackedMembers30d;
    if trackedMembers30d > 0 then
        feed.summary.average_activity_30d = aggregateAverage30d / trackedMembers30d;
    else
        feed.summary.average_activity_30d = 0;
    end

    table.sort(feed.members, function(a, b)
        if a.total_messages ~= b.total_messages then
            return a.total_messages > b.total_messages;
        end
        return string.lower(a.name or "") < string.lower(b.name or "");
    end);

    metrics.feedCache = feed;
    metrics.isDirty = false;

    return feed;
end

local function FindPlayerMetricsEntry(metrics, rawName)
    if type(metrics) ~= "table" or type(metrics.players) ~= "table" then
        return nil, nil;
    end

    local fullName = CanonicalizeName(rawName);
    if fullName and type(metrics.players[fullName]) == "table" then
        return fullName, metrics.players[fullName];
    end

    if type(rawName) ~= "string" or rawName == "" then
        return fullName, nil;
    end

    local trimmed = GRM.Trim(rawName);
    local lookupName = string.lower((string.match(trimmed, "([^%-]+)") or trimmed));
    if lookupName == "" then
        return fullName, nil;
    end

    for candidateName, playerMetrics in pairs(metrics.players) do
        if type(candidateName) == "string" and type(playerMetrics) == "table" then
            local candidateBase = string.lower((string.match(candidateName, "([^%-]+)") or candidateName));
            if candidateBase == lookupName then
                return candidateName, playerMetrics;
            end
        end
    end

    return fullName, nil;
end

function Activity.GetPlayerSummary(rawName)
    local metrics = EnsureMetricsDB();
    if not metrics then
        return nil;
    end

    local fullName, rawMetrics = FindPlayerMetricsEntry(metrics, rawName);
    if type(rawMetrics) ~= "table" then
        return nil;
    end

    local playerMetrics = EnsurePlayerEntry(metrics, fullName);
    local averageActivity30d, daysRecorded30d = CalculateRecentActivityAverage(playerMetrics.daily_hour_marks, 30);
    local todayKey = date("%Y-%m-%d");
    local activeHoursToday = CountActiveHoursInDay(playerMetrics.daily_hour_marks[todayKey]);

    return {
        name = fullName,
        total_messages = math.max(0, math.floor(tonumber(playerMetrics.total_messages) or 0)),
        recent_messages_30d = SumRecentValues(playerMetrics.daily_messages, 30),
        total_connections = math.max(0, math.floor(tonumber(playerMetrics.total_connections) or 0)),
        recent_connections_7d = SumRecentValues(playerMetrics.daily_connections, 7),
        active_hours_today = activeHoursToday,
        today_activity_score = CalculateDailyActivityScore(activeHoursToday),
        days_recorded_30d = daysRecorded30d,
        average_daily_activity_30d = averageActivity30d,
        is_online = metrics.onlineState and metrics.onlineState[fullName] or false,
        last_seen_ts = tonumber(playerMetrics.last_seen_ts) or 0
    };
end

GRM.GetGuildActivityMetricsFeed = function()
    return Activity.BuildFeed();
end

GRM.GetPlayerActivitySummary = function(playerName)
    return Activity.GetPlayerSummary(playerName);
end

local ActivityEvents = CreateFrame("Frame");
ActivityEvents:RegisterEvent("PLAYER_ENTERING_WORLD");
ActivityEvents:RegisterEvent("PLAYER_GUILD_UPDATE");
ActivityEvents:RegisterEvent("GUILD_ROSTER_UPDATE");
ActivityEvents:RegisterEvent("CHAT_MSG_GUILD");
ActivityEvents:RegisterEvent("PLAYER_REGEN_DISABLED");
ActivityEvents:RegisterEvent("PLAYER_REGEN_ENABLED");

ActivityEvents:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        activityInCombat = true;
        return;
    end

    if event == "PLAYER_REGEN_ENABLED" then
        activityInCombat = false;
        if activityDeferredSnapshot then
            activityDeferredSnapshot = false;
            C_Timer.After(1, function()
                if not activityInCombat and IsInGuild() then
                    Activity.RecordRosterSnapshot(true);
                end
            end);
        end
        return;
    end

    if activityInCombat then return; end

    if event == "CHAT_MSG_GUILD" then
        local messageText, sender = ...;
        Activity.RecordGuildChatMessage(sender, messageText);
        return;
    end

    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(4, function()
            if not activityInCombat and IsInGuild() then
                RequestGuildRosterRefresh();
                Activity.RecordRosterSnapshot(true);
            end
        end);
        return;
    end

    if event == "PLAYER_GUILD_UPDATE" then
        C_Timer.After(2, function()
            if not activityInCombat and IsInGuild() then
                RequestGuildRosterRefresh();
                Activity.RecordRosterSnapshot(true);
            end
        end);
        return;
    end

    if event == "GUILD_ROSTER_UPDATE" then
        if activityInCombat then
            activityDeferredSnapshot = true;
        else
            Activity.RecordRosterSnapshot(false);
        end
    end
end);

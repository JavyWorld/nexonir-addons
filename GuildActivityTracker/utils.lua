local addonName = ...
local GAT = _G[addonName]

-- Validar nombres
function GAT:Normalize(name)
    if not name then return nil end

    name = tostring(name)
    if name == "" then return nil end

    if Ambiguate then
        name = Ambiguate(name, "none")
    end

    if not name or name == "" then return nil end

    if not name:find("-") then
        name = name .. "-" .. GetRealmName()
    end

    return name
end

-- Si el jugador es uno de tus personajes
function GAT:IsSelf(name)
    local normalized = GAT:Normalize(name)
    if not normalized then return false end

    local short = Ambiguate and Ambiguate(normalized, "short") or normalized
    return normalized == GAT.fullPlayerName or short == GAT.shortPlayerName
end

-- Si este jugador está filtrado
function GAT:IsFiltered(name)
    if not (GAT.db and GAT.db.filters) then return false end

    local normalized = GAT:Normalize(name)
    if not normalized then return false end

    if GAT.db.filters[normalized] == true then return true end

    local short = Ambiguate and Ambiguate(normalized, "short") or normalized
    return GAT.db.filters[short] == true
end

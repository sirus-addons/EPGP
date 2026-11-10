--
-- GetNumRecords(): Returns the number of log records.
--
-- GetLogRecord(i): Returns the ith log record starting 0.
--
-- ExportLog(): Returns a string with the data of the exported log for
-- import into the web application.
--
-- UndoLastAction(): Removes the last entry from the log and undoes
-- its action. The undone action is not logged.
--
-- This module also fires the following messages.
--
-- LogChanged(n): Fired when the log is changed. n is the new size of
-- the log.
--

local mod = EPGP:NewModule("log", "AceComm-3.0", "AceTimer-3.0")

local L = LibStub:GetLibrary("AceLocale-3.0"):GetLocale("EPGP")
local GS = LibStub("LibGuildStorage-1.0")
local JSON = LibStub("LibJSON-1.0")

local CallbackHandler = LibStub("CallbackHandler-1.0")
if not mod.callbacks then
    mod.callbacks = CallbackHandler:New(mod)
end
local callbacks = mod.callbacks

local function GetTimestamp()
    return time()
end

local function CheckFilter(log, str)
    return string.find(string.lower(log[3]), string.lower(str), 1, true)
end

local filter = ""
local filtered = {}
local exists_logs = {}
local exists_floor = 0

local function starts(str, start)
    return string.sub(str, 1, string.len(start)) == start
end

local function SortLogIfNeeded(records)
    for i = 2, #records do
        if records[i][1] < records[i - 1][1] then
            table.sort(records, function (a, b)
                return a[1] < b[1]
            end)
            return
        end
    end
end

local LOG_FORMAT_NEW = "LOG:%d\31%s\31%s\31%s\31%d\31%s"

local function ParseLogMessage(msg)
    local body = string.match(msg, "^LOG:(.*)$")
    if not body then
        return
    end

    local parts = { strsplit("\31", body) }
    local count = #parts
    local timestamp, amount = tonumber(parts[1]), tonumber(parts[5])
    if not timestamp or not amount or not (timestamp >= 0 and timestamp <= time() + 86400) then
        return
    end

    if count == 7 then
        return { timestamp, parts[2], parts[3], parts[4], amount, parts[7], tonumber(parts[6]) }
    elseif count == 6 or count == 5 then
        return { timestamp, parts[2], parts[3], parts[4], amount, parts[6] }
    end
end

local function NormalizeRecord(record)
    if type(record[2]) ~= "string" then
        return
    end

    local kind, name = string.match(record[2], "^(.-)\31(.*)$")
    local delta = tonumber(record[4])
    if kind and delta then
        record[2], record[3], record[4], record[5], record[7] = kind, name, record[3], delta, record[5]
    end
end

local function AppendToLog(kind, event_type, name, reason, amount, mass, undo)
    -- Clear the redo table
    if not undo then
        for k, _ in ipairs(mod.db.profile.redo) do
            mod.db.profile.redo[k] = nil
        end
    end

    local entry = { GetTimestamp(), kind, name, reason, amount, UnitName("player")}
    table.insert(mod.db.profile.log, entry)
    exists_logs[string.format(LOG_FORMAT_NEW, unpack(entry))] = true

    if filter ~= "" and CheckFilter(entry, filter) then
        table.insert(filtered, entry)
    end

    mod:SendCommMessage("EPGP", string.format(LOG_FORMAT_NEW, unpack(entry)), "GUILD", nil, "BULK")
    callbacks:Fire("LogChanged", #mod.db.profile.log)
end

function mod:LogSync(prefix, msg, distribution, sender)
    if prefix == "EPGP" and distribution == "GUILD" and sender ~= UnitName("player") and GS:GetRank(sender) then
        local entry = ParseLogMessage(msg)
        if entry then
            entry[6] = entry[6] or sender
            local key = string.format(LOG_FORMAT_NEW, unpack(entry))
            if exists_logs[key] then
                return
            end
            table.insert(mod.db.profile.log, entry)
            if filter ~= "" and CheckFilter(entry, filter) then
                table.insert(filtered, entry)
            end
            exists_logs[key] = true
            callbacks:Fire("LogChanged", #self.db.profile.log)
        end
    end
end

local function WithChange(text, record)
    local amount, after = record[5], record[7]
    if type(amount) == "number" and type(after) == "number" then
        return string.format("%s [%d -> %d]", text, after - amount, after)
    end
    return text
end

local function LogRecordToString(record)
    local timestamp, kind, name, reason, amount, officer = unpack(record)

    if kind == "EP" then
        return WithChange(string.format(L["%s: %+d EP (%s) to %s from %s"],
            date("%Y-%m-%d %H:%M", timestamp), amount, reason, name, officer), record)
    elseif kind == "GP" then
        return WithChange(string.format(L["%s: %+d GP (%s) to %s from %s"],
            date("%Y-%m-%d %H:%M", timestamp), amount, reason, name, officer), record)
    elseif kind == "BI" then
        return string.format(L["%s: %s to %s from %s"],
            date("%Y-%m-%d %H:%M", timestamp), reason, name, officer)
    else
        return string.format("%s: [%s] %s (%s) - %s from %s",
            date("%Y-%m-%d %H:%M", timestamp), kind, name, reason or "", tostring(amount or ""), officer or "Unknown")
    end
end

function mod:SetFilter(search)
    filter = search
    table.wipe(filtered)
    if search ~= "" then
        for _, log in pairs(self.db.profile.log) do
            if CheckFilter(log, search) then
                table.insert(filtered, log)
            end
        end
    end

    callbacks:Fire("LogChanged", self:GetNumRecords())
end

function mod:GetNumRecords()
    if filter == "" then
        return #self.db.profile.log
    end
    return #filtered
end

function mod:GetLogRecord(i)
    local logs = filtered
    if filter == "" then
        logs = self.db.profile.log
    end

    local logsize = #logs
    assert(i >= 0 and i < logsize, "Index " .. i .. " is out of bounds")

    return LogRecordToString(logs[logsize - i])
end

function mod:CanUndo()
    if not CanEditOfficerNote() or not GS:IsCurrentState() then
        return false
    end
    return #self.db.profile.log ~= 0
end

function mod:GetLastActionForUndo()
    local skip_count = 0

    for i = #self.db.profile.log, 1, -1 do
        local log = self.db.profile.log[i]

        local is_undo = starts(log[4], L["Undo"])
        if not is_undo and skip_count == 0 then
            return log
        end

        if is_undo then
            skip_count = skip_count + 1
        else
            skip_count = skip_count - 1
        end
    end

    return nil
end

function mod:UndoLastAction()
    assert(#self.db.profile.log ~= 0)

    local record = mod:GetLastActionForUndo()
    if not record then
        return false
    end
    local log_size = #self.db.profile.log

    local timestamp, kind, name, reason, amount, officer = unpack(record)

    if kind == "EP" then
        EPGP:IncEPBy(name, L["Undo"] .. " " .. reason, -amount, false, true)
    elseif kind == "GP" then
        EPGP:IncGPBy(name, L["Undo"] .. " " .. reason, -amount, false, true)
    elseif kind == "BI" then
        EPGP:BankItem(L["Undo"] .. " " .. reason, true)
    else
        EPGP:Print("Cannot undo unknown record type: " .. tostring(kind))
    end
    if #self.db.profile.log > log_size then
        table.insert(self.db.profile.redo, record)
    end

    callbacks:Fire("LogChanged", #self.db.profile.log)
    return true
end

function mod:CanRedo()
    if not CanEditOfficerNote() or not GS:IsCurrentState() then
        return false
    end

    return #self.db.profile.redo ~= 0
end

function mod:RedoLastUndo()
    assert(#self.db.profile.redo ~= 0)

    local record = table.remove(self.db.profile.redo)
    local timestamp, kind, name, reason, amount, officer = unpack(record)

    if kind == "EP" then
        EPGP:IncEPBy(name, L["Redo"] .. " " .. reason, amount, false, true)
    elseif kind == "GP" then
        EPGP:IncGPBy(name, L["Redo"] .. " " .. reason, amount, false, true)
    else
        EPGP:Print("Cannot redo unknown record type: " .. tostring(kind))
    end

    callbacks:Fire("LogChanged", #self.db.profile.log)
    return true
end

-- This is kept for historical reasons: see
-- https://github.com/sirus-addons/EPGP.
function mod:Snapshot()
    local t = self.db.profile.snapshot
    if not t then
        t = {}
        self.db.profile.snapshot = t
    end
    t.time = GetTimestamp()
    GS:Snapshot(t)
end

local function swap(t, i, j)
    t[i], t[j] = t[j], t[i]
end

local function reverse(t)
    for i = 1, math.floor(#t / 2) do
        swap(t, i, #t - i + 1)
    end
end

local timeReuse = 60 * 60 * 24 * 30
function mod:TrimToOneMonth()
    -- The log is sorted in reverse timestamp. We do not want to remove
    -- one item at a time since this will result in O(n^2) time. So we
    -- build it anew.
    local new_log = {}
    local last_timestamp = GetTimestamp() - timeReuse

    -- Go through the log in reverse order and stop when we reach an
    -- entry older than one month.
    for i = #self.db.profile.log, 1, -1 do
        local record = self.db.profile.log[i]
        if record[1] < last_timestamp then
            break
        end
        table.insert(new_log, record)
    end

    -- The new log is in reverse order now so reverse it.
    reverse(new_log)

    self.db.profile.log = new_log

    table.wipe(exists_logs)
    for _, record in ipairs(new_log) do
        if record[1] >= exists_floor then
            exists_logs[string.format(LOG_FORMAT_NEW, unpack(record))] = true
        end
    end

    self:SetFilter(filter)
end

function mod:Export()
    local d = {}
    d.region = GetCVar("portal")
    d.guild = select(1, GetGuildInfo("player"))
    d.realm = GetRealmName()
    d.base_gp = EPGP:GetBaseGP()
    d.min_ep = EPGP:GetMinEP()
    d.decay_p = EPGP:GetDecayPercent()
    d.extras_p = EPGP:GetExtrasPercent()
    d.timestamp = GetTimestamp()

    d.roster = EPGP:ExportRoster()

    d.loot = {}
    for i, record in ipairs(self.db.profile.log) do
        local timestamp, kind, name, reason, amount, officer = unpack(record)
        if kind == "GP" or kind == "BI" then
            local id = tonumber(reason:match("item:(%d+)"))
            if id then
                table.insert(d.loot, { timestamp, name, id, amount })
            end
        end
    end

    return JSON.Serialize(d):gsub("\124", "\124\124")
end

function mod:Import(jsonStr)
    local success, d = pcall(JSON.Deserialize, jsonStr)
    if not success then
        EPGP:Print(L["The imported data is invalid"])
        return
    end

    if d.region and d.region ~= GetCVar("portal") then
        EPGP:Print(L["The imported data is invalid"])
        return
    end

    if d.guild ~= select(1, GetGuildInfo("player")) or
        d.realm ~= GetRealmName() then
        EPGP:Print(L["The imported data is invalid"])
        return
    end

    local types = {
        timestamp = "number",
        roster = "table",
        decay_p = "number",
        extras_p = "number",
        min_ep = "number",
        base_gp = "number",
    }
    for k, t in pairs(types) do
        if type(d[k]) ~= t then
            EPGP:Print(L["The imported data is invalid"])
            return
        end
    end

    for _, entry in pairs(d.roster) do
        if type(entry) ~= "table" then
            EPGP:Print(L["The imported data is invalid"])
            return
        else
            local types = {
                [1] = "string",
                [2] = "number",
                [3] = "number",
            }
            for k, t in pairs(types) do
                if type(entry[k]) ~= t then
                    EPGP:Print(L["The imported data is invalid"])
                    return
                end
            end
        end
    end

    EPGP:Print(L["Importing data snapshot taken at: %s"]:format(
        date("%Y-%m-%d %H:%M", d.timestamp)))
    EPGP:SetGlobalConfiguration(d.decay_p, d.extras_p, d.base_gp, d.min_ep)
    EPGP:ImportRoster(d.roster, d.base_gp)

    -- Trim the log if necessary.
    local timestamp = d.timestamp
    while true do
        local records = #self.db.profile.log
        if records == 0 then
            break
        end

        if self.db.profile.log[records][1] > timestamp then
            table.remove(self.db.profile.log)
        else
            break
        end
    end
    -- Add the redos back to the log if necessary.
    while #self.db.profile.redo ~= 0 do
        local record = table.remove(self.db.profile.redo)
        if record[1] < timestamp then
            table.insert(self.db.profile.log, record)
            exists_logs[string.format(LOG_FORMAT_NEW, unpack(record))] = true
        end
    end

    self:SetFilter(filter)
end

mod.dbDefaults = {
    profile = {
        enabled = true,
        log = {},
        redo = {},
    }
}

local sync_logs = {}
local sync_players_in_progress = {}
local sync_dirty = false
local sync_sort_timer
local self_player_name = UnitName("player")

local function SortSyncedLog()
    sync_sort_timer = nil
    local cur_time = GetTime()
    for _, time in pairs(sync_players_in_progress) do
        local wait = 10 - (cur_time - time)
        if wait > 0 then
            sync_sort_timer = mod:ScheduleTimer(SortSyncedLog, wait)
            return
        end
    end

    if sync_dirty then
        sync_dirty = false
        SortLogIfNeeded(mod.db.profile.log)
    end
end

local sync_sending = {}
local player_not_found = "^" .. ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.+)") .. "$"
local SendNextSyncLog

local function OnSyncLogSent(state, sent, total)
    if sent >= total then
        C_Timer:After(0, function() SendNextSyncLog(state) end)
    end
end

function SendNextSyncLog(state)
    if state.stopped or sync_sending[state.target] ~= state then
        return
    end

    state.index = state.index + 1
    state.last_sent = GetTime()
    local entry = state.logs[state.index]
    if entry then
        mod:SendCommMessage("EPGP_SYNC_LOG", string.format(LOG_FORMAT_NEW, unpack(entry)), "WHISPER", state.target, "BULK", OnSyncLogSent, state)
    else
        mod:SendCommMessage("EPGP_SYNC_LOG", "END:" .. tostring(#state.logs), "WHISPER", state.target, "BULK")
        state.logs = nil
        state.stopped = true
    end
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
    local name = msg and msg:match(player_not_found)
    local state = name and sync_sending[name]
    if not state then
        return
    end

    state.stopped = true
    return GetTime() - state.last_sent < 10
end)

function mod:EPGP_SYNC_REQUEST(tag, msg, channel, sender)
    if channel ~= "GUILD" then
        return
    end

    if sender == self_player_name then
        return
    end

    local from_timestamp = tonumber(msg)
    if not from_timestamp then
        return
    end
    from_timestamp = math.max(from_timestamp, time() - timeReuse)

    local logs_for_sync = {}
    for _, log in ipairs(self.db.profile.log) do
        if log[1] > from_timestamp then
            logs_for_sync[#logs_for_sync + 1] = log
        end
    end

    local state = { target = sender, logs = logs_for_sync, index = 0 }
    sync_sending[sender] = state
    SendNextSyncLog(state)
end

function mod:EPGP_SYNC_LOG(tag, msg, channel, sender)
    if channel ~= "WHISPER" then
        return
    end

    if sender == self_player_name then
        return
    end

    if not GS:GetRank(sender) then
        return
    end

    if starts(msg, "END") then
        return self:EPGP_SYNC_RESPONSE(tag, msg, channel, sender)
    end

    local entry = ParseLogMessage(msg)
    if not entry then
        return
    end
    entry[6] = entry[6] or "Unknown"

    if entry[1] < exists_floor then
        return
    end

    local key = string.format(LOG_FORMAT_NEW, unpack(entry))
    if exists_logs[key] then
        return
    end

    local members_with_logs = sync_logs[key] or {}
    local member_exists = false
    for _, member in pairs(members_with_logs) do
        if member == sender then
            member_exists = true
        end
    end
    if not member_exists then
        table.insert(members_with_logs, sender)
    end
    sync_logs[key] = members_with_logs

    if #members_with_logs == 2 then
        table.insert(mod.db.profile.log, entry)
        exists_logs[key] = true
        sync_logs[key] = nil
        sync_dirty = true

        if filter ~= "" and CheckFilter(entry, filter) then
            table.insert(filtered, entry)
        end
        callbacks:Fire("LogChanged", #self.db.profile.log)
    end

    if #members_with_logs >= 2 then
        return
    end

    sync_players_in_progress[sender] = GetTime()
end

function mod:EPGP_SYNC_RESPONSE(tag, msg, channel, sender)
    if channel ~= "WHISPER" then
        return
    end

    if sender == self_player_name then
        return
    end

    if not GS:GetRank(sender) then
        return
    end

    sync_players_in_progress[sender] = nil
    if sync_sort_timer then
        self:CancelTimer(sync_sort_timer, true)
    end
    SortSyncedLog()
end
local calcLatestTime = 60 * 60 * 24 * 7
function mod:OnEnable()
    EPGP.RegisterCallback(mod, "EPAward", AppendToLog, "EP")
    EPGP.RegisterCallback(mod, "GPAward", AppendToLog, "GP")
    EPGP.RegisterCallback(mod, "BankedItem", AppendToLog, "BI")
    mod:RegisterComm("EPGP", "LogSync")
    mod:RegisterComm("EPGP_SYNC_REQUEST", "EPGP_SYNC_REQUEST")
    mod:RegisterComm("EPGP_SYNC_LOG", "EPGP_SYNC_LOG")

    -- Upgrade the logs from older dbs
    if EPGP.db.profile.log then
        self.db.profile.log = EPGP.db.profile.log
        EPGP.db.profile.log = nil
    end
    if EPGP.db.profile.redo then
        self.db.profile.redo = EPGP.db.profile.redo
        EPGP.db.profile.redo = nil
    end

    self.db.profile.filter = nil
    self.db.profile.filtred_logs = nil

    local logs = self.db.profile.log
    SortLogIfNeeded(logs)

    local latest_time = GetTimestamp() - calcLatestTime
    if logs and #logs > 0 then
        local latest_log = logs[#logs]
        latest_time = latest_log[1]
    end
    exists_floor = latest_time - calcLatestTime
    mod:SendCommMessage("EPGP_SYNC_REQUEST", tostring(latest_time), "GUILD", nil, "BULK")

    for _, log in pairs(logs) do
        NormalizeRecord(log)
        log[6] = log[6] or "Unknown"
        if log[1] >= exists_floor then
            exists_logs[string.format(LOG_FORMAT_NEW, unpack(log))] = true
        end
    end

    -- This is kept for historical reasons. See:
    -- https://github.com/sirus-addons/EPGP.
    EPGP.db.RegisterCallback(self, "OnDatabaseShutdown", "Snapshot")
end

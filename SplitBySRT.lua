-- REAPER Lua Script: Split audio items by .srt subtitle file (enhanced version)
-- Features:
-- - Parses .srt subtitles and splits or copies audio items accordingly
-- - Supports speaker separation (e.g., （A）Hello!)
-- - Handles overlapping lines
-- - Uses external config.ini for newline replacement
-- - Default path for file dialog is project path
-- - Speaker tracks are ordered by first appearance

local reaper = reaper

-------------------------
-- Config Loader
-------------------------
local function load_config()
    local config = { newline_replace = " ", padding_start = 0.0, padding_end = 0.0 } -- defaults
    local script_path = debug.getinfo(1, 'S').source:match("^@(.+)[/\\]")
    local config_path = script_path .. "/config.ini"
    local f = io.open(config_path, "r")
    if f then
        for line in f:lines() do
            local key, val = line:match("^(%w+)%s*=%s*(.+)$")
            if key and val then
                if key == "newline_replace" then config.newline_replace = val end
                if key == "padding_start" then config.padding_start = tonumber(val) or 0 end
                if key == "padding_end" then config.padding_end = tonumber(val) or 0 end
            end
        end
        f:close()
    end
    return config
end

-------------------------
-- User-facing messages (for future localization)
-------------------------
local msg = {
    no_item = "アイテムが選択されていません",
    track_err = "トラック取得に失敗しました",
    multi_track = "複数のトラックにまたがるアイテムが選択されています",
    srt_prompt = "SRTファイルを選択",
    srt_err = "字幕ファイルの読み込みに失敗: ",
    no_match = function(idx)
        return os.date("%X") .. " 字幕 " .. idx .. " の位置にアイテムが見つかりません"
    end
}

-------------------------
-- SRT Parser
-------------------------
local function parse_srt(file_path)
    local entries = {}
    local f = io.open(file_path, "r") -- use text mode instead of binary
    if not f then return nil, "Failed to open file" end

    local content = f:read("*all")
    f:close()

    -- Remove UTF-8 BOM
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end

    local lines = {}
    for line in content:gmatch("([^\r\n]*)\r?\n") do
        line = line:gsub("\r", "")
        table.insert(lines, line)
    end

    local index, start, endt, text = nil, nil, nil, ""
    for _, line in ipairs(lines) do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line:match("^%d+$") then
            if index then
                table.insert(entries, { index = index, start_time = start, end_time = endt, text = text })
            end
            index = tonumber(line)
            start, endt, text = nil, nil, ""
        elseif line:match("%d%d:%d%d:%d%d,%d%d%d%s+%-%-%>%s+%d%d:%d%d:%d%d,%d%d%d") then
            local h1,m1,s1,ms1,h2,m2,s2,ms2 = line:match(
                "(%d+):(%d+):(%d+),(%d+)%s+%-%-%>%s+(%d+):(%d+):(%d+),(%d+)"
            )
            start = tonumber(h1)*3600 + tonumber(m1)*60 + tonumber(s1) + tonumber(ms1)/1000
            endt  = tonumber(h2)*3600 + tonumber(m2)*60 + tonumber(s2) + tonumber(ms2)/1000
        elseif line == "" then
            -- skip
        else
            text = text .. (text ~= "" and "\n" or "") .. line
        end
    end
    if index then
        table.insert(entries, { index = index, start_time = start, end_time = endt, text = text })
    end
    return entries
end

-------------------------
-- Utility: Clean Text (minimally remove invisible characters)
-------------------------
local function clean_text(text)
    local invisible_bytes = {
        "\226\128\139", -- ZWSP
        "\226\128\140", -- ZWNJ
        "\226\128\141", -- ZWJ
        "\226\128\142", -- LRM
        "\226\128\170", -- LRE
        "\226\128\172", -- PDF
        "\239\187\191", -- BOM
        "&lrm;"           -- encoded LRM string
    }
    for _, seq in ipairs(invisible_bytes) do
        text = text:gsub(seq, "")
    end
    return text
end

-------------------------
-- Detect and strip speaker name from text (UTF-8 aware)
-------------------------
local function strip_speaker_utf8(text)
    if type(text) ~= "string" then
        return nil, ""
    end
    if not utf8.len(text) then
        return nil, text
    end

    local brackets = {
        ["（"] = "）",
        ["["]  = "]",
    }

    local chars = {}
    for _, cp in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(cp)
    end

    -- Skip leading whitespace (ASCII/Unicode spaces that match %s)
    local i = 1
    while chars[i] and chars[i]:match("^%s$") do
        i = i + 1
    end

    local open = chars[i]
    local close = brackets[open]
    if not close then
        return nil, text
    end

    -- Find closing bracket
    local j = i + 1
    while chars[j] and chars[j] ~= close do
        j = j + 1
    end
    if not chars[j] then
        return nil, text
    end

    local speaker = table.concat(chars, "", i + 1, j - 1)
    local content = table.concat(chars, "", j + 1)

    content = content:gsub("^%s*", "")

    if content == "" then
        return nil, text
    end

    if speaker == "" then
        return nil, content
    end

    return speaker, content
end


-------------------------
-- Copy and trim item for a subtitle entry
-------------------------
local function copy_and_trim(item, s_time, e_time, target_track)
    if not item or not target_track then return nil, nil end
    local orig_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local offset = s_time - orig_pos
    local length = e_time - s_time
    local new_item = reaper.AddMediaItemToTrack(target_track)
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", s_time)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)
    local take = reaper.GetActiveTake(item)
    if not take then return nil, nil end
    local src = reaper.GetMediaItemTake_Source(take)
    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetMediaItemTake_Source(new_take, src)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", offset)
    reaper.SetActiveTake(new_take)
    return new_item, new_take
end


-------------------------
-- Main Script
-------------------------
local function main()
    reaper.Undo_BeginBlock()

    local config = load_config()
    local newline_replace = config.newline_replace or " "
    local padding_start = config.padding_start or 0.0
    local padding_end = config.padding_end or 0.0

    local selected_count = reaper.CountSelectedMediaItems(0)
    if selected_count == 0 then reaper.MB(msg.no_item, "Error", 0) return end

    local item_list = {}
    for i = 0, selected_count - 1 do
        table.insert(item_list, reaper.GetSelectedMediaItem(0, i))
    end

    local track = reaper.GetMediaItem_Track(item_list[1])
    if not track then reaper.MB(msg.track_err, "Error", 0) return end

    for _, item in ipairs(item_list) do
        if reaper.GetMediaItem_Track(item) ~= track then
            reaper.MB(msg.multi_track, "Error", 0)
            return
        end
    end

    local proj_path = reaper.GetProjectPath("").."\\"
    local retval, srt_path = reaper.GetUserFileNameForRead(proj_path, msg.srt_prompt, ".srt")
    if not retval then return end

    local subtitles, err = parse_srt(srt_path)
    if not subtitles then
        reaper.MB(msg.srt_err .. err, "Error", 0)
        return
    end

    local speaker_tracks = {}
    local speaker_order = {}
    local base_track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    local insert_idx = base_track_idx
    local base_vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")

    local function get_or_create_speaker_track(speaker)
        if not speaker_tracks[speaker] then
            reaper.InsertTrackAtIndex(insert_idx, true)
            reaper.TrackList_AdjustWindows(false)
            local new_track = reaper.GetTrack(0, insert_idx)
            reaper.SetMediaTrackInfo_Value(new_track, "D_VOL", base_vol)
            reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", clean_text(speaker or ""), true)
            speaker_tracks[speaker] = new_track
            insert_idx = insert_idx + 1
            table.insert(speaker_order, speaker)
        end
        return speaker_tracks[speaker]
    end

    reaper.InsertTrackAtIndex(insert_idx, true)
    reaper.TrackList_AdjustWindows(false)
    local default_track = reaper.GetTrack(0, insert_idx)
    reaper.SetMediaTrackInfo_Value(default_track, "D_VOL", base_vol)
    insert_idx = insert_idx + 1

    for _, entry in ipairs(subtitles) do
        local start_time = math.max(0, entry.start_time - padding_start)
        local end_time = entry.end_time + padding_end
        local raw_text = clean_text(entry.text)
        local content = raw_text:gsub("\r?\n", newline_replace)
        local speaker, content = strip_speaker_utf8(content)
        local dest_track = speaker and get_or_create_speaker_track(speaker) or default_track

        local matched = false
        for _, item in ipairs(item_list) do
            local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            if start_time >= item_start and end_time <= item_end then
                local new_item, new_take = copy_and_trim(item, start_time, end_time, dest_track)
                if new_take then
                    reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", content, true)
                    matched = true
                end
                break
            end
        end
        if not matched then
            reaper.MB(msg.no_match(entry.index), "Error", 0)
            return
        end

        -- break;
    end

    reaper.Undo_EndBlock("SRT分割", -1)
end

main()

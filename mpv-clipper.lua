-- mpv-clipper.lua
-- Video trimming script for mpv
-- Usage:
--   c: Set start time
--   v: Set end time
--   b: Make clip from start to end time
--   q: Cycle quality presets
--   i: Show clip info/status

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

-- Defaults
local config = {
    output_dir      = "",
    video_codec     = "copy",     -- default lossless
    audio_codec     = "copy",     -- default lossless
    container       = "auto",
    audio_bitrate   = "",
    clip_suffix     = "-clip",
    osd_duration    = 1500,
    show_logs       = false,
    quality         = "copy",     -- default mode
    crf             = "",
    preset          = "",
    scale           = ""          -- e.g. "1280:-1"
}

-- Quality presets
local quality_presets = {
    copy   = { video_codec="copy", audio_codec="copy" },
    high   = { video_codec="libx264", crf="18", preset="slower", audio_codec="aac", audio_bitrate="192k" },
    medium = { video_codec="libx264", crf="20", preset="medium", audio_codec="aac", audio_bitrate="128k" },
    fast   = { video_codec="libx264", crf="23", preset="fast", audio_codec="aac", audio_bitrate="96k" },
    tiny   = { video_codec="libx264", crf="28", preset="ultrafast", audio_codec="aac", audio_bitrate="64k" },
    custom = {} -- will be filled by config overrides
}

-- Load config file
local function load_config()
    local conf_path = mp.find_config_file("scripts/mpv-clipper.conf") or mp.find_config_file("mpv-clipper.conf")
    if not conf_path then return end
    for line in io.lines(conf_path) do
        local key, val = line:match('^%s*([^#][^=]*)%s*=%s*"(.-)"%s*$')
        if key and val ~= "" then
            if tonumber(val) then val = tonumber(val)
            elseif val == "true" then val = true
            elseif val == "false" then val = false end
            config[key] = val
        end
    end
end
load_config()

-- Merge preset with config overrides
local function get_active_preset()
    local preset = quality_presets[config.quality] or {}
    local merged = {}
    for k,v in pairs(preset) do merged[k] = v end
    for k,v in pairs(config) do if merged[k] == nil or config.quality == "custom" then merged[k] = v end end

    -- Auto-lossless if both codecs = copy
    if merged.video_codec == "copy" and merged.audio_codec == "copy" then
        merged.crf, merged.preset, merged.audio_bitrate = "", "", ""
    end
    return merged
end

-- Clip function
local clip_start, clip_end
local function make_clip()
    if not clip_start or not clip_end then
        mp.osd_message("Set start and end points first", config.osd_duration)
        return
    end
    local file = mp.get_property("path")
    if not file then return end
    local start_time = math.min(clip_start, clip_end)
    local end_time   = math.max(clip_start, clip_end)
    local duration   = end_time - start_time
    local dir, name = utils.split_path(file)
    local out_dir = (config.output_dir ~= "" and config.output_dir) or dir
    local ext = (config.container == "auto") and file:match("^.+(%..+)$") or ("."..config.container)
    -- Timestamp
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local out_path = utils.join_path(out_dir, name:gsub("%..+$", "") .. config.clip_suffix .. "-" .. timestamp .. ext)

    local p = get_active_preset()

    local args = { "ffmpeg", "-y", "-i", file, "-ss", tostring(start_time), "-t", tostring(duration) }

    -- Explicit stream mapping
    table.insert(args, "-map")
    table.insert(args, "0:v:0")

    -- Current selected tracks in mpv
    local audio_id = mp.get_property_number("current-tracks/audio/id")
    if audio_id then
        table.insert(args, "-map")
        table.insert(args, "0:a:" .. (audio_id - 1))
    end

    local sub_id = mp.get_property_number("current-tracks/sub/id")
    if sub_id and config.container=="mkv" then
        table.insert(args, "-map")
        table.insert(args, "0:s:" .. (sub_id - 1))
    end

    -- Video codec
    if p.video_codec == "copy" then
        table.insert(args, "-c:v"); table.insert(args, "copy")
    else
        table.insert(args, "-c:v"); table.insert(args, p.video_codec)
        if config.quality == "custom" then
            table.insert(args, "-profile:v")
            table.insert(args, "baseline")

            table.insert(args, "-level")
            table.insert(args, "3.0")

            table.insert(args, "-pix_fmt")
            table.insert(args, "yuv420p")

            table.insert(args, "-ac")
            table.insert(args, "2")
        end

        if p.crf ~= "" then table.insert(args, "-crf"); table.insert(args, tostring(p.crf)) end
        if p.preset ~= "" then table.insert(args, "-preset"); table.insert(args, tostring(p.preset)) end
    end

    if p.audio_codec == "copy" then
        table.insert(args, "-c:a"); table.insert(args, "copy")
    else
        table.insert(args, "-c:a"); table.insert(args, p.audio_codec)
        if p.audio_bitrate and p.audio_bitrate ~= "" then
            table.insert(args, "-b:a"); table.insert(args, tostring(p.audio_bitrate))
        end
    end

    -- Subtitle handling
    if sub_id and config.container=="mkv" then
        table.insert(args, "-c:s")
        table.insert(args, "copy")
    end

    -- Scaling
    if p.scale and p.scale ~= "" then
        table.insert(args, "-vf"); table.insert(args, "scale="..p.scale)
    end

    table.insert(args, out_path)

    if config.show_logs then msg.info("Running:", table.concat(args, " ")) end
    msg.info("OUT:", out_path)
    msg.info("ARGS:", utils.to_string(args))
    msg.info("COMMAND: " .. table.concat(args, " "))
    mp.command_native_async(
    {
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true
    },
    function(success, result, err)
        msg.info("FFmpeg finished")

        if result then
            msg.info("STATUS: " .. tostring(result.status))
            msg.info("STDOUT: " .. tostring(result.stdout))
            msg.info("STDERR: " .. tostring(result.stderr))
        end

        if err then
            msg.error("ERROR: " .. tostring(err))
        end
    end)
    mp.osd_message("Clip saved: " .. out_path, config.osd_duration)
end

-- Key bindings
mp.add_key_binding("c", "set-start", function() clip_start = mp.get_property_number("time-pos"); mp.osd_message("Clip start: "..clip_start) end)
mp.add_key_binding("v", "set-end",   function() clip_end = mp.get_property_number("time-pos");   mp.osd_message("Clip end: "..clip_end) end)
mp.add_key_binding("b", "make-clip", make_clip)

-- Cycle quality presets
local preset_order = { "copy", "high", "medium", "fast", "tiny", "custom" }
mp.add_key_binding("q", "cycle-quality", function()
    local idx
    for i,v in ipairs(preset_order) do if v == config.quality then idx = i break end end
    config.quality = preset_order[(idx % #preset_order) + 1]
    mp.osd_message("Quality: " .. config.quality, config.osd_duration)
end)

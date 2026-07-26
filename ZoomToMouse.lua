--
-- Zoom to Mouse Pro
-- A standalone OBS Lua script that smoothly zooms a display-capture source to follow the mouse.
-- Originally based on "OBS Zoom to Mouse" by BlankSourceCode / ported by Timexo,
-- now maintained as its own independent project with its own feature set.
--

local obs = obslua
local ffi = require("ffi")
local VERSION = "1.2.0"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"
local SCALE_FILTER_NAME = "obs-zoom-to-mouse-rescale"

local socket_available, socket = pcall(require, "ljsocket")
local socket_server = nil
local socket_mouse = nil

local source_name = ""
local source = nil
local sceneitem = nil
local sceneitem_info_orig = nil
local sceneitem_crop_orig = nil
local sceneitem_info = nil
local sceneitem_crop = nil
local crop_filter = nil
local crop_filter_temp = nil
local crop_filter_settings = nil
local scale_filter = nil
local scale_filter_settings = nil
local crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
local crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
local monitor_info = nil
local zoom_info = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local zoom_time = 0
local zoom_target = nil
local locked_center = nil
local locked_last_pos = nil
local hotkey_zoom_id = nil
local hotkey_cycle_zoom_id = nil
local hotkey_freeze_id = nil
local hotkey_zoom_level_1_id = nil
local hotkey_zoom_level_2_id = nil
local hotkey_zoom_level_3_id = nil
local is_timer_running = false
local is_manually_frozen = false

-- v1.2.0: dedicated zoom-level hotkeys (1/2/3) + a stepped cycle hotkey
local zoom_level_1 = 1.5
local zoom_level_2 = 2
local zoom_level_3 = 3
local direct_zoom_active_level = nil -- which level (if any) is currently active via a direct/cycle hotkey press
local cycle_step = 0 -- 0 = not using the cycle hotkey right now, 1/2/3 = currently at level 1/2/3 via the cycle hotkey

-- v1.2.0: per-scene zoom level memory
local use_per_scene_zoom_memory = false
local scene_zoom_memory = {}
local current_scene_name = nil

-- v1.2.0: opt-in self-healing across every scene (not just the current one)
local fix_all_scenes = false

-- v1.2.0: preset system (holds the live settings reference so button callbacks can read/write it)
local current_settings = nil

local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.1
local follow_border = 0
local follow_safezone_sensitivity = 10
local use_follow_auto_lock = false
local zoom_value = 2
local zoom_speed = 0.1
local allow_all_sources = false
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local monitor_override_sx = 0
local monitor_override_sy = 0
local monitor_override_dw = 0
local monitor_override_dh = 0
local use_socket = false
local socket_port = 0
local socket_poll = 1000
local debug_logs = false
local is_obs_loaded = false
local is_script_loaded = false

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

local version = obs.obs_get_version_string()
local m1, m2 = version:match("(%d+%.%d+)%.(%d+)")
local major = tonumber(m1) or 0
local minor = tonumber(m2) or 0

-- Helper für verschiedene OBS Versionen
local function get_transform(item, info)
    if obs.obs_sceneitem_get_transform_info then
        obs.obs_sceneitem_get_transform_info(item, info)
    elseif obs.obs_sceneitem_get_info then
        obs.obs_sceneitem_get_info(item, info)
    end
end

local function set_transform(item, info)
    if obs.obs_sceneitem_set_transform_info then
        obs.obs_sceneitem_set_transform_info(item, info)
    elseif obs.obs_sceneitem_set_info then
        obs.obs_sceneitem_set_info(item, info)
    end
end

-- Define the mouse cursor functions for each platform
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
    ]])
    win_point = ffi.new("POINT[1]")
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    x11_lib = ffi.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = ffi.new("Window[1]"),
            child_win = ffi.new("Window[1]"),
            root_x = ffi.new("int[1]"),
            root_y = ffi.new("int[1]"),
            win_x = ffi.new("int[1]"),
            win_y = ffi.new("int[1]"),
            mask = ffi.new("unsigned int[1]")
        }
    end
elseif ffi.os == "OSX" then
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;

        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
        int access(const char *path, int amode);
    ]])

    osx_lib = ffi.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if socket_mouse ~= nil then
        mouse.x = socket_mouse.x
        mouse.y = socket_mouse.y
    else
        if ffi.os == "Windows" then
            if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
                mouse.x = win_point[0].x
                mouse.y = win_point[0].y
            end
        elseif ffi.os == "Linux" then
            if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
                if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                    mouse.x = tonumber(x11_mouse.win_x[0])
                    mouse.y = tonumber(x11_mouse.win_y[0])
                end
            end
        elseif ffi.os == "OSX" then
            if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
                local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
                mouse.x = point.x
                if monitor_info ~= nil then
                    if monitor_info.display_height > 0 then
                        mouse.y = monitor_info.display_height - point.y
                    else
                        mouse.y = monitor_info.height - point.y
                    end
                end
            end
        end
    end

    return mouse
end

---
-- Get the information about display capture sources for the current platform
---@return any
function get_dc_info()
    if ffi.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif ffi.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif ffi.os == "OSX" then
        if major > 29.0 then
            return {
                source_id = "screen_capture",
                prop_id = "display_uuid",
                prop_type = "string"
            }
        else
            return {
                source_id = "display_capture",
                prop_id = "display",
                prop_type = "int"
            }
        end
    end

    return nil
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

---
-- Format the given lua table into a string
---@param tbl any
---@param indent any
---@return string result The formatted string
function format_table(tbl, indent)
    if not indent then
        indent = 0
    end

    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key + " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"

    return str
end

---
-- Linear interpolate between v0 and v1
---@param v0 number The start position
---@param v1 number The end position
---@param t number Time
---@return number value The interpolated value
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t;
end

---
-- Ease a time value in and out (cubic)
---@param t number Time between 0 and 1
---@return number
function ease_in_out(t)
    t = t * 2
    if t < 1 then
        return 0.5 * t * t * t
    else
        t = t - 2
        return 0.5 * (t * t * t + 2)
    end
end

---
-- Clamps a given value between min and max
---@param min number The min value
---@param max number The max value
---@param value number The number to clamp
---@return number result the clamped number
function clamp(min, max, value)
    return math.max(min, math.min(max, value))
end

---
-- Gets the name of the currently active OBS program scene (or nil)
---@return string|nil
function get_current_scene_name()
    local scene_source = obs.obs_frontend_get_current_scene()
    local name = nil
    if scene_source ~= nil then
        name = obs.obs_source_get_name(scene_source)
        obs.obs_source_release(scene_source)
    end
    return name
end

---
-- Serializes the per-scene zoom memory table into a single string for storage in script settings
---@return string
function serialize_scene_zoom_memory()
    local parts = {}
    for scene_name, level in pairs(scene_zoom_memory) do
        table.insert(parts, scene_name .. "\29" .. tostring(level))
    end
    return table.concat(parts, "\30")
end

---
-- Restores the per-scene zoom memory table from a string previously produced by serialize_scene_zoom_memory
---@param str string
function deserialize_scene_zoom_memory(str)
    scene_zoom_memory = {}
    if str == nil or str == "" then
        return
    end

    for entry in string.gmatch(str, "([^\30]+)") do
        local scene_name, level = entry:match("(.+)\29(.+)")
        if scene_name ~= nil and level ~= nil then
            scene_zoom_memory[scene_name] = tonumber(level)
        end
    end
end

---
-- Called whenever the active OBS scene changes. If per-scene zoom memory is enabled, this
-- remembers the zoom level that was in use for the scene we're leaving, and restores whatever
-- zoom level (if any) was previously used the last time we were on the new scene.
function handle_scene_changed_for_zoom_memory()
    if not use_per_scene_zoom_memory then
        return
    end

    if current_scene_name ~= nil then
        scene_zoom_memory[current_scene_name] = zoom_value
    end

    local new_scene_name = get_current_scene_name()
    if new_scene_name ~= nil and scene_zoom_memory[new_scene_name] ~= nil then
        zoom_value = scene_zoom_memory[new_scene_name]
        zoom_info.zoom_to = zoom_value
        log("Restored remembered zoom level for scene '" .. new_scene_name .. "': " .. zoom_value .. "x")
    end

    current_scene_name = new_scene_name
end

---
-- Makes sure the animation timer is running (shared by every way of starting/retargeting a zoom)
function ensure_zoom_timer_running()
    if is_timer_running == false then
        is_timer_running = true
        local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
        obs.timer_add(on_timer, timer_interval)
    end
end

---
-- Starts a fresh zoom-in from the normal (un-zoomed) state, targeting the given zoom level
---@param level number
function start_zoom_in_at_level(level)
    force_canvas_fit()
    log("Zooming in at " .. level .. "x")
    zoom_state = ZoomState.ZoomingIn
    zoom_info.zoom_to = level
    zoom_time = 0
    locked_center = nil
    locked_last_pos = nil
    zoom_target = get_target_position(zoom_info)
    ensure_zoom_timer_running()
end

---
-- Smoothly re-targets an already-active zoom to a new zoom level, without zooming back out first
---@param level number
function retarget_zoom_level(level)
    log("Re-targeting zoom to " .. level .. "x")
    zoom_info.zoom_to = level
    zoom_time = 0
    zoom_state = ZoomState.ZoomingIn
    zoom_target = get_target_position(zoom_info)
    ensure_zoom_timer_running()
end

---
-- Starts zooming back out to the normal (un-zoomed) view
function start_zoom_out()
    log("Zooming out")
    zoom_state = ZoomState.ZoomingOut
    zoom_time = 0
    locked_center = nil
    locked_last_pos = nil
    zoom_target = { crop = crop_filter_info_orig, c = sceneitem_crop_orig }
    if is_following_mouse then
        is_following_mouse = false
        log("Tracking mouse is off (due to zoom out)")
    end
    ensure_zoom_timer_running()
end

---
-- Shared handler for the three dedicated "Zoom to Nx" hotkeys. Pressing the hotkey for the
-- level that's already active zooms back out; pressing it while zoomed to a different level
-- smoothly re-targets to the new level; pressing it while not zoomed starts a fresh zoom-in.
---@param level number
function handle_direct_zoom_level_press(level)
    if zoom_state == ZoomState.None then
        cycle_step = 0
        direct_zoom_active_level = level
        start_zoom_in_at_level(level)
    elseif zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.ZoomingIn then
        if direct_zoom_active_level ~= nil and math.abs(direct_zoom_active_level - level) < 0.0001 then
            direct_zoom_active_level = nil
            cycle_step = 0
            start_zoom_out()
        else
            direct_zoom_active_level = level
            cycle_step = 0
            retarget_zoom_level(level)
        end
    end
end

function on_toggle_zoom_level_1(pressed)
    if pressed then
        handle_direct_zoom_level_press(zoom_level_1)
    end
end

function on_toggle_zoom_level_2(pressed)
    if pressed then
        handle_direct_zoom_level_press(zoom_level_2)
    end
end

function on_toggle_zoom_level_3(pressed)
    if pressed then
        handle_direct_zoom_level_press(zoom_level_3)
    end
end

---
-- Steps through Zoom Level 1 -> Level 2 -> Level 3 -> zoomed out, one step per press.
-- Pressing it while already zoomed in via a direct level hotkey restarts the cycle at Level 1.
function on_cycle_zoom_level(pressed)
    if not pressed then
        return
    end

    if zoom_state == ZoomState.None then
        cycle_step = 1
        direct_zoom_active_level = zoom_level_1
        start_zoom_in_at_level(zoom_level_1)
        return
    end

    if zoom_state ~= ZoomState.ZoomedIn and zoom_state ~= ZoomState.ZoomingIn then
        return
    end

    if cycle_step >= 3 then
        cycle_step = 0
        direct_zoom_active_level = nil
        start_zoom_out()
        return
    end

    if cycle_step == 0 then
        -- Currently zoomed in via something other than the cycle hotkey - restart the cycle
        cycle_step = 1
        direct_zoom_active_level = zoom_level_1
        retarget_zoom_level(zoom_level_1)
        return
    end

    cycle_step = cycle_step + 1
    local level = zoom_level_1
    if cycle_step == 2 then
        level = zoom_level_2
    elseif cycle_step == 3 then
        level = zoom_level_3
    end

    direct_zoom_active_level = level
    retarget_zoom_level(level)
end

---
-- Toggles a manual "freeze" of the mouse tracking while zoomed in - the view stops following
-- the mouse until unfrozen again, without zooming back out. Distinct from the auto-lock/safezone
-- tracking feature, which resumes automatically; this only resumes when the hotkey is pressed again.
function on_toggle_freeze(pressed)
    if not pressed then
        return
    end

    if zoom_state ~= ZoomState.ZoomedIn and zoom_state ~= ZoomState.ZoomingIn then
        log("Freeze hotkey ignored - not currently zoomed in.")
        return
    end

    is_manually_frozen = not is_manually_frozen
    log("Zoom view is now " .. (is_manually_frozen and "FROZEN (mouse tracking paused)" or "unfrozen (mouse tracking resumed)"))
end

---
-- Applies the "fill the canvas with Scale to Outer Bounds / Top Left" fix to EVERY scene that
-- contains the configured zoom source, not just the current one. Opt-in (Fix All Scenes setting)
-- since forcing this everywhere isn't correct if a scene intentionally uses the source as a small
-- picture-in-picture layout - only enable this if you want the source to always fill the canvas
-- in every scene it appears in.
function force_canvas_fit_all_scenes()
    if use_monitor_override or source_name == nil or source_name == "" then
        return
    end

    local ovi = obs.obs_video_info()
    obs.obs_get_video_info(ovi)
    local canvas_w = ovi.base_width
    local canvas_h = ovi.base_height
    if canvas_w <= 0 or canvas_h <= 0 then
        return
    end

    local scenes = obs.obs_frontend_get_scenes()
    if scenes == nil then
        return
    end

    local fixed_count = 0
    for _, scene_source in ipairs(scenes) do
        local sc = obs.obs_scene_from_source(scene_source)
        if sc ~= nil then
            local item = obs.obs_scene_find_source(sc, source_name)
            if item ~= nil then
                local info = obs.obs_transform_info()
                get_transform(item, info)
                info.pos.x = 0
                info.pos.y = 0
                info.rot = 0
                info.bounds_type = obs.OBS_BOUNDS_SCALE_OUTER
                info.bounds_alignment = 5
                info.alignment = 5
                info.bounds.x = canvas_w
                info.bounds.y = canvas_h
                info.scale.x = 1
                info.scale.y = 1
                set_transform(item, info)
                fixed_count = fixed_count + 1
            end
        end
    end
    obs.source_list_release(scenes)

    if fixed_count > 0 then
        log("INFO: 'Fix All Scenes' applied canvas-fit to " .. fixed_count .. " scene(s) containing '" ..
            source_name .. "'.")
    end
end

---
-- Runs a human-readable diagnostic check of the current zoom source setup and prints the
-- results to the Script Log. Useful for figuring out why a source might not be filling the
-- canvas correctly, or is present in multiple scenes with mismatched configurations.
function run_diagnostics()
    log("==================== Zoom to Mouse Pro: Setup Diagnostics ====================")

    if source_name == nil or source_name == "" or source_name == "obs-zoom-to-mouse-none" then
        log("PROBLEM: No Zoom Source is selected in the script settings.")
        log("================================================================================")
        return
    end

    if sceneitem == nil then
        log("PROBLEM: Could not find a scene item for source '" .. source_name .. "' in the current scene.")
        log("         Make sure the source is actually placed in the currently active scene (or one of")
        log("         its nested groups/scenes), and that the name matches exactly.")
        log("================================================================================")
        return
    end

    local info = obs.obs_transform_info()
    get_transform(sceneitem, info)

    log("Zoom Source: '" .. source_name .. "'")
    log("Scene item position: " .. string.format("%.1f", info.pos.x) .. ", " .. string.format("%.1f", info.pos.y))
    log("Scene item scale: " .. string.format("%.3f", info.scale.x) .. ", " .. string.format("%.3f", info.scale.y))

    local bt_name = "NONE (plain position/scale, no bounding box)"
    if info.bounds_type == obs.OBS_BOUNDS_SCALE_INNER then
        bt_name = "SCALE_INNER ('contain' - can letterbox with black bars if aspect ratio mismatches!)"
    elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_OUTER then
        bt_name = "SCALE_OUTER ('cover' - recommended for full-canvas zoom sources)"
    elseif info.bounds_type == obs.OBS_BOUNDS_STRETCH then
        bt_name = "STRETCH (ignores aspect ratio, always fills exactly)"
    elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_TO_WIDTH then
        bt_name = "SCALE_TO_WIDTH"
    elseif info.bounds_type == obs.OBS_BOUNDS_SCALE_TO_HEIGHT then
        bt_name = "SCALE_TO_HEIGHT"
    elseif info.bounds_type == obs.OBS_BOUNDS_MAX_ONLY then
        bt_name = "MAX_ONLY"
    end
    log("Bounds type: " .. bt_name)
    log("Bounds size: " .. string.format("%.1f", info.bounds.x) .. " x " .. string.format("%.1f", info.bounds.y))

    local ovi = obs.obs_video_info()
    obs.obs_get_video_info(ovi)
    log("Canvas (base) resolution: " .. ovi.base_width .. "x" .. ovi.base_height)

    if info.bounds_type == obs.OBS_BOUNDS_SCALE_INNER then
        log("WARNING: 'Scale to Inner Bounds' can letterbox the source with black bars if its aspect")
        log("         ratio doesn't match the canvas. 'Scale to Outer Bounds' is usually what you want.")
    end

    if use_monitor_override then
        log("NOTE: 'Set manual source position' is ENABLED - automatic canvas-fit checks are skipped,")
        log("      since you're managing position/size manually.")
    end

    log("Zoom rescale filter present: " .. tostring(scale_filter ~= nil) ..
        " (this keeps the source's reported size constant while zooming - should always be true while zoomed)")

    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        local other_scene_count = 0
        for _, scene_source in ipairs(scenes) do
            local scene_name = obs.obs_source_get_name(scene_source)
            local sc = obs.obs_scene_from_source(scene_source)
            if sc ~= nil then
                local found = obs.obs_scene_find_source(sc, source_name)
                if found ~= nil then
                    other_scene_count = other_scene_count + 1
                    log("Source also present in scene: '" .. scene_name .. "'")
                end
            end
        end
        obs.source_list_release(scenes)

        if other_scene_count > 1 and not fix_all_scenes then
            log("NOTE: The source appears in " .. other_scene_count .. " scenes. Only the currently active")
            log("      scene's transform is auto-fixed by default. Enable 'Fix All Scenes' if you want")
            log("      every scene containing this source to be forced to fill the canvas.")
        end
    end

    log("==================== End of diagnostics - review WARNING/PROBLEM lines above ====================")
end

---
-- Get the size and position of the monitor so that we know the top-left mouse point
---@param source any The OBS source
---@return table|nil monitor_info The monitor size/top-left point
function get_monitor_info(source)
    local info = nil

    -- Only do the expensive look up if we are using automatic calculations on a display source
    if is_display_capture(source) and not use_monitor_override then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            local props = obs.obs_source_properties(source)
            if props ~= nil then
                local monitor_id_prop = obs.obs_properties_get(props, dc_info.prop_id)
                if monitor_id_prop then
                    local found = nil
                    local settings = obs.obs_source_get_settings(source)
                    if settings ~= nil then
                        local to_match
                        if dc_info.prop_type == "string" then
                            to_match = obs.obs_data_get_string(settings, dc_info.prop_id)
                        elseif dc_info.prop_type == "int" then
                            to_match = obs.obs_data_get_int(settings, dc_info.prop_id)
                        end

                        local item_count = obs.obs_property_list_item_count(monitor_id_prop);
                        for i = 0, item_count do
                            local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                            local value
                            if dc_info.prop_type == "string" then
                                value = obs.obs_property_list_item_string(monitor_id_prop, i)
                            elseif dc_info.prop_type == "int" then
                                value = obs.obs_property_list_item_int(monitor_id_prop, i)
                            end

                            if value == to_match then
                                found = name
                                break
                            end
                        end
                        obs.obs_data_release(settings)
                    end

                    if found then
                        log("Parsing display name: " .. found)
                        local x, y = found:match("(-?%d+),(-?%d+)")
                        local width, height = found:match("(%d+)x(%d+)")

                        info = { x = 0, y = 0, width = 0, height = 0 }
                        info.x = tonumber(x, 10)
                        info.y = tonumber(y, 10)
                        info.width = tonumber(width, 10)
                        info.height = tonumber(height, 10)
                        info.scale_x = 1
                        info.scale_y = 1
                        info.display_width = info.width
                        info.display_height = info.height

                        log("Parsed the following display information\n" .. format_table(info))

                        if info.width == 0 and info.height == 0 then
                            info = nil
                        end
                    end
                end

                obs.obs_properties_destroy(props)
            end
        end
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h,
            scale_x = monitor_override_sx,
            scale_y = monitor_override_sy,
            display_width = monitor_override_dw,
            display_height = monitor_override_dh
        }
    end

    if not info then
        log("WARNING: Could not auto calculate zoom source position and size.\n" ..
            "         Try using the 'Set manual source position' option and adding override values")
    end

    return info
end

---
-- Check to see if the specified source is a display capture source
-- If the source_to_check is nil then the answer will be false
---@param source_to_check any The source to check
---@return boolean result True if source is a display capture, false if it nil or some other source type
function is_display_capture(source_to_check)
    if source_to_check ~= nil then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            if allow_all_sources then
                local source_type = obs.obs_source_get_id(source_to_check)
                if source_type == dc_info.source_id then
                    return true
                end
            else
                return true
            end
        end
    end

    return false
end

---
-- Releases the current sceneitem and resets data back to default
function release_sceneitem()
    if is_timer_running then
        obs.timer_remove(on_timer)
        is_timer_running = false
    end

    zoom_state = ZoomState.None

    if sceneitem ~= nil then
        if crop_filter ~= nil and source ~= nil then
            log("Zoom crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("Conversion crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if scale_filter ~= nil and source ~= nil then
            log("Zoom rescale filter removed")
            obs.obs_source_filter_remove(source, scale_filter)
            obs.obs_source_release(scale_filter)
            scale_filter = nil
        end

        if scale_filter_settings ~= nil then
            obs.obs_data_release(scale_filter_settings)
            scale_filter_settings = nil
        end

        if sceneitem_info_orig ~= nil then
            log("Transform info reset back to original")
            set_transform(sceneitem, sceneitem_info_orig)
            sceneitem_info_orig = nil
        end

        if sceneitem_crop_orig ~= nil then
            log("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop_orig)
            sceneitem_crop_orig = nil
        end

        obs.obs_sceneitem_release(sceneitem)
        sceneitem = nil
    end

    if source ~= nil then
        obs.obs_source_release(source)
        source = nil
    end
end

---
-- Updates the current sceneitem with a refreshed set of data from the source
-- Optionally will release the existing sceneitem and get a new one from the current scene
---@param find_newest boolean True to release the current sceneitem and get a new one
---
-- Forces the current zoom sceneitem to exactly fill the OBS canvas using
-- 'Scale to Outer Bounds' with Top-Left alignment, regardless of whatever
-- transform is currently saved/active. This is self-healing: it does not
-- matter if a previous (possibly broken) transform was saved to the scene
-- collection file - it gets overwritten every time this runs.
function force_canvas_fit()
    if sceneitem == nil or use_monitor_override then
        return
    end

    local ovi = obs.obs_video_info()
    obs.obs_get_video_info(ovi)
    local canvas_w = ovi.base_width
    local canvas_h = ovi.base_height

    if canvas_w <= 0 or canvas_h <= 0 then
        return
    end

    if sceneitem_info == nil then
        sceneitem_info = obs.obs_transform_info()
    end
    get_transform(sceneitem, sceneitem_info)

    sceneitem_info.pos.x = 0
    sceneitem_info.pos.y = 0
    sceneitem_info.rot = 0
    sceneitem_info.bounds_type = obs.OBS_BOUNDS_SCALE_OUTER
    sceneitem_info.bounds_alignment = 5 -- Top Left
    sceneitem_info.alignment = 5 -- Top Left
    sceneitem_info.bounds.x = canvas_w
    sceneitem_info.bounds.y = canvas_h
    sceneitem_info.scale.x = 1
    sceneitem_info.scale.y = 1

    set_transform(sceneitem, sceneitem_info)

    if sceneitem_info_orig ~= nil then
        sceneitem_info_orig.pos.x = sceneitem_info.pos.x
        sceneitem_info_orig.pos.y = sceneitem_info.pos.y
        sceneitem_info_orig.rot = sceneitem_info.rot
        sceneitem_info_orig.bounds_type = sceneitem_info.bounds_type
        sceneitem_info_orig.bounds_alignment = sceneitem_info.bounds_alignment
        sceneitem_info_orig.alignment = sceneitem_info.alignment
        sceneitem_info_orig.bounds.x = sceneitem_info.bounds.x
        sceneitem_info_orig.bounds.y = sceneitem_info.bounds.y
        sceneitem_info_orig.scale.x = sceneitem_info.scale.x
        sceneitem_info_orig.scale.y = sceneitem_info.scale.y
    end

    log("INFO: Zoom-Quelle wurde zwangsweise auf volle Canvas-Groesse (" .. canvas_w .. "x" .. canvas_h ..
        ") mit 'Scale to Outer Bounds' (Top Left) gesetzt.")
end

function refresh_sceneitem(find_newest)
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        release_sceneitem()

        if source_name == "obs-zoom-to-mouse-none" then
            return
        end

        log("Finding sceneitem for Zoom Source '" .. source_name .. "'")
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local function find_scene_item_by_name(root_scene)
                        local queue = {}
                        table.insert(queue, root_scene)

                        while #queue > 0 do
                            local s = table.remove(queue, 1)
                            log("Looking in scene '" .. obs.obs_source_get_name(obs.obs_scene_get_source(s)) .. "'")

                            local found = obs.obs_scene_find_source(s, source_name)
                            if found ~= nil then
                                log("Found sceneitem '" .. source_name .. "'")
                                obs.obs_sceneitem_addref(found)
                                return found
                            end

                            local all_items = obs.obs_scene_enum_items(s)
                            if all_items then
                                for _, item in pairs(all_items) do
                                    local nested = obs.obs_sceneitem_get_source(item)
                                    if nested ~= nil then
                                        if obs.obs_source_is_scene(nested) then
                                            local nested_scene = obs.obs_scene_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        elseif obs.obs_source_is_group(nested) then
                                            local nested_scene = obs.obs_group_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        end
                                    end
                                end
                                obs.sceneitem_list_release(all_items)
                            end
                        end

                        return nil
                    end

                    local current = obs.obs_scene_from_source(scene_source)
                    sceneitem = find_scene_item_by_name(current)

                    obs.obs_source_release(scene_source)
                end

                if not sceneitem then
                    log("WARNING: Source not part of the current scene hierarchy.\n" ..
                        "         Try selecting a different zoom source or switching scenes.")
                    obs.obs_sceneitem_release(sceneitem)
                    obs.obs_source_release(source)

                    sceneitem = nil
                    source = nil
                    return
                end
            end
        end
    end

    if not monitor_info then
        monitor_info = get_monitor_info(source)
    end

    local is_non_display_capture = not is_display_capture(source)
    if is_non_display_capture then
        if not use_monitor_override then
            log("ERROR: Selected Zoom Source is not a display capture source.\n" ..
                "       You MUST enable 'Set manual source position' and set the correct override values for size and position.")
        end
    end

    if sceneitem ~= nil then
        sceneitem_info_orig = obs.obs_transform_info()
        get_transform(sceneitem, sceneitem_info_orig)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = obs.obs_transform_info()
        get_transform(sceneitem, sceneitem_info)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        if is_non_display_capture then
            sceneitem_crop_orig.left = 0
            sceneitem_crop_orig.top = 0
            sceneitem_crop_orig.right = 0
            sceneitem_crop_orig.bottom = 0
        end

        if not source then
            log("ERROR: Could not get source for sceneitem (" .. source_name .. ")")
        end

        local source_width = obs.obs_source_get_base_width(source)
        local source_height = obs.obs_source_get_base_height(source)

        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        if source_width == 0 or source_height == 0 then
            if monitor_info ~= nil and monitor_info.width > 0 and monitor_info.height > 0 then
                log("WARNING: Something went wrong determining source size.\n" ..
                    "         Using source size from info: " .. monitor_info.width .. ", " .. monitor_info.height)
                source_width = monitor_info.width
                source_height = monitor_info.height
            else
                log("ERROR: Something went wrong determining source size.\n" ..
                "       Try using the 'Set manual source position' option and adding override values")
            end
        else
            log("Using source size: " .. source_width .. ", " .. source_height)
        end

        -- Erzwingt volle Canvas-Fuellung (Scale to Outer Bounds, Top Left). Self-healing gegen
        -- kaputt gespeicherte Transforms. Ausgelagert in force_canvas_fit(), die zusaetzlich auch
        -- direkt bei jedem Zoom-Hotkey-Druck aufgerufen wird (siehe on_toggle_zoom), damit der Fix
        -- nicht davon abhaengt, ob OBS gerade ein Scene-Changed/Loaded Event feuert oder nicht.
        force_canvas_fit()
        zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
        local found_crop_filter = false
        local filters = obs.obs_source_enum_filters(source)
        if filters ~= nil then
            for k, v in pairs(filters) do
                local id = obs.obs_source_get_id(v)
                if id == "crop_filter" then
                    local name = obs.obs_source_get_name(v)
                    if name ~= CROP_FILTER_NAME and name ~= "temp_" .. CROP_FILTER_NAME then
                        found_crop_filter = true
                        local settings = obs.obs_source_get_settings(v)
                        if settings ~= nil then
                            if not obs.obs_data_get_bool(settings, "relative") then
                                zoom_info.source_crop_filter.x =
                                    zoom_info.source_crop_filter.x + obs.obs_data_get_int(settings, "left")
                                zoom_info.source_crop_filter.y =
                                    zoom_info.source_crop_filter.y + obs.obs_data_get_int(settings, "top")
                                zoom_info.source_crop_filter.w =
                                    zoom_info.source_crop_filter.w + obs.obs_data_get_int(settings, "cx")
                                zoom_info.source_crop_filter.h =
                                    zoom_info.source_crop_filter.h + obs.obs_data_get_int(settings, "cy")
                            end
                            obs.obs_data_release(settings)
                        end
                    end
                end
            end
            obs.source_list_release(filters)
        end

        if not found_crop_filter and (sceneitem_crop_orig.left ~= 0 or sceneitem_crop_orig.top ~= 0 or sceneitem_crop_orig.right ~= 0 or sceneitem_crop_orig.bottom ~= 0) then
            source_width = source_width - (sceneitem_crop_orig.left + sceneitem_crop_orig.right)
            source_height = source_height - (sceneitem_crop_orig.top + sceneitem_crop_orig.bottom)

            zoom_info.source_crop_filter.x = sceneitem_crop_orig.left
            zoom_info.source_crop_filter.y = sceneitem_crop_orig.top
            zoom_info.source_crop_filter.w = source_width
            zoom_info.source_crop_filter.h = source_height

            local settings = obs.obs_data_create()
            obs.obs_data_set_bool(settings, "relative", false)
            obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
            obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
            obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
            obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
            crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
            obs.obs_source_filter_add(source, crop_filter_temp)
            obs.obs_data_release(settings)

            sceneitem_crop.left = 0
            sceneitem_crop.top = 0
            sceneitem_crop.right = 0
            sceneitem_crop.bottom = 0
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)
        elseif found_crop_filter then
            source_width = zoom_info.source_crop_filter.w
            source_height = zoom_info.source_crop_filter.h
        end

        zoom_info.source_size = { width = source_width, height = source_height }
        zoom_info.source_crop = {
            l = sceneitem_crop_orig.left,
            t = sceneitem_crop_orig.top,
            r = sceneitem_crop_orig.right,
            b = sceneitem_crop_orig.bottom
        }

        crop_filter_info_orig = { x = 0, y = 0, w = zoom_info.source_size.width, h = zoom_info.source_size.height }
        crop_filter_info = {
            x = crop_filter_info_orig.x,
            y = crop_filter_info_orig.y,
            w = crop_filter_info_orig.w,
            h = crop_filter_info_orig.h
        }

        crop_filter = obs.obs_source_get_filter_by_name(source, CROP_FILTER_NAME)
        if crop_filter == nil then
            crop_filter_settings = obs.obs_data_create()
            obs.obs_data_set_bool(crop_filter_settings, "relative", false)
            crop_filter = obs.obs_source_create_private("crop_filter", CROP_FILTER_NAME, crop_filter_settings)
            obs.obs_source_filter_add(source, crop_filter)
        else
            crop_filter_settings = obs.obs_source_get_settings(crop_filter)
        end

        -- FIX: Fuegt einen zweiten Filter (OBS' eingebauten "scale_filter" / "Skalierung/Seitenverhaeltnis")
        -- direkt NACH dem Crop-Filter ein. Dieser skaliert das gecroppte (kleinere) Bild rechnerisch wieder
        -- exakt auf die urspruengliche Quellgroesse hoch. Dadurch bleibt die von OBS gemeldete Aufloesung der
        -- Quelle (obs_source_get_base_width/height) IMMER konstant, unabhaengig vom Zoom-Level.
        --
        -- Das ist entscheidend fuer Setups mit mehreren Canvases (z.B. Aitum Vertical Canvas): Jedes Canvas
        -- (Main UND Vertikal) haelt seine EIGENE, komplett unabhaengige Transform/Skalierung fuer dieselbe
        -- Quelle - unser Script kann dort nur das Main-Canvas-Sceneitem erreichen. Wenn aber die Quelle selbst
        -- (dank dieses Filters) nie ihre gemeldete Groesse aendert, muessen wir das Main- ODER Vertikal-Item
        -- ueberhaupt nicht anfassen - beide zeigen automatisch weiterhin korrekt in voller Groesse an, weil sie
        -- schlicht nie mitbekommen, dass intern gecroppt wurde. Nur das BILD innerhalb der konstanten Groesse
        -- aendert sich (Zoom-Effekt), nicht die Groesse selbst.
        scale_filter = obs.obs_source_get_filter_by_name(source, SCALE_FILTER_NAME)
        if scale_filter == nil then
            scale_filter_settings = obs.obs_data_create()
            obs.obs_data_set_string(scale_filter_settings, "sampling", "bicubic")
            obs.obs_data_set_string(scale_filter_settings, "resolution",
                zoom_info.source_size.width .. "x" .. zoom_info.source_size.height)
            scale_filter = obs.obs_source_create_private("scale_filter", SCALE_FILTER_NAME, scale_filter_settings)
            obs.obs_source_filter_add(source, scale_filter)
        else
            scale_filter_settings = obs.obs_source_get_settings(scale_filter)
            obs.obs_data_set_string(scale_filter_settings, "resolution",
                zoom_info.source_size.width .. "x" .. zoom_info.source_size.height)
            obs.obs_source_update(scale_filter, scale_filter_settings)
        end

        obs.obs_source_filter_set_order(source, crop_filter, obs.OBS_ORDER_MOVE_BOTTOM)
        obs.obs_source_filter_set_order(source, scale_filter, obs.OBS_ORDER_MOVE_BOTTOM)
        set_crop_settings(crop_filter_info_orig)
    end
end

---
-- Get the target position that we will attempt to zoom towards
---@param zoom any
---@return table
function get_target_position(zoom)
    local mouse = get_mouse_pos()

    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    mouse.x = mouse.x - zoom.source_crop_filter.x
    mouse.y = mouse.y - zoom.source_crop_filter.y

    if monitor_info and monitor_info.scale_x and monitor_info.scale_y then
        mouse.x = mouse.x * monitor_info.scale_x
        mouse.y = mouse.y * monitor_info.scale_y
    end

    local new_size = {
        width = zoom.source_size.width / zoom.zoom_to,
        height = zoom.source_size.height / zoom.zoom_to
    }

    local pos = {
        x = mouse.x - new_size.width * 0.5,
        y = mouse.y - new_size.height * 0.5
    }

    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))
    crop.y = math.floor(clamp(0, (zoom.source_size.height - new_size.height), crop.y))

    return { crop = crop, raw_center = mouse, clamped_center = { x = math.floor(crop.x + crop.w * 0.5), y = math.floor(crop.y + crop.h * 0.5) } }
end

function on_toggle_zoom(pressed)
    if pressed then
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None then
            cycle_step = 0
            direct_zoom_active_level = nil

            if zoom_state == ZoomState.ZoomedIn then
                start_zoom_out()
            else
                start_zoom_in_at_level(zoom_value)
            end
        end
    end
end

function on_timer()
    if crop_filter_info ~= nil and zoom_target ~= nil then
        zoom_time = zoom_time + zoom_speed

        if zoom_state == ZoomState.ZoomingOut or zoom_state == ZoomState.ZoomingIn then
            if zoom_time <= 1 then
                if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
                    zoom_target = get_target_position(zoom_info)
                end
                crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, ease_in_out(zoom_time))
                crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, ease_in_out(zoom_time))
                crop_filter_info.w = lerp(crop_filter_info.w, zoom_target.crop.w, ease_in_out(zoom_time))
                crop_filter_info.h = lerp(crop_filter_info.h, zoom_target.crop.h, ease_in_out(zoom_time))
                set_crop_settings(crop_filter_info)
            end
        else
            if is_following_mouse and not is_manually_frozen then
                zoom_target = get_target_position(zoom_info)

                local skip_frame = false
                if not use_follow_outside_bounds then
                    if zoom_target.raw_center.x < zoom_target.crop.x or
                        zoom_target.raw_center.x > zoom_target.crop.x + zoom_target.crop.w or
                        zoom_target.raw_center.y < zoom_target.crop.y or
                        zoom_target.raw_center.y > zoom_target.crop.y + zoom_target.crop.h then
                        skip_frame = true
                    end
                end

                if not skip_frame then
                    if locked_center ~= nil then
                        local diff = {
                            x = zoom_target.raw_center.x - locked_center.x,
                            y = zoom_target.raw_center.y - locked_center.y
                        }

                        local track = {
                            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
                            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
                        }

                        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                            locked_center = nil
                            locked_last_pos = {
                                x = zoom_target.raw_center.x,
                                y = zoom_target.raw_center.y,
                                diff_x = diff.x,
                                diff_y = diff.y
                            }
                            log("Locked area exited - resume tracking")
                        end
                    end

                    if locked_center == nil and (zoom_target.crop.x ~= crop_filter_info.x or zoom_target.crop.y ~= crop_filter_info.y) then
                        crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, follow_speed)
                        crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, follow_speed)
                        set_crop_settings(crop_filter_info)

                        if is_following_mouse and locked_center == nil and locked_last_pos ~= nil then
                            local diff = {
                                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                                y = math.abs(crop_filter_info.y - zoom_target.crop.y),
                                auto_x = zoom_target.raw_center.x - locked_last_pos.x,
                                auto_y = zoom_target.raw_center.y - locked_last_pos.y
                            }

                            locked_last_pos.x = zoom_target.raw_center.x
                            locked_last_pos.y = zoom_target.raw_center.y

                            local lock = false
                            if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                                if (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or (diff.auto_x > 0 and locked_last_pos.diff_x < 0) then
                                    lock = true
                                end
                            else
                                if (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or (diff.auto_y > 0 and locked_last_pos.diff_y < 0) then
                                    lock = true
                                end
                            end

                            if (lock and use_follow_auto_lock) or (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                                locked_center = {
                                    x = math.floor(crop_filter_info.x + zoom_target.crop.w * 0.5),
                                    y = math.floor(crop_filter_info.y + zoom_target.crop.h * 0.5)
                                }
                                log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                            end
                        end
                    end
                end
            end
        end

        if zoom_time >= 1 then
            local should_stop_timer = false
            if zoom_state == ZoomState.ZoomingOut then
                log("Zoomed out")
                zoom_state = ZoomState.None
                should_stop_timer = true
            elseif zoom_state == ZoomState.ZoomingIn then
                log("Zoomed in")
                zoom_state = ZoomState.ZoomedIn
                should_stop_timer = (not use_auto_follow_mouse) and (not is_following_mouse)

                if use_auto_follow_mouse then
                    is_following_mouse = true
                    log("Tracking mouse is " .. (is_following_mouse and "on" or "off") .. " (due to auto follow)")
                end

                if is_following_mouse and follow_border < 50 then
                    zoom_target = get_target_position(zoom_info)
                    locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                    log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                end
            end

            if should_stop_timer then
                is_timer_running = false
                obs.timer_remove(on_timer)
            end
        end
    end
end

function on_socket_timer()
    if not socket_server then
        return
    end

    repeat
        local data, status = socket_server:receive_from()
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                local x = tonumber(sx, 10)
                local y = tonumber(sy, 10)
                if not socket_mouse then
                    log("Socket server client connected")
                    socket_mouse = { x = x, y = y }
                else
                    socket_mouse.x = x
                    socket_mouse.y = y
                end
            end
        elseif status ~= "timeout" then
            error(status)
        end
    until data == nil
end

function start_server()
    if socket_available then
        local address = socket.find_first_address("*", socket_port)

        socket_server = socket.create("inet", "dgram", "udp")
        if socket_server ~= nil then
            socket_server:set_option("reuseaddr", 1)
            socket_server:set_blocking(false)
            socket_server:bind(address, socket_port)
            obs.timer_add(on_socket_timer, socket_poll)
            log("Socket server listening on port " .. socket_port .. "...")
        end
    end
end

function stop_server()
    if socket_server ~= nil then
        log("Socket server stopped")
        obs.timer_remove(on_socket_timer)
        socket_server:close()
        socket_server = nil
        socket_mouse = nil
    end
end

function set_crop_settings(crop)
    if crop_filter ~= nil and crop_filter_settings ~= nil then
        obs.obs_data_set_int(crop_filter_settings, "left", math.floor(crop.x))
        obs.obs_data_set_int(crop_filter_settings, "top", math.floor(crop.y))
        obs.obs_data_set_int(crop_filter_settings, "cx", math.floor(crop.w))
        obs.obs_data_set_int(crop_filter_settings, "cy", math.floor(crop.h))
        obs.obs_source_update(crop_filter, crop_filter_settings)
    end
end

function on_transition_start(t)
    log("Transition started")
    release_sceneitem()
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("OBS Scene changed")
        handle_scene_changed_for_zoom_memory()
        if is_obs_loaded then
            refresh_sceneitem(true)
            if fix_all_scenes then
                force_canvas_fit_all_scenes()
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        log("OBS Loaded")
        is_obs_loaded = true
        monitor_info = get_monitor_info(source)
        current_scene_name = get_current_scene_name()
        refresh_sceneitem(true)
        if fix_all_scenes then
            force_canvas_fit_all_scenes()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        log("OBS Shutting down")
        if is_script_loaded then
            script_unload()
        end
    end
end

function on_update_transform()
    if is_obs_loaded then
        refresh_sceneitem(true)
    end

    return true
end

function on_settings_modified(props, prop, settings)
    current_settings = settings
    local name = obs.obs_property_name(prop)

    if name == "use_monitor_override" then
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_x"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_y"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_w"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_h"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sx"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sy"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dw"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dh"), visible)
        return true
    elseif name == "use_socket" then
        local visible = obs.obs_data_get_bool(settings, "use_socket")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_port"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_poll"), visible)
        return true
    elseif name == "allow_all_sources" then
        local sources_list = obs.obs_properties_get(props, "source")
        populate_zoom_sources(sources_list)
        return true
    elseif name == "debug_logs" then
        if obs.obs_data_get_bool(settings, "debug_logs") then
            log_current_settings()
        end
    end

    return false
end

---
-- Bundles the current "feel" settings (zoom levels, speed, follow behavior) into a
-- fresh obs_data_t, suitable for saving as a named preset. Deliberately excludes source
-- selection / monitor overrides / socket settings, since presets are about zoom behavior,
-- not which source you're zooming.
---@return userdata obs_data_t
function build_preset_data()
    local d = obs.obs_data_create()
    obs.obs_data_set_double(d, "zoom_value", zoom_value)
    obs.obs_data_set_double(d, "zoom_speed", zoom_speed)
    obs.obs_data_set_double(d, "zoom_level_1", zoom_level_1)
    obs.obs_data_set_double(d, "zoom_level_2", zoom_level_2)
    obs.obs_data_set_double(d, "zoom_level_3", zoom_level_3)
    obs.obs_data_set_bool(d, "follow", use_auto_follow_mouse)
    obs.obs_data_set_bool(d, "follow_outside_bounds", use_follow_outside_bounds)
    obs.obs_data_set_double(d, "follow_speed", follow_speed)
    obs.obs_data_set_int(d, "follow_border", follow_border)
    obs.obs_data_set_int(d, "follow_safezone_sensitivity", follow_safezone_sensitivity)
    obs.obs_data_set_bool(d, "follow_auto_lock", use_follow_auto_lock)
    obs.obs_data_set_bool(d, "per_scene_zoom_memory", use_per_scene_zoom_memory)
    obs.obs_data_set_bool(d, "fix_all_scenes", fix_all_scenes)
    return d
end

---
-- Applies a preset's obs_data_t (as produced by build_preset_data) to the live script state
-- and writes it back into the script's own settings object so the UI reflects the change.
---@param d userdata obs_data_t
function apply_preset_data(d)
    zoom_value = obs.obs_data_get_double(d, "zoom_value")
    zoom_speed = obs.obs_data_get_double(d, "zoom_speed")
    zoom_level_1 = obs.obs_data_get_double(d, "zoom_level_1")
    zoom_level_2 = obs.obs_data_get_double(d, "zoom_level_2")
    zoom_level_3 = obs.obs_data_get_double(d, "zoom_level_3")
    cycle_step = 0
    direct_zoom_active_level = nil
    use_auto_follow_mouse = obs.obs_data_get_bool(d, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(d, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(d, "follow_speed")
    follow_border = obs.obs_data_get_int(d, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(d, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(d, "follow_auto_lock")
    use_per_scene_zoom_memory = obs.obs_data_get_bool(d, "per_scene_zoom_memory")
    fix_all_scenes = obs.obs_data_get_bool(d, "fix_all_scenes")

    if current_settings ~= nil then
        obs.obs_data_set_double(current_settings, "zoom_value", zoom_value)
        obs.obs_data_set_double(current_settings, "zoom_speed", zoom_speed)
        obs.obs_data_set_double(current_settings, "zoom_level_1", zoom_level_1)
        obs.obs_data_set_double(current_settings, "zoom_level_2", zoom_level_2)
        obs.obs_data_set_double(current_settings, "zoom_level_3", zoom_level_3)
        obs.obs_data_set_bool(current_settings, "follow", use_auto_follow_mouse)
        obs.obs_data_set_bool(current_settings, "follow_outside_bounds", use_follow_outside_bounds)
        obs.obs_data_set_double(current_settings, "follow_speed", follow_speed)
        obs.obs_data_set_int(current_settings, "follow_border", follow_border)
        obs.obs_data_set_int(current_settings, "follow_safezone_sensitivity", follow_safezone_sensitivity)
        obs.obs_data_set_bool(current_settings, "follow_auto_lock", use_follow_auto_lock)
        obs.obs_data_set_bool(current_settings, "per_scene_zoom_memory", use_per_scene_zoom_memory)
        obs.obs_data_set_bool(current_settings, "fix_all_scenes", fix_all_scenes)
    end
end

---
-- Returns the list of saved preset names (stored as a delimited string in script settings)
---@return table
function get_preset_names()
    local names = {}
    if current_settings ~= nil then
        local str = obs.obs_data_get_string(current_settings, "preset_names")
        for token in string.gmatch(str, "[^\30]+") do
            table.insert(names, token)
        end
    end
    return names
end

---@param names table
function set_preset_names(names)
    if current_settings ~= nil then
        obs.obs_data_set_string(current_settings, "preset_names", table.concat(names, "\30"))
    end
end

---@param list userdata obs_property_t (a list property)
function populate_preset_list(list)
    obs.obs_property_list_clear(list)
    obs.obs_property_list_add_string(list, "<Select a preset>", "")
    for _, preset_name in ipairs(get_preset_names()) do
        obs.obs_property_list_add_string(list, preset_name, preset_name)
    end
end

function on_save_preset_clicked(props, property)
    if current_settings == nil then
        return true
    end

    local name = obs.obs_data_get_string(current_settings, "preset_name_input")
    name = name:match("^%s*(.-)%s*$")
    if name == nil or name == "" then
        log("WARNING: Enter a preset name before saving.")
        return true
    end

    local d = build_preset_data()
    local json = obs.obs_data_get_json(d)
    obs.obs_data_release(d)
    obs.obs_data_set_string(current_settings, "preset:" .. name, json)

    local names = get_preset_names()
    local exists = false
    for _, n in ipairs(names) do
        if n == name then
            exists = true
        end
    end
    if not exists then
        table.insert(names, name)
        set_preset_names(names)
    end

    log("Saved preset '" .. name .. "'.")

    local preset_list = obs.obs_properties_get(props, "preset_select")
    if preset_list ~= nil then
        populate_preset_list(preset_list)
    end

    return true
end

function on_load_preset_clicked(props, property)
    if current_settings == nil then
        return true
    end

    local name = obs.obs_data_get_string(current_settings, "preset_select")
    if name == nil or name == "" then
        log("WARNING: Select a preset to load first.")
        return true
    end

    local json = obs.obs_data_get_string(current_settings, "preset:" .. name)
    if json == nil or json == "" then
        log("WARNING: Preset '" .. name .. "' not found.")
        return true
    end

    local d = obs.obs_data_create_from_json(json)
    if d ~= nil then
        apply_preset_data(d)
        obs.obs_data_release(d)
        log("Loaded preset '" .. name .. "'.")
    end

    return true
end

function on_delete_preset_clicked(props, property)
    if current_settings == nil then
        return true
    end

    local name = obs.obs_data_get_string(current_settings, "preset_select")
    if name == nil or name == "" then
        log("WARNING: Select a preset to delete first.")
        return true
    end

    local names = get_preset_names()
    local new_names = {}
    for _, n in ipairs(names) do
        if n ~= name then
            table.insert(new_names, n)
        end
    end
    set_preset_names(new_names)

    log("Deleted preset '" .. name .. "' (settings entry cleared on next save).")

    local preset_list = obs.obs_properties_get(props, "preset_select")
    if preset_list ~= nil then
        populate_preset_list(preset_list)
    end

    return true
end

function log_current_settings()
    local settings = {
        zoom_value = zoom_value,
        zoom_speed = zoom_speed,
        zoom_level_1 = zoom_level_1,
        zoom_level_2 = zoom_level_2,
        zoom_level_3 = zoom_level_3,
        use_auto_follow_mouse = use_auto_follow_mouse,
        use_follow_outside_bounds = use_follow_outside_bounds,
        follow_speed = follow_speed,
        follow_border = follow_border,
        follow_safezone_sensitivity = follow_safezone_sensitivity,
        use_follow_auto_lock = use_follow_auto_lock,
        use_per_scene_zoom_memory = use_per_scene_zoom_memory,
        fix_all_scenes = fix_all_scenes,
        use_monitor_override = use_monitor_override,
        monitor_override_x = monitor_override_x,
        monitor_override_y = monitor_override_y,
        monitor_override_w = monitor_override_w,
        monitor_override_h = monitor_override_h,
        monitor_override_sx = monitor_override_sx,
        monitor_override_sy = monitor_override_sy,
        monitor_override_dw = monitor_override_dw,
        monitor_override_dh = monitor_override_dh,
        use_socket = use_socket,
        socket_port = socket_port,
        socket_poll = socket_poll,
        debug_logs = debug_logs,
        version = VERSION
    }

    log("OBS Version: " .. string.format("%.1f", major) .. "." .. minor)
    log("Platform: " .. ffi.os)
    log("Current settings:")
    log(format_table(settings))
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "Help Information for Zoom to Mouse Pro v" .. VERSION .. "\n" ..
        "----------------------------------------------------\n" ..
        "This script smoothly zooms the selected display-capture source to focus on the mouse.\n\n"

    obs.script_log(obs.OBS_LOG_INFO, help)
end

function script_description()
    return "<h2 style='margin-bottom:0px;'>Zoom to Mouse Pro</h2>" ..
        "<div style='color:gray;font-size:11px;margin-top:0px;margin-bottom:8px;'>v" .. VERSION .. "</div>" ..
        "Smoothly zooms a display-capture source to follow your mouse. " ..
        "Includes dedicated zoom-level hotkeys, a stepped cycle hotkey, per-scene zoom memory, " ..
        "a freeze hotkey, presets, and a setup diagnostics check."
end

---
-- Opens a URL in the user's default browser (best effort - falls back to just logging the
-- link if the platform command isn't available, so the user can still copy/paste it manually)
---@param url string
function open_url(url)
    local ok = false
    if ffi.os == "Windows" then
        ok = pcall(function() os.execute('start "" "' .. url .. '"') end)
    elseif ffi.os == "OSX" then
        ok = pcall(function() os.execute('open "' .. url .. '"') end)
    else
        ok = pcall(function() os.execute('xdg-open "' .. url .. '"') end)
    end

    if not ok then
        log("Could not open the browser automatically - here's the link: " .. url)
    end
end

function script_properties()
    local props = obs.obs_properties_create()

    -- --- Source ---
    local sources_list = obs.obs_properties_add_list(props, "source", "Zoom Source", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)
    populate_zoom_sources(sources_list)

    obs.obs_properties_add_button(props, "refresh", "Refresh zoom sources",
        function()
            populate_zoom_sources(sources_list)
            monitor_info = get_monitor_info(source)
            return true
        end)

    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "Allow any zoom source ")

    -- --- Zoom Levels & hotkeys ---
    local zoom_group_props = obs.obs_properties_create()
    obs.obs_properties_add_float(zoom_group_props, "zoom_value", "Zoom Factor (main Toggle Zoom hotkey)", 1, 5, 0.5)
    obs.obs_properties_add_float(zoom_group_props, "zoom_level_1", "Zoom Level 1 (dedicated hotkey)", 1, 10, 0.1)
    obs.obs_properties_add_float(zoom_group_props, "zoom_level_2", "Zoom Level 2 (dedicated hotkey)", 1, 10, 0.1)
    obs.obs_properties_add_float(zoom_group_props, "zoom_level_3", "Zoom Level 3 (dedicated hotkey)", 1, 10, 0.1)
    local levels_info = obs.obs_properties_add_text(zoom_group_props, "zoom_levels_info",
        "", obs.OBS_TEXT_INFO)
    obs.obs_property_set_long_description(levels_info,
        "Assign hotkeys under Settings > Hotkeys:\n" ..
        "- 'Zoom to Level 1/2/3': jump straight to that level (press again to zoom back out)\n" ..
        "- 'Cycle zoom level': steps Level 1 -> Level 2 -> Level 3 -> zoomed out, one press at a time\n" ..
        "- 'Toggle zoom to mouse': simple in/out toggle using 'Zoom Factor' above\n" ..
        "- 'Freeze/unfreeze zoom view': pause mouse tracking without zooming out")
    obs.obs_properties_add_float_slider(zoom_group_props, "zoom_speed", "Zoom Speed", 0.01, 1, 0.01)
    obs.obs_properties_add_group(props, "zoom_levels_group", "Zoom Levels", obs.OBS_GROUP_NORMAL, zoom_group_props)

    -- --- Mouse follow behavior ---
    local follow_group_props = obs.obs_properties_create()
    obs.obs_properties_add_bool(follow_group_props, "follow", "Auto follow mouse ")
    obs.obs_properties_add_bool(follow_group_props, "follow_outside_bounds", "Follow outside bounds ")
    obs.obs_properties_add_float_slider(follow_group_props, "follow_speed", "Follow Speed", 0.01, 1, 0.01)
    obs.obs_properties_add_int_slider(follow_group_props, "follow_border", "Follow Border", 0, 50, 1)
    obs.obs_properties_add_int_slider(follow_group_props,
        "follow_safezone_sensitivity", "Lock Sensitivity", 1, 20, 1)
    obs.obs_properties_add_bool(follow_group_props, "follow_auto_lock", "Auto Lock on reverse direction ")
    obs.obs_properties_add_group(props, "follow_group", "Mouse Follow Behavior", obs.OBS_GROUP_NORMAL,
        follow_group_props)

    -- --- Scene behavior ---
    local scene_group_props = obs.obs_properties_create()
    obs.obs_properties_add_bool(scene_group_props, "per_scene_zoom_memory", "Remember zoom level per scene ")
    obs.obs_properties_add_bool(scene_group_props, "fix_all_scenes",
        "Fix canvas-fit in ALL scenes containing this source (not just the active one) ")
    obs.obs_properties_add_group(props, "scene_group", "Scene Behavior", obs.OBS_GROUP_NORMAL, scene_group_props)

    -- --- Advanced: manual position override ---
    local override_props = obs.obs_properties_create();
    local override_label = obs.obs_properties_add_text(override_props, "monitor_override_label", "", obs.OBS_TEXT_INFO)
    local override_x = obs.obs_properties_add_int(override_props, "monitor_override_x", "X", -10000, 10000, 1)
    local override_y = obs.obs_properties_add_int(override_props, "monitor_override_y", "Y", -10000, 10000, 1)
    local override_w = obs.obs_properties_add_int(override_props, "monitor_override_w", "Width", 0, 10000, 1)
    local override_h = obs.obs_properties_add_int(override_props, "monitor_override_h", "Height", 0, 10000, 1)
    local override_sx = obs.obs_properties_add_float(override_props, "monitor_override_sx", "Scale X ", 0, 100, 0.01)
    local override_sy = obs.obs_properties_add_float(override_props, "monitor_override_sy", "Scale Y ", 0, 100, 0.01)
    local override_dw = obs.obs_properties_add_int(override_props, "monitor_override_dw", "Monitor Width ", 0, 10000, 1)
    local override_dh = obs.obs_properties_add_int(override_props, "monitor_override_dh", "Monitor Height ", 0, 10000, 1)
    local override = obs.obs_properties_add_group(props, "use_monitor_override", "Set manual source position ",
        obs.OBS_GROUP_CHECKABLE, override_props)

    if socket_available then
        local socket_props = obs.obs_properties_create();
        local r_label = obs.obs_properties_add_text(socket_props, "socket_label", "", obs.OBS_TEXT_INFO)
        local r_port = obs.obs_properties_add_int(socket_props, "socket_port", "Port ", 1024, 65535, 1)
        local r_poll = obs.obs_properties_add_int(socket_props, "socket_poll", "Poll Delay (ms) ", 0, 1000, 1)
        local socket = obs.obs_properties_add_group(props, "use_socket", "Enable remote mouse listener ",
            obs.OBS_GROUP_CHECKABLE, socket_props)
        obs.obs_property_set_visible(r_label, not use_socket)
        obs.obs_property_set_visible(r_port, use_socket)
        obs.obs_property_set_visible(r_poll, use_socket)
        obs.obs_property_set_modified_callback(socket, on_settings_modified)
    end

    -- --- Presets ---
    local preset_props = obs.obs_properties_create()
    obs.obs_properties_add_text(preset_props, "preset_name_input", "New Preset Name", obs.OBS_TEXT_DEFAULT)
    local preset_select = obs.obs_properties_add_list(preset_props, "preset_select", "Saved Presets",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    populate_preset_list(preset_select)
    obs.obs_properties_add_button(preset_props, "save_preset", "Save current settings as preset",
        on_save_preset_clicked)
    obs.obs_properties_add_button(preset_props, "load_preset", "Load selected preset", on_load_preset_clicked)
    obs.obs_properties_add_button(preset_props, "delete_preset", "Delete selected preset", on_delete_preset_clicked)
    obs.obs_properties_add_group(props, "presets_group", "Presets (Zoom Levels, Speed, Follow behavior) ",
        obs.OBS_GROUP_NORMAL, preset_props)

    -- --- Diagnostics & debug ---
    local debug_group_props = obs.obs_properties_create()
    obs.obs_properties_add_button(debug_group_props, "help_button", "More Info", on_print_help)
    obs.obs_properties_add_button(debug_group_props, "run_diagnostics", "Run Setup Diagnostics (check Script Log)",
        function(p, prop)
            run_diagnostics()
            return true
        end)
    local debug = obs.obs_properties_add_bool(debug_group_props, "debug_logs", "Enable debug logging ")
    obs.obs_properties_add_group(props, "debug_group", "Diagnostics & Debug", obs.OBS_GROUP_NORMAL,
        debug_group_props)

    -- --- Support ---
    local support_props = obs.obs_properties_create()
    obs.obs_properties_add_button(support_props, "support_youtube", "YouTube: Timexo",
        function(p, prop)
            open_url("https://www.youtube.com/@timexo_official")
            return false
        end)
    obs.obs_properties_add_button(support_props, "support_coffee", "Buy me a coffee",
        function(p, prop)
            open_url("https://timexo.gumroad.com/coffee")
            return false
        end)
    obs.obs_properties_add_group(props, "support_group", "Support this Project", obs.OBS_GROUP_NORMAL, support_props)

    obs.obs_property_set_visible(override_label, not use_monitor_override)
    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_visible(override_sx, use_monitor_override)
    obs.obs_property_set_visible(override_sy, use_monitor_override)
    obs.obs_property_set_visible(override_dw, use_monitor_override)
    obs.obs_property_set_visible(override_dh, use_monitor_override)
    obs.obs_property_set_modified_callback(override, on_settings_modified)

    obs.obs_property_set_modified_callback(allow_all, on_settings_modified)
    obs.obs_property_set_modified_callback(debug, on_settings_modified)

    return props
end

function script_load(settings)
    sceneitem_info_orig = nil
    current_settings = settings

    local current_scene = obs.obs_frontend_get_current_scene()
    is_obs_loaded = current_scene ~= nil 
    obs.obs_source_release(current_scene)

    hotkey_zoom_id = obs.obs_hotkey_register_frontend("toggle_zoom_hotkey", "Toggle zoom to mouse",
        on_toggle_zoom)

    hotkey_zoom_level_1_id = obs.obs_hotkey_register_frontend("zoom_level_1_hotkey", "Zoom to Level 1",
        on_toggle_zoom_level_1)

    hotkey_zoom_level_2_id = obs.obs_hotkey_register_frontend("zoom_level_2_hotkey", "Zoom to Level 2",
        on_toggle_zoom_level_2)

    hotkey_zoom_level_3_id = obs.obs_hotkey_register_frontend("zoom_level_3_hotkey", "Zoom to Level 3",
        on_toggle_zoom_level_3)

    hotkey_cycle_zoom_id = obs.obs_hotkey_register_frontend("cycle_zoom_level_hotkey", "Cycle zoom level (1 -> 2 -> 3 -> off)",
        on_cycle_zoom_level)

    hotkey_freeze_id = obs.obs_hotkey_register_frontend("toggle_freeze_hotkey", "Freeze/unfreeze zoom view",
        on_toggle_freeze)

    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom")
    obs.obs_hotkey_load(hotkey_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom_level_1")
    obs.obs_hotkey_load(hotkey_zoom_level_1_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom_level_2")
    obs.obs_hotkey_load(hotkey_zoom_level_2_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom_level_3")
    obs.obs_hotkey_load(hotkey_zoom_level_3_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.cycle_zoom")
    obs.obs_hotkey_load(hotkey_cycle_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.freeze")
    obs.obs_hotkey_load(hotkey_freeze_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    zoom_level_1 = obs.obs_data_get_double(settings, "zoom_level_1")
    zoom_level_2 = obs.obs_data_get_double(settings, "zoom_level_2")
    zoom_level_3 = obs.obs_data_get_double(settings, "zoom_level_3")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    use_per_scene_zoom_memory = obs.obs_data_get_bool(settings, "per_scene_zoom_memory")
    fix_all_scenes = obs.obs_data_get_bool(settings, "fix_all_scenes")
    deserialize_scene_zoom_memory(obs.obs_data_get_string(settings, "scene_zoom_memory_data"))
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = obs.obs_source_get_name(s)
            log("Adding transition_start listener to " .. name)
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    source_name = ""
    use_socket = false
    is_script_loaded = true
end

function script_unload()
    is_script_loaded = false

    if major > 29.1 or (major == 29.1 and minor > 2) then 
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for i, s in pairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        obs.obs_hotkey_unregister(on_toggle_zoom)
        obs.obs_hotkey_unregister(on_toggle_zoom_level_1)
        obs.obs_hotkey_unregister(on_toggle_zoom_level_2)
        obs.obs_hotkey_unregister(on_toggle_zoom_level_3)
        obs.obs_hotkey_unregister(on_cycle_zoom_level)
        obs.obs_hotkey_unregister(on_toggle_freeze)
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
        x11_display = nil
        x11_lib = nil
    end

    if socket_server ~= nil then
        stop_server()
    end
end

function script_defaults(settings)
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    obs.obs_data_set_default_double(settings, "zoom_level_1", 1.5)
    obs.obs_data_set_default_double(settings, "zoom_level_2", 2)
    obs.obs_data_set_default_double(settings, "zoom_level_3", 3)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.25)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "per_scene_zoom_memory", false)
    obs.obs_data_set_default_bool(settings, "fix_all_scenes", false)
    obs.obs_data_set_default_bool(settings, "allow_all_sources", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    obs.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    obs.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    obs.obs_data_set_default_bool(settings, "use_socket", false)
    obs.obs_data_set_default_int(settings, "socket_port", 12345)
    obs.obs_data_set_default_int(settings, "socket_poll", 10)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)
end

function script_save(settings)
    if hotkey_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_zoom_level_1_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_level_1_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom_level_1", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_zoom_level_2_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_level_2_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom_level_2", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_zoom_level_3_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_level_3_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom_level_3", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_cycle_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_cycle_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.cycle_zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_freeze_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_freeze_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.freeze", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    obs.obs_data_set_string(settings, "scene_zoom_memory_data", serialize_scene_zoom_memory())
end

function script_update(settings)
    current_settings = settings
    local old_source_name = source_name
    local old_override = use_monitor_override
    local old_x = monitor_override_x
    local old_y = monitor_override_y
    local old_w = monitor_override_w
    local old_h = monitor_override_h
    local old_sx = monitor_override_sx
    local old_sy = monitor_override_sy
    local old_dw = monitor_override_dw
    local old_dh = monitor_override_dh
    local old_socket = use_socket
    local old_port = socket_port
    local old_poll = socket_poll

    source_name = obs.obs_data_get_string(settings, "source")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    zoom_level_1 = obs.obs_data_get_double(settings, "zoom_level_1")
    zoom_level_2 = obs.obs_data_get_double(settings, "zoom_level_2")
    zoom_level_3 = obs.obs_data_get_double(settings, "zoom_level_3")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    use_per_scene_zoom_memory = obs.obs_data_get_bool(settings, "per_scene_zoom_memory")
    fix_all_scenes = obs.obs_data_get_bool(settings, "fix_all_scenes")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    if fix_all_scenes and is_obs_loaded then
        force_canvas_fit_all_scenes()
    end

    if source_name ~= old_source_name and is_obs_loaded then
        refresh_sceneitem(true)
    end

    if source_name ~= old_source_name or
        use_monitor_override ~= old_override or
        monitor_override_x ~= old_x or
        monitor_override_y ~= old_y or
        monitor_override_w ~= old_w or
        monitor_override_h ~= old_h or
        monitor_override_sx ~= old_sx or
        monitor_override_sy ~= old_sy or
        monitor_override_w ~= old_dw or
        monitor_override_h ~= old_dh then
        if is_obs_loaded then
            monitor_info = get_monitor_info(source)
        end
    end

    if old_socket ~= use_socket then
        if use_socket then
            start_server()
        else
            stop_server()
        end
    elseif use_socket and (old_poll ~= socket_poll or old_port ~= socket_port) then
        stop_server()
        start_server()
    end
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<None>", "obs-zoom-to-mouse-none")
        for _, source in ipairs(sources) do
            local source_type = obs.obs_source_get_id(source)
            if source_type == dc_info.source_id or allow_all_sources then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end

        obs.source_list_release(sources)
    end
end

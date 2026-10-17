--[[
	Activity Scene Switch

	Switches scenes based on system-wide mouse and keyboard activity:

	* when input happened within the activity window, switch to the
	  "active" scene
	* when no input has been seen for X seconds, switch to the
	  "away" scene

	Optional screen change detection: a small GDI thumbnail of the screen
	is captured at a low rate and compared with a dHash. While the screen
	keeps changing, the "away" state is prevented. Screen changes never
	switch back to the "active" scene, so an animated away scene cannot
	cause the script to fight itself.

	Windows only. Input idle time is read from the Win32 function
	GetLastInputInfo through LuaJIT FFI, which the Lua interpreter
	bundled with OBS provides.
]]

obs = obslua

--------------------------------------------------------------------------
-- Settings

active_scene_name = ""
away_scene_name   = ""
poll_seconds      = 0.2
active_seconds    = 0.4
away_seconds      = 10
screen_compare    = true
screen_area       = "primary" -- "primary" or "all"
capture_seconds   = 1
hash_threshold    = 6

--------------------------------------------------------------------------
-- Runtime state

local ffi = nil

do
	local ok, mod = pcall(require, "ffi")
	if ok then
		ffi = mod
	end
end

if ffi ~= nil then
	ffi.cdef[[
		typedef struct { uint32_t cbSize; uint32_t dwTime; } LASTINPUTINFO;

		uint32_t GetTickCount(void);
		int GetLastInputInfo(LASTINPUTINFO *plii);

		int GetSystemMetrics(int index);
		void *GetDC(void *hwnd);
		int ReleaseDC(void *hwnd, void *hdc);

		typedef struct {
			uint32_t biSize;
			int32_t biWidth;
			int32_t biHeight;
			uint16_t biPlanes;
			uint16_t biBitCount;
			uint32_t biCompression;
			uint32_t biSizeImage;
			int32_t biXPelsPerMeter;
			int32_t biYPelsPerMeter;
			uint32_t biClrUsed;
			uint32_t biClrImportant;
		} BITMAPINFOHEADER;

		typedef struct {
			BITMAPINFOHEADER bmiHeader;
			uint32_t bmiColors[3];
		} BITMAPINFO;

		void *CreateCompatibleDC(void *hdc);
		int DeleteDC(void *hdc);
		void *CreateDIBSection(void *hdc, BITMAPINFO *pbmi, uint32_t usage, void **ppvBits, void *hSection, uint32_t offset);
		int DeleteObject(void *handle);
		void *SelectObject(void *hdc, void *obj);
		int StretchBlt(void *hdcDest, int32_t x, int32_t y, int32_t width, int32_t height, void *hdcSrc,
			int32_t src_x, int32_t src_y, int32_t src_width, int32_t src_height, uint32_t rop);
		int SetStretchBltMode(void *hdc, int32_t mode);
	]]
end

local user32          = nil
local kernel32        = nil
local gdi             = nil
local last_input_info = nil

local mode             = "unknown" -- "unknown" | "active" | "away"
local timer_added      = false
local input_error_seen = false
local warned_interval  = false
local warned_overlap   = false
local warned_capture   = false

-- GetTickCount() and LASTINPUTINFO.dwTime are 32-bit values and wrap
-- around every ~49.7 days.
local TICK_WRAP = 4294967296

-- Screen capture state
local capture_ready     = false
local capture_hdc       = nil
local capture_bitmap    = nil
local capture_old_bmp   = nil
local capture_px        = nil -- uint8_t* into the DIB section
local last_hash         = nil
local last_change_tick  = nil
local capture_countdown = 0
local capture_every     = 1
local capture_error_seen = false

--------------------------------------------------------------------------
-- Constants

local SRCCOPY = 0x00CC0020
local HALFTONE = 4

local SM_CXSCREEN        = 0
local SM_CYSCREEN        = 1
local SM_XVIRTUALSCREEN  = 76
local SM_YVIRTUALSCREEN  = 77
local SM_CXVIRTUALSCREEN = 78
local SM_CYVIRTUALSCREEN = 79

-- The screen is stretched into a 72x64 thumbnail which is divided into
-- 9x8 cells of 8x8 pixels. Per-cell luma feeds a 64 bit dHash (8 bit per
-- row, comparing neighboring cells).
local CAPTURE_CELLS_X = 9
local CAPTURE_CELLS_Y = 8
local CAPTURE_CELL_PX = 8
local CAPTURE_W = CAPTURE_CELLS_X * CAPTURE_CELL_PX
local CAPTURE_H = CAPTURE_CELLS_Y * CAPTURE_CELL_PX
local HASH_BITS = (CAPTURE_CELLS_X - 1) * CAPTURE_CELLS_Y

--------------------------------------------------------------------------
-- Helpers

local function clamp(value, min_value, max_value)
	if value < min_value then
		return min_value
	elseif value > max_value then
		return max_value
	end
	return value
end

-- Reads the system-wide input idle time in milliseconds and the current
-- tick, or nil when the system call fails.
local function read_idle_ms()
	if user32.GetLastInputInfo(last_input_info) == 0 then
		return nil
	end

	local now = tonumber(kernel32.GetTickCount())
	local last = tonumber(last_input_info.dwTime)

	-- The subtraction is done modulo 2^32 so the tick wraparound is
	-- handled correctly.
	return (now - last) % TICK_WRAP, now
end

local function current_scene_name()
	local scene = obs.obs_frontend_get_current_scene()
	if scene == nil then
		return nil
	end

	local name = obs.obs_source_get_name(scene)
	obs.obs_source_release(scene)

	return name
end

local function switch_to_scene(scene_name, state)
	-- state is "active" or "away" and is only used for logging
	if scene_name == nil or scene_name == "" then
		obs.script_log(obs.LOG_WARNING, "No " .. state .. " scene selected, skipping switch")
		return
	end

	local source = obs.obs_get_source_by_name(scene_name)
	if source == nil then
		obs.script_log(obs.LOG_WARNING, string.format(
			"Scene '%s' does not exist in the current scene collection, skipping switch to %s scene",
			scene_name, state))
		return
	end

	if obs.obs_source_get_id(source) ~= "scene" then
		obs.obs_source_release(source)
		obs.script_log(obs.LOG_WARNING, string.format(
			"Source '%s' is not a scene, skipping switch to %s scene", scene_name, state))
		return
	end

	if current_scene_name() == scene_name then
		obs.obs_source_release(source)
		obs.script_log(obs.LOG_INFO, string.format("Already on scene '%s', no switch needed", scene_name))
		return
	end

	obs.obs_frontend_set_current_scene(source)
	obs.obs_source_release(source)

	obs.script_log(obs.LOG_INFO, string.format("Switched to %s scene '%s'", state, scene_name))
end

--------------------------------------------------------------------------
-- Screen capture (GDI)

local function init_capture()
	if gdi == nil or ffi == nil then
		return false
	end

	local hdc = gdi.CreateCompatibleDC(nil)
	if hdc == nil then
		return false
	end

	local bmi = ffi.new("BITMAPINFO")
	bmi.bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
	bmi.bmiHeader.biWidth = CAPTURE_W
	bmi.bmiHeader.biHeight = -CAPTURE_H -- top-down bitmap
	bmi.bmiHeader.biPlanes = 1
	bmi.bmiHeader.biBitCount = 32
	bmi.bmiHeader.biCompression = 0 -- BI_RGB

	local bits_ptr = ffi.new("void *[1]")
	local bitmap = gdi.CreateDIBSection(hdc, bmi, 0, bits_ptr, nil, 0)
	if bitmap == nil then
		gdi.DeleteDC(hdc)
		return false
	end

	capture_hdc = hdc
	capture_bitmap = bitmap
	capture_old_bmp = gdi.SelectObject(hdc, bitmap)
	capture_px = ffi.cast("uint8_t *", bits_ptr[0])

	gdi.SetStretchBltMode(hdc, HALFTONE)

	return true
end

local function destroy_capture()
	if capture_hdc ~= nil then
		if capture_old_bmp ~= nil then
			gdi.SelectObject(capture_hdc, capture_old_bmp)
		end
		if capture_bitmap ~= nil then
			gdi.DeleteObject(capture_bitmap)
		end
		gdi.DeleteDC(capture_hdc)
	end

	capture_hdc = nil
	capture_bitmap = nil
	capture_old_bmp = nil
	capture_px = nil
end

-- Returns x, y, width, height of the area to capture, or nil.
local function screen_rect()
	if screen_area == "all" then
		local x = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
		local y = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
		local w = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
		local h = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
		if w > 0 and h > 0 then
			return x, y, w, h
		end
	end

	local w = user32.GetSystemMetrics(SM_CXSCREEN)
	local h = user32.GetSystemMetrics(SM_CYSCREEN)
	if w <= 0 or h <= 0 then
		return nil
	end

	return 0, 0, w, h
end

-- Captures the screen as a thumbnail and returns its dHash as a table of
-- HASH_BITS entries (0/1), or nil when the capture fails.
local function capture_hash()
	local x, y, w, h = screen_rect()
	if x == nil then
		return nil
	end

	local hdc_screen = user32.GetDC(nil)
	if hdc_screen == nil then
		return nil
	end

	local ok = gdi.StretchBlt(capture_hdc, 0, 0, CAPTURE_W, CAPTURE_H,
		hdc_screen, x, y, w, h, SRCCOPY)
	user32.ReleaseDC(nil, hdc_screen)

	if ok == 0 then
		return nil
	end

	local px = capture_px
	local luma = {}
	local index = 0

	for cell_y = 0, CAPTURE_CELLS_Y - 1 do
		for cell_x = 0, CAPTURE_CELLS_X - 1 do
			local sum = 0
			for py = 0, CAPTURE_CELL_PX - 1 do
				local row = ((cell_y * CAPTURE_CELL_PX + py) * CAPTURE_W + cell_x * CAPTURE_CELL_PX) * 4
				for pxx = 0, CAPTURE_CELL_PX - 1 do
					local offset = row + pxx * 4
					-- Luma-ish weights; only relative values are needed.
					sum = sum + px[offset + 2] * 77 + px[offset + 1] * 150 + px[offset] * 29
				end
			end
			index = index + 1
			luma[index] = sum
		end
	end

	local hash = {}
	local n = 0
	for cell_y = 0, CAPTURE_CELLS_Y - 1 do
		for cell_x = 0, CAPTURE_CELLS_X - 2 do
			n = n + 1
			if luma[cell_y * CAPTURE_CELLS_X + cell_x + 1] > luma[cell_y * CAPTURE_CELLS_X + cell_x + 2] then
				hash[n] = 1
			else
				hash[n] = 0
			end
		end
	end

	return hash
end

local function hash_distance(a, b)
	local d = 0
	for i = 1, HASH_BITS do
		if a[i] ~= b[i] then
			d = d + 1
		end
	end
	return d
end

--------------------------------------------------------------------------
-- State machine

local function tick()
	local idle_ms, now = read_idle_ms()
	if idle_ms == nil then
		if not input_error_seen then
			obs.script_log(obs.LOG_WARNING, "GetLastInputInfo failed, automatic switching is not working")
			input_error_seen = true
		end
		return
	end

	-- Screen comparisons run continuously while the script is not in the
	-- away state, so the "screen has been quiet" timer stays fresh at all
	-- times. Only the away state itself stops the comparisons.
	if screen_compare and capture_ready then
		if mode ~= "away" then
			capture_countdown = capture_countdown - 1
			if capture_countdown <= 0 then
				capture_countdown = capture_every

				local hash = nil
				local ok_capture, capture_result = pcall(capture_hash)
				if ok_capture then
					hash = capture_result
				else
					capture_ready = false
					obs.script_log(obs.LOG_WARNING,
						"Screen capture raised an error, screen change detection disabled: " .. tostring(capture_result))
				end

				if hash == nil then
					if capture_ready and not capture_error_seen then
						capture_error_seen = true
						obs.script_log(obs.LOG_WARNING, "Screen capture failed, screen change detection is not working")
					end
				else
					if last_hash ~= nil then
						local distance = hash_distance(last_hash, hash)
						local changed = distance >= hash_threshold
						obs.script_log(obs.LOG_INFO, string.format(
							"Screen compare: distance %d of %d (%s %d)",
							distance, HASH_BITS, changed and ">=" or "<", hash_threshold))

						if changed then
							last_change_tick = now
						end
					else
						obs.script_log(obs.LOG_INFO, "Screen compare: baseline captured")
					end

					last_hash = hash
				end
			end
		else
			-- Re-baseline after leaving the away state.
			last_hash = nil
			capture_countdown = 0
		end
	end

	if last_change_tick == nil then
		last_change_tick = now
	end

	-- Both states are derived from the input idle time; with screen
	-- comparison enabled, a changing screen also postpones the away state.
	local away_idle = idle_ms
	if screen_compare and capture_ready then
		local since_change = (now - last_change_tick) % TICK_WRAP
		if since_change < away_idle then
			away_idle = since_change
		end
	end

	local observed = nil
	if idle_ms < active_seconds * 1000 then
		observed = "active"
	elseif away_idle >= away_seconds * 1000 then
		observed = "away"
	end

	if observed == nil or observed == mode then
		return
	end

	-- The first state observed after loading only arms the state machine,
	-- scenes are switched from the next state change on.
	if mode ~= "unknown" then
		if observed == "active" then
			switch_to_scene(active_scene_name, "active")
		else
			switch_to_scene(away_scene_name, "away")
		end
	end

	mode = observed
end

local function stop_timer()
	if timer_added then
		obs.timer_remove(tick)
		timer_added = false
	end
end

local function start_timer()
	if user32 == nil then
		return
	end

	local interval_ms = math.floor(poll_seconds * 1000 + 0.5)
	if interval_ms < 50 then
		interval_ms = 50
	end

	obs.timer_add(tick, interval_ms)
	timer_added = true
end

local function apply_settings(settings)
	if settings == nil then
		return
	end

	active_scene_name = obs.obs_data_get_string(settings, "active_scene")
	away_scene_name   = obs.obs_data_get_string(settings, "away_scene")
	poll_seconds      = clamp(obs.obs_data_get_double(settings, "poll_seconds"), 0.05, 60)
	active_seconds    = clamp(obs.obs_data_get_double(settings, "active_seconds"), 0.05, 60)
	away_seconds      = clamp(obs.obs_data_get_double(settings, "away_seconds"), 1, 3600)
	screen_compare    = obs.obs_data_get_bool(settings, "screen_compare")
	screen_area       = obs.obs_data_get_string(settings, "screen_area")
	capture_seconds   = clamp(obs.obs_data_get_double(settings, "capture_seconds"), 0.5, 60)
	hash_threshold    = clamp(obs.obs_data_get_int(settings, "hash_threshold"), 1, 64)

	capture_every = math.max(1, math.floor(capture_seconds / poll_seconds + 0.5))
	capture_countdown = 0
	last_hash = nil

	if kernel32 ~= nil then
		last_change_tick = tonumber(kernel32.GetTickCount())
	end
end

-- Warns once when the settings combination can prevent or distort detection.
local function check_configuration()
	local interval_bad = poll_seconds >= active_seconds
	if interval_bad and not warned_interval then
		obs.script_log(obs.LOG_WARNING, string.format(
			"Check interval (%.2fs) is not shorter than the activity window (%.2fs); " ..
			"short inputs may be missed, lower the interval or raise the window",
			poll_seconds, active_seconds))
	end
	warned_interval = interval_bad

	local overlap_bad = active_seconds >= away_seconds
	if overlap_bad and not warned_overlap then
		obs.script_log(obs.LOG_WARNING, string.format(
			"Activity window (%.2fs) is not smaller than the idle time before away (%.2fs); " ..
			"the away threshold will be effectively the activity window",
			active_seconds, away_seconds))
	end
	warned_overlap = overlap_bad

	local capture_bad = screen_compare and not capture_ready
	if capture_bad and not warned_capture then
		obs.script_log(obs.LOG_WARNING,
			"Screen change detection is enabled but screen capture could not be initialized; it will be ignored")
	end
	warned_capture = capture_bad
end

--------------------------------------------------------------------------
-- OBS script callbacks

function script_description()
	return "Switches scenes based on system-wide mouse and keyboard activity.\n" ..
		"When input happened within the activity window, the \"active\" scene is shown. " ..
		"After no input for X seconds, the \"away\" scene is shown.\n" ..
		"Optionally, a changing screen prevents the \"away\" state (it never switches " ..
		"back to the active scene).\n" ..
		"Scenes are only switched on input state changes, manual scene switches are " ..
		"left alone until the next state change.\n\n" ..
		"Windows only. Game controllers are not counted as input."
end

function script_defaults(settings)
	obs.obs_data_set_default_double(settings, "poll_seconds", 0.2)
	obs.obs_data_set_default_double(settings, "active_seconds", 0.4)
	obs.obs_data_set_default_double(settings, "away_seconds", 10)
	obs.obs_data_set_default_bool(settings, "screen_compare", true)
	obs.obs_data_set_default_string(settings, "screen_area", "primary")
	obs.obs_data_set_default_double(settings, "capture_seconds", 1)
	obs.obs_data_set_default_int(settings, "hash_threshold", 6)
end

function script_properties()
	local props = obs.obs_properties_create()

	local active_list = obs.obs_properties_add_list(props, "active_scene",
		"Active scene (recent input)", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	local away_list = obs.obs_properties_add_list(props, "away_scene",
		"Away scene (no input)", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)

	local scene_names = obs.obs_frontend_get_scene_names()
	if scene_names ~= nil then
		for _, name in ipairs(scene_names) do
			obs.obs_property_list_add_string(active_list, name, name)
			obs.obs_property_list_add_string(away_list, name, name)
		end
	end

	obs.obs_properties_add_float(props, "poll_seconds", "Check interval (seconds)", 0.05, 60, 0.05)
	obs.obs_properties_add_float(props, "active_seconds", "Activity window (seconds)", 0.05, 60, 0.05)
	obs.obs_properties_add_float(props, "away_seconds", "Idle time before away (seconds)", 1, 3600, 1)

	obs.obs_properties_add_bool(props, "screen_compare", "Screen change detection (prevents the away state)")

	local area_list = obs.obs_properties_add_list(props, "screen_area", "Screen capture area",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(area_list, "Primary monitor", "primary")
	obs.obs_property_list_add_string(area_list, "All monitors", "all")

	obs.obs_properties_add_float(props, "capture_seconds", "Screen compare interval (seconds)", 0.5, 60, 0.5)
	obs.obs_properties_add_int(props, "hash_threshold", "Screen change threshold (bits of 64)", 1, 64, 1)

	obs.obs_properties_add_text(props, "note", "Scenes are only switched on input state " ..
		"changes; screen changes only prevent the away state. " ..
		"Game controllers are not counted as input.", obs.OBS_TEXT_INFO)

	return props
end

function script_update(settings)
	apply_settings(settings)

	stop_timer()
	start_timer()
	check_configuration()
end

function script_load(settings)
	if ffi == nil then
		obs.script_log(obs.LOG_WARNING, "LuaJIT FFI (require \"ffi\") is not available, script disabled")
		return
	end

	user32   = ffi.load("user32")
	kernel32 = ffi.load("kernel32")
	gdi      = ffi.load("gdi32")

	last_input_info = ffi.new("LASTINPUTINFO")
	last_input_info.cbSize = ffi.sizeof("LASTINPUTINFO")

	local ok_init, init_result = pcall(init_capture)
	if ok_init then
		capture_ready = init_result
	else
		capture_ready = false
		obs.script_log(obs.LOG_WARNING,
			"Screen capture initialization failed: " .. tostring(init_result))
	end

	apply_settings(settings)

	stop_timer()
	start_timer()
	check_configuration()

	local screen_state = "off"
	if screen_compare and capture_ready then
		screen_state = string.format("on (%s every %.1fs, threshold %d)",
			screen_area == "all" and "all monitors" or "primary monitor", capture_seconds, hash_threshold)
	end

	obs.script_log(obs.LOG_INFO, string.format(
		"Activity scene switching started: active='%s', away='%s', interval=%.2fs, window=%.2fs, idle=%.1fs, screen compare=%s",
		active_scene_name, away_scene_name, poll_seconds, active_seconds, away_seconds, screen_state))
end

function script_unload()
	stop_timer()
	destroy_capture()
end

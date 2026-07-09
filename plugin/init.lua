-- wezterm-synchronize-panes
-- ---------------------------------------------------------------------------
-- A WezTerm plugin that mimics tmux's `synchronize-panes`: while enabled, every
-- key you press in the active pane is mirrored to *all* panes in the active tab.
--
-- WezTerm exposes no generic "key pressed" event, so synchronization is
-- implemented with a key table that enumerates the keys to mirror. While the
-- table is active each binding writes the corresponding bytes to every pane in
-- the tab via `pane:send_text()` (this includes the active pane, so there is no
-- double input). Toggling the table off restores completely normal input.
--
-- Usage (in your wezterm.lua):
--   local wezterm = require("wezterm")
--   local config  = wezterm.config_builder()
--   local sync    = wezterm.plugin.require("https://github.com/annie444/sync-panes.wez")
--   sync.apply_to_config(config, {
--     toggle_key  = "E",
--     toggle_mods = "CTRL|SHIFT",
--   })
--   return config
--
-- ---------------------------------------------------------------------------
---@class SyncPanesConfig
---@field key_table_name string
---@field toggle_key string
---@field toggle_mods string
---@field indicator boolean
---@field status_text string
---@field indicator_color string
---@field backspace string
---@field border boolean
---@field border_color string

---@class SyncPanesConfigBuilder
---@field key_table_name string?
---@field toggle_key string?
---@field toggle_mods string?
---@field indicator boolean?
---@field status_text string?
---@field indicator_color string?
---@field backspace string?
---@field border boolean?
---@field border_color string?

---@type Wezterm
local wezterm = require("wezterm")
local act = wezterm.action

---@class SyncPanesPlugin
---@field _cfg SyncPanesConfig?
---@field _win_frame WindowFrameConfig?
---@field _split string?
---@field toggle { EmitEvent: string }
---@field is_synced fun(window: Window): boolean
---@field apply_to_config fun(config: Config, opts: SyncPanesConfigBuilder?): Config
local M = {}

-- M._cfg is populated by apply_to_config and read at runtime by the toggle
-- action and the status handler (both of which are created once at load time).
M._cfg = nil

-- M._win_frame is used to track the current window frame for status updates, so we
-- can trigger a refresh when the border color needs to change.
M._win_frame = nil

--- M._split is used to track the current split color for status updates, so we can
--- trigger a refresh when the border color needs to change.
M._split = nil

---@type SyncPanesConfig
local default_config = {
	-- Name of the generated key table.
	key_table_name = "sync_mode",
	-- Key + modifiers that toggle synchronization on/off. This combination must
	-- NOT be one of the mirrored keys (CTRL|SHIFT combos are never mirrored), so
	-- that it falls through to toggle even while the sync table is active.
	toggle_key = "E",
	toggle_mods = "CTRL|SHIFT",
	-- Show a right-status indicator while sync is active.
	indicator = false,
	status_text = "⟳ SYNC",
	indicator_color = "Red",
	-- Changed the boarder color of the panes while sync is active.
	border = false,
	border_color = "Red",
	-- Byte(s) sent for Backspace. 0x7f (DEL) is the common terminal default;
	-- set to "\8" if your environment expects ^H.
	backspace = "\127",
}

-- ---------------------------------------------------------------------------
-- Per-GUI-window enabled state, persisted in wezterm.GLOBAL so it survives
-- config reloads. Keyed by stringified window id.
-- ---------------------------------------------------------------------------

---@return table<string, boolean>
local function get_state()
	return wezterm.GLOBAL.synchronize_panes or {} --[[@as table<string, boolean>]]
end

---@param window_id integer|string
---@return boolean
local function is_enabled(window_id)
	return get_state()[tostring(window_id)] == true
end

---@param window_id integer|string
---@param on boolean
local function set_enabled(window_id, on)
	local s = get_state()
	s[tostring(window_id)] = on or nil
	-- Reassign the whole table so the GLOBAL proxy persists the change.
	wezterm.GLOBAL.synchronize_panes = s
end

-- ---------------------------------------------------------------------------
-- Broadcasting
-- ---------------------------------------------------------------------------

-- Returns an action that writes `text` to every pane in the active tab.
---@param text string
---@return { EmitEvent: string }
local function broadcast(text)
	return wezterm.action_callback(function(window, _)
		local tab = window:active_tab()
		if not tab then
			return
		end
		for _, p in ipairs(tab:panes()) do
			p:send_text(text)
		end
	end)
end

---@param source ClipboardPasteDestination
local function broadcast_paste(source)
	return wezterm.action_callback(function(window, _)
		local tab = window:active_tab()
		if not tab then
			return
		end
		for _, p in ipairs(tab:panes()) do
			window:perform_action(act.PasteFrom(source), p)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Key table generation
-- ---------------------------------------------------------------------------

---@param cfg SyncPanesConfig
---@param keys Key[]
---@return Key[]
local function build_key_table(cfg, keys)
	---@type Key[]
	local t = {}

	---@param key string
	---@param mods string?
	---@param text string
	local function add(key, mods, text)
		t[#t + 1] = { key = key, mods = mods, action = broadcast(text) }
	end

	-- Printable ASCII (space .. '~'). With the default key_map_preference of
	-- "Mapped", we match on the literal produced character ("A", "!", "%", ...).
	--
	-- A SHIFT-modified binding is added ONLY for glyphs that require shift to type
	-- on a US layout (uppercase letters + shifted punctuation) -- those can appear
	-- with SHIFT still attached to the mapped character. A base glyph must NOT get
	-- one: SHIFT+";" is ":", never ";", so add(";", "SHIFT", ";") describes a
	-- keystroke that doesn't exist and it shadows the real ":" binding.
	local needs_shift = {}
	for c in ('!@#$%^&*()_+{}|:"<>?~'):gmatch(".") do
		needs_shift[c] = true
	end
	for code = 0x20, 0x7e do
		local ch = string.char(code)
		add(ch, nil, ch)
		if needs_shift[ch] or (code >= 0x41 and code <= 0x5a) then
			add(ch, "SHIFT", ch)
		end
	end

	-- Named keys outside the printable range.
	add("Space", nil, " ")
	add("Tab", nil, "\t")
	add("Tab", "SHIFT", "\27[Z") -- back-tab
	add("Enter", nil, "\r")
	add("Escape", nil, "\27")
	add("Backspace", nil, cfg.backspace)

	-- Ctrl + <letter>  ->  control byte 0x01 .. 0x1a (Ctrl+C interrupts all, etc.)
	for code = string.byte("a"), string.byte("z") do
		add(string.char(code), "CTRL", string.char(code - 0x60))
	end
	add(" ", "CTRL", "\0") -- Ctrl+Space -> NUL

	-- Alt/Meta + <letter>  ->  ESC-prefixed (readline meta bindings).
	for code = string.byte("a"), string.byte("z") do
		-- selene: allow(shadowing)
		local ch = string.char(code)
		add(ch, "ALT", "\27" .. ch)
	end

	-- Cursor / navigation keys. These are the *normal* (not application) cursor
	-- mode CSI sequences -- see the caveat in the README about app cursor mode.
	add("UpArrow", nil, "\27[A")
	add("DownArrow", nil, "\27[B")
	add("RightArrow", nil, "\27[C")
	add("LeftArrow", nil, "\27[D")
	add("Home", nil, "\27[H")
	add("End", nil, "\27[F")
	add("PageUp", nil, "\27[5~")
	add("PageDown", nil, "\27[6~")
	add("Insert", nil, "\27[2~")
	add("Delete", nil, "\27[3~")

	-- Function keys F1..F12 (xterm sequences).
	local fkeys = {
		F1 = "\27OP",
		F2 = "\27OQ",
		F3 = "\27OR",
		F4 = "\27OS",
		F5 = "\27[15~",
		F6 = "\27[17~",
		F7 = "\27[18~",
		F8 = "\27[19~",
		F9 = "\27[20~",
		F10 = "\27[21~",
		F11 = "\27[23~",
		F12 = "\27[24~",
	}
	for k, seq in pairs(fkeys) do
		add(k, nil, seq)
	end

	--- Track which of the default clipboard-related bindings are overridden by
	--- the user's config, so we can avoid overriding them with our own
	--- broadcast versions.
	---@type table<string, boolean>
	local default_clips_override = {
		super_c = true,
		super_v = true,
		ctrlsh_c = true,
		ctrlsh_v = true,
		Copy = true,
		Paste = true,
		ctrl_Insert = true,
		sh_Insert = true,
	}

	---@type table<string, Key>
	local clips_keys = {
		super_c = { key = "c", mods = "SUPER", action = act.CopyTo("Clipboard") },
		super_v = { key = "v", mods = "SUPER", action = broadcast_paste("Clipboard") },
		ctrlsh_c = { key = "c", mods = "CTRL|SHIFT", action = act.CopyTo("Clipboard") },
		ctrlsh_v = { key = "v", mods = "CTRL|SHIFT", action = broadcast_paste("Clipboard") },
		Copy = { key = "Copy", action = act.CopyTo("Clipboard") },
		Paste = { key = "Paste", action = broadcast_paste("Clipboard") },
		ctrl_Insert = { key = "Insert", mods = "CTRL", action = act.CopyTo("PrimarySelection") },
		sh_Insert = { key = "Insert", mods = "SHIFT", action = broadcast_paste("PrimarySelection") },
	}

	--- Lookup tables for keys that trigger clipboard actions, so we can detect when
	--- the user has overridden them in their config and avoid adding our own bindings
	--- that would conflict.
	local c_keys = {
		["c"] = true,
		["C"] = true,
		["mapped:c"] = true,
		["mapped:C"] = true,
		["phys:c"] = true,
		["phys:C"] = true,
		["raw:c"] = true,
		["raw:C"] = true,
	}
	local v_keys = {
		["v"] = true,
		["V"] = true,
		["mapped:v"] = true,
		["mapped:V"] = true,
		["phys:v"] = true,
		["phys:V"] = true,
		["raw:v"] = true,
		["raw:V"] = true,
	}
	local ctrlsh_keys = {
		["CTRL|SHIFT"] = true,
		["SHIFT|CTRL"] = true,
	}

	for _, k in ipairs(keys) do
		if k.action["PasteFrom"] ~= nil then
			-- Capture PasteFrom bindings to mirror the paste action, rather than the literal
			-- chars sent by the source key (e.g. Ctrl+Shift+V). This allows users to maintain a single
			-- paste binding in their config and have it work both inside and outside of synchronize-panes mode,
			-- without having to worry about the underlying byte sequences or key combinations.
			t[#t + 1] = { key = k.key, mods = k.mods, action = broadcast_paste(k.action.PasteFrom) }
		elseif k.action["CopyTo"] ~= nil then
			-- Allow passthrough of existing CopyTo bindings, which are common in
			-- user configs and should not be mirrored.
			t[#t + 1] = { key = k.key, mods = k.mods, action = act.CopyTo(k.action.CopyTo) }
		elseif c_keys[k.key] and k.mods == "SUPER" then
			default_clips_override.super_c = false
			t[#t + 1] = k
		elseif v_keys[k.key] and k.mods == "SUPER" then
			default_clips_override.super_v = false
			t[#t + 1] = k
		elseif c_keys[k.key] and ctrlsh_keys[k.mods] then
			default_clips_override.ctrlsh_c = false
			t[#t + 1] = k
		elseif v_keys[k.key] and ctrlsh_keys[k.mods] then
			default_clips_override.ctrlsh_v = false
			t[#t + 1] = k
		elseif k.key == "Copy" and (k.mods == nil or k.mods == "") then
			default_clips_override.Copy = false
			t[#t + 1] = k
		elseif k.key == "Paste" and (k.mods == nil or k.mods == "") then
			default_clips_override.Paste = false
			t[#t + 1] = k
		elseif k.key == "Insert" and k.mods == "CTRL" then
			default_clips_override.ctrl_Insert = false
			t[#t + 1] = k
		elseif k.key == "Insert" and k.mods == "SHIFT" then
			default_clips_override.sh_Insert = false
			t[#t + 1] = k
		end
	end

	for type, enabled in pairs(default_clips_override) do
		if enabled then
			t[#t + 1] = clips_keys[type]
		end
	end

	return t
end

-- ---------------------------------------------------------------------------
-- Status indicators
-- ---------------------------------------------------------------------------

---@param window Window
local function update_status_bar(window)
	local cfg = M._cfg
	if not cfg or not cfg.indicator then
		return
	end
	if is_enabled(window:window_id()) then
		window:set_right_status(wezterm.format({
			{ Foreground = { AnsiColor = cfg.indicator_color or "#ab4444" } },
			---@diagnostic disable-next-line: missing-fields
			{ Attribute = { Intensity = "Bold" } },
			{ Text = " " .. cfg.status_text .. " " },
		}))
	end
end

---@param window Window
local function update_status_border(window)
	local cfg = M._cfg
	if not cfg or not cfg.border then
		return
	end
	if is_enabled(window:window_id()) then
		local run_cfg = window:effective_config()
		M._win_frame = run_cfg.window_frame or {}
		local colors = run_cfg.colors or {}
		M._split = colors.split or ""
		window:set_config_overrides({
			colors = {
				split = cfg.border_color or "#ab4444",
			},
			window_frame = {
				border_left_color = cfg.border_color or "#ab4444",
				border_right_color = cfg.border_color or "#ab4444",
				border_bottom_color = cfg.border_color or "#ab4444",
				border_top_color = cfg.border_color or "#ab4444",
				border_left_width = M._win_frame.border_left_width or "0.5cell",
				border_right_width = M._win_frame.border_right_width or "0.5cell",
				border_bottom_height = M._win_frame.border_bottom_height or "0.25cell",
				border_top_height = M._win_frame.border_top_height or "0.25cell",
			},
		})
	else
		window:set_config_overrides({
			colors = {
				split = M._split,
			},
			window_frame = M._win_frame,
		})
	end
end

-- ---------------------------------------------------------------------------
-- Public actions / helpers
-- ---------------------------------------------------------------------------

-- Toggle synchronization for the current GUI window.
M.toggle = wezterm.action_callback(function(window, pane)
	local cfg = M._cfg or default_config
	local id = window:window_id()
	local now_on = not is_enabled(id)
	set_enabled(id, now_on)

	if now_on then
		window:perform_action(
			act.ActivateKeyTable({
				name = cfg.key_table_name,
				one_shot = false,
				until_unknown = false,
				prevent_fallback = false,
			}),
			pane
		)
		update_status_bar(window)
		update_status_border(window)
	else
		window:perform_action("PopKeyTable", pane)
		update_status_border(window)
	end

	wezterm.emit("update-status", window, pane)
end)

-- True if sync is currently enabled for the given GUI window. Useful for
-- composing your own status bar when indicator = false.
---@param window Window
---@return boolean
function M.is_synced(window)
	return is_enabled(window:window_id())
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- Registered once at module load time (the plugin module is cached, so this
-- does not accumulate duplicate handlers across config reloads).
wezterm.on("update-status", function(window, _)
	update_status_bar(window)
end)

---@param config Config
---@param opts SyncPanesConfigBuilder?
---@return Config
function M.apply_to_config(config, opts)
	---@cast opts SyncPanesConfigBuilder
	opts = opts or {}
	---@type SyncPanesConfigBuilder
	local cfg = {}
	for k, v in pairs(default_config) do
		cfg[k] = v
	end
	for k, v in pairs(opts) do
		cfg[k] = v
	end
	---@cast cfg SyncPanesConfig
	M._cfg = cfg

	config.key_tables = config.key_tables or {}
	config.keys = config.keys or {}
	config.key_tables[cfg.key_table_name] = build_key_table(cfg, config.keys)

	table.insert(config.keys, {
		key = cfg.toggle_key,
		mods = cfg.toggle_mods,
		action = M.toggle,
	})

	return config
end

return M

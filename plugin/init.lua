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
--   local sync    = wezterm.plugin.require("https://github.com/<you>/wezterm-synchronize-panes")
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
---@field indicator_ansi_color string
---@field backspace string

---@class SyncPanesConfigBuilder
---@field key_table_name string|nil
---@field toggle_key string|nil
---@field toggle_mods string|nil
---@field indicator boolean|nil
---@field status_text string|nil
---@field indicator_ansi_color string|nil
---@field backspace string|nil

---@type Wezterm
local wezterm = require("wezterm")
local act = wezterm.action

---@class SyncPanesPlugin
---@field _cfg SyncPanesConfig|nil
---@field toggle { EmitEvent: string }
---@field is_synced fun(window: Window): boolean
---@field apply_to_config fun(config: Config, opts: SyncPanesConfigBuilder|nil): Config
local M = {}

-- M._cfg is populated by apply_to_config and read at runtime by the toggle
-- action and the status handler (both of which are created once at load time).
M._cfg = nil

---@type SyncPanesConfig
local default_config = {
	-- Name of the generated key table.
	key_table_name = "synchronize_panes",
	-- Key + modifiers that toggle synchronization on/off. This combination must
	-- NOT be one of the mirrored keys (CTRL|SHIFT combos are never mirrored), so
	-- that it falls through to toggle even while the sync table is active.
	toggle_key = "E",
	toggle_mods = "CTRL|SHIFT",
	-- Show a right-status indicator while sync is active. Set to false if you
	-- maintain your own status bar (then use M.is_synced(window) to integrate).
	indicator = true,
	status_text = "⟳ SYNC",
	indicator_ansi_color = "Red",
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

-- ---------------------------------------------------------------------------
-- Key table generation
-- ---------------------------------------------------------------------------

---@class SyncPanesKeyBinding
---@field key string
---@field mods string|nil
---@field action { EmitEvent: string }

---@param cfg SyncPanesConfig
---@return SyncPanesKeyBinding[]
local function build_key_table(cfg)
	---@type SyncPanesKeyBinding[]
	local t = {}

	---@param key string
	---@param mods string|nil
	---@param text string
	local function add(key, mods, text)
		t[#t + 1] = { key = key, mods = mods, action = broadcast(text) }
	end

	-- Printable ASCII (space .. '~'). With the default key_map_preference of
	-- "Mapped", SHIFT is consumed by producing the character, so we match on the
	-- literal produced character with no modifiers ("A", "!", "%", ...).
	for code = 0x20, 0x7e do
		local ch = string.char(code)
		add(ch, nil, ch)
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

	return t
end

-- ---------------------------------------------------------------------------
-- Status indicator
-- ---------------------------------------------------------------------------

---@param window Window
local function update_status(window)
	local cfg = M._cfg
	if not cfg or not cfg.indicator then
		return
	end
	if is_enabled(window:window_id()) then
		window:set_right_status(wezterm.format({
			{ Foreground = { AnsiColor = cfg.indicator_ansi_color or "Red" } },
			{ Attribute = { Intensity = "Bold" } },
			{ Text = " " .. cfg.status_text .. " " },
		}))
	else
		window:set_right_status("")
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
	else
		window:perform_action("PopKeyTable", pane)
	end

	update_status(window)
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
	update_status(window)
end)

---@param config Config
---@param opts SyncPanesConfigBuilder|nil
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
	config.key_tables[cfg.key_table_name] = build_key_table(cfg)

	config.keys = config.keys or {}
	table.insert(config.keys, {
		key = cfg.toggle_key,
		mods = cfg.toggle_mods,
		action = M.toggle,
	})

	return config
end

return M

-- ---------------------------------------------------------------------------
-- A fake `wezterm` module plus pane/tab/window test doubles, just faithful
-- enough to drive plugin/init.lua under plain Lua 5.4 + busted.
--
-- The plugin only touches WezTerm through a tiny surface, so we model exactly
-- that surface and nothing more:
--
--   wezterm.action.PasteFrom(x)  -> { PasteFrom = x }   (shape the plugin reads)
--   wezterm.action.CopyTo(x)     -> { CopyTo = x }
--   wezterm.action_callback(fn)  -> { __callback = fn } (so tests can invoke fn)
--   wezterm.GLOBAL               -> a plain table (per-window enabled state)
--   wezterm.on / emit / format   -> no-ops that record just enough to assert on
--
-- The `{ __callback = fn }` shape is the key trick: a broadcast binding's action
-- carries the real closure, so a test can call `binding.action.__callback(win, pane)`
-- and then inspect what each pane received -- exercising the runtime broadcast
-- without a GUI.
-- ---------------------------------------------------------------------------

local M = {}

-- A pane records every send_text() so tests can assert the broadcast bytes.
---@return table
function M.make_pane()
	local pane = { sent = {} }
	function pane:send_text(text)
		self.sent[#self.sent + 1] = text
	end

	return pane
end

-- A window owns one active tab containing `panes`, and records perform_action
-- calls (used by the clipboard paste broadcast and the toggle action).
---@param panes table[]
---@param id integer|nil
---@return table
function M.make_window(panes, id)
	local tab = {
		panes = function()
			return panes
		end,
	}
	local window = {
		id = id or 1,
		performed = {}, -- list of { action = ..., pane = ... }
		right_status = nil,
	}
	function window:active_tab()
		return tab
	end

	function window:window_id()
		return self.id
	end

	function window:perform_action(action, pane)
		self.performed[#self.performed + 1] = { action = action, pane = pane }
	end

	function window:set_right_status(text)
		self.right_status = text
	end

	return window
end

-- Build a fresh fake `wezterm` module. Fresh per test => fresh GLOBAL state, so
-- enabled/disabled state never leaks between specs.
---@return table
function M.new_wezterm()
	local wezterm = {
		GLOBAL = {},
		_events = {}, -- event name -> list of handlers (recorded, not dispatched)
		_emitted = {}, -- list of emitted event names
	}

	wezterm.action = {
		PasteFrom = function(x)
			return { PasteFrom = x }
		end,
		CopyTo = function(x)
			return { CopyTo = x }
		end,
		ActivateKeyTable = function(opts)
			return { ActivateKeyTable = opts }
		end,
	}

	function wezterm.action_callback(fn)
		return { __callback = fn }
	end

	function wezterm.on(event, handler)
		local list = wezterm._events[event] or {}
		list[#list + 1] = handler
		wezterm._events[event] = list
	end

	function wezterm.emit(event)
		wezterm._emitted[#wezterm._emitted + 1] = event
	end

	-- Real wezterm.format takes a list of formatting directives and returns a
	-- string; we just stringify any { Text = ... } items so update_status works.
	function wezterm.format(items)
		local parts = {}
		for _, item in ipairs(items) do
			if type(item) == "table" and item.Text then
				parts[#parts + 1] = item.Text
			end
		end
		return table.concat(parts)
	end

	return wezterm
end

-- Load a fresh copy of the plugin with a fresh fake wezterm injected.
-- Returns (plugin_module, wezterm_mock). dofile re-executes init.lua every call,
-- and seeding package.loaded["wezterm"] makes its require() resolve to our mock.
---@return table plugin, table wezterm
function M.load_plugin()
	local wezterm = M.new_wezterm()
	package.loaded["wezterm"] = wezterm
	local plugin = dofile("plugin/init.lua")
	return plugin, wezterm
end

-- Find the first binding in a key table matching key (+ optional mods).
---@param key_table table[]
---@param key string
---@param mods string|nil
---@return table|nil
function M.find_binding(key_table, key, mods)
	for _, b in ipairs(key_table) do
		if b.key == key and b.mods == mods then
			return b
		end
	end
	return nil
end

return M

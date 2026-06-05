-- Unit tests for plugin/init.lua, driven entirely through the public API
-- (apply_to_config / toggle / is_synced) with a fake wezterm injected.
-- See spec/mock_wezterm.lua for the test doubles.

local mock = require("spec.mock_wezterm")

-- Name of the key table the plugin generates (matches default_config).
local KT = "synchronize_panes"

describe("sync-panes.wez", function()
	describe("apply_to_config", function()
		it("registers the toggle key on config.keys", function()
			local plugin = mock.load_plugin()
			local config = { keys = {}, key_tables = {} }
			plugin.apply_to_config(config)

			local toggle = mock.find_binding(config.keys, "E", "CTRL|SHIFT")
			assert.is_not_nil(toggle)
			assert.equal(plugin.toggle, toggle.action)
		end)

		it("honors custom toggle_key / toggle_mods", function()
			local plugin = mock.load_plugin()
			local config = { keys = {}, key_tables = {} }
			plugin.apply_to_config(config, { toggle_key = "S", toggle_mods = "CTRL|ALT" })

			assert.is_not_nil(mock.find_binding(config.keys, "S", "CTRL|ALT"))
		end)

		it("builds a key table under the configured name", function()
			local plugin = mock.load_plugin()
			local config = { keys = {}, key_tables = {} }
			plugin.apply_to_config(config)

			assert.is_table(config.key_tables[KT])
			assert.is_true(#config.key_tables[KT] > 0)
		end)
	end)

	describe("broadcasting", function()
		-- Helper: build the key table with no pre-existing user keys.
		local function key_table()
			local plugin = mock.load_plugin()
			local config = { keys = {}, key_tables = {} }
			plugin.apply_to_config(config)
			return config.key_tables[KT]
		end

		it("mirrors a printable key to every pane in the tab", function()
			local b = mock.find_binding(key_table(), "A", nil)
			assert.is_not_nil(b)

			local panes = { mock.make_pane(), mock.make_pane(), mock.make_pane() }
			b.action.__callback(mock.make_window(panes), panes[1])

			for _, p in ipairs(panes) do
				assert.same({ "A" }, p.sent)
			end
		end)

		it("sends the control byte for Ctrl+<letter>", function()
			-- Ctrl+C must interrupt all panes at once -> 0x03.
			local b = mock.find_binding(key_table(), "c", "CTRL")
			assert.is_not_nil(b)

			local panes = { mock.make_pane(), mock.make_pane() }
			b.action.__callback(mock.make_window(panes), panes[1])

			for _, p in ipairs(panes) do
				assert.same({ "\3" }, p.sent)
			end
		end)

		it("does nothing gracefully when there is no active tab", function()
			local b = mock.find_binding(key_table(), "A", nil)
			local window = {
				active_tab = function()
					return nil
				end,
			}
			assert.has_no.errors(function()
				b.action.__callback(window, nil)
			end)
		end)
	end)

	describe("clipboard handling", function()
		it("mirrors a user PasteFrom binding as a broadcast paste", function()
			-- Use CTRL|SHIFT so the fixture doesn't collide with the auto-generated
			-- printable / Ctrl+<letter> bindings that exist for every letter.
			local plugin, wezterm = mock.load_plugin()
			local config = {
				key_tables = {},
				keys = {
					{
						key = "v",
						mods = "CTRL|SHIFT",
						action = wezterm.action.PasteFrom("PrimarySelection"),
					},
				},
			}
			plugin.apply_to_config(config)

			local b = mock.find_binding(config.key_tables[KT], "v", "CTRL|SHIFT")
			assert.is_not_nil(b)

			-- Invoking it should perform a PasteFrom on each pane.
			local panes = { mock.make_pane(), mock.make_pane() }
			local window = mock.make_window(panes)
			b.action.__callback(window, panes[1])

			assert.equal(2, #window.performed)
			assert.same({ PasteFrom = "PrimarySelection" }, window.performed[1].action)
		end)

		it("passes a user CopyTo binding through unmirrored", function()
			local plugin, wezterm = mock.load_plugin()
			local config = {
				key_tables = {},
				keys = {
					{ key = "x", mods = "CTRL|SHIFT", action = wezterm.action.CopyTo("Clipboard") },
				},
			}
			plugin.apply_to_config(config)

			local b = mock.find_binding(config.key_tables[KT], "x", "CTRL|SHIFT")
			assert.is_not_nil(b)
			-- CopyTo is passed straight through (not wrapped in a broadcast callback).
			assert.same({ CopyTo = "Clipboard" }, b.action)
		end)

		it("does not override a user-customized SUPER+c binding", function()
			local plugin = mock.load_plugin()
			local action = { EmitEvent = "not-copy" }
			local config = {
				key_tables = {},
				keys = {
					{ key = "c", mods = "SUPER", action = { EmitEvent = "not-copy" } },
				},
			}
			plugin.apply_to_config(config)
			local b = mock.find_binding(config.key_tables[KT], "c", "SUPER")
			assert.is_nil(b)
		end)
	end)

	describe("toggle / is_synced", function()
		it("flips per-window sync state through wezterm.GLOBAL", function()
			local plugin = mock.load_plugin()
			local config = { keys = {}, key_tables = {} }
			plugin.apply_to_config(config)

			local window = mock.make_window({ mock.make_pane() }, 42)
			assert.is_false(plugin.is_synced(window))

			plugin.toggle.__callback(window, mock.make_pane())
			assert.is_true(plugin.is_synced(window))

			plugin.toggle.__callback(window, mock.make_pane())
			assert.is_false(plugin.is_synced(window))
		end)

		it("activates the key table when toggled on", function()
			local plugin = mock.load_plugin()
			local config = { keys = {}, key_tables = {} }
			plugin.apply_to_config(config)

			local window = mock.make_window({ mock.make_pane() }, 7)
			plugin.toggle.__callback(window, mock.make_pane())

			assert.equal(1, #window.performed)
			assert.equal(KT, window.performed[1].action.ActivateKeyTable.name)
		end)
	end)
end)

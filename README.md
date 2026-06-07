# sync-panes.wez

A [WezTerm](https://wezterm.org/) plugin that mirrors your keystrokes to **every
pane in the active tab** — the equivalent of tmux's `synchronize-panes`. Toggle
it on, type once, and the same input lands in all panes at the same time.

## Features

- **One-key toggle** — turn synchronization on/off per GUI window (default
  `CTRL+SHIFT+E`).
- **Status indicator** — an optional `⟳ SYNC` badge in the right status bar
  while sync is active.
- **Border highlight** — optionally recolor the window border _and_ pane split
  lines while sync is active for a second, hard-to-miss visual cue.
- **Broadcasts everything you'd expect** — printable characters, `Ctrl`/`Alt`
  combinations, `Enter`/`Tab`/`Backspace`/`Escape`, arrow & navigation keys, and
  `F1`–`F12`.
- **Survives config reloads** — enabled state is stored in `wezterm.GLOBAL`, so
  reloading your config won't drop you out of sync mode.
- **Configurable** — change the toggle key, key-table name, indicator text and
  color, the border highlight color, and the Backspace byte.

## Requirements

A recent version of WezTerm — any build that includes the `wezterm.plugin` API.

## Installation

WezTerm plugins are loaded straight from a git URL. Add this to your
`wezterm.lua`:

```lua
local sync = wezterm.plugin.require("https://github.com/annie444/sync-panes.wez")
```

WezTerm clones and caches the plugin automatically on next launch.

## Quick start

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local sync = wezterm.plugin.require("https://github.com/annie444/sync-panes.wez")
sync.apply_to_config(config)

return config
```

That's it. Press **`CTRL+SHIFT+E`** to toggle synchronization for the current
window. While it's on, the `⟳ SYNC` indicator appears at the right of the status
bar and every key you type is sent to all panes in the tab.

## Configuration

Pass an options table as the second argument to `apply_to_config`. Every field
is optional and falls back to the default below.

| Option                 | Default               | Description                                                                                   |
| ---------------------- | --------------------- | --------------------------------------------------------------------------------------------- |
| `key_table_name`       | `"synchronize_panes"` | Name of the key table the plugin generates.                                                   |
| `toggle_key`           | `"E"`                 | Key that toggles synchronization.                                                             |
| `toggle_mods`          | `"CTRL\|SHIFT"`       | Modifiers for the toggle key. Must not collide with a mirrored key (see [Caveats](#caveats)). |
| `indicator`            | `true`                | Show the right-status indicator while sync is active. Set `false` to manage it yourself.      |
| `status_text`          | `"⟳ SYNC"`            | Text shown in the indicator.                                                                  |
| `indicator_color`      | `"Red"`               | Color for the indicator text (ANSI color name or `#rrggbb` hex).                              |
| `border`               | `false`               | Recolor the window border and pane splits while sync is active. Set `true` to enable.         |
| `border_color`         | `"Red"`               | Color for the border and pane splits while sync is active (used when `border = true`).        |
| `backspace`            | `"\127"`              | Byte(s) sent for Backspace. `0x7f` (DEL) is the common default; use `"\8"` for `^H`.          |

### Example

```lua
sync.apply_to_config(config, {
  toggle_key = "S",
  toggle_mods = "CTRL|SHIFT",
  status_text = "BROADCAST",
  indicator_color = "Yellow",
  border = true,
  border_color = "Yellow",
})
```

## Usage

- Press the toggle key (default `CTRL+SHIFT+E`) to start or stop synchronizing.
- Synchronization is **per GUI window** — toggling one window doesn't affect
  another.
- While active, anything you type is sent to every pane in the active tab,
  including the pane you're typing in (so there's no double input).
- Control sequences are broadcast too: pressing **`Ctrl+C`** while synced sends
  an interrupt to _all_ panes at once.

## API

`apply_to_config` is all most setups need, but the plugin also exposes helpers
for custom integrations.

### `sync.apply_to_config(config, opts?)`

Registers the key table and binds the toggle key. Returns the modified `config`.

### `sync.is_synced(window)`

Returns `true` if synchronization is currently enabled for the given GUI window.
Useful for composing your own status bar when you set `indicator = false`:

```lua
sync.apply_to_config(config, { indicator = false })

wezterm.on("update-status", function(window, _)
  if sync.is_synced(window) then
    window:set_right_status(" SYNC ")
  else
    window:set_right_status("")
  end
end)
```

### `sync.toggle`

The toggle action itself. Bind it to an additional key if you'd like more than
one way to switch sync on and off:

```lua
table.insert(config.keys, {
  key = "F5",
  action = sync.toggle,
})
```

## Caveats

- **Toggle key must not be a mirrored key.** The key that toggles sync has to
  fall _through_ the active key table rather than being broadcast. `CTRL|SHIFT`
  combinations are never mirrored, which is why the default `CTRL+SHIFT+E` works.
  If you pick a different combination, make sure it isn't one of the broadcast
  keys.
- **Arrow keys use normal cursor mode.** Navigation keys are sent as
  _normal_-mode (not application-mode) cursor sequences. Full-screen TUIs that
  switch the terminal into application cursor mode may receive different bytes
  than they expect for the arrow keys.
- **Backspace defaults to DEL (`0x7f`).** This matches the behavior of the latest
  WezTerm release. If you're running an older version, set `backspace = "\8"`.

## License

[MIT](./LICENSE)

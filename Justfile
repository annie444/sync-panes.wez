lua_version := "5.4"
luarocks_version := "latest"
lua_env_path := "lua" + replace(lua_version, ".", "")
hererocks_flags := if env("DEBUG", "0") == "1" { "--verbose" } else { "" }

debug := '''
set -Eeuo pipefail
if [[ -z "${DEBUG:-}" && "${DEBUG:-}" -eq 1 ]]; then
  set -x
fi
'''

[default]
[private]
default:
    @just --list

[group('Development')]
install-tools:
    #!/usr/bin/env bash
    {{ debug }}
    if command -v uv &>/dev/null; then
        install_cmd=("uv" "tool" "install")
    elif command -v pipx &>/dev/null; then
        install_cmd=("pipx" "install")
    elif command -v pip3 &>/dev/null; then
        install_cmd=("pip3" "install" "--user")
    elif command -v python3 &>/dev/null; then
        install_cmd=("python3" "-m" "pip" "install" "--user")
    else
        echo "No python package manager present. Hererocks requires python. Please install python with pip, pipx, or uv." >&2
    fi
    if ! command -v hererocks &>/dev/null; then
        "${install_cmd[@]}" hererocks
    fi
    if ! command -v pre-commit &>/dev/null; then
        "${install_cmd[@]}" pre-commit
    fi
    if [[ ! -f ".git/hooks/commit-msg" || ! -f ".git/hooks/pre-commit" ]]; then
        pre-commit install --install-hooks
    fi
    if [[ ! -d "{{ lua_env_path }}" ]]; then
        hererocks {{ lua_env_path }} --lua="{{ lua_version }}" --luarocks="{{ luarocks_version }}" {{ hererocks_flags }}
    fi
    source {{ lua_env_path }}/bin/activate
    luarocks install wezterm-types
    luarocks install busted
    if command -v cargo &>/dev/null; then
        if command -v cargo-binstall &>/dev/null; then
            cargo binstall selene
        else
            cargo install selene
        fi
        cargo install stylua --features lua54
    else
        echo "Cargo not found. Please install Rust and Cargo to install stylua." >&2
    fi

[group('Development')]
[parallel]
lint: _run_selene _run_stylua_check

_run_selene:
    selene plugin/

_run_stylua_check:
    stylua --check .

[group('Development')]
fmt:
    stylua .

[group('Development')]
test:
    #!/usr/bin/env bash
    source {{ lua_env_path }}/bin/activate
    busted

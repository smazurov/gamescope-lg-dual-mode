#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Stepan Mazurov
# Installs one Lua file. Never installs packages or changes display settings.
set -euo pipefail
script_path=${BASH_SOURCE[0]:-}
source_file=''
if [[ -n "$script_path" && -f "$script_path" ]]; then
    root=$(cd -- "$(dirname -- "$script_path")" && pwd -P)
    source_file=$root/gamescope-lg-dual-mode.lua
fi
# Each released installer fetches its payload from this exact release, not latest.
release_tag='v0.1.0'
marker='-- gamescope-lg-dual-mode standalone v1'
action=install
upgrade=false
temporary=''
release_directory=''

usage() {
    printf '%s\n' \
        'Usage: ./install.sh [--check | --uninstall | --upgrade]' \
        '  (default)    Check prerequisites and install one user Lua script.' \
        '  --check      Read-only prerequisite and monitor/DDC checks.' \
        '  --upgrade    Replace an existing standalone installation, never a symlink.' \
        '  --uninstall  Remove only a recognized, inactive standalone installation.' \
        'No sudo, automatic package installs, Gamescope patches or display switching.'
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n "$temporary" && -f "$temporary" ]]; then rm -f -- "$temporary"; fi
    if [[ -n "$release_directory" ]]; then rm -rf -- "$release_directory"; fi
}
trap cleanup EXIT

[[ $# -le 1 ]] || { usage >&2; exit 2; }
case ${1:-} in
    '') ;;
    --check) action=check ;;
    --uninstall) action=uninstall ;;
    --upgrade) upgrade=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[[ $(uname -s) == Linux ]] || die 'Linux is required.'
[[ $EUID -ne 0 ]] || die 'Run this as your desktop user, not with sudo.'
[[ ${HOME:-} == /* ]] || die 'HOME must be an absolute path.'
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
[[ $config_home == /* ]] || die 'XDG_CONFIG_HOME must be an absolute path.'
target=$config_home/gamescope/scripts/90-lg-dual-mode.lua

owned_file() {
    local first_line=''
    [[ -f "$target" && ! -L "$target" ]] || return 1
    IFS= read -r first_line < "$target" || return 1
    [[ $first_line == "$marker" ]]
}
require_luajit() {
    command -v luajit >/dev/null || die 'LuaJIT interpreter missing. Install luajit with your package manager, then retry.'
}
assert_idle() {
    [[ -n ${XDG_RUNTIME_DIR:-} ]] || die 'XDG_RUNTIME_DIR is missing; run this from your desktop session.'
    luajit -E "$1" --can-uninstall || die 'Close managed Gamescope sessions and restore the desktop before changing the installation.'
}

download_release() {
    command -v curl >/dev/null || die 'curl is required to download release files.'
    release_directory=$(mktemp -d "${TMPDIR:-/tmp}/gamescope-lg-release.XXXXXX")
    local base="https://github.com/smazurov/gamescope-lg-dual-mode/releases/download/$release_tag"
    local file
    printf 'Downloading LG Dual Mode %s release files...\n' "$release_tag"
    for file in install.sh gamescope-lg-dual-mode.lua; do
        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 \
            --output "$release_directory/$file" "$base/$file" \
            || die "Could not download $file from release $release_tag."
        [[ -s "$release_directory/$file" ]] || die "Empty release file: $file"
    done
    # Execute only after both downloads have completed successfully.
    bash "$release_directory/install.sh" "$@"
}

if [[ $action == uninstall ]]; then
    if [[ ! -e "$target" && ! -L "$target" ]]; then printf 'Not installed: %s\n' "$target"; exit 0; fi
    owned_file || die "Refusing to remove an unrecognized file or symlink: $target"
    require_luajit
    assert_idle "$target"
    rm -- "$target"
    printf 'Removed %s\n' "$target"
    exit 0
fi

require_luajit
if [[ -z "$source_file" || ! -f "$source_file" ]]; then
    download_release "$@"
    exit 0
fi
if [[ $action != check && ( -e "$target" || -L "$target" ) ]]; then
    owned_file || die "Refusing to overwrite an existing file or symlink: $target. Existing installations are left untouched."
    if ! cmp -s -- "$source_file" "$target" && [[ $upgrade != true ]]; then
        die 'A different standalone version is installed. Use --upgrade to explicitly replace it.'
    fi
fi

printf 'Checking prerequisites (read-only)...\n'
luajit -E "$source_file" --check || {
    printf '\nNo packages were installed or settings changed.\n' >&2
    printf 'Common prerequisites: gamescope, luajit, ddcutil, GNOME Wayland and a systemd user session.\n' >&2
    exit 1
}
if [[ $action == check ]]; then exit 0; fi
assert_idle "$source_file"

if [[ -f "$target" ]] && cmp -s -- "$source_file" "$target"; then
    printf 'Already installed: %s\n' "$target"
    exit 0
fi
mkdir -p -- "$(dirname -- "$target")"
temporary=$(mktemp "$(dirname -- "$target")/.lg-dual-mode.XXXXXX")
cp -- "$source_file" "$temporary"
chmod 0644 "$temporary"
if [[ $upgrade == true && -e "$target" ]]; then
    owned_file || die "Installation target changed; refusing to overwrite: $target"
    mv -fT -- "$temporary" "$target"
else
    mv -nT -- "$temporary" "$target"
    cmp -s -- "$source_file" "$target" || die 'Installation target changed; nothing was overwritten.'
fi
temporary=''
printf 'Installed %s\n' "$target"
printf 'Keep the pointer on the gaming LG while launching fullscreen 1440p Gamescope.\n'
printf 'Existing Gamescope launch options need no changes. Uninstall: ./install.sh --uninstall\n'

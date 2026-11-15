#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Stepan Mazurov
# Installer tests use a fake LuaJIT and isolated HOME/config/runtime directories.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ $EUID -eq 0 ]]; then
    printf 'SKIP: installer tests must run as a non-root user.\n'
    exit 0
fi
sandbox=$(mktemp -d /tmp/gamescope-lg-install-tests.XXXXXX)
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/runtime" "$sandbox/home with spaces"
export HOME="$sandbox/home with spaces"
export XDG_CONFIG_HOME="$HOME/custom config"
export XDG_RUNTIME_DIR="$sandbox/runtime"
export PATH="$sandbox/bin:$PATH"
export TEST_CALLS="$sandbox/calls"
cat > "$sandbox/bin/luajit" <<'SH'
#!/bin/sh
printf '%s\n' "$3" >> "$TEST_CALLS"
case "$3" in
    --check) exit "${TEST_PREFLIGHT_STATUS:-0}" ;;
    --can-uninstall) exit "${TEST_BUSY_STATUS:-0}" ;;
    *) printf 'Unexpected Lua invocation\n' >&2; exit 99 ;;
esac
SH
chmod +x "$sandbox/bin/luajit"
target=$XDG_CONFIG_HOME/gamescope/scripts/90-lg-dual-mode.lua
count=0
pass() { count=$((count + 1)); printf 'ok - %s\n' "$*"; }
expect_failure() {
    if bash "$root/install.sh" "$@" > "$sandbox/output" 2>&1; then
        printf 'Unexpected installer success: %s\n' "$*" >&2; exit 1
    fi
}

bash "$root/install.sh" --help > "$sandbox/output"
[[ ! -e "$target" ]]
pass 'help does not install anything'
expect_failure --unknown
expect_failure --check --upgrade
[[ ! -e "$TEST_CALLS" && ! -e "$target" ]]
pass 'invalid or conflicting arguments do not invoke preflight'
make --no-print-directory -C "$root" check-install > "$sandbox/output"
[[ ! -d "$XDG_CONFIG_HOME" ]]
[[ $(tail -n 1 "$TEST_CALLS") == --check ]]
pass 'check mode does not create configuration directories'
export TEST_PREFLIGHT_STATUS=1
expect_failure
[[ ! -d "$XDG_CONFIG_HOME" ]]
unset TEST_PREFLIGHT_STATUS
pass 'failed preflight leaves installation untouched'

make --no-print-directory -C "$root" install > "$sandbox/output"
[[ -f "$target" && ! -L "$target" ]]
cmp -s "$root/gamescope-lg-dual-mode.lua" "$target"
pass 'installation copies exactly one Lua file into a path with spaces'
bash "$root/install.sh" > "$sandbox/output"
grep -q 'Already installed' "$sandbox/output"
pass 'reinstalling identical content is idempotent'

printf '\n-- installed-file change\n' >> "$target"
expect_failure
[[ $(tail -n 1 "$target") == '-- installed-file change' ]]
pass 'a changed owned version requires explicit upgrade'
make --no-print-directory -C "$root" upgrade > "$sandbox/output"
cmp -s "$root/gamescope-lg-dual-mode.lua" "$target"
pass 'explicit upgrade replaces only an owned standalone file'

export TEST_BUSY_STATUS=1
expect_failure --uninstall
[[ -f "$target" ]]
pass 'uninstall refuses an active monitor session'
printf '\n-- preserve while active\n' >> "$target"
expect_failure --upgrade
[[ $(tail -n 1 "$target") == '-- preserve while active' ]]
unset TEST_BUSY_STATUS
pass 'upgrade refuses an active monitor session without replacing its file'
make --no-print-directory -C "$root" uninstall > "$sandbox/output"
[[ ! -e "$target" ]]
pass 'uninstall removes its own inactive script'
bash "$root/install.sh" --uninstall > "$sandbox/output"
pass 'uninstall is idempotent'

printf '%s\n' 'unrelated Lua configuration' > "$target"
expect_failure --upgrade
expect_failure --uninstall
[[ $(head -n 1 "$target") == 'unrelated Lua configuration' ]]
pass 'foreign files cannot be upgraded or uninstalled'
rm -- "$target"
printf '%s\n' 'existing hook fixture' > "$sandbox/existing-hook.lua"
ln -s "$sandbox/existing-hook.lua" "$target"
expect_failure
expect_failure --upgrade
expect_failure --uninstall
[[ -L "$target" ]]
[[ $(readlink -- "$target") == "$sandbox/existing-hook.lua" ]]
[[ $(head -n 1 "$sandbox/existing-hook.lua") == 'existing hook fixture' ]]
pass 'existing symlinks and their targets remain completely untouched'
rm -- "$target"

unset XDG_CONFIG_HOME
target=$HOME/.config/gamescope/scripts/90-lg-dual-mode.lua
bash "$root/install.sh" > "$sandbox/output"
cmp -s "$root/gamescope-lg-dual-mode.lua" "$target"
[[ $(find "$HOME/.config" -type f | wc -l) -eq 1 ]]
bash "$root/install.sh" --uninstall > "$sandbox/output"
[[ ! -e "$target" ]]
pass 'default XDG path installs exactly one file and uninstalls cleanly'

# Release bootstrap tests use a fake curl: never contact GitHub or the monitor.
export TEST_RELEASE_SOURCE="$root"
export TEST_CURL_CALLS="$sandbox/curl-calls"
export TMPDIR="$sandbox/release downloads"
mkdir -p "$TMPDIR"
cat > "$sandbox/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --output|-o) output=$2; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time) shift 2 ;;
        --fail|--silent|--show-error|--location) shift ;;
        https://*) url=$1; shift ;;
        *) printf 'Unexpected curl argument: %s\n' "$1" >&2; exit 99 ;;
    esac
done
[[ -n "$output" ]]
case $url in
    https://github.com/smazurov/gamescope-lg-dual-mode/releases/download/v0.1.0/install.sh|\
    https://github.com/smazurov/gamescope-lg-dual-mode/releases/download/v0.1.0/gamescope-lg-dual-mode.lua) ;;
    *) printf 'Not a matching pinned release asset: %s\n' "$url" >&2; exit 99 ;;
esac
printf '%s\n' "$url" >> "$TEST_CURL_CALLS"
file=${url##*/}
if [[ ${TEST_CURL_FAIL:-} == "$file" ]]; then printf 'partial download\n' > "$output"; exit 22; fi
if [[ ${TEST_CURL_EMPTY:-} == "$file" ]]; then : > "$output"; exit 0; fi
cp -- "$TEST_RELEASE_SOURCE/$file" "$output"
SH
chmod +x "$sandbox/bin/curl"
pipe_install() { bash -s -- "$@" < "$root/install.sh"; }
expect_pipe_failure() {
    if pipe_install "$@" > "$sandbox/output" 2>&1; then
        printf 'Unexpected piped installer success: %s\n' "$*" >&2; exit 1
    fi
}
assert_downloads_cleaned() { [[ $(find "$TMPDIR" -mindepth 1 | wc -l) -eq 0 ]]; }

pipe_install --check > "$sandbox/output"
[[ ! -e "$target" && $(wc -l < "$TEST_CURL_CALLS") -eq 2 ]]
[[ $(tail -n 1 "$TEST_CALLS") == --check ]]
assert_downloads_cleaned
pass 'piped check downloads matching release assets without installing'

: > "$TEST_CURL_CALLS"
pipe_install > "$sandbox/output"
cmp -s "$root/gamescope-lg-dual-mode.lua" "$target"
[[ $(wc -l < "$TEST_CURL_CALLS") -eq 2 ]]
assert_downloads_cleaned
pass 'piped installation downloads both assets before running the local installer'

printf '\n-- installed-file change\n' >> "$target"
pipe_install --upgrade > "$sandbox/output"
cmp -s "$root/gamescope-lg-dual-mode.lua" "$target"
assert_downloads_cleaned
pass 'piped upgrade forwards its explicit upgrade flag'

: > "$TEST_CURL_CALLS"
pipe_install --uninstall > "$sandbox/output"
[[ ! -e "$target" && ! -s "$TEST_CURL_CALLS" ]]
pass 'piped uninstall uses the installed script without downloading payloads'

for file in install.sh gamescope-lg-dual-mode.lua; do
    export TEST_CURL_FAIL=$file
    calls_before=$(wc -l < "$TEST_CALLS")
    expect_pipe_failure
    [[ ! -e "$target" && $(wc -l < "$TEST_CALLS") -eq "$calls_before" ]]
    assert_downloads_cleaned
    pass "failed $file download cleans partial files without invoking Lua"
done
unset TEST_CURL_FAIL
export TEST_CURL_EMPTY=gamescope-lg-dual-mode.lua
calls_before=$(wc -l < "$TEST_CALLS")
expect_pipe_failure
[[ ! -e "$target" && $(wc -l < "$TEST_CALLS") -eq "$calls_before" ]]
assert_downloads_cleaned
unset TEST_CURL_EMPTY
pass 'empty release payload is rejected before preflight or installation'

: > "$TEST_CURL_CALLS"
pipe_install --help > "$sandbox/output"
expect_pipe_failure --unknown
[[ ! -s "$TEST_CURL_CALLS" && ! -e "$target" ]]
pass 'piped help and invalid arguments never download anything'

if grep -Ev '^(--check|--can-uninstall)$' "$TEST_CALLS"; then
    printf 'Installer invoked an unexpected Lua action\n' >&2
    exit 1
fi
pass 'installer never calls attach/watch/recover or display switching'
printf '%s installer tests passed\n' "$count"

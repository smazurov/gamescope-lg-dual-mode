-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Stepan Mazurov
-- Hardware-free regression tests for the standalone Lua implementation.
local M = assert(loadfile(arg[1] or "gamescope-lg-dual-mode.lua"))("library")
local ffi = require("ffi")
local passed, failed = 0, 0
local function test(name, fn)
    local ok, message = pcall(fn)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; io.stderr:write("FAIL - " .. name .. ": " .. tostring(message) .. "\n") end
end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function raises(pattern, fn)
    local ok, message = pcall(fn)
    assert(not ok, "Expected an error")
    assert(tostring(message):find(pattern), tostring(message))
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local SERIAL = "FAKE-SERIAL"
local ENV = { XDG_CURRENT_DESKTOP = "GNOME", XDG_SESSION_TYPE = "wayland", WAYLAND_DISPLAY = "wayland-0" }
local ARGS = { "gamescope", "--backend", "wayland", "-w", "2560", "-h", "1440",
    "-W", "2560", "-H", "1440", "-f", "--", "game" }
local function state(dual)
    local modes = dual and [[
        ('2560x1440@330.117', 2560, 1440, 330.117, 1.0, [1.0, 1.5, 2.0], {'is-current': <true>}),
        ('2560x1440@330.117+vrr', 2560, 1440, 330.117, 1.0, [1.0, 1.5, 2.0], {'refresh-rate-mode': <'variable'>})
    ]] or [[
        ('5120x2880@165.058', 5120, 2880, 165.058, 2.0, [1.0, 1.5, 2.0], {}),
        ('5120x2880@165.058+vrr', 5120, 2880, 165.058, 2.0, [1.0, 1.5, 2.0],
            {'is-current': <true>, 'refresh-rate-mode': <'variable'>})
    ]]
    return M.state_from_text([[
        (uint32 7, [
            (('HDMI-1', 'GSM', 'Other display', 'OTHER'),
             [('3840x2160@60.000', 3840, 2160, 60.0, 1.0, [1.0, 1.5, 2.0], {'is-current': <true>})],
             {'color-mode': <uint32 1>, 'rgb-range': <uint32 1>, 'is-underscanning': <false>}),
            (('DP-1', 'GSM', 'LG ULTRAGEAR+', 'FAKE-SERIAL'), []] .. modes .. [[],
             {'color-mode': <uint32 0>, 'rgb-range': <uint32 1>, 'is-underscanning': <false>})
        ], [
            (0, 0, 1.5, uint32 0, false, [('HDMI-1', 'GSM', 'Other display', 'OTHER')], {}),
            (2560, 0, ]] .. (dual and "1.0" or "2.0") .. [[, uint32 0, true,
                [('DP-1', 'GSM', 'LG ULTRAGEAR+', 'FAKE-SERIAL')], {})
        ], {'layout-mode': <uint32 1>})
    ]])
end
local FakeDesktop = {}; FakeDesktop.__index = FakeDesktop
function FakeDesktop.new(initial) return setmetatable({ value = copy(initial) }, FakeDesktop) end
function FakeDesktop:state() return copy(self.value) end
function FakeDesktop:apply(saved, serial, game, verify)
    if verify then return end
    if game and self.fail_game then error("simulated apply failure") end
    local configuration = M.configuration(saved, serial, game)
    local logicals = {}
    for _, logical in ipairs(configuration) do
        local specs = {}
        for _, output in ipairs(logical[6]) do
            local monitor
            for _, candidate in ipairs(self.value[2]) do if candidate[1][1] == output[1] then monitor = candidate end end
            assert(monitor, "unknown connector")
            local found = false
            for _, mode in ipairs(monitor[2]) do
                mode[7]["is-current"] = nil
                if mode[1] == output[2] then mode[7]["is-current"] = true; found = true end
            end
            assert(found, "mode unavailable")
            for key, value in pairs(output[3]) do monitor[3][key] = value end
            specs[#specs + 1] = monitor[1]
        end
        logicals[#logicals + 1] = { logical[1], logical[2], logical[3], logical[4], logical[5], specs, {} }
    end
    self.value[3] = logicals
end
function FakeDesktop:wait(predicate, alive)
    if alive and not alive() then error("process exited during setup") end
    local value = self:state()
    assert(predicate(value), "simulated timeout")
    return value
end

local temp_pipe = assert(io.popen("mktemp -d /tmp/gamescope-lg-lua-tests.XXXXXX"))
local temporary = assert(temp_pipe:read("*l")); temp_pipe:close()
local index = 0
local function session(initial, options)
    options = options or {}; index = index + 1
    local runtime = M.Runtime.new(temporary .. "/session-" .. index)
    local desktop = FakeDesktop.new(initial or state(false))
    desktop.fail_game = options.fail_game
    local writes, messages = {}, {}
    local process = { pid = 123, start = "456", alive = options.alive or function() return true end,
        wait = function() if options.wait then options.wait(runtime, desktop) end end }
    local send = function(serial, on)
        equal(serial, SERIAL)
        writes[#writes + 1] = on and "on" or "off"
        if not (options.fail_restore and not on) then desktop.value = state(on) end
    end
    local ok, message = pcall(M.session, runtime, desktop, SERIAL, process,
        function(status) messages[#messages + 1] = status end, send)
    return ok, message, runtime, desktop, writes, messages
end

test("current Steam options match", function() assert(M.eligible(ARGS, ENV)) end)
test("compact and long dimensions match", function()
    assert(M.eligible({ "gamescope", "-f", "-W2560", "--output-height=1440", "--", "game" }, ENV))
end)
test("nested dimensions supply output dimensions", function()
    assert(M.eligible({ "gamescope", "-f", "-w2560", "-h1440", "--", "game" }, ENV))
end)
test("other resolution and windowed launches do not match", function()
    assert(not M.eligible({ "gamescope", "-f", "-W1920", "-H1080", "--", "game" }, ENV))
    assert(not M.eligible({ "gamescope", "-W2560", "-H1440", "--", "game" }, ENV))
end)
test("game arguments never become Gamescope options", function()
    assert(not M.eligible({ "gamescope", "--", "game", "-f", "-W2560", "-H1440" }, ENV))
end)
test("help, empty command and other backend are skipped", function()
    assert(not M.eligible({ "gamescope", "--help" }, ENV))
    assert(not M.eligible({ "gamescope", "-f", "-W2560", "-H1440", "--" }, ENV))
    local args = copy(ARGS); args[3] = "sdl"; assert(not M.eligible(args, ENV))
end)
test("opt out and non-GNOME/non-Wayland sessions are skipped", function()
    for key, value in pairs({ GAMESCOPE_LG_DUAL_MODE = "0", XDG_CURRENT_DESKTOP = "KDE",
        XDG_SESSION_TYPE = "x11", WAYLAND_DISPLAY = "" }) do
        local env = copy(ENV); env[key] = value; assert(not M.eligible(ARGS, env))
    end
end)
test("invalid or missing dimensions fail closed", function()
    assert(not M.eligible({ "gamescope", "-f", "-Wbad", "-H1440", "--", "game" }, ENV))
    assert(not M.eligible({ "gamescope", "-f", "-W2560", "--", "game" }, ENV))
end)
test("GVariant state round trip preserves configuration", function()
    local original = state(false)
    equal(M.fingerprint(M.state_from_text(original.raw)), M.fingerprint(original))
end)
test("GVariant strings safely round trip quotes and newlines", function()
    local text = "name's \\ \"quoted\"\nline"
    local parsed = M.state_from_text(state(false).raw:gsub("'Other display'", function() return M.string_literal(text) end))
    equal(parsed[2][1][1][3], text)
end)
test("game mode preserves VRR, second monitor HDR and logical width", function()
    local config = M.configuration(state(false), SERIAL, state(true))
    equal(config[2][6][1][2], "2560x1440@330.117+vrr")
    equal(config[2][3], 1.0)
    equal(config[1][6][1][3]["color-mode"], 1)
    equal(config[1][1], 0); equal(config[2][1], 2560)
end)
test("disabled VRR and monitor transform are preserved", function()
    local original = state(false)
    original[2][2][2][1][7]["is-current"] = true
    original[2][2][2][2][7]["is-current"] = nil
    original[3][1][4] = 2
    local config = M.configuration(original, SERIAL, state(true))
    equal(config[2][6][1][2], "2560x1440@330.117")
    equal(config[1][4], 2)
end)
test("normal exit restores the exact desktop", function()
    local original = state(false)
    local ok, err, runtime, desktop, writes, messages = session(original, { wait = function(rt, d)
        equal(M.current(M.target(d:state(), SERIAL))[1], "2560x1440@330.117+vrr")
        assert(io.open(rt.snapshot, "r")):close()
    end })
    assert(ok, err); equal(table.concat(writes, ","), "on,off")
    equal(messages[1], "ready"); equal(M.fingerprint(desktop:state()), M.fingerprint(original))
    equal(io.open(runtime.snapshot, "r"), nil)
end)
test("game failure still restores", function()
    local ok, err, runtime, desktop = session(nil, { wait = function() error("simulated game crash") end })
    assert(not ok and tostring(err):find("simulated game crash"))
    equal(M.fingerprint(desktop:state()), M.fingerprint(state(false)))
    equal(io.open(runtime.snapshot, "r"), nil)
end)
test("apply failure restores before reporting failure", function()
    local ok, err, runtime, desktop = session(nil, { fail_game = true })
    assert(not ok and tostring(err):find("simulated apply failure"))
    equal(M.fingerprint(desktop:state()), M.fingerprint(state(false)))
    equal(io.open(runtime.snapshot, "r"), nil)
end)
test("already-dual-mode monitor stays in Dual Mode", function()
    local original = state(true)
    local ok, err, _, desktop, writes = session(original)
    assert(ok, err); equal(#writes, 0)
    equal(M.fingerprint(desktop:state()), M.fingerprint(original))
end)
test("dead Gamescope causes no hardware write", function()
    local ok, err, runtime, _, writes = session(nil, { alive = function() return false end })
    assert(not ok and tostring(err):find("exited before")); equal(#writes, 0)
    equal(io.open(runtime.snapshot, "r"), nil)
end)
test("missing target is a no-op", function()
    local original = state(false); table.remove(original[2], 2); table.remove(original[3], 2)
    local ok, err, _, _, writes, messages = session(original)
    assert(ok, err); equal(#writes, 0); equal(messages[1], "skip")
end)
test("mirrored layouts fail before hardware writes", function()
    local original = state(false); original[3][2][6][2] = original[2][1][1]
    local ok, err, runtime, _, writes = session(original)
    assert(not ok and tostring(err):find("Mirrored")); equal(#writes, 0)
    equal(io.open(runtime.snapshot, "r"), nil)
end)
test("failed restore retains the snapshot", function()
    local ok, _, runtime = session(nil, { fail_restore = true })
    assert(not ok); assert(io.open(runtime.snapshot, "r")):close()
end)
test("exclusive lock rejects concurrent sessions", function()
    local runtime = M.Runtime.new(temporary .. "/locking")
    local unlock = runtime:lock()
    raises("already using", function() runtime:lock() end)
    unlock()
    runtime:lock()()
end)
test("stale snapshot recovers with explicit off", function()
    local runtime = M.Runtime.new(temporary .. "/stale")
    local original = state(false); runtime:save(original, SERIAL, true, { pid = 1, start = "2" })
    local desktop = FakeDesktop.new(state(true)); local writes = {}
    runtime:restore(desktop, function(serial, on) equal(serial, SERIAL); assert(not on); writes[#writes + 1] = "off"; desktop.value = state(false) end)
    equal(#writes, 1); equal(M.fingerprint(desktop:state()), M.fingerprint(original))
end)
test("corrupt snapshot cannot issue hardware writes", function()
    local runtime = M.Runtime.new(temporary .. "/corrupt")
    runtime:write(runtime.snapshot, "not a valid snapshot")
    local writes = 0
    raises("Invalid recovery snapshot", function()
        runtime:restore(FakeDesktop.new(state(false)), function() writes = writes + 1 end)
    end)
    equal(writes, 0)
end)

local function edid(product, serial)
    local bytes = {}; for i = 1, 128 do bytes[i] = 0 end
    for i = 2, 7 do bytes[i] = 255 end
    bytes[9], bytes[10], bytes[11], bytes[12] = 0x1e, 0x6d, product % 256, math.floor(product / 256)
    bytes[112] = 255
    serial = (serial .. "\n" .. string.rep(" ", 13)):sub(1, 13)
    for i = 1, 13 do bytes[113 + i] = serial:byte(i) end
    local result = {}; for i, value in ipairs(bytes) do result[i] = string.char(value) end
    return table.concat(result)
end
test("EDID matching uses vendor and tested product, not generic LG name", function()
    local vendor, product, serial = M.edid_identity(edid(0x5cf8, SERIAL))
    equal(vendor, "GSM"); equal(product, 0x5cf8); equal(serial, SERIAL)
    equal(M.edid_identity("not an EDID"), nil)
end)
test("ambiguous monitors require explicit serial", function()
    local value = state(false); local second = copy(value[2][2]); second[1][4] = "SECOND"; value[2][3] = second
    raises("Several supported", function() M.select_monitor(value, { SERIAL, "SECOND" }) end)
    equal(M.select_monitor(value, { SERIAL, "SECOND" }, "SECOND")[1][4], "SECOND")
    equal(M.select_monitor(value, { "UNKNOWN" }), nil)
end)
test("both Lua wait-status conventions are normalized", function()
    equal(M.exit_status(0), 0); equal(M.exit_status(2560), 10)
    equal(M.exit_status(true, "exit", 0), 0); equal(M.exit_status(nil, "exit", 7), 7)
    local code = M.run({ "/bin/sh", "-c", "exit 7" }); equal(code, 7)
end)
test("shell quoting does not execute embedded shell syntax", function()
    local input = "spaces ' quotes; $(echo WRONG) % $dollar"
    local code, output = M.run({ "/usr/bin/printf", "%s", input })
    equal(code, 0); equal(output, input)
end)
test("systemd property quoting escapes unit specifiers", function()
    local quoted = M.systemd_quote('/tmp/a%name "quoted" $dollar.lua')
    assert(quoted:find("%%name", 1, true)); assert(quoted:find('\\"quoted\\"', 1, true))
    assert(quoted:find("$dollar", 1, true))
end)
test("own process start time is readable without /proc/PID/exe", function()
    assert(M.process_start(ffi.C.getpid()):match("^%d+$"))
end)
test("embedded hook handles exit statuses without loading GIO into Gamescope", function()
    local cases = {
        { 'true, "exit", 0', true, false }, { 'nil, "exit", 10', false, false },
        { 'nil, "exit", 1', false, true }, { '0', true, false },
        { '2560', false, false }, { '256', false, true },
    }
    for _, case in ipairs(cases) do
        local script = [[
            local ffi = require('ffi')
            ffi.load = function() error('Do not load GIO into the Gamescope process') end
            gamescope = {convars = {adaptive_sync = {value = false}}}
            local called, exited = false, false
            os.execute = function(command)
                assert(command:find('luajit', 1, true))
                assert(command:find('--attach', 1, true))
                assert(not command:find('python', 1, true))
                called = true
                return RESULT
            end
            os.exit = function(code) assert(code == 1); exited = true end
            dofile(SOURCE)
            assert(called)
            assert(gamescope.convars.adaptive_sync.value == ADAPTIVE)
            assert(exited == EXITED)
        ]]
        script = script:gsub("RESULT", function() return case[1] end)
            :gsub("SOURCE", function() return string.format("%q", M.source) end)
            :gsub("ADAPTIVE", tostring(case[2])):gsub("EXITED", tostring(case[3]))
        local code, output = M.run({ "luajit", "-E", "-e", script })
        assert(code == 0, output)
    end
end)

test("embedded hook tolerates Gamescope replacing the global debug library", function()
    local script = [[
        local debug_library = require('debug')
        debug = function() end -- Gamescope's common util.lua installs a logger here.
        assert(require('debug') == debug_library)
        gamescope = {convars = {adaptive_sync = {value = false}}}
        os.execute = function() return 2560 end -- Skip, without invoking the host helper.
        dofile(SOURCE)
    ]]
    script = script:gsub("SOURCE", function() return string.format("%q", M.source) end)
    local code, output = M.run({ "luajit", "-E", "-e", script })
    assert(code == 0, output)
end)

test("requested serial cannot select an unsupported or different monitor", function()
    equal(M.select_monitor(state(false), {}, SERIAL), nil)
    equal(M.select_monitor(state(false), { SERIAL }, "DIFFERENT"), nil)
end)
test("disabled supported monitor is skipped before hardware writes", function()
    local original = state(false); table.remove(original[3], 2)
    local ok, err, runtime, _, writes, messages = session(original)
    assert(ok, err); equal(#writes, 0); equal(messages[1], "skip")
    equal(io.open(runtime.snapshot, "r"), nil)
end)
test("display apply uses typed verify-only parameters", function()
    local glib = ffi.load("libglib-2.0.so.0")
    local calls = 0
    local desktop = setmetatable({
        state = function() return state(false) end,
        call = function(_, method, parameters)
            calls = calls + 1; equal(method, "ApplyMonitorsConfig")
            equal(ffi.string(glib.g_variant_get_type_string(parameters)), "(uua(iiduba(ssa{sv}))a{sv})")
            local flag = glib.g_variant_get_child_value(parameters, 1)
            equal(tonumber(glib.g_variant_get_uint32(flag)), 0)
            glib.g_variant_unref(flag)
            return assert(glib.g_variant_parse(nil, "()", nil, nil, nil))
        end,
    }, M.Desktop)
    desktop:apply(state(false), nil, nil, true)
    equal(calls, 1)
end)
test("hotplug refuses layout replacement before the apply call", function()
    local changed = state(false)
    local added = copy(changed[2][1]); added[1][4] = "NEW-MONITOR"
    changed[2][3] = added
    local desktop = setmetatable({
        state = function() return changed end,
        call = function() error("Must not apply a changed monitor layout") end,
    }, M.Desktop)
    raises("Connected monitors changed", function() desktop:apply(state(false)) end)
end)
test("DRM detection accepts only connected supported EDIDs", function()
    local root = temporary .. "/drm"
    local connectors = {
        { "card0-DP-1", "connected\n", 0x5cf8, SERIAL },
        { "card0-DP-2", "connected\n", 0x5cf9, "UNSUPPORTED" },
        { "card0-DP-3", "disconnected\n", 0x5cf8, "DISCONNECTED" },
    }
    for _, connector in ipairs(connectors) do
        local directory = root .. "/" .. connector[1]
        equal(M.run({ "/bin/mkdir", "-p", directory }), 0)
        local status = assert(io.open(directory .. "/status", "w"))
        status:write(connector[2]); status:close()
        local identity = assert(io.open(directory .. "/edid", "wb"))
        identity:write(edid(connector[3], connector[4])); identity:close()
    end
    local found = M.detect_supported(root)
    equal(#found, 1); equal(found[1], SERIAL)
end)
test("invalid GVariant inside a valid snapshot cannot issue hardware writes", function()
    local runtime = M.Runtime.new(temporary .. "/corrupt-variant")
    runtime:write(runtime.snapshot, "gamescope-lg-dual-mode-v1\n" .. SERIAL .. "\n1\n1\n2\ninvalid variant")
    local writes = 0
    local ok = pcall(runtime.restore, runtime, FakeDesktop.new(state(false)), function() writes = writes + 1 end)
    assert(not ok); equal(writes, 0)
    assert(io.open(runtime.snapshot, "r")):close()
end)
test("oversized snapshot cannot issue hardware writes", function()
    local runtime = M.Runtime.new(temporary .. "/oversized")
    runtime:write(runtime.snapshot, string.rep("x", 2097153))
    local writes = 0
    raises("too large", function()
        runtime:restore(FakeDesktop.new(state(false)), function() writes = writes + 1 end)
    end)
    equal(writes, 0)
end)
test("installation changes require an idle session with no pending recovery", function()
    local base = temporary .. "/installation-state"
    M.Runtime.new(base)
    local runtime = M.Runtime.new(base .. "/gamescope-lg-dual-mode")
    local function check()
        return M.run({ "/usr/bin/env", "XDG_RUNTIME_DIR=" .. base,
            "luajit", "-E", M.source, "--can-uninstall" })
    end
    local unlock = runtime:lock()
    local code, output = check()
    assert(code ~= 0 and output:find("already using"), output)
    unlock()
    runtime:write(runtime.snapshot, "pending recovery")
    code, output = check()
    assert(code ~= 0 and output:find("recover the desktop"), output)
    assert(os.remove(runtime.snapshot))
    equal(check(), 0)
end)

test("runtime state is private to the desktop user", function()
    local runtime = M.Runtime.new(temporary .. "/permissions")
    runtime:write(runtime.snapshot, "private state")
    for _, entry in ipairs({ { runtime.root, "700" }, { runtime.snapshot, "600" } }) do
        local code, output = M.run({ "stat", "-c", "%a", entry[1] })
        equal(code, 0); equal(output:gsub("%s+$", ""), entry[2])
    end
end)

os.execute("rm -rf -- " .. M.shell_quote(temporary))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

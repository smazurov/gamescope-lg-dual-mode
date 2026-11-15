-- gamescope-lg-dual-mode standalone v1
-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Stepan Mazurov
-- One file: Gamescope startup hook and independent LuaJIT lifecycle watcher.
-- Requires GNOME Wayland, systemd user services, LuaJIT, ddcutil and GLib/GIO.
-- Keep the pointer on the gaming LG during launch and reconnection.
-- Optional: GAMESCOPE_LG_MONITOR_SERIAL selects one of several supported LGs.
-- Bypass: GAMESCOPE_LG_DUAL_MODE=0 gamescope ...

-- Gamescope's common scripts replace the global debug table with a logger.
local SOURCE = require("debug").getinfo(1, "S").source:sub(2)
local LIBRARY = ... == "library"
local M = {}
local ffi = require("ffi")
ffi.cdef[[
typedef struct _GVariant GVariant;
typedef struct _GVariantType GVariantType;
typedef struct _GDBusConnection GDBusConnection;
typedef struct _GDir GDir;
typedef struct { unsigned int domain; int code; char *message; } GError;
GDBusConnection *g_bus_get_sync(int, void *, GError **);
GVariant *g_dbus_connection_call_sync(GDBusConnection *, const char *, const char *,
 const char *, const char *, GVariant *, const GVariantType *, int, int, void *, GError **);
void g_object_unref(void *);
void g_error_free(GError *);
void g_free(void *);
GVariantType *g_variant_type_new(const char *);
void g_variant_type_free(GVariantType *);
GVariant *g_variant_parse(const GVariantType *, const char *, const char *, const char **, GError **);
GVariant *g_variant_new_string(const char *);
GVariant *g_variant_ref_sink(GVariant *);
void g_variant_unref(GVariant *);
char *g_variant_print(GVariant *, int);
const char *g_variant_get_type_string(GVariant *);
size_t g_variant_n_children(GVariant *);
GVariant *g_variant_get_child_value(GVariant *, size_t);
GVariant *g_variant_get_variant(GVariant *);
const char *g_variant_get_string(GVariant *, size_t *);
unsigned int g_variant_get_uint32(GVariant *);
int g_variant_get_int32(GVariant *);
unsigned short g_variant_get_uint16(GVariant *);
short g_variant_get_int16(GVariant *);
unsigned long long g_variant_get_uint64(GVariant *);
long long g_variant_get_int64(GVariant *);
unsigned char g_variant_get_byte(GVariant *);
int g_variant_get_boolean(GVariant *);
double g_variant_get_double(GVariant *);
long long g_get_monotonic_time(void);
void g_usleep(unsigned long);
GDir *g_dir_open(const char *, unsigned int, GError **);
const char *g_dir_read_name(GDir *);
void g_dir_close(GDir *);
int getpid(void);
int pidfd_open(int, unsigned int);
struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *, unsigned long, int);
int close(int);
int open(const char *, int, ...);
int flock(int, int);
int mkdir(const char *, unsigned int);
int chmod(const char *, unsigned int);
int rename(const char *, const char *);
int unlink(const char *);
long write(int, const void *, size_t);
int fsync(int);
unsigned int umask(unsigned int);
char *realpath(const char *, char *);
void free(void *);
typedef struct _IO_FILE FILE;
FILE *popen(const char *, const char *);
size_t fread(void *, size_t, size_t, FILE *);
int ferror(FILE *);
int pclose(FILE *);
]]
-- Only the sanitized host watcher needs GIO. Do not dlopen Steam's GLib/GIO
-- into Gamescope while running the embedded startup hook.
local function lazy_library(name)
    local library
    return setmetatable({}, { __index = function(_, symbol)
        library = library or ffi.load(name)
        return library[symbol]
    end })
end
local GLib = lazy_library("libglib-2.0.so.0")
local Gio = lazy_library("libgio-2.0.so.0")
local C = ffi.C
local APPLY_TYPE = "(uua(iiduba(ssa{sv}))a{sv})"
local STATE_TYPE = "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"
M.profile = { vendor = "GSM", product = 0x5cf8, name = "LG 27GM950B",
              width = 2560, height = 1440, minimum_refresh = 300 }
M.source = SOURCE

local function fail(message) error(message, 0) end
local function say(message) io.stdout:write("[gamescope-lg-dual-mode] " .. message .. "\n"); io.stdout:flush() end
local function now() return tonumber(GLib.g_get_monotonic_time()) / 1000000 end
local function sleep(seconds) GLib.g_usleep(math.floor(seconds * 1000000)) end
local function read(path, limit)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read(limit or "*a")
    file:close()
    return value
end
local function gerror(errors, fallback)
    if errors[0] == nil then return fallback end
    local message = ffi.string(errors[0].message)
    GLib.g_error_free(errors[0])
    return message
end
local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local function command_text(arguments)
    local quoted = {}
    for i, value in ipairs(arguments) do quoted[i] = shell_quote(value) end
    return table.concat(quoted, " ")
end
local function exit_status(ok, kind, code)
    if type(ok) == "number" then
        if ok < 0 then return 1 end
        local signal = ok % 128
        if signal ~= 0 then return 128 + signal end
        return math.floor(ok / 256) % 256
    end
    if not ok and kind == "signal" then return 128 + (code or 0) end
    return ok and 0 or (code or 1)
end
local function run(arguments, seconds)
    local command = command_text(arguments)
    if seconds then command = "timeout " .. seconds .. "s " .. command end
    -- Lua 5.1's pipe:close() can report stream success instead of child status.
    -- POSIX pclose supplies the actual wait status on every supported LuaJIT build.
    local pipe = C.popen(command .. " 2>&1", "r")
    if pipe == nil then return 1, "Could not run command" end
    local chunks, buffer = {}, ffi.new("char[4096]")
    while true do
        local count = tonumber(C.fread(buffer, 1, 4096, pipe))
        if count > 0 then chunks[#chunks + 1] = ffi.string(buffer, count) end
        if count < 4096 then break end
    end
    local read_failed = C.ferror(pipe) ~= 0
    local status, output = exit_status(C.pclose(pipe)), table.concat(chunks)
    if read_failed then return 1, output .. "\nCould not read command output" end
    return status, output
end
local function executable(name)
    for directory in (os.getenv("PATH") or "/usr/bin:/bin"):gmatch("[^:]+") do
        local candidate = directory .. "/" .. name
        -- command -v also checks executable permissions and handles symlinks.
        local status = os.execute("test -f " .. shell_quote(candidate) .. " -a -x " .. shell_quote(candidate))
        if exit_status(status) == 0 then return candidate end
    end
    fail("Missing executable: " .. name)
end
local function realpath(path)
    local value = C.realpath(path, nil)
    if value == nil then fail("Cannot resolve script path: " .. path) end
    local result = ffi.string(value); C.free(value)
    return result
end
local function systemd_quote(value)
    -- ExecStopPost uses ':' to disable $ expansion; unit specifiers still need escaping.
    return '"' .. value:gsub("%%", "%%%%"):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end
M.shell_quote, M.exit_status, M.systemd_quote = shell_quote, exit_status, systemd_quote
M.run = run

local function variant_print(value)
    local text = GLib.g_variant_print(value, 1)
    local result = ffi.string(text); GLib.g_free(text)
    return result
end
local function variant_parse(text, signature)
    local kind = signature and GLib.g_variant_type_new(signature) or nil
    local errors = ffi.new("GError *[1]")
    local value = GLib.g_variant_parse(kind, text, nil, nil, errors)
    if kind ~= nil then GLib.g_variant_type_free(kind) end
    if value == nil then fail(gerror(errors, "Cannot parse display state")) end
    return value
end
local decode
local function child(value, index)
    local item = GLib.g_variant_get_child_value(value, index)
    local result = decode(item); GLib.g_variant_unref(item)
    return result
end
decode = function(value)
    local kind = ffi.string(GLib.g_variant_get_type_string(value))
    if kind == "s" or kind == "o" or kind == "g" then
        return ffi.string(GLib.g_variant_get_string(value, nil))
    elseif kind == "u" then return tonumber(GLib.g_variant_get_uint32(value))
    elseif kind == "i" then return tonumber(GLib.g_variant_get_int32(value))
    elseif kind == "q" then return tonumber(GLib.g_variant_get_uint16(value))
    elseif kind == "n" then return tonumber(GLib.g_variant_get_int16(value))
    elseif kind == "t" then return tonumber(GLib.g_variant_get_uint64(value))
    elseif kind == "x" then return tonumber(GLib.g_variant_get_int64(value))
    elseif kind == "y" then return tonumber(GLib.g_variant_get_byte(value))
    elseif kind == "b" then return GLib.g_variant_get_boolean(value) ~= 0
    elseif kind == "d" then return tonumber(GLib.g_variant_get_double(value))
    elseif kind == "v" then
        local inner = GLib.g_variant_get_variant(value)
        local result = decode(inner); GLib.g_variant_unref(inner)
        return result
    elseif kind:sub(1, 1) == "a" or kind:sub(1, 1) == "(" or kind:sub(1, 1) == "{" then
        local result = {}
        for i = 0, tonumber(GLib.g_variant_n_children(value)) - 1 do
            local item = child(value, i)
            if kind:sub(1, 2) == "a{" then result[item[1]] = item[2]
            else result[#result + 1] = item end
        end
        return result
    end
    fail("Unsupported display-state type: " .. kind)
end
local function string_literal(text)
    local value = GLib.g_variant_ref_sink(GLib.g_variant_new_string(text))
    local result = variant_print(value); GLib.g_variant_unref(value)
    return result
end
local function state_from_text(text)
    local value = variant_parse(text, STATE_TYPE)
    local result = decode(value)
    result.raw = variant_print(value)
    GLib.g_variant_unref(value)
    return result
end
M.state_from_text, M.string_literal = state_from_text, string_literal

function M.current(monitor)
    for _, mode in ipairs(monitor[2]) do if mode[7]["is-current"] then return mode end end
    fail("Monitor has no active mode: " .. monitor[1][1])
end
function M.target(state, serial)
    for _, monitor in ipairs(state[2]) do if monitor[1][4] == serial then return monitor end end
end
function M.dual_mode(state, serial)
    local monitor = M.target(state, serial)
    if monitor then
        for _, mode in ipairs(monitor[2]) do
            if mode[2] == M.profile.width and mode[3] == M.profile.height
                and mode[4] > M.profile.minimum_refresh then return true end
        end
    end
    return false
end
function M.configuration(saved, serial, game_state)
    local monitors, result = {}, {}
    for _, monitor in ipairs(saved[2]) do monitors[monitor[1][1]] = monitor end
    for _, logical in ipairs(saved[3]) do
        local x, y, scale, transform, primary = unpack(logical, 1, 5)
        local outputs = {}
        for _, spec in ipairs(logical[6]) do
            local monitor = monitors[spec[1]]
            local mode = M.current(monitor)
            local properties = {}
            for _, key in ipairs({ "color-mode", "rgb-range", "is-underscanning" }) do
                properties[key] = monitor[3][key]
            end
            if game_state and spec[4] == serial then
                if #logical[6] ~= 1 then fail("Mirrored LG display layouts are not supported") end
                local candidate, score, refresh
                local variable = mode[7]["refresh-rate-mode"] == "variable"
                for _, item in ipairs(assert(M.target(game_state, serial))[2]) do
                    if item[2] == M.profile.width and item[3] == M.profile.height
                        and item[4] > M.profile.minimum_refresh then
                        local match = ((item[7]["refresh-rate-mode"] == "variable") == variable) and 1 or 0
                        if not candidate or match > score or (match == score and item[4] > refresh) then
                            candidate, score, refresh = item, match, item[4]
                        end
                    end
                end
                if not candidate then fail("No 1440p mode above 300 Hz was advertised") end
                local desired, best = M.profile.width * scale / mode[2], math.huge
                for _, supported in ipairs(candidate[6]) do
                    local distance = math.abs(supported - desired)
                    if distance < best then scale, best = supported, distance end
                end
                mode = candidate
            end
            outputs[#outputs + 1] = { spec[1], mode[1], properties }
        end
        if game_state then
            primary = false
            for _, spec in ipairs(logical[6]) do if spec[4] == serial then primary = true end end
        end
        result[#result + 1] = { x, y, scale, transform, primary, outputs }
    end
    return result
end
local function parameters_text(serial, method, configuration, layout)
    local logicals = {}
    for _, logical in ipairs(configuration) do
        local outputs = {}
        for _, output in ipairs(logical[6]) do
            local properties = {}
            for _, key in ipairs({ "color-mode", "rgb-range", "is-underscanning" }) do
                local value = output[3][key]
                if value ~= nil then
                    local encoded = type(value) == "boolean" and tostring(value) or ("uint32 " .. value)
                    properties[#properties + 1] = string_literal(key) .. ": <" .. encoded .. ">"
                end
            end
            outputs[#outputs + 1] = "(" .. string_literal(output[1]) .. ", " .. string_literal(output[2])
                .. ", {" .. table.concat(properties, ", ") .. "})"
        end
        logicals[#logicals + 1] = string.format("(%d, %d, %.17g, %d, %s, [", logical[1], logical[2],
            logical[3], logical[4], tostring(logical[5])) .. table.concat(outputs, ", ") .. "])"
    end
    return "(" .. serial .. ", " .. method .. ", [" .. table.concat(logicals, ", ")
        .. "], {'layout-mode': <uint32 " .. layout .. ">})"
end
M.parameters_text = parameters_text
function M.fingerprint(state)
    local configuration = M.configuration(state)
    table.sort(configuration, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    return parameters_text(0, 0, configuration, state[4]["layout-mode"])
end
local function same_connected(a, b)
    local left, right = {}, {}
    for _, monitor in ipairs(a[2]) do left[#left + 1] = table.concat(monitor[1], "\0") end
    for _, monitor in ipairs(b[2]) do right[#right + 1] = table.concat(monitor[1], "\0") end
    table.sort(left); table.sort(right)
    return table.concat(left, "\n") == table.concat(right, "\n")
end

local Desktop = {}; Desktop.__index = Desktop
function Desktop.new()
    local errors = ffi.new("GError *[1]")
    local bus = Gio.g_bus_get_sync(2, nil, errors)
    if bus == nil then fail(gerror(errors, "Cannot connect to the session bus")) end
    return setmetatable({ bus = ffi.gc(bus, Gio.g_object_unref) }, Desktop)
end
function Desktop:call(method, parameters)
    local errors = ffi.new("GError *[1]")
    local result = Gio.g_dbus_connection_call_sync(self.bus, "org.gnome.Mutter.DisplayConfig",
        "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", method,
        parameters, nil, 0, 10000, nil, errors)
    if result == nil then fail(gerror(errors, "Mutter call failed: " .. method)) end
    return result
end
function Desktop:state()
    local result = self:call("GetCurrentState")
    local state = decode(result); state.raw = variant_print(result)
    GLib.g_variant_unref(result)
    return state
end
function Desktop:apply(saved, serial, game_state, verify)
    local configuration = M.configuration(saved, serial, game_state)
    local last_error
    for attempt = 1, 3 do
        local current = self:state()
        if not same_connected(current, saved) then fail("Connected monitors changed; refusing to replace the layout") end
        local parameters = variant_parse(parameters_text(current[1], verify and 0 or 1,
            configuration, saved[4]["layout-mode"]), APPLY_TYPE)
        local ok, result = pcall(self.call, self, "ApplyMonitorsConfig", parameters)
        GLib.g_variant_unref(parameters)
        if ok then GLib.g_variant_unref(result); return end
        last_error = result
        if attempt < 3 then sleep(0.5) end
    end
    fail(last_error)
end
function Desktop:wait(predicate, alive)
    local deadline = now() + 30
    while now() < deadline do
        if alive and not alive() then fail("Gamescope exited during setup") end
        local state = self:state()
        if predicate(state) then return state end
        sleep(0.5)
    end
    fail("Timed out waiting for the monitor or display configuration")
end
M.Desktop = Desktop

function M.edid_identity(edid)
    if not edid or #edid < 128 or edid:sub(1, 8) ~= "\0\255\255\255\255\255\255\0" then return end
    local vendor = edid:byte(9) * 256 + edid:byte(10)
    local manufacturer = string.char(64 + math.floor(vendor / 1024) % 32,
        64 + math.floor(vendor / 32) % 32, 64 + vendor % 32)
    local product = edid:byte(11) + edid:byte(12) * 256
    local serial
    for offset = 54, 108, 18 do
        if edid:sub(offset + 1, offset + 5) == "\0\0\0\255\0" then
            serial = edid:sub(offset + 6, offset + 18):gsub("[%z\r\n]", ""):gsub("%s+$", "")
        end
    end
    return manufacturer, product, serial
end
function M.detect_supported(sysfs)
    local root = sysfs or "/sys/class/drm"
    local errors = ffi.new("GError *[1]")
    local directory = GLib.g_dir_open(root, 0, errors)
    if directory == nil then fail(gerror(errors, "Cannot read DRM connectors")) end
    local found = {}
    while true do
        local name = GLib.g_dir_read_name(directory)
        if name == nil then break end
        name = ffi.string(name)
        if name:match("^card%d+%-") and read(root .. "/" .. name .. "/status") == "connected\n" then
            local vendor, product, serial = M.edid_identity(read(root .. "/" .. name .. "/edid"))
            if vendor == M.profile.vendor and product == M.profile.product and serial and serial ~= "" then
                found[#found + 1] = serial
            end
        end
    end
    GLib.g_dir_close(directory)
    return found
end
function M.select_monitor(state, supported, requested)
    local available, matches = {}, {}
    for _, serial in ipairs(supported) do available[serial] = true end
    for _, monitor in ipairs(state[2]) do
        local serial = monitor[1][4]
        if available[serial] and (not requested or requested == serial) then matches[#matches + 1] = monitor end
    end
    if #matches > 1 then fail("Several supported LGs are connected; set GAMESCOPE_LG_MONITOR_SERIAL") end
    return matches[1]
end
local function ddc(serial, on)
    local status, output = run({ executable("ddcutil"), "--sn", serial, "setvcp", "B1",
        on and "0x2100" or "0x2200", "--permit-unknown-feature", "--noverify" }, 20)
    if status ~= 0 then fail("DDC write failed: " .. output) end
end
M.ddc = ddc

function M.eligible(argv, environment)
    local env = environment or setmetatable({}, { __index = function(_, key) return os.getenv(key) end })
    if env.GAMESCOPE_LG_DUAL_MODE == "0" then return false end
    if not (env.XDG_CURRENT_DESKTOP or ""):upper():find("GNOME", 1, true)
        or env.XDG_SESSION_TYPE ~= "wayland" or not env.WAYLAND_DISPLAY or env.WAYLAND_DISPLAY == "" then return false end
    local stop
    for i = 2, #argv do if argv[i] == "--" then stop = i; break end end
    if not stop or stop == #argv then return false end
    local options, fullscreen, backend = {}, false, "auto"
    local keys = { W = "width", H = "height", w = "nested_width", h = "nested_height",
        ["output-width"] = "width", ["output-height"] = "height",
        ["nested-width"] = "nested_width", ["nested-height"] = "nested_height" }
    local i = 2
    while i < stop do
        local option, value = argv[i]:match("^%-%-([^=]+)=(.*)$")
        if not option then option = argv[i]:match("^%-%-(.+)$") end
        if not option then
            local short, attached = argv[i]:match("^%-([WHwh])(.*)$")
            if short then option, value = short, attached ~= "" and attached or nil end
        end
        if argv[i] == "-f" or option == "fullscreen" then fullscreen = true end
        if option == "help" then return false end
        if option == "backend" or keys[option] then
            if not value then i = i + 1; value = i < stop and argv[i] or nil end
            if not value then return false end
            if option == "backend" then backend = value
            else
                if not value:match("^%d+$") then return false end
                options[keys[option]] = tonumber(value)
            end
        end
        i = i + 1
    end
    return fullscreen and (backend == "wayland" or backend == "auto")
        and (options.width or options.nested_width) == M.profile.width
        and (options.height or options.nested_height) == M.profile.height
end
local function process_start(pid)
    local stat = read("/proc/" .. pid .. "/stat")
    if not stat then fail("Process no longer exists: " .. pid) end
    local rest = stat:match("^.*%) (.*)$")
    local fields = {}; for item in (rest or ""):gmatch("%S+") do fields[#fields + 1] = item end
    if not fields[20] or not fields[20]:match("^%d+$") then fail("Cannot identify process start time") end
    return fields[20]
end
local function open_process(pid, start)
    if process_start(pid) ~= start then fail("Gamescope PID was reused") end
    local fd = C.pidfd_open(pid, 0)
    if fd < 0 then fail("Cannot watch Gamescope with pidfd_open (Linux 5.3+ required)") end
    local descriptors = ffi.new("struct pollfd[1]", { { fd, 1, 0 } })
    return {
        pid = pid, start = start,
        alive = function() return C.poll(descriptors, 1, 0) == 0 end,
        wait = function()
            while true do
                local result = C.poll(descriptors, 1, -1)
                if result > 0 then return end
                if result < 0 and ffi.errno() ~= 4 then fail("pidfd poll failed") end
            end
        end,
        close = function() C.close(fd) end,
    }
end
M.process_start = process_start

local Runtime = {}; Runtime.__index = Runtime
function Runtime.new(root, create)
    if not root then
        local base = os.getenv("XDG_RUNTIME_DIR")
        if not base or base == "" then fail("XDG_RUNTIME_DIR is not set") end
        root = base .. "/gamescope-lg-dual-mode"
    end
    if create ~= false then
        if C.mkdir(root, 448) ~= 0 and ffi.errno() ~= 17 then fail("Cannot create runtime directory: " .. root) end
    end
    return setmetatable({ root = root, snapshot = root .. "/session.gv" }, Runtime)
end
function Runtime:lock()
    local fd = C.open(self.root .. "/lock", 2 + 64 + 524288, ffi.cast("int", 384))
    if fd < 0 then fail("Cannot open monitor session lock") end
    if C.flock(fd, 6) ~= 0 then C.close(fd); fail("Another Gamescope session is already using LG Dual Mode") end
    return function() C.close(fd) end
end
function Runtime.write(_, path, value)
    local temporary = path .. ".tmp." .. C.getpid()
    local fd = C.open(temporary, 1 + 64 + 128 + 524288, ffi.cast("int", 384))
    if fd < 0 then fail("Cannot create temporary state file") end
    local offset, ok = 0, true
    while offset < #value do
        local written = tonumber(C.write(fd, ffi.cast("const char *", value) + offset, #value - offset))
        if written > 0 then offset = offset + written
        -- A negative result with EINTR is retried; zero or other errors abort.
        elseif written == 0 or ffi.errno() ~= 4 then ok = false; break end
    end
    if ok then ok = C.fsync(fd) == 0 end
    C.close(fd)
    if not ok or C.rename(temporary, path) ~= 0 then C.unlink(temporary); fail("Cannot save monitor state") end
end
function Runtime:save(state, serial, switch_back, process)
    if serial:find("[\r\n%z]") then fail("Invalid monitor serial") end
    self:write(self.snapshot, "gamescope-lg-dual-mode-v1\n" .. serial .. "\n"
        .. (switch_back and "1" or "0") .. "\n" .. process.pid .. "\n" .. process.start .. "\n" .. assert(state.raw))
end
function Runtime:restore(desktop, send_ddc)
    local snapshot = read(self.snapshot, 2097153)
    if not snapshot then return end
    if #snapshot > 2097152 then fail("Recovery snapshot is too large") end
    local serial, back, raw = snapshot:match("^gamescope%-lg%-dual%-mode%-v1\n([^\n]+)\n([01])\n%d+\n%d+\n(.*)$")
    if not serial then fail("Invalid recovery snapshot; refusing hardware writes") end
    local saved = state_from_text(raw)
    if not M.target(saved, serial) then fail("Recovery snapshot has no matching monitor") end
    if back == "1" then
        local ok, message
        for attempt = 1, 3 do
            ok, message = pcall(send_ddc or ddc, serial, false)
            if ok then break end
            if attempt < 3 then sleep(1) end
        end
        if not ok then fail(message) end
    end
    local expected = M.current(M.target(saved, serial))[1]
    desktop:wait(function(state)
        local monitor = M.target(state, serial)
        if monitor then for _, mode in ipairs(monitor[2]) do if mode[1] == expected then return true end end end
        return false
    end)
    desktop:apply(saved)
    desktop:wait(function(state) return M.fingerprint(state) == M.fingerprint(saved) end)
    assert(os.remove(self.snapshot))
    say("Restored the saved desktop modes, layout, scaling, VRR and color settings")
end
M.Runtime = Runtime

function M.session(runtime, desktop, serial, process, ready, send_ddc)
    send_ddc = send_ddc or ddc
    local unlock = runtime:lock()
    local ok, message = pcall(function()
        runtime:restore(desktop, send_ddc)
        local saved = desktop:state()
        if not M.target(saved, serial) then ready("skip"); return end
        local active = false
        for _, logical in ipairs(saved[3]) do
            for _, spec in ipairs(logical[6]) do
                if spec[4] == serial then
                    active = true
                    if #logical[6] ~= 1 then fail("Mirrored LG layouts are not supported") end
                end
            end
        end
        if not active then ready("skip"); return end
        if not process.alive() then fail("Gamescope exited before setup") end
        desktop:apply(saved, nil, nil, true)
        local switch_back = not M.dual_mode(saved, serial)
        runtime:save(saved, serial, switch_back, process)
        local setup_ok, setup_error = pcall(function()
            if switch_back then say("Enabling LG Dual Mode"); send_ddc(serial, true) end
            local game = desktop:wait(function(state) return M.dual_mode(state, serial) end, process.alive)
            desktop:apply(saved, serial, game)
            local wanted = parameters_text(0, 0, M.configuration(saved, serial, game), saved[4]["layout-mode"])
            desktop:wait(function(state)
                return parameters_text(0, 0, M.configuration(state), state[4]["layout-mode"]) == wanted
            end, process.alive)
            ready("ready")
            say("1440p330 ready; leave the pointer on the gaming LG")
            process.wait() -- pidfd, no polling DDC while gaming
        end)
        runtime:restore(desktop, send_ddc)
        if not setup_ok then fail(setup_error) end
    end)
    unlock()
    if not ok then fail(message) end
end

local function watch(runtime, pid, start, serial, ready_file)
    local process = open_process(pid, start)
    local ok, message = pcall(M.session, runtime, Desktop.new(), serial, process,
        function(status) runtime:write(ready_file, status) end)
    process.close()
    if not ok then runtime:write(ready_file, "error\n" .. tostring(message)); fail(message) end
end
local function attach(runtime, pid)
    local cmdline = assert(read("/proc/" .. pid .. "/cmdline"), "Gamescope exited before setup")
    local argv = {}; for item in cmdline:gmatch("([^%z]+)%z") do argv[#argv + 1] = item end
    if not argv[1] or argv[1]:match("([^/]+)$") ~= "gamescope" then fail("Requesting process is not Gamescope") end
    if not M.eligible(argv) then return 10 end
    local monitor = M.select_monitor(Desktop.new():state(), M.detect_supported(), os.getenv("GAMESCOPE_LG_MONITOR_SERIAL"))
    if not monitor then return 10 end
    local start, serial = process_start(pid), monitor[1][4]
    local unit = "gamescope-lg-lua-" .. pid .. "-" .. start
    local ready_file = runtime.root .. "/" .. unit .. ".ready"
    local script, interpreter = realpath(SOURCE), realpath(executable("luajit"))
    local recovery = ":" .. systemd_quote(interpreter) .. " -E " .. systemd_quote(script) .. " --recover"
    local arguments = { executable("systemd-run"), "--user", "--quiet", "--collect", "--expand-environment=no",
        "--unit=" .. unit, "--service-type=exec", "--property=TimeoutStopSec=90s", "--property=ExecStopPost=" .. recovery }
    for _, key in ipairs({ "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR" }) do
        if os.getenv(key) then arguments[#arguments + 1] = "--setenv=" .. key .. "=" .. os.getenv(key) end
    end
    for _, value in ipairs({ "--", interpreter, "-E", script, "--watch", tostring(pid), start, serial, ready_file }) do
        arguments[#arguments + 1] = value
    end
    local status, output = run(arguments, 10)
    if status ~= 0 then fail("Cannot start monitor watcher: " .. output) end
    local ok, result = pcall(function()
        local deadline = now() + 65
        while now() < deadline do
            local response = read(ready_file)
            if response == "ready" then return 0 end
            if response == "skip" then return 10 end
            if response then fail(response:gsub("^error\n", "")) end
            local active = run({ executable("systemctl"), "--user", "is-active", "--quiet", unit }, 5)
            if active ~= 0 then fail("Watcher failed; inspect journalctl --user -u " .. unit) end
            sleep(0.2)
        end
        fail("Timed out waiting for monitor setup")
    end)
    if not ok then run({ executable("systemctl"), "--user", "stop", "--no-block", unit }, 5) end
    os.remove(ready_file)
    if not ok then fail(result) end
    return result
end
M.attach = attach

function M.preflight()
    if ffi.os ~= "Linux" then fail("Linux is required") end
    if not (os.getenv("XDG_CURRENT_DESKTOP") or ""):upper():find("GNOME", 1, true)
        or os.getenv("XDG_SESSION_TYPE") ~= "wayland" or not os.getenv("WAYLAND_DISPLAY") then
        fail("Run the installer from your GNOME Wayland desktop session")
    end
    if not os.getenv("XDG_RUNTIME_DIR") then fail("XDG_RUNTIME_DIR is not set") end
    for _, name in ipairs({ "gamescope", "luajit", "ddcutil", "systemctl", "systemd-run", "timeout", "env" }) do executable(name) end
    local binary = read(executable("gamescope"), 16777216)
    if not binary or not binary:find("GAMESCOPE_SCRIPT_PATH", 1, true) then
        fail("Cannot confirm Lua scripting support in this Gamescope executable; no files will be installed")
    end
    say("GNOME Wayland, Gamescope scripting and required executables found")
    local status, output = run({ executable("systemctl"), "--user", "is-system-running" }, 5)
    if status ~= 0 and not output:match("^degraded") then fail("systemd user manager is unavailable: " .. output) end
    local _, help = run({ executable("systemd-run"), "--help" }, 5)
    if not help:find("--expand-environment", 1, true) then fail("systemd-run with --expand-environment support is required (systemd 254+)") end
    local process = open_process(C.getpid(), process_start(C.getpid())); process.close()
    say("systemd user manager and pidfd process watching available")
    local desktop = Desktop.new()
    local state = desktop:state()
    local monitor = M.select_monitor(state, M.detect_supported(), os.getenv("GAMESCOPE_LG_MONITOR_SERIAL"))
    if not monitor then fail("No supported LG 27GM950B detected (GSM product 0x5cf8)") end
    local serial, enabled = monitor[1][4], false
    for _, logical in ipairs(state[3]) do
        for _, spec in ipairs(logical[6]) do
            if spec[4] == serial then
                enabled = true
                if #logical[6] ~= 1 then fail("Mirrored LG layouts are not supported; use an extended display layout") end
            end
        end
    end
    if not enabled then fail("Enable the gaming LG in GNOME Displays before installing") end
    status, output = run({ executable("ddcutil"), "--sn", serial, "getvcp", "10", "--brief" }, 20)
    if status ~= 0 then fail("Cannot read the LG over DDC/CI. Check DDC/CI and I2C permissions: " .. output) end
    say("Mutter display access and read-only DDC access verified on " .. monitor[1][1])
    say("Checks passed. No display modes or settings were changed.")
end

local function can_uninstall()
    local runtime = Runtime.new(nil, false)
    if not read(runtime.root .. "/lock") then return end
    local unlock = runtime:lock()
    local busy = read(runtime.snapshot)
    unlock()
    if busy then fail("Close managed Gamescope sessions and recover the desktop before uninstalling") end
end
local function main(arguments)
    local action = arguments[1]
    if action == "--check" then M.preflight(); return 0 end
    if action == "--can-uninstall" then can_uninstall(); return 0 end
    if action == "--help" or not action then
        print("Usage: luajit gamescope-lg-dual-mode.lua --check | --recover\nInternal: --attach PID | --watch PID START SERIAL READY_FILE")
        return 0
    end
    local runtime = Runtime.new()
    if action == "--attach" and #arguments == 2 and arguments[2]:match("^%d+$") then
        return attach(runtime, tonumber(arguments[2]))
    elseif action == "--watch" and #arguments == 5 and arguments[2]:match("^%d+$") then
        watch(runtime, tonumber(arguments[2]), arguments[3], arguments[4], arguments[5]); return 0
    elseif action == "--recover" and #arguments == 1 then
        local ok, unlock = pcall(runtime.lock, runtime)
        if not ok then say("Recovery skipped: another monitor session holds the lock"); return 0 end
        local restored, message = pcall(function()
            if read(runtime.snapshot) then runtime:restore(Desktop.new()) end
        end)
        unlock()
        if not restored then fail(message) end
        return 0
    end
    fail("Invalid command; use --help")
end
M.main = main

if LIBRARY then return M end
if rawget(_G, "gamescope") then
    if os.getenv("GAMESCOPE_LG_DUAL_MODE") == "0" then return end
    -- The host interpreter must not inherit Steam's library/preload environment.
    local arguments = { "/usr/bin/env", "-u", "LD_PRELOAD", "-u", "LD_LIBRARY_PATH", "-u", "LUA_INIT",
        "luajit", "-E", realpath(SOURCE), "--attach", tostring(C.getpid()) }
    local status = exit_status(os.execute(command_text(arguments)))
    if status == 0 then
        if gamescope.convars.adaptive_sync then gamescope.convars.adaptive_sync.value = true end
    elseif status ~= 10 then
        io.stderr:write("[gamescope-lg-dual-mode] Setup failed; use GAMESCOPE_LG_DUAL_MODE=0 to bypass.\n")
        os.exit(1)
    end
else
    C.umask(63)
    local arguments = {}; for i = 1, #arg do arguments[i] = arg[i] end
    local ok, result = pcall(main, arguments)
    if not ok then say("ERROR: " .. tostring(result)); os.exit(1) end
    os.exit(result or 0)
end

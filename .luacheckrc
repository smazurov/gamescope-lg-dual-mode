-- Static checks target LuaJIT, including its Lua 5.1 standard library.
std = "luajit"
-- Keep formatting separate from static analysis of the existing compact code.
max_line_length = false

-- Gamescope supplies this table. Only the adaptive-sync value is writable here.
files["gamescope-lg-dual-mode.lua"].read_globals = {
    gamescope = {
        fields = {
            convars = {
                fields = {
                    adaptive_sync = {
                        fields = { value = { read_only = false } },
                    },
                },
            },
        },
    },
}

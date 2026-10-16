-- Lenient config: this codebase targets LuaJIT (Lua 5.1 + extensions) and
-- talks to the game engine and Windows FFI through globals/patterns luacheck
-- doesn't know about. Goal for now is catching real mistakes (syntax errors,
-- genuinely undefined globals) without flooding PRs with style noise.
std = "luajit"
max_line_length = false
ignore = {
    "212", -- unused argument (test files intentionally ignore some)
    "213", -- unused loop variable
    "231", -- unused local variable (common in destructive/table-shape tests)
    "421", -- shadowing a local (widespread, stylistic, e.g. reused `mode`/`ok` names in tests)
    "431", -- shadowing an upvalue (same as above)
}
globals = {
    -- Stingray/HD2 engine + mod loader globals referenced throughout src/ and tests/
    "stingray", "CowboyBingusModLoader", "update", "render", "shutdown",
}

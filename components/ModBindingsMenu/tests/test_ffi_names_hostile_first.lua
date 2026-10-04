-- tests/test_ffi_names.lua in a fresh VM, after a careless mod declared every
-- Windows name Mod Bindings Menu calls with a prototype that does not fit
-- (ReadProcessMemory with an integer address).
rawset(_G, 'MBM_FFI_ORDER', 'hostile-first')
dofile((arg[0]:match('^(.*[/\\])') or './') .. 'test_ffi_names.lua')

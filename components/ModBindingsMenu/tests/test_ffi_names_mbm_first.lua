-- tests/test_ffi_names.lua in a fresh VM, with Mod Bindings Menu loaded before
-- the other mod declares its SDK prototypes.
rawset(_G, 'MBM_FFI_ORDER', 'mbm-first')
dofile((arg[0]:match('^(.*[/\\])') or './') .. 'test_ffi_names.lua')

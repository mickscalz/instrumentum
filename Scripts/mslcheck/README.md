# mslcheck: type-check the app's Metal shaders without a Mac

`python3 Scripts/mslcheck/mslcheck.py . [--only SkyShaders,MoonlitLakeShaders] [--git REV] [--out DIR]`

It finds every shader program under `Sources/InStrumApp` (each `static let source = A + B + """..."""`, resolving
references such as `SkyShaders.common`), gives unsuffixed floating literals an `f` (MSL literals are float), and runs
`clang++ -fsyntax-only` on each through `shim/metal_stdlib`, a small stand-in for Metal's standard library: clang
ext vectors (swizzles `.xyzw`/`.rgba`), constructors, matrices, the maths functions, textures and samplers, and
function constants (`[[function_constant(i)]]` globals and `is_function_constant_defined`).

It catches undeclared identifiers, wrong argument counts and types, vector size mismatches and missing functions. It
does **not** model address spaces (Metal lets structs be copied out of `constant` memory, which clang's address spaces
refuse), and it is not the Metal compiler: CI's `test*ShadersCompile` tests stay the real check. All of main's shaders
passed it on 4 Nov 2026.

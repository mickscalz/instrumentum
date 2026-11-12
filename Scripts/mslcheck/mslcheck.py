#!/usr/bin/env python3
"""Type-check the app's Metal shaders with clang through a small MSL shim (no Metal compiler on Linux).

Usage: mslcheck.py <repo root> [--out DIR] [--only NAME[,NAME...]] [--git REV]
Finds every `static let NAME = <a + b + triple-quoted literal>` in Sources/InStrumApp, resolves the concatenations
(e.g. `SkyShaders.common + OceanShaders.common + literal`), gives unsuffixed floating literals an `f`
(MSL literals are float), and runs `clang++ -fsyntax-only` on each shader program (the statics named `source`).
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))

def swift_files(root, rev):
    base = 'Sources/InStrumApp'
    if rev:
        out = subprocess.run(['git', '-C', root, 'ls-tree', '-r', '--name-only', rev, base], capture_output=True, text=True).stdout.split()
        for p in out:
            if p.endswith('.swift'):
                yield p, subprocess.run(['git', '-C', root, 'show', f'{rev}:{p}'], capture_output=True, text=True).stdout
    else:
        for d, _, fs in os.walk(os.path.join(root, base)):
            for f in fs:
                if f.endswith('.swift'):
                    p = os.path.join(d, f)
                    yield os.path.relpath(p, root), open(p, encoding='utf-8').read()

def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            n = s[i + 1]
            out.append({'n': '\n', 't': '\t', '\\': '\\', '"': '"', "'": "'", '0': '\0'}.get(n, '\\' + n)); i += 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def parse_statics(path, text):
    """Returns {(Type, name): (path, line, [parts])} where parts are ('lit', str) or ('ref', 'Type.name' or 'name')."""
    res = {}
    lines = text.split('\n')
    type_stack = []
    i = 0
    cur_type = None
    while i < len(lines):
        line = lines[i]
        m = re.match(r'\s*(?:public |internal |private |fileprivate )?(?:final )?(?:enum|struct|class|extension)\s+(\w+)', line)
        if m:
            cur_type = m.group(1)
        m = re.match(r'\s*(?:public |internal |private |fileprivate )?static let (\w+)\s*(?::\s*String\s*)?=\s*(.*)$', line)
        if m and ('"""' in m.group(2) or re.match(r'^[\w.]+\s*\+', m.group(2))):
            name, rest = m.group(1), m.group(2)
            parts, start_line = [], i + 1
            # Tokens before the first literal: refs joined by +
            while True:
                rest = rest.strip()
                if rest.startswith('"""'):
                    # multi-line literal: content lines until a line whose stripped text starts with """
                    j = i + 1
                    body = []
                    while j < len(lines) and not lines[j].strip().startswith('"""'):
                        body.append(lines[j]); j += 1
                    indent = re.match(r'(\s*)', lines[j]).group(1) if j < len(lines) else ''
                    content = '\n'.join(l[len(indent):] if l.startswith(indent) else l.lstrip() for l in body)
                    parts.append(('lit', unescape(content) + '\n'))
                    after = lines[j].strip()[3:].strip() if j < len(lines) else ''
                    i = j
                    if after.startswith('+'):
                        rest = after[1:]
                        if not rest.strip():
                            i += 1; rest = lines[i]
                        continue
                    break
                mm = re.match(r'([\w.]+)\s*\+\s*(.*)$', rest)
                if mm:
                    parts.append(('ref', mm.group(1)))
                    rest = mm.group(2)
                    if not rest.strip():
                        i += 1; rest = lines[i]
                    continue
                mm = re.match(r'([\w.]+)\s*$', rest)
                if mm:
                    parts.append(('ref', mm.group(1)))
                break
            res[(cur_type, name)] = (path, start_line, parts)
        i += 1
    return res

def resolve(statics, key, seen=()):
    path, line, parts = statics[key]
    out = []
    for kind, v in parts:
        if kind == 'lit':
            out.append(v)
        else:
            ref = tuple(v.split('.')) if '.' in v else (key[0], v)
            if ref not in statics:
                raise KeyError(f'{key}: unknown reference {v}')
            if ref in seen:
                raise KeyError(f'cycle at {ref}')
            out.append(resolve(statics, ref, seen + (key,)))
    return ''.join(out)

LIT = re.compile(r'(?<![\w.])((?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)(?![\w.])')

def msl_to_cpp(src):
    return LIT.sub(lambda m: m.group(1) + 'f', src)

# Metal's built-in scalar and vector type names: C++ lets a variable shadow a typedef, Metal's compiler does not (13 Nov:
# `float half = …` passed here and failed on the real compiler, so two worlds had no renderer). Names Metal only uses
# as attributes or library types (`patch`, `flat`, `texture`, `sampler`) are fine as variables, and shipping shaders
# use them.
MSL_RESERVED = ('half|half2|half3|half4|char|uchar|short|ushort|uint|uint2|uint3|uint4|long|ulong|bool2|bool3|bool4|'
                'float2|float3|float4|int2|int3|int4|size_t|ptrdiff_t')
RESERVED_DECL = re.compile(r'\b(?:float|int|uint|half|bool)[234]?(?:x[234])?\s+(?:[A-Za-z_]\w*\s*(?:=[^,;]*)?,\s*)*(' + MSL_RESERVED + r')\s*[=;,)\[]')

def reserved_names(src):
    out = []
    for n, line in enumerate(src.split('\n'), 1):
        code = line.split('//')[0]
        m = RESERVED_DECL.search(code)
        if m:
            out.append((n, m.group(1), code.strip()))
    return out

def main():
    root = sys.argv[1]
    out = os.path.join(HERE, 'out'); only = None; rev = None
    args = sys.argv[2:]
    while args:
        a = args.pop(0)
        if a == '--out': out = args.pop(0)
        elif a == '--only': only = set(args.pop(0).split(','))
        elif a == '--git': rev = args.pop(0)
    os.makedirs(out, exist_ok=True)
    statics = {}
    for p, t in swift_files(root, rev):
        statics.update(parse_statics(p, t))
    programs = sorted(k for k in statics if k[1] == 'source' and k[0])
    failures = 0
    for key in programs:
        if only and key[0] not in only:
            continue
        try:
            src = resolve(statics, key)
        except KeyError as e:
            print(f'== {key[0]}: cannot resolve: {e}'); failures += 1; continue
        if 'metal_stdlib' not in src:
            continue
        fn = os.path.join(out, f'{key[0]}.cpp')
        open(fn, 'w').write(msl_to_cpp(src))
        r = subprocess.run(['clang++', '-std=c++17', '-fsyntax-only', '-ferror-limit=60', '-I', os.path.join(HERE, 'shim'),
                            '-Wno-unknown-attributes', '-Wno-ignored-attributes', '-Wno-unused-value', '-x', 'c++', fn],
                           capture_output=True, text=True)
        errs = [l for l in r.stderr.split('\n') if ': error:' in l]
        taken = reserved_names(src)
        bad = r.returncode != 0 or bool(taken)
        status = 'OK' if not bad else f'{len(errs) + len(taken)} error(s)'
        print(f'== {key[0]} ({statics[key][0]}): {status}')
        for n, name, code in taken:
            print(f'   {key[0]}.cpp:{n}: error: `{name}` is a Metal type name, not a variable name: {code[:120]}')
        if bad:
            failures += 1
            for l in r.stderr.split('\n'):
                if ': error:' in l or ': note:' in l:
                    print('   ' + l.replace(fn, key[0] + '.cpp'))
    sys.exit(1 if failures else 0)

if __name__ == '__main__':
    main()

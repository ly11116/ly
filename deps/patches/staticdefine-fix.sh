#!/bin/bash -e
# staticdefine.sh (robust) — 从 compile_commands.json 提取 asbestos.c 的编译参数
# 原版按"固定砍尾部9个token"，meson/clang版本变化时会砍错 → 这里按token类别切
# Usage: staticdefine.sh <compile_commands.json> <input.c> <output.h> <depfile>
compile_commands=$1
input=$2
output=$3
dep=$4
flags=$(python3 - "$compile_commands" "$output" "$dep" <<'PYEOF'
import json, shlex, sys
cc, out, dep = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cc) as f:
    data = json.load(f)
ent = None
for e in data:
    if e.get('file', '').endswith('asbestos/asbestos.c'):
        ent = e
        break
if ent is None:
    sys.exit('asbestos/asbestos.c not found in compile_commands.json')
cmd = ent.get('command')
if cmd is None:
    cmd = ' '.join(ent.get('arguments', []))
toks = shlex.split(cmd)
# 砍掉第一个输出/依赖参数及其后全部（-MD/-MQ/-MF/-o/-c/-S），只保留 -I/-D/-isysroot 等
cut = len(toks)
for i, t in enumerate(toks):
    if t in ('-MD', '-MQ', '-MF', '-o', '-c', '-S'):
        cut = i
        break
core = toks[:cut] + ['-MD', '-MQ', out, '-MF', dep]
print(' '.join(core))
PYEOF
)
$flags "$input" -include "$(dirname "$0")/staticdefine.h" -S -o - | \
sed -ne 's:^[[:space:]]*\.ascii[[:space:]]*"\(.*\)".*:\1:;
         /^->/{s:->#\(.*\):/* \1 */:;
         s:^->\([^ ]*\) [\$$#]*\([^ ]*\) \(.*\):#define \1 \2 /* \3 */:;
         s:->::; p;}' > "$output"

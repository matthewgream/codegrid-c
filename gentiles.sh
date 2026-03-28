#!/bin/bash
# gen_tiles.sh — Convert codegrid JSON tiles into native C struct data.
#
# Encoding:
#   _cgrd: 3-bit + escape bitstream (row data, pre-decoded)
#   _cgrb: 4-bit dictionary + escape bitstream (row pool)
#   _cgz9/_cgz13: zoom tables split by level, profile-factored, binary-searchable
#
# Usage:  bash gen_tiles.sh path/to/tiles > codegrid_tiles.h
#    or:  bash gen_tiles.sh path/to/tiles codegrid_tiles.h

set -euo pipefail

TILES_DIR="${1:?Usage: $0 <tiles-dir> [output-file]}"
OUTFILE="${2:-/dev/stdout}"

TILES_DIR="${TILES_DIR%/}"
if [ ! -d "$TILES_DIR" ]; then
    echo "Error: '$TILES_DIR' is not a directory" >&2
    exit 1
fi

mapfile -t JSON_FILES < <(find "$TILES_DIR" -name '*.json' -type f | sort -V)
COUNT=${#JSON_FILES[@]}
if [ "$COUNT" -eq 0 ]; then
    echo "Error: no .json files found in '$TILES_DIR'" >&2
    exit 1
fi
echo "Found $COUNT JSON files in '$TILES_DIR'" >&2

python3 - "$TILES_DIR" "$OUTFILE" "${JSON_FILES[@]}" <<'PYEOF'
import sys, json, os
from collections import Counter

tiles_dir  = sys.argv[1]
outfile    = sys.argv[2]
json_files = sys.argv[3:]

def parse_key(k):
    if isinstance(k, str):
        return -1 if k == '' else int(k)
    return int(k)

def utf_decode(c):
    if c >= 93: c -= 1
    if c >= 35: c -= 1
    return c - 32

# ── BitWriter ───────────────────────────────────────────────────────

class BitWriter:
    def __init__(self, prealloc=256*1024):
        self.buf = bytearray(prealloc)
        self.cap = prealloc
        self.pos = 0

    def write(self, value, nbits):
        p = self.pos
        need = (p + nbits + 7) >> 3
        if need >= self.cap:
            ext = max(self.cap, need + 1)
            self.buf.extend(b'\x00' * ext)
            self.cap = len(self.buf)
        for i in range(nbits):
            if (value >> i) & 1:
                self.buf[p >> 3] |= 1 << (p & 7)
            p += 1
        self.pos = p

    def pad(self, n=3):
        for _ in range(n):
            self.buf.append(0)
            self.cap += 1

    def get(self):
        used = (self.pos + 7) >> 3
        return bytes(self.buf[:used])

# ── String blob (attr code/subcode only) ────────────────────────────

blob_bytes = bytearray()
blob_dedup = {}

def intern_str(s):
    if s in blob_dedup:
        return blob_dedup[s]
    off = len(blob_bytes)
    blob_dedup[s] = off
    blob_bytes.extend(s.encode('utf-8'))
    blob_bytes.append(0)
    return off

# ── Row pools ───────────────────────────────────────────────────────

row_data    = []
row_offsets = [0]
row_dedup   = {}

def intern_row(decoded_values):
    key = tuple(decoded_values)
    if key in row_dedup:
        return row_dedup[key]
    idx = len(row_dedup)
    row_dedup[key] = idx
    row_data.extend(decoded_values)
    row_offsets.append(len(row_data))
    return idx

def resolve_row(rows, idx, depth=0):
    s = rows[idx]
    cp_len = len(s)
    if cp_len > 1 and cp_len < 4 and depth < 10:
        try:
            redir = int(s)
            if 0 <= redir < len(rows):
                return resolve_row(rows, redir, depth + 1)
        except ValueError:
            pass
    return s

def decode_row(s):
    return [utf_decode(ord(c)) for c in s]

# ── Grid pools ──────────────────────────────────────────────────────

row_pool      = []
row_seq_dedup = {}
key_pool      = []
key_seq_dedup = {}
attr_pool     = []

def pack_rows(rows):
    resolved = []
    for i in range(len(rows)):
        s = resolve_row(rows, i)
        resolved.append(tuple(decode_row(s)))
    seq_key = tuple(resolved)
    if seq_key in row_seq_dedup:
        return row_seq_dedup[seq_key]
    ri_off = len(row_pool)
    for decoded in resolved:
        row_pool.append(intern_row(decoded))
    row_seq_dedup[seq_key] = ri_off
    return ri_off

def pack_keys(keys):
    ints = tuple(parse_key(k) for k in keys)
    if ints in key_seq_dedup:
        return key_seq_dedup[ints]
    keys_off = len(key_pool)
    key_pool.extend(ints)
    key_seq_dedup[ints] = (keys_off, len(ints))
    return (keys_off, len(ints))

def pack_grid(grid_obj):
    rows = grid_obj['grid']
    keys = grid_obj['keys']
    data = grid_obj.get('data', None)
    size = len(rows)

    ri_off = pack_rows(rows)
    keys_off, num_keys = pack_keys(keys)

    attrs_off = len(attr_pool)
    num_attrs = 0
    if data and len(data) > 0:
        al = sorted(((int(k), v) for k, v in data.items()), key=lambda x: x[0])
        for key, v in al:
            code = v.get('code', '')
            subcode = v.get('subcode', None)
            attr_pool.append((key, intern_str(code), intern_str(subcode) if subcode else -1))
        num_attrs = len(al)

    return (size, ri_off, num_keys, keys_off, num_attrs, attrs_off)

# ── Collect ─────────────────────────────────────────────────────────

world_grid = None
zoom_grids = []

for fpath in json_files:
    with open(fpath, 'rb') as fp:
        obj = json.loads(fp.read())
    if os.path.basename(fpath) == 'worldgrid.json':
        world_grid = obj
        continue
    for z_str, z_val in obj.items():
        zoom = int(z_str)
        for tx_str, tx_val in z_val.items():
            tx = int(tx_str)
            for ty_str, grid_obj in tx_val.items():
                ty = int(ty_str)
                if 'grid' in grid_obj and 'keys' in grid_obj:
                    zoom_grids.append((zoom, tx, ty, grid_obj))

zoom_grids.sort(key=lambda x: (x[0], x[1], x[2]))
assert world_grid, "worldgrid.json not found!"

# ── Pack grids ──────────────────────────────────────────────────────

wg = pack_grid(world_grid)

ga_off = len(attr_pool)
wd = world_grid.get('data', {})
ga_list = sorted(((int(k), v) for k, v in wd.items()), key=lambda x: x[0])
for key, v in ga_list:
    code = v.get('code', '')
    subcode = v.get('subcode', None)
    attr_pool.append((key, intern_str(code), intern_str(subcode) if subcode else -1))
ga_count = len(ga_list)

zg_infos = []
for zoom, tx, ty, gobj in zoom_grids:
    zg_infos.append((zoom, tx, ty, pack_grid(gobj)))

# ── Encode _cgrd bitstream ──────────────────────────────────────────

print(f"Encoding _cgrd bitstream ({len(row_dedup)} rows, {len(row_data)} values)...", file=sys.stderr)
max_val = max(row_data) if row_data else 0
assert max_val < 512, f"Max row value {max_val} doesn't fit in 9-bit escape!"

cgrd_bw = BitWriter(len(row_data) * 2)
new_cgro = []

for row_id in range(len(row_dedup)):
    new_cgro.append(cgrd_bw.pos)
    start = row_offsets[row_id]
    end = row_offsets[row_id + 1]
    values = row_data[start:end]
    elem_count = len(values)
    assert elem_count < 1024

    cgrd_bw.write(elem_count, 10)
    for v in values:
        if v < 7:
            cgrd_bw.write(v, 3)
        else:
            cgrd_bw.write(7, 3)
            cgrd_bw.write(v, 9)

cgrd_bw.pad(3)
cgrd_bytes = cgrd_bw.get()
print(f"  _cgrd bitstream: {len(cgrd_bytes):,} bytes", file=sys.stderr)

# ── Encode _cgrb bitstream ──────────────────────────────────────────

print(f"Encoding _cgrb bitstream ({len(row_pool)} values)...", file=sys.stderr)
max_ri = max(row_pool) if row_pool else 0
assert max_ri.bit_length() <= 13

freq = Counter(row_pool)
top15 = [val for val, cnt in freq.most_common(15)]
lut_to_code = {val: idx for idx, val in enumerate(top15)}

cgrb_bw = BitWriter(len(row_pool))
ri_elem_to_bit = []

for v in row_pool:
    ri_elem_to_bit.append(cgrb_bw.pos)
    if v in lut_to_code:
        cgrb_bw.write(lut_to_code[v], 4)
    else:
        cgrb_bw.write(15, 4)
        cgrb_bw.write(v, 13)

cgrb_bw.pad(3)
cgrb_bytes = cgrb_bw.get()
print(f"  _cgrb bitstream: {len(cgrb_bytes):,} bytes", file=sys.stderr)

# ── Convert ri_off to bit offsets ───────────────────────────────────

def convert_ri_off(elem_off):
    return ri_elem_to_bit[elem_off]

wg_size, wg_ri, wg_nk, wg_ko, wg_na, wg_ao = wg
wg = (wg_size, convert_ri_off(wg_ri), wg_nk, wg_ko, wg_na, wg_ao)

converted_zg = []
for zoom, tx, ty, info in zg_infos:
    size, ri_off, nk, ko, na, ao = info
    converted_zg.append((zoom, tx, ty, (size, convert_ri_off(ri_off), nk, ko, na, ao)))

# ── Build profile table and zoom tables ─────────────────────────────

# Verify constants
all_na = set(info[4] for _,_,_,info in converted_zg)
all_ao = set(info[5] for _,_,_,info in converted_zg)
assert len(all_na) == 1, f"num_attrs not constant: {all_na}"
assert len(all_ao) == 1, f"attrs_off not constant: {all_ao}"
const_ao = all_ao.pop()
print(f"  Constant: num_attrs=0, attrs_off={const_ao}", file=sys.stderr)

# Profile = (size, num_keys, keys_off) — the non-constant, non-per-tile fields
profile_dedup = {}
profiles = []

def get_profile_id(size, num_keys, keys_off):
    key = (size, num_keys, keys_off)
    if key in profile_dedup:
        return profile_dedup[key]
    pid = len(profiles)
    profile_dedup[key] = pid
    profiles.append(key)
    return pid

# Split into zoom 9 and zoom 13, create slim entries
z9_entries = []   # (tx, ty, profile_id, ri_off)
z13_entries = []

for zoom, tx, ty, info in converted_zg:
    size, ri_off, nk, ko, na, ao = info
    pid = get_profile_id(size, nk, ko)
    entry = (tx, ty, pid, ri_off)
    if zoom == 9:
        z9_entries.append(entry)
    elif zoom == 13:
        z13_entries.append(entry)
    else:
        assert False, f"Unexpected zoom {zoom}"

# Sort by (tx, ty) for binary search
z9_entries.sort(key=lambda e: (e[0], e[1]))
z13_entries.sort(key=lambda e: (e[0], e[1]))

print(f"  Profiles: {len(profiles)}", file=sys.stderr)
print(f"  Zoom 9: {len(z9_entries)} entries", file=sys.stderr)
print(f"  Zoom 13: {len(z13_entries)} entries", file=sys.stderr)

# Check profile_id fits in uint16_t
assert len(profiles) <= 0xFFFF

# ── Stats ───────────────────────────────────────────────────────────

# Old _cgz cost
old_cgz = len(converted_zg) * 20
# New cost: profiles + two zoom tables
#   profile: 8 bytes each (uint8_t size + padding? let's use packed: 1+2+4=7, pad to 8)
#   Actually packed: uint8_t size, uint16_t num_keys, uint32_t keys_off = 7 bytes
#   zoom entry: uint16_t tx, uint16_t ty, uint16_t profile_id, uint32_t ri_off = 10 bytes
profile_bytes = len(profiles) * 7
z9_bytes = len(z9_entries) * 10
z13_bytes = len(z13_entries) * 10
new_total_z = profile_bytes + z9_bytes + z13_bytes

print(f"\n  _cgz: was {old_cgz:,} bytes", file=sys.stderr)
print(f"  profiles: {profile_bytes:,} bytes ({len(profiles)} × 7)", file=sys.stderr)
print(f"  z9 table: {z9_bytes:,} bytes ({len(z9_entries)} × 10)", file=sys.stderr)
print(f"  z13 table: {z13_bytes:,} bytes ({len(z13_entries)} × 10)", file=sys.stderr)
print(f"  new zoom total: {new_total_z:,} bytes (saved {old_cgz - new_total_z:,})", file=sys.stderr)

total = (len(cgrd_bytes) + len(new_cgro)*4 + len(cgrb_bytes) + len(top15)*2 +
         len(key_pool)*2 + len(attr_pool)*6 + new_total_z + len(blob_bytes))
print(f"\n  TOTAL: ~{total:,} bytes ({total/1024:.0f} KB)", file=sys.stderr)

# ── Emit ────────────────────────────────────────────────────────────

def emit_uint8_array(f, name, data, per_line=32):
    f.write(f'static const uint8_t {name}[{len(data)}] = {{')
    for i, v in enumerate(data):
        if i % per_line == 0: f.write('\n')
        f.write(f'{v},')
    f.write('\n};\n\n')

def emit_uint32_array(f, name, data, per_line=12):
    f.write(f'static const uint32_t {name}[{len(data)}] = {{')
    for i, v in enumerate(data):
        if i % per_line == 0: f.write('\n')
        f.write(f'{v},')
    f.write('\n};\n\n')

def emit_uint16_array(f, name, data, per_line=16):
    f.write(f'static const uint16_t {name}[{len(data)}] = {{')
    for i, v in enumerate(data):
        if i % per_line == 0: f.write('\n')
        f.write(f'{v},')
    f.write('\n};\n\n')

def emit_int16_array(f, name, data, per_line=20):
    f.write(f'static const int16_t {name}[{len(data)}] = {{')
    for i, v in enumerate(data):
        if i % per_line == 0: f.write('\n')
        f.write(f'{v},')
    f.write('\n};\n\n')

def c_escape_bytes(b):
    out = []
    prev_hex = False
    prev_oct = False
    for byte in b:
        ch = chr(byte) if 32 <= byte < 127 else None
        if prev_hex and ch and ch in '0123456789abcdefABCDEF':
            out.append('" "')
        if prev_oct and ch and ch in '01234567':
            out.append('" "')
        prev_hex = False
        prev_oct = False
        if byte == 0:
            out.append('\\0')
            prev_oct = True
        elif byte == ord('\\'): out.append('\\\\')
        elif byte == ord('"'):  out.append('\\"')
        elif byte == ord('\n'): out.append('\\n')
        elif byte == ord('\r'): out.append('\\r')
        elif byte == ord('\t'): out.append('\\t')
        elif 32 <= byte < 127:  out.append(chr(byte))
        else:
            out.append(f'\\x{byte:02x}')
            prev_hex = True
    return ''.join(out)

f = open(outfile, 'w') if outfile != '/dev/stdout' else sys.stdout

f.write('''\
/*
 * codegrid_tiles.h — Auto-generated by gen_tiles.sh
 *
 * _cgrd: 3-bit + escape bitstream (row data)
 * _cgrb: 4-bit dictionary + escape bitstream (row pool)
 * Zoom tables: profile-factored, split by zoom, binary-searchable on (tx,ty).
 * DO NOT EDIT BY HAND.
 */
#ifndef CODEGRID_TILES_H
#define CODEGRID_TILES_H

#include <stdint.h>

/* ── structures ─────────────────────────────────────────────────── */

struct __attribute__((packed)) cg_attr    { int16_t key; int16_t code_off, subcode_off; };
struct __attribute__((packed)) cg_profile { uint8_t size; uint16_t num_keys; uint32_t keys_off; };
struct __attribute__((packed)) cg_ztile  { uint16_t tx, ty, profile_id; uint32_t ri_off; };

/* world grid (zoom 0) — kept as full descriptor */
struct __attribute__((packed)) cg_grid   { uint16_t size; uint32_t ri_off; uint16_t num_keys; uint32_t keys_off; uint16_t num_attrs; int16_t attrs_off; };

/* ── bit reader ─────────────────────────────────────────────────── */

static inline uint32_t cg_read_bits(const uint8_t *s, uint32_t boff, int n) {
    uint32_t B = boff >> 3;
    uint32_t b = boff & 7;
    uint32_t raw = (uint32_t)s[B] | ((uint32_t)s[B+1] << 8) | ((uint32_t)s[B+2] << 16);
    return (raw >> b) & ((1u << n) - 1);
}

''')

# constants
f.write(f'#define CG_ZOOM_ATTRS_OFF {const_ao}\n\n')

# _cgrd bitstream
f.write(f'/* row data bitstream: {len(cgrd_bytes):,} bytes */\n')
emit_uint8_array(f, '_cgrd', cgrd_bytes)

# _cgro
f.write(f'/* bit offsets into _cgrd per row ({len(new_cgro)} rows) */\n')
emit_uint32_array(f, '_cgro', new_cgro)

# _cgrb bitstream
f.write(f'/* row pool bitstream: {len(cgrb_bytes):,} bytes */\n')
emit_uint8_array(f, '_cgrb', cgrb_bytes)

# _cgr_lut
f.write(f'/* dictionary for _cgrb: top 15 row indices */\n')
emit_uint16_array(f, '_cgr_lut', top15)

# key pool
emit_int16_array(f, '_cgk', key_pool)

# string blob
CHUNK = 4096
f.write(f'/* {len(blob_bytes)} bytes — attr code/subcode strings */\n')
f.write(f'static const char _cgblob[{len(blob_bytes)}] =\n')
for i in range(0, len(blob_bytes), CHUNK):
    chunk = blob_bytes[i:i+CHUNK]
    f.write(f'    "{c_escape_bytes(chunk)}"\n')
f.write(';\n')
f.write('#define CGB(off) (&_cgblob[(off)])\n\n')

# attr pool
f.write(f'static const struct cg_attr _cga[{len(attr_pool)}] = {{')
for i, (k, c, s) in enumerate(attr_pool):
    if i % 5 == 0: f.write('\n')
    f.write(f'{{{k},{c},{s}}},')
f.write('\n};\n\n')

# world grid
size, ri_off, nk, ko, na, ao = wg
f.write(f'static const struct cg_grid cg_world = {{{size},{ri_off},{nk},{ko},{na},{ao}}};\n')
f.write(f'#define CG_GA_OFF {ga_off}\n')
f.write(f'#define CG_GA_COUNT {ga_count}\n\n')

# profile table
f.write(f'/* {len(profiles)} grid profiles: (size, num_keys, keys_off) */\n')
f.write(f'static const struct cg_profile _cgp[{len(profiles)}] = {{\n')
for size, nk, ko in profiles:
    f.write(f'{{{size},{nk},{ko}}},\n')
f.write(f'}};\n\n')

# zoom 9 table
f.write(f'/* zoom 9: {len(z9_entries)} tiles, sorted by (tx,ty) */\n')
f.write(f'static const struct cg_ztile _cgz9[{len(z9_entries)}] = {{\n')
for tx, ty, pid, ri_off in z9_entries:
    f.write(f'{{{tx},{ty},{pid},{ri_off}}},\n')
f.write(f'}};\n')
f.write(f'#define CG_Z9_COUNT {len(z9_entries)}\n\n')

# zoom 13 table
f.write(f'/* zoom 13: {len(z13_entries)} tiles, sorted by (tx,ty) */\n')
f.write(f'static const struct cg_ztile _cgz13[{len(z13_entries)}] = {{\n')
for tx, ty, pid, ri_off in z13_entries:
    f.write(f'{{{tx},{ty},{pid},{ri_off}}},\n')
f.write(f'}};\n')
f.write(f'#define CG_Z13_COUNT {len(z13_entries)}\n\n')

f.write('#endif /* CODEGRID_TILES_H */\n')

if f is not sys.stdout:
    f.close()

print(f"\nGenerated -> {outfile}", file=sys.stderr)
PYEOF

echo "Done." >&2

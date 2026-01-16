#!/bin/bash

# Morph Disassembler
# Uses objdump to disassemble .morph binaries (raw machine code)

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.morph> [output.txt]"
    exit 1
fi

INPUT="$1"
OUTPUT="${2:-/dev/stdout}"
TEMP_CODE="/tmp/morph_disasm_$$.bin"
BASE_ADDR=$((0x400078))

# 1. Check Magic
if [[ ! -f "$INPUT" ]]; then
    echo "Error: File $INPUT not found."
    exit 1
fi

MAGIC=$(head -c 8 "$INPUT")
if [[ "$MAGIC" != "VZOELFOX" ]]; then
    echo "Error: Not a valid VZOELFOX .morph file."
    exit 1
fi

# 2. Extract Code (Skip 8 bytes)
tail -c +9 "$INPUT" > "$TEMP_CODE"

# 3. Disassemble
# -b binary: Treat as raw binary
# -m i386:x86-64: Architecture
# -M intel: Intel syntax
# --adjust-vma: Set base address to match parser's BASE_ADDR
echo "Disassembling $INPUT..." >&2
objdump -D -b binary -m i386:x86-64 -M intel --adjust-vma="$BASE_ADDR" "$TEMP_CODE" > "$OUTPUT"

# Cleanup
rm -f "$TEMP_CODE"

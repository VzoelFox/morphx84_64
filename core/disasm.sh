#!/bin/bash

# Morph Disassembler
# Uses objdump to disassemble .morph binaries (raw machine code)

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.morph> [output.txt]"
    exit 1
fi

INPUT="$1"
OUTPUT="${2:-/dev/stdout}"
SYM_FILE="output.sym"
TEMP_CODE="/tmp/morph_disasm_$$.bin"
TEMP_DISASM="/tmp/morph_disasm_raw_$$.txt"
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
objdump -D -b binary -m i386:x86-64 -M intel --adjust-vma="$BASE_ADDR" "$TEMP_CODE" > "$TEMP_DISASM"

# 4. Symbol Resolution (if .sym exists)
if [[ -f "$SYM_FILE" ]]; then
    echo "Resolving symbols using $SYM_FILE..." >&2

    # Process line by line
    while IFS= read -r line; do
        # Extract address from line (first field, hex without 0x)
        # objdump format: "  400123: ..."
        # We look for hex patterns in the operands too.

        # Simple Replace Strategy:
        # Load all symbols into SED commands
        # Example: s/400123/map_create/g
        # Note: Avoid partial matches? Hex addrs usually distinct enough in 0x40... range

        # Use awk to inject symbols?
        # Actually, let's just generate a big sed script from sym file.
        :
    done < "$TEMP_DISASM"

    # Construct SED script
    # Pattern: Replace distinct hex address with Name ( <ADDR>)
    # Symbols in sym file: "400123 name"
    # We want to replace "400123" with "name (400123)" or just "name"

    SED_SCRIPT="/tmp/morph_sym_$$.sed"
    > "$SED_SCRIPT"

    while read -r addr name; do
        # Replace address in call/jmp targets (often appear as just hex)
        # Also put label name at the definition line (start of line)

        # 1. Definition: "  400123:" -> "  400123 <name>:"
        echo "s/  $addr:/  $addr <$name>:/g" >> "$SED_SCRIPT"

        # 2. Call Target: "call   0x400123" -> "call   0x400123 <name>"
        # objdump output usually "call   0x400123"
        echo "s/0x$addr/0x$addr <$name>/g" >> "$SED_SCRIPT"
    done < "$SYM_FILE"

    sed -f "$SED_SCRIPT" "$TEMP_DISASM" > "$OUTPUT"
    rm -f "$SED_SCRIPT"
else
    cat "$TEMP_DISASM" > "$OUTPUT"
fi

# Cleanup
rm -f "$TEMP_CODE" "$TEMP_DISASM"

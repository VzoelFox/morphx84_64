#!/bin/bash

# Morph Runner - Executes .morph files by wrapping them in ELF

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.morph>"
    exit 1
fi

INPUT="$1"
TEMP_EXEC="/tmp/morph_exec_$$"

# 1. Check Magic
MAGIC=$(head -c 8 "$INPUT")
if [[ "$MAGIC" != "VZOELFOX" ]]; then
    echo "Error: Not a valid VZOELFOX .morph file."
    exit 1
fi

# 2. Extract Code
# Skip first 8 bytes
tail -c +9 "$INPUT" > "${TEMP_EXEC}.code"
CODE_SIZE=$(stat -c%s "${TEMP_EXEC}.code")

# 3. Construct ELF Header
# We need to emit raw bytes. I'll use a python one-liner or similar helper if available,
# but strictly without deps means using printf.

# Helpers
emit_byte() { printf "\\x$(printf "%02x" $1)" >> "$TEMP_EXEC"; }
emit_word() { emit_byte $(( $1 & 0xFF )); emit_byte $(( ($1 >> 8) & 0xFF )); }
emit_dword() { emit_word $(( $1 & 0xFFFF )); emit_word $(( ($1 >> 16) & 0xFFFF )); }
emit_qword() { emit_dword $(( $1 & 0xFFFFFFFF )); emit_dword $(( ($1 >> 32) & 0xFFFFFFFF )); }

# Create empty file
: > "$TEMP_EXEC"

# --- ELF Header (64 bytes) ---
# e_ident
printf "\x7fELF" >> "$TEMP_EXEC" # Magic
emit_byte 2  # Class: 64-bit
emit_byte 1  # Data: Little endian
emit_byte 1  # Version: 1
emit_byte 0  # ABI: System V
emit_byte 0  # ABI Version
printf "\x00\x00\x00\x00\x00\x00\x00" >> "$TEMP_EXEC" # Pad

emit_word 2  # e_type: ET_EXEC
emit_word 62 # e_machine: AMD64
emit_dword 1 # e_version: 1
emit_qword $((0x400000 + 0x78)) # e_entry: Start after headers (64+56=120=0x78)
emit_qword 64 # e_phoff: Program header follows ELF header
emit_qword 0  # e_shoff: No section headers
emit_dword 0  # e_flags
emit_word 64  # e_ehsize
emit_word 56  # e_phentsize
emit_word 1   # e_phnum: 1 segment
emit_word 64  # e_shentsize
emit_word 0   # e_shnum
emit_word 0   # e_shstrndx

# --- Program Header (56 bytes) ---
emit_dword 1  # p_type: PT_LOAD
emit_dword 7  # p_flags: R W X
emit_qword 0  # p_offset: Map from start of file
emit_qword 0x400000 # p_vaddr
emit_qword 0x400000 # p_paddr
# Filesz = Header(120) + CodeSize
FILE_SIZE=$((120 + CODE_SIZE))
emit_qword $FILE_SIZE # p_filesz
emit_qword $FILE_SIZE # p_memsz
emit_qword 0x1000     # p_align

# --- Code ---
cat "${TEMP_EXEC}.code" >> "$TEMP_EXEC"

# 4. Run
chmod +x "$TEMP_EXEC"
"$TEMP_EXEC" "${@:2}"
RET=$?

# Cleanup
rm -f "$TEMP_EXEC" "${TEMP_EXEC}.code"

exit $RET

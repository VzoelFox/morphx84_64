#!/bin/bash

# Morph Parser - The Bootstrap Compiler
# Reads Brainlib definitions and compiles .fox (Indonesian/Hybrid) to .morph (VZOELFOX)

BRAINLIB_DIR="Brainlib"
OUTPUT_FILE="output.morph"
CURRENT_OFFSET=0
PASS=1

# Associative arrays
declare -A ISA_OPCODES
declare -A LABELS
# Register Mapping
declare -A REGISTERS
REGISTERS["rax"]=0
REGISTERS["rcx"]=1
REGISTERS["rdx"]=2
REGISTERS["rbx"]=3
REGISTERS["rsp"]=4
REGISTERS["rbp"]=5
REGISTERS["rsi"]=6
REGISTERS["rdi"]=7
REGISTERS["r8"]=8
REGISTERS["r9"]=9
REGISTERS["r10"]=10
REGISTERS["r11"]=11
REGISTERS["r12"]=12
REGISTERS["r13"]=13
REGISTERS["r14"]=14
REGISTERS["r15"]=15

log() {
    echo "[PARSER] $1" >&2
}

load_isa() {
    if [[ ! -d "$BRAINLIB_DIR" ]]; then
        log "Error: Brainlib directory $BRAINLIB_DIR not found."
        exit 1
    fi

    for spec_file in "$BRAINLIB_DIR"/*.vzoel; do
        if [[ ! -f "$spec_file" ]]; then continue; fi
        log "Loading ISA from $spec_file..."

        while IFS= read -r line; do
            # Trim
            line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
            if [[ -z "$line" || "$line" == ";"* ]]; then continue; fi

            mnemonic=$(echo "$line" | awk '{print $1}')
            props=$(echo "$line" | cut -d' ' -f2-)
            ISA_OPCODES["$mnemonic"]="$props"
        done < "$spec_file"
    done
}

init_output() {
    if [[ $PASS -eq 2 ]]; then
        # Write Magic Header VZOELFOX (8 bytes)
        printf "VZOELFOX" > "$OUTPUT_FILE"
    fi
    CURRENT_OFFSET=0
}

emit_byte() {
    local val=$1
    if [[ $PASS -eq 2 ]]; then
        printf "\\x$(printf "%02x" $val)" >> "$OUTPUT_FILE"
    fi
    CURRENT_OFFSET=$((CURRENT_OFFSET + 1))
}

emit_dword() { # 4 bytes
    local val=$1
    # Bash handles negative numbers correctly in bitwise ops usually, but let's be safe for 32-bit
    local b1=$((val & 0xFF))
    local b2=$(((val >> 8) & 0xFF))
    local b3=$(((val >> 16) & 0xFF))
    local b4=$(((val >> 24) & 0xFF))
    emit_byte $b1
    emit_byte $b2
    emit_byte $b3
    emit_byte $b4
}

emit_qword() { # 8 bytes
    local val=$1
    emit_byte $((val & 0xFF))
    emit_byte $(((val >> 8) & 0xFF))
    emit_byte $(((val >> 16) & 0xFF))
    emit_byte $(((val >> 24) & 0xFF))
    emit_byte $(((val >> 32) & 0xFF))
    emit_byte $(((val >> 40) & 0xFF))
    emit_byte $(((val >> 48) & 0xFF))
    emit_byte $(((val >> 56) & 0xFF))
}

parse_operand() {
    local op="$1"
    op=${op%,}
    echo "$op"
}

is_reg() { [[ -n "${REGISTERS[$1]}" ]]; }

is_imm() {
    if [[ "$1" =~ ^-?[0-9]+$ ]] || [[ "$1" =~ ^0x[0-9a-fA-F]+$ ]]; then return 0; fi
    return 1
}

is_imm8() {
    if ! is_imm "$1"; then return 1; fi
    if (( $1 >= -128 && $1 <= 127 )); then return 0; fi
    return 1
}

is_imm32() {
    if ! is_imm "$1"; then return 1; fi
    # Check signed 32-bit range
    if (( $1 >= -2147483648 && $1 <= 2147483647 )); then return 0; fi
    # Also check unsigned 32-bit (common for addresses/masks)
    if (( $1 >= 0 && $1 <= 4294967295 )); then return 0; fi
    return 1
}

is_mem_operand() {
    if [[ "$1" == \[*\] ]]; then return 0; else return 1; fi
}

get_mem_reg_id() {
    local op="$1"; op=${op#\[}; op=${op%\]};
    get_reg_id "$op"
}

get_reg_id() {
    local reg="$1"; reg=${reg%,}
    local id=${REGISTERS[$reg]}
    if [[ -z "$id" ]]; then echo "Error: Unknown register $reg" >&2; exit 1; fi
    echo "$id"
}

compile_line() {
    local line="$1"
    line=${line%%;*} # Remove comments
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
    if [[ -z "$line" ]]; then return; fi

    local mnemonic=$(echo "$line" | awk '{print $1}')
    local args=$(echo "$line" | cut -d' ' -f2-)

    # --- INDONESIAN SYNTAX / MACROS ---

    # Fungsi: Label definition
    if [[ "$mnemonic" == "fungsi" ]]; then
        local name=${args%%(*}
        name=${name%%:*}
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$CURRENT_OFFSET
            log "Fungsi: $name -> $CURRENT_OFFSET"
        fi
        return
    fi

    # Tutup Fungsi: ret
    if [[ "$mnemonic" == "tutup_fungsi" || "$mnemonic" == "kembali" ]]; then
        compile_line "ret"
        return
    fi

    # Lompat: jmp
    if [[ "$mnemonic" == "lompat" ]]; then
        compile_line "jmp $args"
        return
    fi

    # Jika: Conditional Jump logic
    # jika1 => jne .L_end_jika1 (Skip block if Not Equal/Zero)
    if [[ "$mnemonic" =~ ^jika[0-9]+$ ]]; then
        local id=${mnemonic#jika}
        compile_line "jne .L_end_jika${id}"
        return
    fi

    if [[ "$mnemonic" =~ ^tutup_jika[0-9]+$ ]]; then
        local id=${mnemonic#tutup_jika}
        compile_line ".L_end_jika${id}:"
        return
    fi

    # Debug Macro: Prints "DEBUG\n" to stdout
    if [[ "$mnemonic" == "debug" ]]; then
        # Save registers (Clobbered: rax, rdi, rsi, rdx, rcx, r11)
        compile_line "push rax"
        compile_line "push rdi"
        compile_line "push rsi"
        compile_line "push rdx"
        compile_line "push rcx"
        compile_line "push r11"

        # Push "DEBUG\n" (Little Endian: 0x0A 0x47 0x55 0x42 0x45 0x44)
        # 0x0A4755424544
        compile_line "mov rax, 0x0A4755424544"
        compile_line "push rax"

        # Syscall write(1, rsp, 6)
        compile_line "mov rax, 1"
        compile_line "mov rdi, 1"
        compile_line "mov rsi, rsp"
        compile_line "mov rdx, 6"
        compile_line "syscall"

        # Cleanup Stack (Pop string)
        compile_line "pop rax"

        # Restore Registers
        compile_line "pop r11"
        compile_line "pop rcx"
        compile_line "pop rdx"
        compile_line "pop rsi"
        compile_line "pop rdi"
        compile_line "pop rax"
        return
    fi

    # Label Definition (name:)
    if [[ "$mnemonic" == *":" ]]; then
        local name=${mnemonic%:}
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$CURRENT_OFFSET
        fi
        return
    fi

    # --- INSTRUCTION ENCODING ---

    # Smart Opcode Suffix Resolution
    local suffix=""
    local arg1=$(echo "$args" | awk '{print $1}')
    local arg2=$(echo "$args" | awk '{print $2}')
    arg1=${arg1%,}
    arg2=${arg2%,}

    if [[ -n "$arg1" ]]; then
        if is_reg "$arg1"; then
            if [[ -n "$arg2" ]]; then
                if is_reg "$arg2"; then suffix=".r64.r64";
                elif is_mem_operand "$arg2"; then suffix=".r64.mem";
                elif is_imm "$arg2"; then
                     if is_imm8 "$arg2" && [[ -n "${ISA_OPCODES[${mnemonic}.r64.imm8]}" ]]; then suffix=".r64.imm8";
                     elif is_imm32 "$arg2" && [[ -n "${ISA_OPCODES[${mnemonic}.r64.imm32]}" ]]; then suffix=".r64.imm32";
                     elif [[ -n "${ISA_OPCODES[${mnemonic}.r64.imm64]}" ]]; then suffix=".r64.imm64";
                     fi
                fi
            else
                # Single Reg (e.g., push rax, idiv rax)
                suffix=".r64"
            fi
        elif is_mem_operand "$arg1"; then
             if [[ -n "$arg2" ]] && is_reg "$arg2"; then suffix=".mem.r64";
             elif [[ -n "$arg2" ]] && is_imm "$arg2"; then suffix=".mem.imm32"; fi # TODO: check sizes
        elif is_imm "$arg1"; then
             # Immediate as first arg (push 10)
             if is_imm8 "$arg1" && [[ -n "${ISA_OPCODES[${mnemonic}.imm8]}" ]]; then suffix=".imm8";
             elif [[ -n "${ISA_OPCODES[${mnemonic}.imm32]}" ]]; then suffix=".imm32";
             fi
        else
             # Label? (call label, jmp label)
             if [[ -n "${ISA_OPCODES[${mnemonic}.rel32]}" ]]; then suffix=".rel32"; fi
        fi
    fi

    local lookup="${mnemonic}${suffix}"
    local props="${ISA_OPCODES[$lookup]}"
    if [[ -z "$props" ]]; then props="${ISA_OPCODES[$mnemonic]}"; fi # Fallback

    if [[ -z "$props" ]]; then
        log "Error: Unknown instruction '$mnemonic' (args: $args)"
        return
    fi

    # Decoding Props
    local rex=0
    local opcode=0
    local has_modrm=0
    local modrm_mode=""
    local reg_in_op=0
    local imm_size=0
    local is_rel32=0
    local opcode_bytes=()

    for prop in $props; do
        key=${prop%%=*}
        val=${prop#*=}
        case $key in
            rex) if [[ "$val" == "W" ]]; then rex=$((rex | 0x48)); fi ;;
            opcode) if [[ "$val" == *","* ]]; then opcode_bytes=(${val//,/ }); else opcode_bytes=($val); fi ;;
            reg_in_op) reg_in_op=1 ;;
            imm64) imm_size=64 ;;
            imm32) imm_size=32 ;;
            imm8) imm_size=8 ;;
            rel32) imm_size=32; is_rel32=1 ;;
            modrm) has_modrm=1; modrm_mode=$val ;;
        esac
    done

    # Emit REX
    if [[ $rex -ne 0 ]]; then emit_byte $rex; fi

    # Handle reg_in_op (Opcode + RegID)
    if [[ $reg_in_op -eq 1 ]]; then
        local r=$(get_reg_id "$arg1")
        local idx=$((${#opcode_bytes[@]} - 1))
        opcode_bytes[$idx]=$((opcode_bytes[$idx] + r))
    fi

    # Emit Opcode
    for b in "${opcode_bytes[@]}"; do emit_byte $b; done

    # Emit ModRM
    if [[ $has_modrm -eq 1 ]]; then
        local modrm=0
        if [[ "$modrm_mode" == "reg,reg" ]]; then
            # Mod=11 (C0)
            local r_src=$(get_reg_id "$arg2"); local r_dst=$(get_reg_id "$arg1")
            modrm=$((0xC0 + (r_src << 3) + r_dst))
            emit_byte $modrm
        elif [[ "$modrm_mode" =~ ^[0-7]$ ]]; then
            # Extension (e.g. /0)
            local ext=$modrm_mode
            local r_rm=$(get_reg_id "$arg1")
            modrm=$((0xC0 + (ext << 3) + r_rm))
            emit_byte $modrm
        elif [[ "$modrm_mode" == "reg,mem" ]]; then
             # reg, [mem] -> Dest=Reg, Src=Mem
             local r_reg=$(get_reg_id "$arg1")
             local r_rm=$(get_mem_reg_id "$arg2")
             # Simple [reg] support
             if [[ $r_rm -eq 4 ]]; then emit_byte $((0x00 + (r_reg<<3) + 4)); emit_byte 0x24; # SIB
             elif [[ $r_rm -eq 5 ]]; then emit_byte $((0x40 + (r_reg<<3) + 5)); emit_byte 0x00; # [rbp+0]
             else emit_byte $((0x00 + (r_reg<<3) + r_rm)); fi
        elif [[ "$modrm_mode" == "mem,reg" ]]; then
             # [mem], reg -> Dest=Mem, Src=Reg
             local r_reg=$(get_reg_id "$arg2")
             local r_rm=$(get_mem_reg_id "$arg1")
             if [[ $r_rm -eq 4 ]]; then emit_byte $((0x00 + (r_reg<<3) + 4)); emit_byte 0x24;
             elif [[ $r_rm -eq 5 ]]; then emit_byte $((0x40 + (r_reg<<3) + 5)); emit_byte 0x00;
             else emit_byte $((0x00 + (r_reg<<3) + r_rm)); fi
        fi
    fi

    # Emit Immediates
    if [[ $imm_size -eq 32 ]]; then
        if [[ $is_rel32 -eq 1 ]]; then
            local label=$(parse_operand "$arg1")
            if [[ $PASS -eq 2 ]]; then
                local target=${LABELS["$label"]}
                if [[ -z "$target" ]]; then log "Error: Label '$label' not found"; exit 1; fi
                # rel32 = target - (current_offset + 4)
                # Note: current_offset is at START of imm32.
                local rel=$((target - (CURRENT_OFFSET + 4)))
                emit_dword $rel
            else
                emit_dword 0
            fi
        else
            local imm=$(parse_operand "$arg2")
            if [[ -z "$imm" ]]; then imm=$(parse_operand "$arg1"); fi
            emit_dword "$imm"
        fi
    elif [[ $imm_size -eq 8 ]]; then
        local imm=$(parse_operand "$arg2")
        if [[ -z "$imm" ]]; then imm=$(parse_operand "$arg1"); fi
        emit_byte $((imm & 0xFF))
    elif [[ $imm_size -eq 64 ]]; then
        local imm=$(parse_operand "$arg2")
        emit_qword "$imm"
    fi
}

if [[ $# -lt 1 ]]; then echo "Usage: $0 <input.fox>"; exit 1; fi
INPUT_FILE="$1"
load_isa

log "PASS 1: Scanning Labels..."
PASS=1; init_output
while IFS= read -r line; do compile_line "$line"; done < "$INPUT_FILE"

log "PASS 2: Compiling..."
PASS=2; init_output
while IFS= read -r line; do compile_line "$line"; done < "$INPUT_FILE"

chmod +x "$OUTPUT_FILE"
log "Success: $OUTPUT_FILE"

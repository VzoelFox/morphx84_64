#!/bin/bash

# Morph Parser - The Bootstrap Compiler
# Reads spec/x84_64.vzoel and compiles .fox to .morph

BRAINLIB_DIR="Brainlib"
OUTPUT_FILE="output.morph"
CURRENT_OFFSET=0
PASS=1

# Associative arrays
declare -A ISA_OPCODES
declare -A LABELS
declare -A UNRESOLVED_LABELS

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
# Extended registers would require REX handling logic which we can add later
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
            line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
            if [[ -z "$line" || "$line" == ";"* ]]; then continue; fi

            mnemonic=$(echo "$line" | awk '{print $1}')
            props=$(echo "$line" | cut -d' ' -f2-)
            ISA_OPCODES["$mnemonic"]="$props"
        done < "$spec_file"
    done
}

# Output handling
init_output() {
    if [[ $PASS -eq 2 ]]; then
        # Write Magic Header VZOELFOX
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

emit_word() { # 2 bytes
    local val=$1
    emit_byte $((val & 0xFF))
    emit_byte $(((val >> 8) & 0xFF))
}

emit_dword() { # 4 bytes
    local val=$1
    emit_byte $((val & 0xFF))
    emit_byte $(((val >> 8) & 0xFF))
    emit_byte $(((val >> 16) & 0xFF))
    emit_byte $(((val >> 24) & 0xFF))
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
    # Clean up comma
    op=${op%,}
    echo "$op"
}

is_reg() {
    local op="$1"
    if [[ -n "${REGISTERS[$op]}" ]]; then
        return 0
    else
        return 1
    fi
}

is_imm() {
    local op="$1"
    if [[ "$op" =~ ^-?[0-9]+$ ]] || [[ "$op" =~ ^0x[0-9a-fA-F]+$ ]]; then
        return 0
    fi
    return 1
}

is_mem_operand() {
    local op="$1"
    if [[ "$op" == \[*\] ]]; then
        return 0 # true
    else
        return 1 # false
    fi
}

get_mem_reg_id() {
    local op="$1"
    # Strip [ and ]
    op=${op#\[}
    op=${op%\]}
    get_reg_id "$op"
}

get_reg_id() {
    local reg="$1"
    reg=${reg%,} # remove trailing comma if any
    local id=${REGISTERS[$reg]}
    if [[ -z "$id" ]]; then
        echo "Error: Unknown register $reg" >&2
        exit 1
    fi
    echo "$id"
}

compile_line() {
    local line="$1"
    # Basic tokenizer
    local mnemonic=$(echo "$line" | awk '{print $1}')
    local args=$(echo "$line" | cut -d' ' -f2-)

    # Handle High-Level Constructs
    if [[ "$mnemonic" == "fungsi" ]]; then
        # Format: fungsi name(...)
        local name=${args%%(*}
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$CURRENT_OFFSET
            log "Label defined: $name at $CURRENT_OFFSET"
        fi
        return
    fi

    if [[ "$mnemonic" == "tutup_fungsi" ]]; then
        # Emit ret (0xC3)
        # Check if 'ret' is in ISA
        # It is: ret opcode=0xC3
        compile_line "ret"
        return
    fi

    # Explicit Control Flow (Indonesian)
    if [[ "$mnemonic" =~ ^jika[0-9]+$ ]]; then
        local id=${mnemonic#jika}
        # Emits jump if NOT equal (assumes implicit cmp before)
        compile_line "jne .L_end_jika${id}"
        return
    fi

    if [[ "$mnemonic" =~ ^tutup_jika[0-9]+$ ]]; then
        local id=${mnemonic#tutup_jika}
        compile_line ".L_end_jika${id}:"
        return
    fi

    # Debug Instruction
    if [[ "$mnemonic" == "debug" ]]; then
        # Prints "DEBUG\n" using syscall
        # Save clobbered registers (rax, rdi, rsi, rdx, rcx) - r11 omitted due to lack of REX support yet
        compile_line "push rax"
        compile_line "push rdi"
        compile_line "push rsi"
        compile_line "push rdx"
        compile_line "push rcx"

        # Prepare string on stack
        compile_line "mov rax, 0x0A4755424544"
        compile_line "push rax"

        # Syscall
        compile_line "mov rax, 1"
        compile_line "mov rdi, 1"
        compile_line "mov rsi, rsp"
        compile_line "mov rdx, 6"
        compile_line "syscall"

        # Cleanup string
        compile_line "pop rax"

        # Restore registers
        compile_line "pop rcx"
        compile_line "pop rdx"
        compile_line "pop rsi"
        compile_line "pop rdi"
        compile_line "pop rax"
        return
    fi

    if [[ "$mnemonic" == *":" ]]; then
        # Label definition: name:
        local name=${mnemonic%:}
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$CURRENT_OFFSET
        fi
        return
    fi

    # Smart Opcode Resolution
    local suffix=""
    local arg1=$(echo "$args" | awk '{print $1}')
    local arg2=$(echo "$args" | awk '{print $2}')
    arg1=${arg1%,}
    arg2=${arg2%,}

    if [[ -n "$arg1" ]]; then
        if is_reg "$arg1"; then
            if [[ -n "$arg2" ]]; then
                if is_reg "$arg2"; then
                    suffix=".r64.r64"
                elif is_mem_operand "$arg2"; then
                    suffix=".r64.mem"
                elif is_imm "$arg2"; then
                     if [[ -n "${ISA_OPCODES[${mnemonic}.r64.imm64]}" ]]; then
                         suffix=".r64.imm64"
                     elif [[ -n "${ISA_OPCODES[${mnemonic}.r64.imm32]}" ]]; then
                         suffix=".r64.imm32"
                     fi
                fi
            else
                # Single register operand (e.g. push rax)
                suffix=".r64"
            fi
        # Handle call/jmp label (Arg1 is not Reg, Mem, or Imm -> Label?)
        elif ! is_reg "$arg1" && ! is_mem_operand "$arg1" && ! is_imm "$arg1"; then
             # Likely a label
             if [[ -n "${ISA_OPCODES[${mnemonic}.rel32]}" ]]; then
                 suffix=".rel32"
             fi
        elif is_mem_operand "$arg1"; then
            if [[ -n "$arg2" ]] && is_reg "$arg2"; then
                suffix=".mem.r64"
            fi
        fi
    fi

    local lookup_mnemonic="${mnemonic}${suffix}"
    local props="${ISA_OPCODES[$lookup_mnemonic]}"

    # Fallback to exact match (e.g. syscall, ret, or explicit mnemonic)
    if [[ -z "$props" ]]; then
        props="${ISA_OPCODES[$mnemonic]}"
    fi

    if [[ -z "$props" ]]; then
        log "Unknown instruction: $mnemonic (tried $lookup_mnemonic)"
        return
    fi

    # Defaults
    local rex=0
    local opcode=0
    local has_modrm=0
    local reg_in_op=0
    local imm_size=0
    local is_rel32=0

    # Parse Props
    for prop in $props; do
        key=${prop%%=*}
        val=${prop#*=}

        case $key in
            rex)
                if [[ "$val" == "W" ]]; then
                    rex=$((rex | 0x48)) # REX.W
                fi
                ;;
            opcode)
                # Handle multi-byte opcodes like 0x0F,0x05
                if [[ "$val" == *","* ]]; then
                    # Split
                    local op1=${val%%,*}
                    local op2=${val#*,}
                    opcode=$((op1)) # assume first byte is handled specially if needed?
                    # For now, let's just emit instruction bytes directly if logic allows
                    # But wait, logic is structured around "opcode" being the main byte.
                    # Let's store opcode bytes in a list
                    opcode_bytes=(${val//,/ })
                else
                    opcode_bytes=($val)
                fi
                ;;
            reg_in_op)
                reg_in_op=1
                ;;
            imm64)
                imm_size=64
                ;;
            imm32)
                imm_size=32
                ;;
            rel32)
                imm_size=32
                is_rel32=1
                ;;
            modrm)
                has_modrm=1
                modrm_mode=$val # e.g., reg,reg or 0
                ;;
        esac
    done

    # Parse Arguments
    # Very simple parsing: split by comma or space
    local arg1=$(echo "$args" | awk '{print $1}')
    local arg2=$(echo "$args" | awk '{print $2}')

    # Strip commas
    arg1=${arg1%,}
    arg2=${arg2%,}

    # Handle REX.B/R/X for extended registers (r8-r15)
    # TODO: Implement REX extension logic

    # Emit REX
    if [[ $rex -ne 0 ]]; then
        emit_byte $rex
    fi

    # Process Opcode & ModRM
    # This is a simplification. We need to know WHICH argument maps to WHICH modrm field.
    # spec says: modrm=reg,reg -> arg1 is reg (modrm.reg), arg2 is rm (modrm.rm) ???
    # Usually Intel syntax is 'mnemonic dst, src'.
    # Spec: mov.r64.r64 modrm=reg,reg.
    # Let's assume arg1=dst, arg2=src.
    # ModRM byte: Mod(2) Reg(3) RM(3)

    # Handle reg_in_op
    if [[ $reg_in_op -eq 1 ]]; then
        # The register ID is added to the last byte of opcode
        local reg_id=$(get_reg_id "$arg1") # Assumes first arg is the one encoded in opcode
        local last_idx=$((${#opcode_bytes[@]} - 1))
        opcode_bytes[$last_idx]=$((opcode_bytes[$last_idx] + reg_id))
    fi

    # Emit Opcode Bytes
    for b in "${opcode_bytes[@]}"; do
        emit_byte $b
    done

    # Emit ModRM
    if [[ $has_modrm -eq 1 ]]; then
        if [[ "$modrm_mode" == "reg,reg" ]]; then
            # Mod=11 (Direct Register)
            local r1=$(get_reg_id "$arg2") # Src -> Reg
            local r2=$(get_reg_id "$arg1") # Dst -> RM
            # ModRM = 11 (2 bits) | Reg (3 bits) | RM (3 bits)
            # 0xC0 + (r1 << 3) + r2
            local modrm=$((0xC0 + (r1 << 3) + r2))
            emit_byte $modrm

        elif [[ "$modrm_mode" == "mem,reg" ]]; then
            # mov.mem.r64 [dest], src
            # Arg1 is Mem (RM), Arg2 is Reg (Reg)
            local r_reg=$(get_reg_id "$arg2")

            # Parse Arg1
            if is_mem_operand "$arg1"; then
                local r_rm=$(get_mem_reg_id "$arg1")
                # TODO: Handle RSP/RBP special cases (SIB/Disp)
                if [[ $r_rm -eq 4 ]]; then # RSP
                     # Mod=00, Reg=r_reg, RM=100 (4) -> SIB follows
                     # SIB for [rsp]: Scale=0, Index=4(none), Base=4(rsp) -> 0x24
                     local modrm=$((0x00 + (r_reg << 3) + 4))
                     emit_byte $modrm
                     emit_byte 0x24
                elif [[ $r_rm -eq 5 ]]; then # RBP
                     # [rbp] usually means [rip+disp32] in 64-bit or [rbp+0] with mod=01
                     # For simplicity, let's allow [rbp] as [rbp+0] (Mod=01, Disp8=0)
                     # Mod=01 (0x40)
                     local modrm=$((0x40 + (r_reg << 3) + 5))
                     emit_byte $modrm
                     emit_byte 0x00
                else
                     # Mod=00 (Indirect), Reg=r_reg, RM=r_rm
                     local modrm=$((0x00 + (r_reg << 3) + r_rm))
                     emit_byte $modrm
                fi
            else
                log "Error: Expected memory operand for arg1"
                exit 1
            fi

        elif [[ "$modrm_mode" == "reg,mem" ]]; then
            # mov.r64.mem dest, [src]
            # Arg1 is Reg (Reg), Arg2 is Mem (RM)
            local r_reg=$(get_reg_id "$arg1")

            if is_mem_operand "$arg2"; then
                local r_rm=$(get_mem_reg_id "$arg2")
                if [[ $r_rm -eq 4 ]]; then # RSP
                     local modrm=$((0x00 + (r_reg << 3) + 4))
                     emit_byte $modrm
                     emit_byte 0x24
                elif [[ $r_rm -eq 5 ]]; then # RBP
                     local modrm=$((0x40 + (r_reg << 3) + 5))
                     emit_byte $modrm
                     emit_byte 0x00
                else
                     local modrm=$((0x00 + (r_reg << 3) + r_rm))
                     emit_byte $modrm
                fi
            else
                log "Error: Expected memory operand for arg2"
                exit 1
            fi

        elif [[ "$modrm_mode" =~ ^[0-7]$ ]]; then
             # Case for add.r64.imm32 modrm=0, sub.r64.imm32 modrm=5
             # ModRM extension. /digit means Reg field is that digit.
             # Dst is RM.
             # Mod=11 (Register)
             local r_ext=$modrm_mode
             local r_dst=$(get_reg_id "$arg1")
             local modrm=$((0xC0 + (r_ext << 3) + r_dst))
             emit_byte $modrm
        fi
    fi

    # Emit Immediate
    if [[ $imm_size -eq 64 ]]; then
        # Arg2 is immediate
        local imm=$(parse_operand "$arg2")
        emit_qword "$imm"
    elif [[ $imm_size -eq 32 ]]; then
        local arg_val=""
        if [[ $is_rel32 -eq 1 ]]; then
             # Handle Relative Jump (call, jmp, je)
             # Arg is a label
             local label=$(parse_operand "$arg1") # e.g. call label
             if [[ $PASS -eq 2 ]]; then
                 local target=${LABELS["$label"]}
                 if [[ -z "$target" ]]; then
                     log "Error: Undefined label '$label'"
                     exit 1
                 fi
                 # Calculate relative offset
                 # rel32 = target - (current + 4)
                 # Wait, we need to know WHERE the immediate starts?
                 # current is start of instruction? No, emit_byte increments CURRENT_OFFSET.
                 # So CURRENT_OFFSET is now at the start of the immediate (since we emitted opcode/modrm).
                 # rel32 is relative to the END of the instruction.
                 # So target - (current + 4).
                 local rel=$((target - (CURRENT_OFFSET + 4)))
                 # Handle negative numbers for 32-bit (bash handles them as signed 64-bit)
                 emit_dword "$rel"
             else
                 # Pass 1: just advance
                 emit_dword 0
             fi
        else
             local imm=$(parse_operand "$arg2")
             # If arg2 is missing, maybe it's arg1 (e.g. add rax, imm)?
             # For add.r64.imm32, arg2 is imm.
             # Check if instruction uses arg1 as imm? No, usually arg2.
             # What if imm is a Label? (e.g. mov rax, label_addr) - Not supported yet.
             emit_dword "$imm"
        fi
    fi
}

# Main
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.fox>"
    exit 1
fi

INPUT_FILE="$1"

load_isa

# PASS 1
log "PASS 1: Collecting labels..."
PASS=1
init_output
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
    if [[ -z "$line" || "$line" == ";"* ]]; then continue; fi
    compile_line "$line"
done < "$INPUT_FILE"

# PASS 2
log "PASS 2: Generating code..."
PASS=2
init_output
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
    if [[ -z "$line" || "$line" == ";"* ]]; then continue; fi
    compile_line "$line"
done < "$INPUT_FILE"

log "Done. Output: $OUTPUT_FILE"

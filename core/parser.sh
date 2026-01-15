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

# Control Flow Stack
declare -a STACK_TYPE
declare -a STACK_ID
declare -a STACK_ELSE
STACK_PTR=0
BLOCK_COUNTER=0

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
    # Reset Stack for Pass 2 to ensure consistent ID generation
    # Actually, we rely on deterministic BLOCK_COUNTER.
    # We should reset BLOCK_COUNTER if we want consistent labeling,
    # but since labels are resolved in Pass 1, we just need to ensure Pass 2 generates SAME labels.
    BLOCK_COUNTER=0
    STACK_PTR=0
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

# --- STACK OPERATIONS ---
stack_push() {
    local type=$1
    local id=$2
    STACK_TYPE[$STACK_PTR]=$type
    STACK_ID[$STACK_PTR]=$id
    STACK_ELSE[$STACK_PTR]=0 # 0=NoElse, 1=ElsePresent
    STACK_PTR=$((STACK_PTR + 1))
}

# Global return registers for stack ops
POP_TYPE=""
POP_ID=""
POP_ELSE=""

stack_pop() {
    if [[ $STACK_PTR -le 0 ]]; then
        log "Error: Stack underflow (Extra tutup_?)"
        exit 1
    fi
    STACK_PTR=$((STACK_PTR - 1))
    POP_TYPE="${STACK_TYPE[$STACK_PTR]}"
    POP_ID="${STACK_ID[$STACK_PTR]}"
    POP_ELSE="${STACK_ELSE[$STACK_PTR]}"
}

stack_peek() {
    if [[ $STACK_PTR -le 0 ]]; then
        POP_TYPE="EMPTY"; POP_ID=""; POP_ELSE="";
        return;
    fi
    local idx=$((STACK_PTR - 1))
    POP_TYPE="${STACK_TYPE[$idx]}"
    POP_ID="${STACK_ID[$idx]}"
    POP_ELSE="${STACK_ELSE[$idx]}"
}

# Find nearest Loop in stack (for break/continue)
stack_find_loop() {
    local idx=$((STACK_PTR - 1))
    while [[ $idx -ge 0 ]]; do
        if [[ "${STACK_TYPE[$idx]}" == "LOOP" || "${STACK_TYPE[$idx]}" == "SELAMA" ]]; then
            echo "${STACK_ID[$idx]}"
            return 0
        fi
        idx=$((idx - 1))
    done
    return 1
}

compile_line() {
    local line="$1"
    line=${line%%;*} # Remove comments
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
    if [[ -z "$line" ]]; then return; fi

    local mnemonic=$(echo "$line" | awk '{print $1}')
    local args=$(echo "$line" | cut -d' ' -f2-)


    # --- INDONESIAN CONTROL FLOW ---

    # 1. FUNGSI
    if [[ "$mnemonic" == "fungsi" ]]; then
        local name=${args%%(*}
        name=${name%%:*}
        stack_push "FUNGSI" "$name"
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$CURRENT_OFFSET
            log "Fungsi: $name -> $CURRENT_OFFSET"
        fi
        return
    fi

    if [[ "$mnemonic" == "tutup_fungsi" ]]; then
        stack_pop
        if [[ "$POP_TYPE" != "FUNGSI" ]]; then
            log "Error: 'tutup_fungsi' without matching 'fungsi' (Found: $POP_TYPE)"
            exit 1
        fi
        compile_line "ret"
        return
    fi

    # 2. JIKA (Conditionals)
    # Syntax: jika_sama, jika_beda, jika_lebih, dll.
    if [[ "$mnemonic" == "jika_"* ]]; then
        BLOCK_COUNTER=$((BLOCK_COUNTER + 1))
        local id=$BLOCK_COUNTER
        local condition=${mnemonic#jika_}

        stack_push "IF" "$id"

        # Determine Jump Logic (Inverse Logic: If condition is TRUE, we Fall Through. If FALSE, Jump to END/ELSE)
        # e.g. jika_sama (If Equal) -> jne LABEL_FALSE
        case $condition in
            sama)        compile_line "jne .L_FALSE_${id}" ;; # Equal -> jne
            beda)        compile_line "je .L_FALSE_${id}"  ;; # Not Equal -> je
            lebih)       compile_line "jle .L_FALSE_${id}" ;; # Greater -> jle
            kurang)      compile_line "jge .L_FALSE_${id}" ;; # Less -> jge
            lebih_sama)  compile_line "jl .L_FALSE_${id}"  ;; # >= -> jl
            kurang_sama) compile_line "jg .L_FALSE_${id}"  ;; # <= -> jg
            positif)     compile_line "js .L_FALSE_${id}"  ;; # Not Sign (Pos) -> js (Neg)
            negatif)     compile_line "jns .L_FALSE_${id}" ;; # Sign (Neg) -> jns (Pos)
            nol)         compile_line "jne .L_FALSE_${id}" ;; # Zero -> jne
            *)
                log "Error: Unknown condition 'jika_$condition'"
                exit 1
                ;;
        esac
        return
    fi

    if [[ "$mnemonic" == "lainnya" ]]; then
        # Else block
        stack_peek
        if [[ "$POP_TYPE" != "IF" ]]; then
            log "Error: 'lainnya' must be inside 'jika' block"
            exit 1
        fi
        if [[ "$POP_ELSE" -eq 1 ]]; then
             log "Error: multiple 'lainnya' in one block"
             exit 1
        fi

        # Mark stack that we saw else
        local idx=$((STACK_PTR - 1))
        STACK_ELSE[$idx]=1

        # Jump from TRUE block over the FALSE block
        compile_line "jmp .L_END_${POP_ID}"

        # Place FALSE label here (Start of Else)
        compile_line ".L_FALSE_${POP_ID}:"
        return
    fi

    if [[ "$mnemonic" == "tutup_jika" ]]; then
        stack_pop
        if [[ "$POP_TYPE" != "IF" ]]; then
            log "Error: 'tutup_jika' mismatch (Expected IF, found $POP_TYPE)"
            exit 1
        fi

        if [[ "$POP_ELSE" -eq 1 ]]; then
            # If we had else, we just place the END label
            compile_line ".L_END_${POP_ID}:"
        else
            # If no else, the FALSE label is the END label
            compile_line ".L_FALSE_${POP_ID}:"
        fi
        return
    fi

    # 3. LOOP (Infinite / Do-While base)
    if [[ "$mnemonic" == "loop" ]]; then
        BLOCK_COUNTER=$((BLOCK_COUNTER + 1))
        local id=$BLOCK_COUNTER
        stack_push "LOOP" "$id"
        compile_line ".L_LOOP_START_${id}:"
        return
    fi

    if [[ "$mnemonic" == "tutup_loop" ]]; then
        stack_pop
        if [[ "$POP_TYPE" != "LOOP" ]]; then
            log "Error: 'tutup_loop' mismatch. Expected LOOP, found '$POP_TYPE' (ID: $POP_ID)"
            exit 1
        fi
        compile_line "jmp .L_LOOP_START_${POP_ID}"
        compile_line ".L_LOOP_END_${POP_ID}:"
        return
    fi

    # 4. SELAMA (While-like, structure-wise similar to LOOP but different keyword)
    if [[ "$mnemonic" == "selama" ]]; then
        BLOCK_COUNTER=$((BLOCK_COUNTER + 1))
        local id=$BLOCK_COUNTER
        stack_push "SELAMA" "$id"
        compile_line ".L_LOOP_START_${id}:"
        return
    fi

    if [[ "$mnemonic" == "tutup_selama" ]]; then
        stack_pop
        if [[ "$POP_TYPE" != "SELAMA" ]]; then
            log "Error: 'tutup_selama' mismatch"
            exit 1
        fi
        compile_line "jmp .L_LOOP_START_${POP_ID}"
        compile_line ".L_LOOP_END_${POP_ID}:"
        return
    fi

    # 5. FLOW CONTROL (Henti/Lanjut)
    if [[ "$mnemonic" == "henti" ]]; then # Break
        local loop_id=$(stack_find_loop)
        if [[ -z "$loop_id" ]]; then
            log "Error: 'henti' outside of loop"
            exit 1
        fi
        compile_line "jmp .L_LOOP_END_${loop_id}"
        return
    fi

    if [[ "$mnemonic" == "lanjut" ]]; then # Continue
        local loop_id=$(stack_find_loop)
        if [[ -z "$loop_id" ]]; then
            log "Error: 'lanjut' outside of loop"
            exit 1
        fi
        compile_line "jmp .L_LOOP_START_${loop_id}"
        return
    fi

    # Legacy / Manual Jumps
    if [[ "$mnemonic" == "lompat" ]]; then
        compile_line "jmp $args"
        return
    fi
    if [[ "$mnemonic" == "kembali" ]]; then
        compile_line "ret"
        return
    fi

    # Debug Macro
    if [[ "$mnemonic" == "debug" ]]; then
        compile_line "push rax"; compile_line "push rdi"; compile_line "push rsi";
        compile_line "push rdx"; compile_line "push rcx"; compile_line "push r11";
        compile_line "mov rax, 0x0A4755424544" # "DEBUG\n"
        compile_line "push rax"
        compile_line "mov rax, 1"; compile_line "mov rdi, 1";
        compile_line "mov rsi, rsp"; compile_line "mov rdx, 6"; compile_line "syscall"
        compile_line "pop rax"; compile_line "pop r11"; compile_line "pop rcx";
        compile_line "pop rdx"; compile_line "pop rsi"; compile_line "pop rdi"; compile_line "pop rax"
        return
    fi

    # Label Definition (name:)
    if [[ "$mnemonic" == *":" ]]; then
        local name=${mnemonic%:}
        if [[ $PASS -eq 1 ]]; then LABELS["$name"]=$CURRENT_OFFSET; fi
        return
    fi

    # --- INSTRUCTION ENCODING ---
    local suffix=""
    local arg1=$(echo "$args" | awk '{print $1}')
    local arg2=$(echo "$args" | awk '{print $2}')
    arg1=${arg1%,}; arg2=${arg2%,}

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
                suffix=".r64"
            fi
        elif is_mem_operand "$arg1"; then
             if [[ -n "$arg2" ]] && is_reg "$arg2"; then suffix=".mem.r64";
             elif [[ -n "$arg2" ]] && is_imm "$arg2"; then suffix=".mem.imm32"; fi
        elif is_imm "$arg1"; then
             if is_imm8 "$arg1" && [[ -n "${ISA_OPCODES[${mnemonic}.imm8]}" ]]; then suffix=".imm8";
             elif [[ -n "${ISA_OPCODES[${mnemonic}.imm32]}" ]]; then suffix=".imm32";
             fi
        else
             if [[ -n "${ISA_OPCODES[${mnemonic}.rel32]}" ]]; then suffix=".rel32"; fi
        fi
    fi

    local lookup="${mnemonic}${suffix}"
    local props="${ISA_OPCODES[$lookup]}"
    if [[ -z "$props" ]]; then props="${ISA_OPCODES[$mnemonic]}"; fi

    if [[ -z "$props" ]]; then
        log "Error: Unknown instruction '$mnemonic' (args: $args)"
        return
    fi

    # Decoding Props (Same as before)
    local rex=0; local opcode=0; local has_modrm=0; local modrm_mode=""
    local reg_in_op=0; local imm_size=0; local is_rel32=0; local opcode_bytes=()
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

    # Handle reg_in_op (Calculate REX.B if needed)
    local r_val=0
    if [[ $reg_in_op -eq 1 ]]; then
        r_val=$(get_reg_id "$arg1")
        if [[ $r_val -ge 8 ]]; then
            rex=$((rex | 0x41)) # REX.B
            r_val=$((r_val - 8))
        fi
    fi

    # Emit REX
    if [[ $rex -ne 0 ]]; then emit_byte $rex; fi

    # Apply Register to Opcode
    if [[ $reg_in_op -eq 1 ]]; then
        local idx=$((${#opcode_bytes[@]} - 1))
        opcode_bytes[$idx]=$((opcode_bytes[$idx] + r_val))
    fi

    # Emit Opcode
    for b in "${opcode_bytes[@]}"; do emit_byte $b; done
    # Emit ModRM
    if [[ $has_modrm -eq 1 ]]; then
        local modrm=0
        if [[ "$modrm_mode" == "reg,reg" ]]; then
            local r_src=$(get_reg_id "$arg2"); local r_dst=$(get_reg_id "$arg1")
            modrm=$((0xC0 + (r_src << 3) + r_dst))
            emit_byte $modrm
        elif [[ "$modrm_mode" =~ ^[0-7]$ ]]; then
            local ext=$modrm_mode; local r_rm=$(get_reg_id "$arg1")
            modrm=$((0xC0 + (ext << 3) + r_rm))
            emit_byte $modrm
        elif [[ "$modrm_mode" == "reg,mem" ]]; then
             local r_reg=$(get_reg_id "$arg1"); local r_rm=$(get_mem_reg_id "$arg2")
             if [[ $r_rm -eq 4 ]]; then emit_byte $((0x00 + (r_reg<<3) + 4)); emit_byte 0x24;
             elif [[ $r_rm -eq 5 ]]; then emit_byte $((0x40 + (r_reg<<3) + 5)); emit_byte 0x00;
             else emit_byte $((0x00 + (r_reg<<3) + r_rm)); fi
        elif [[ "$modrm_mode" == "mem,reg" ]]; then
             local r_reg=$(get_reg_id "$arg2"); local r_rm=$(get_mem_reg_id "$arg1")
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
                # Try finding in generated labels (e.g. .L_FALSE_1) if not in global LABELS?
                # Actually, PASS 1 should have generated the .L_FALSE_1 entries in LABELS if compile_line for label def is called.
                # Yes, compile_line(".L_FALSE_1:") calls LABELS add.
                if [[ -z "$target" ]]; then log "Error: Label '$label' not found"; exit 1; fi
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

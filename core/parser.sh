#!/bin/bash

# Morph Parser - The Bootstrap Compiler
# Reads Brainlib definitions and compiles .fox (Indonesian/Hybrid) to .morph (VZOELFOX)

BRAINLIB_DIR="Brainlib"
OUTPUT_FILE="output.morph"
SYM_FILE="output.sym"
CURRENT_OFFSET=0
BASE_ADDR=$((0x400078))
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

# SIMD Registers (Mapped to 100-115 for internal distinction)
REGISTERS["xmm0"]=100
REGISTERS["xmm1"]=101
REGISTERS["xmm2"]=102
REGISTERS["xmm3"]=103
REGISTERS["xmm4"]=104
REGISTERS["xmm5"]=105
REGISTERS["xmm6"]=106
REGISTERS["xmm7"]=107
REGISTERS["xmm8"]=108
REGISTERS["xmm9"]=109
REGISTERS["xmm10"]=110
REGISTERS["xmm11"]=111
REGISTERS["xmm12"]=112
REGISTERS["xmm13"]=113
REGISTERS["xmm14"]=114
REGISTERS["xmm15"]=115

# Control Flow Stack
declare -a STACK_TYPE
declare -a STACK_ID
declare -a STACK_ELSE
STACK_PTR=0
BLOCK_COUNTER=0

# Struct Management
STRUCT_NAME=""
STRUCT_OFFSET=0

# Unit / Namespace Management
CURRENT_UNIT=""

# Lambda/Closure State
declare -a LAMBDA_CAPTURES
LAMBDA_COUNT=0

# IntentTree Construction (Buffer for Auto-Gen Code)
INTENT_INIT_CODE_FILE="intent_init.tmp"
INTENT_ACTIVE_UNIT=""
INTENT_ACTIVE_SHARD=""

# Deduplication Map
declare -A INCLUDED_FILES

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
        # Clear Sym File
        > "$SYM_FILE"
    fi
    CURRENT_OFFSET=0
    # Reset Stack for Pass 2 to ensure consistent ID generation
    BLOCK_COUNTER=0
    STACK_PTR=0
    # Reset Unit for compilation pass (state machine)
    CURRENT_UNIT=""
    # Reset Lambda Counter
    LAMBDA_COUNT=0
}

emit_byte() {
    local val=$1
    if [[ $PASS -eq 2 ]]; then
        printf "\\x$(printf "%02x" $val)" >> "$OUTPUT_FILE"
    fi
    CURRENT_OFFSET=$((CURRENT_OFFSET + 1))
}

lookup_label() {
    local name="$1"
    local target=""

    # 1. Try Unit-Prefixed Label
    if [[ -n "$CURRENT_UNIT" ]]; then
        target=${LABELS["${CURRENT_UNIT}_${name}"]}
    fi

    # 2. Try Global Label (Fallback)
    if [[ -z "$target" ]]; then
        target=${LABELS["$name"]}
    fi

    echo "$target"
}

emit_dword() { # 4 bytes
    local val=$1
    if ! is_imm "$val"; then
        # Resolve Label
        local target=$(lookup_label "$val")

        if [[ -n "$target" ]]; then
            val=$target
        elif [[ $PASS -eq 2 ]]; then
            log "Error: Label '$val' not found (Unit: $CURRENT_UNIT)"
            exit 1
        else
            val=0
        fi
    fi

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
    if ! is_imm "$val"; then
        local target=$(lookup_label "$val")

        if [[ -n "$target" ]]; then
            val=$target
        elif [[ $PASS -eq 2 ]]; then
            log "Error: Label '$val' not found (Unit: $CURRENT_UNIT)"
            exit 1
        else
            val=0
        fi
    fi

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

is_xmm() {
    local id=${REGISTERS[$1]}
    if [[ -n "$id" && $id -ge 100 ]]; then return 0; fi
    return 1
}

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

# --- DATA-DRIVEN STRUCTURE HANDLER ---
handle_structure() {
    local mnemonic="$1"
    local props="$2"
    local args="$3"

    local type=""
    local scope=""
    local action=""
    local jump_cond=""

    for prop in $props; do
        key=${prop%%=*}
        val=${prop#*=}
        case $key in
            type) type=$val ;;
            scope) scope=$val ;;
            action) action=$val ;;
            jump_condition) jump_cond=$val ;;
        esac
    done

    # --- SCOPE START ---
    if [[ "$type" == "scope_start" ]]; then
        local id=""

        # STRUKTUR Special Case
        if [[ "$scope" == "STRUKTUR" ]]; then
            local name=${args%%(*}
            STRUCT_NAME="$name"
            STRUCT_OFFSET=0
            stack_push "$scope" "$name"
            return
        fi

        # FUNGSI Special Case (Arguments as Name)
        if [[ "$scope" == "FUNGSI" ]]; then
            local name=${args%%(*}
            name=${name%%:*}
            id="$name"

            # Apply Namespace Prefix
            local full_name="$name"
            if [[ -n "$CURRENT_UNIT" ]]; then
                full_name="${CURRENT_UNIT}_${name}"
            fi

            if [[ $PASS -eq 1 ]]; then
                LABELS["$full_name"]=$((BASE_ADDR + CURRENT_OFFSET))
                log "Fungsi: $full_name -> $CURRENT_OFFSET"
            elif [[ $PASS -eq 2 ]]; then
                local addr=$((BASE_ADDR + CURRENT_OFFSET))
                printf "%x %s\n" $addr "$full_name" >> "$SYM_FILE"
            fi
        else
            BLOCK_COUNTER=$((BLOCK_COUNTER + 1))
            id=$BLOCK_COUNTER

            # Action: Label Start (for Loop)
            if [[ "$action" == "label_start" ]]; then
                compile_line ".L_LOOP_START_${id}:"
            fi

            # Conditional Loop (SELAMA) Support
            if [[ "$scope" == "SELAMA" && -n "$jump_cond" ]]; then
                # Emit Label Start
                compile_line ".L_LOOP_START_${id}:"

                # Parse Comparison Arguments: arg1, arg2
                # e.g., selama_kurang rbx, 10
                local arg1=$(echo "$args" | awk '{print $1}')
                local arg2=$(echo "$args" | awk '{print $2}')
                arg1=${arg1%,}; arg2=${arg2%,}

                # Emit Compare
                compile_line "cmp $arg1, $arg2"

                # Emit Jump to END (Inverse Logic)
                compile_line "$jump_cond .L_LOOP_END_${id}"
            elif [[ -n "$jump_cond" ]]; then
                # Normal IF Jump Condition
                compile_line "$jump_cond .L_FALSE_${id}"
            fi
        fi

        stack_push "$scope" "$id"
        return
    fi

    # --- SCOPE END ---
    if [[ "$type" == "scope_end" ]]; then
        stack_pop
        if [[ "$POP_TYPE" != "$scope" ]]; then
            log "Error: Structure mismatch. Expected $scope, found $POP_TYPE (ID: $POP_ID)"
            exit 1
        fi

        if [[ "$scope" == "STRUKTUR" ]]; then
             # Define SIZE constant
             local const_name="${POP_ID}_SIZE"
             if [[ -n "$CURRENT_UNIT" ]]; then const_name="${CURRENT_UNIT}_${const_name}"; fi

             if [[ $PASS -eq 1 ]]; then
                 LABELS["$const_name"]=$STRUCT_OFFSET
             fi

             STRUCT_NAME=""
             return
        fi

        if [[ "$action" == "ret" ]]; then
            compile_line "ret"
        elif [[ "$action" == "jump_start" ]]; then
            compile_line "jmp .L_LOOP_START_${POP_ID}"
            compile_line ".L_LOOP_END_${POP_ID}:"
        elif [[ "$action" == "close_label" ]]; then
             if [[ "$POP_ELSE" -eq 1 ]]; then
                compile_line ".L_END_${POP_ID}:"
            else
                compile_line ".L_FALSE_${POP_ID}:"
            fi
        fi
        return
    fi

    # --- MID SCOPE (ELSE) ---
    if [[ "$type" == "mid_scope" ]]; then
        if [[ "$scope" == "IF" ]]; then
            stack_peek
            if [[ "$POP_TYPE" != "IF" ]]; then log "Error: 'lainnya' outside IF"; exit 1; fi
            if [[ "$POP_ELSE" -eq 1 ]]; then log "Error: Double 'lainnya'"; exit 1; fi

            # Mark Else
            local idx=$((STACK_PTR - 1))
            STACK_ELSE[$idx]=1

            compile_line "jmp .L_END_${POP_ID}"
            compile_line ".L_FALSE_${POP_ID}:"
        fi
        return
    fi

    # --- FLOW CONTROL ---
    if [[ "$type" == "flow_control" ]]; then
        if [[ "$action" == "break" ]]; then
            local loop_id=$(stack_find_loop)
            if [[ -z "$loop_id" ]]; then log "Error: 'henti' outside loop"; exit 1; fi
            compile_line "jmp .L_LOOP_END_${loop_id}"
        elif [[ "$action" == "continue" ]]; then
            local loop_id=$(stack_find_loop)
            if [[ -z "$loop_id" ]]; then log "Error: 'lanjut' outside loop"; exit 1; fi
            compile_line "jmp .L_LOOP_START_${loop_id}"
        elif [[ "$action" == "jump_explicit" ]]; then
            compile_line "jmp $args"
        fi
        return
    fi
}

compile_line() {
    local line="$1"
    # echo "DEBUG: $line" >&2
    line=${line%%;*} # Remove comments
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
    if [[ -z "$line" ]]; then return; fi

    local mnemonic=$(echo "$line" | awk '{print $1}')
    local args=$(echo "$line" | cut -d' ' -f2-)
    if [[ "$args" == "$mnemonic" ]]; then args=""; fi

    # --- META DIRECTIVES ---
    if [[ "$mnemonic" == ".meta_unit" ]]; then
        CURRENT_UNIT="$args"
        return
    fi
    if [[ "$mnemonic" == ".meta_unit_reset" ]]; then
        CURRENT_UNIT=""
        return
    fi

    # --- PREFIX HANDLER (One-Line Support) ---
    if [[ "$mnemonic" == "rep" || "$mnemonic" == "repe" || "$mnemonic" == "repz" || "$mnemonic" == "repne" || "$mnemonic" == "repnz" || "$mnemonic" == "lock" ]]; then
        if [[ -n "$args" ]]; then
            # Look up prefix opcode (e.g., rep -> 0xF3)
            # We assume prefixes are defined in ISA with opcode only
            local prefix_props="${ISA_OPCODES[$mnemonic]}"
            if [[ -z "$prefix_props" ]]; then log "Error: Unknown prefix '$mnemonic'"; return; fi

            # Extract opcode
            local prefix_opcode=""
            for prop in $prefix_props; do
                if [[ "$prop" == opcode=* ]]; then prefix_opcode="${prop#*=}"; break; fi
            done

            # Emit prefix
            if [[ $PASS -eq 2 ]]; then
                 printf "\\x$(printf "%02x" $prefix_opcode)" >> "$OUTPUT_FILE"
            fi
            CURRENT_OFFSET=$((CURRENT_OFFSET + 1))

            # Recurse
            compile_line "$args"
            return
        fi
    fi

    # Prop Directive
    if [[ "$mnemonic" == "prop" ]]; then
        if [[ -z "$STRUCT_NAME" ]]; then log "Error: 'prop' outside 'struktur'"; exit 1; fi
        local prop_name=$(echo "$args" | awk '{print $1}')
        local prop_size=$(echo "$args" | awk '{print $2}')
        local const_name="${STRUCT_NAME}_${prop_name}"
        if [[ -n "$CURRENT_UNIT" ]]; then const_name="${CURRENT_UNIT}_${const_name}"; fi
        if [[ $PASS -eq 1 ]]; then
            LABELS["$const_name"]=$STRUCT_OFFSET
        fi
        STRUCT_OFFSET=$((STRUCT_OFFSET + prop_size))
        return
    fi

    # Const Directive
    if [[ "$mnemonic" == "const" ]]; then
        local const_name=$(echo "$args" | awk '{print $1}')
        local const_val=$(echo "$args" | awk '{print $2}')
        if [[ -n "$CURRENT_UNIT" ]]; then
             const_name="${CURRENT_UNIT}_${const_name}"
        fi
        if [[ $PASS -eq 1 ]]; then
            LABELS["$const_name"]=$const_val
        fi
        return
    fi

    # Data Directive
    if [[ "$mnemonic" == "data" ]]; then
        local content=$(echo "$line" | cut -d'"' -f2)
        local hex_bytes=$(printf "%b" "$content" | od -An -v -t x1)
        for byte in $hex_bytes; do
            if [[ $PASS -eq 2 ]]; then
                printf "\\x$byte" >> "$OUTPUT_FILE"
            fi
            CURRENT_OFFSET=$((CURRENT_OFFSET + 1))
        done
        return
    fi

    # Debug Macro
    if [[ "$mnemonic" == "debug" ]]; then
        compile_line "push rax"; compile_line "push rdi"; compile_line "push rsi";
        compile_line "push rdx"; compile_line "push rcx"; compile_line "push r11";
        compile_line "mov rax, 0x0A4755424544"
        compile_line "push rax"
        compile_line "mov rax, 1"; compile_line "mov rdi, 1";
        compile_line "mov rsi, rsp"; compile_line "mov rdx, 6"; compile_line "syscall"
        compile_line "pop rax"; compile_line "pop r11"; compile_line "pop rcx";
        compile_line "pop rdx"; compile_line "pop rsi"; compile_line "pop rdi"; compile_line "pop rax"
        return
    fi

    # --- LAMBDA & CLOSURE SUPPORT ---
    if [[ "$mnemonic" == "lambda" ]]; then
        LAMBDA_COUNT=$((LAMBDA_COUNT + 1))
        local lambda_name=$(echo "$args" | awk '{print $1}')
        local rest=$(echo "$args" | cut -d' ' -f2-)
        local captures=""
        if [[ "$rest" =~ capture\((.*)\) ]]; then
            captures="${BASH_REMATCH[1]}"
            captures=${captures//,/ }
        fi
        LAMBDA_CAPTURES=($captures)
        local lambda_label="_lambda_gen_${LAMBDA_COUNT}"
        local skip_label=".skip_lambda_${LAMBDA_COUNT}"
        compile_line "jmp $skip_label"
        compile_line "${lambda_label}:"
        stack_push "LAMBDA" "$lambda_name"
        return
    fi

    if [[ "$mnemonic" == "tutup_lambda" ]]; then
        stack_pop
        if [[ "$POP_TYPE" != "LAMBDA" ]]; then log "Error: tutup_lambda mismatch"; exit 1; fi
        local lambda_id=$LAMBDA_COUNT
        local lambda_label="_lambda_gen_${lambda_id}"
        local skip_label=".skip_lambda_${lambda_id}"
        compile_line "ret"
        compile_line "${skip_label}:"
        local num_captures=${#LAMBDA_CAPTURES[@]}
        local struct_size=$((8 + num_captures * 8))
        compile_line "mov rdi, $struct_size"
        compile_line "call MorphLib_mem_alloc"
        compile_line "mov rdx, $lambda_label"
        compile_line "mov [rax], rdx"
        local offset=8
        for cap in "${LAMBDA_CAPTURES[@]}"; do
             compile_line "mov rdx, $cap"
             compile_line "mov [rax+$offset], rdx"
             offset=$((offset + 8))
        done
        return
    fi

    # Macro: context(N)
    if [[ "$mnemonic" == "context("* ]]; then :; fi

    # Macro: panggil_closure
    if [[ "$mnemonic" == "panggil_closure" ]]; then
        local reg="$args"
        compile_line "mov r10, $reg"
        compile_line "mov r11, [r10]"
        compile_line "call r11"
        return
    fi

    # Label Definition
    if [[ "$mnemonic" == *":" ]]; then
        local name=${mnemonic%:}
        if [[ -n "$CURRENT_UNIT" ]]; then
            name="${CURRENT_UNIT}_${name}"
        fi
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$((BASE_ADDR + CURRENT_OFFSET))
        elif [[ $PASS -eq 2 ]]; then
            local addr=$((BASE_ADDR + CURRENT_OFFSET))
            printf "%x %s\n" $addr "$name" >> "$SYM_FILE"
        fi
        return
    fi

    # --- INSTRUCTION / STRUCTURE LOOKUP ---
    local suffix=""
    local arg1=$(echo "$args" | awk '{print $1}')
    local arg2=$(echo "$args" | awk '{print $2}')
    arg1=${arg1%,}; arg2=${arg2%,}

    # Structure Handler
    local struct_props="${ISA_OPCODES[$mnemonic]}"
    if [[ "$struct_props" == *"kind=struct"* ]]; then
        handle_structure "$mnemonic" "$struct_props" "$args"
        return
    fi

    # ... Normal Opcode Encoding ...

    # Check for context(N) macro in args
    if [[ "$arg1" =~ context\(([0-9]+)\) ]]; then
        local idx="${BASH_REMATCH[1]}"
        local offset=$((8 + idx * 8))
        arg1="[r10+$offset]"
    fi
    if [[ "$arg2" =~ context\(([0-9]+)\) ]]; then
        local idx="${BASH_REMATCH[1]}"
        local offset=$((8 + idx * 8))
        arg2="[r10+$offset]"
    fi

    if [[ -n "$arg1" ]]; then
        if is_reg "$arg1"; then
            local type1="r64"
            if is_xmm "$arg1"; then type1="xmm"; fi

            if [[ -n "$arg2" ]]; then
                if is_reg "$arg2"; then
                    local type2="r64"
                    if is_xmm "$arg2"; then type2="xmm"; fi
                    suffix=".${type1}.${type2}"
                elif is_mem_operand "$arg2"; then
                    suffix=".${type1}.mem";
                elif is_imm "$arg2"; then
                     if is_imm8 "$arg2" && [[ -n "${ISA_OPCODES[${mnemonic}.${type1}.imm8]}" ]]; then suffix=".${type1}.imm8";
                     elif is_imm32 "$arg2" && [[ -n "${ISA_OPCODES[${mnemonic}.${type1}.imm32]}" ]]; then suffix=".${type1}.imm32";
                     elif [[ -n "${ISA_OPCODES[${mnemonic}.${type1}.imm64]}" ]]; then suffix=".${type1}.imm64";
                     fi
                else
                     # Assume Label -> imm32 (Address)
                     suffix=".${type1}.imm32"
                fi
            else
                suffix=".${type1}"
            fi
        elif is_mem_operand "$arg1"; then
             if [[ -n "$arg2" ]] && is_reg "$arg2"; then
                 local type2="r64"
                 if is_xmm "$arg2"; then type2="xmm"; fi
                 suffix=".mem.${type2}";
             elif [[ -n "$arg2" ]] && is_imm "$arg2"; then
                 if is_imm8 "$arg2" && [[ -n "${ISA_OPCODES[${mnemonic}.mem.imm8]}" ]]; then suffix=".mem.imm8";
                 else suffix=".mem.imm32"; fi
             else suffix=".mem64"; fi
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
        log "Error: Unknown instruction '$mnemonic' (args: $args) [Lookup: $lookup]"
        return
    fi

    # Decoding Props
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
        if [[ $r_val -ge 100 ]]; then r_val=$((r_val - 100)); fi # Map to HW ID
        if [[ $r_val -ge 8 ]]; then
            rex=$((rex | 0x41)) # REX.B
            r_val=$((r_val - 8))
        fi
    fi

    # Handle REX for ModRM
    local r_reg=-1
    local r_rm=-1
    local modrm_disp_size=0
    local modrm_disp_val=0

    if [[ $has_modrm -eq 1 ]]; then
        # --- ModRM with Displacement Logic Update ---
        local target_mem_arg=""
        if is_mem_operand "$arg1"; then target_mem_arg="$arg1"; fi
        if is_mem_operand "$arg2"; then target_mem_arg="$arg2"; fi

        if [[ -n "$target_mem_arg" ]]; then
             # Parse [base+disp]
             local inner=${target_mem_arg#\[}
             inner=${inner%\]}
             local base_reg=""
             local disp=0
             if [[ "$inner" =~ ([a-z0-9]+)\+([0-9]+) ]]; then
                 base_reg="${BASH_REMATCH[1]}"
                 disp="${BASH_REMATCH[2]}"
                 modrm_disp_val=$disp
                 if (( disp >= -128 && disp <= 127 )); then modrm_disp_size=8;
                 else modrm_disp_size=32; fi
             elif [[ "$inner" =~ ([a-z0-9]+)\-([0-9]+) ]]; then :
             else
                 base_reg="$inner"
             fi

             # Re-map base_reg for lookup
             if [[ "$modrm_mode" =~ ^[0-7]$ ]]; then r_rm=$(get_reg_id "$base_reg");
             elif [[ "$modrm_mode" == "reg,mem" ]]; then r_rm=$(get_reg_id "$base_reg"); r_reg=$(get_reg_id "$arg1");
             elif [[ "$modrm_mode" == "mem,reg" ]]; then r_rm=$(get_reg_id "$base_reg"); r_reg=$(get_reg_id "$arg2");
             else
                 if is_mem_operand "$arg1"; then r_rm=$(get_reg_id "$base_reg"); else r_reg=$(get_reg_id "$base_reg"); fi
             fi
        else
            # Normal Reg-Reg
             if [[ "$modrm_mode" == "reg,reg" ]]; then
                 r_rm=$(get_reg_id "$arg1")
                 r_reg=$(get_reg_id "$arg2")
             elif [[ "$modrm_mode" == "dst_reg,src_reg" ]]; then
                 r_reg=$(get_reg_id "$arg1")
                 r_rm=$(get_reg_id "$arg2")
             elif [[ "$modrm_mode" =~ ^[0-7]$ ]]; then r_rm=$(get_reg_id "$arg1");
             fi
        fi

        # Get HW IDs for REX calculation
        if [[ $r_reg -ne -1 ]]; then if [[ $r_reg -ge 100 ]]; then r_reg=$((r_reg - 100)); fi; fi
        if [[ $r_rm -ne -1 ]]; then if [[ $r_rm -ge 100 ]]; then r_rm=$((r_rm - 100)); fi; fi

        if [[ $r_reg -ge 8 ]]; then rex=$((rex | 0x44)); fi # REX.R
        if [[ $r_rm -ge 8 ]]; then rex=$((rex | 0x41)); fi # REX.B
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
        local r_reg_low=0
        if [[ $r_reg -ne -1 ]]; then r_reg_low=$((r_reg & 7)); elif [[ "$modrm_mode" =~ ^[0-7]$ ]]; then r_reg_low=$modrm_mode; fi

        # Determine Mod
        local mod=0
        local rm_low=0
        local needs_sib=0
        local disp_mode=0 # 0=none, 1=disp8, 2=disp32

        if [[ "$modrm_mode" == "reg,reg" ]]; then
            mod=3
            rm_low=$((r_rm & 7))
        elif is_mem_operand "$arg1" || is_mem_operand "$arg2"; then
             rm_low=$((r_rm & 7))
             if [[ $rm_low -eq 4 ]]; then needs_sib=1; fi

             if [[ $modrm_disp_size -eq 8 ]]; then mod=1; disp_mode=1;
             elif [[ $modrm_disp_size -eq 32 ]]; then mod=2; disp_mode=2;
             else
                 mod=0
                 if [[ $rm_low -eq 5 ]]; then mod=1; disp_mode=1; modrm_disp_val=0; fi # [rbp]
             fi
        else
            mod=3
            rm_low=$((r_rm & 7))
        fi

        emit_byte $(( (mod << 6) + (r_reg_low << 3) + rm_low ))

        if [[ $needs_sib -eq 1 ]]; then
            emit_byte 0x24 # SIB
        fi

        if [[ $disp_mode -eq 1 ]]; then emit_byte $((modrm_disp_val & 0xFF));
        elif [[ $disp_mode -eq 2 ]]; then emit_dword $modrm_disp_val;
        fi
    fi
    # Emit Immediates
    if [[ $imm_size -eq 32 ]]; then
        if [[ $is_rel32 -eq 1 ]]; then
            local label=$(parse_operand "$arg1")
            if [[ $PASS -eq 2 ]]; then
                local target=$(lookup_label "$label")
                if [[ -z "$target" ]]; then log "Error: Label '$label' not found (Unit: $CURRENT_UNIT)"; exit 1; fi
                local pc=$((BASE_ADDR + CURRENT_OFFSET + 4))
                local rel=$((target - pc))
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

get_abs_path() {
    readlink -f "$1"
}

process_file() {
    local filepath="$1"
    local abs_path=$(get_abs_path "$filepath")

    if [[ -n "${INCLUDED_FILES[$abs_path]}" ]]; then
        return
    fi
    INCLUDED_FILES["$abs_path"]=1

    local dir=$(dirname "$filepath")

    if [[ ! -f "$filepath" ]]; then
        log "Error: File $filepath not found."
        exit 1
    fi

    log "Processing file: $filepath"

    local file_lines
    mapfile -t file_lines < "$filepath"

    for line in "${file_lines[@]}"; do
        local clean_line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
        local lc_line=${clean_line,,} # Lowercase for check

        if [[ "$lc_line" == ambil* ]]; then
            # Extract target regardless of case
            local target=$(echo "$clean_line" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')

            # Resolve relative to current file's directory
            local target_path="$dir/$target"
            process_file "$target_path"
        else
            # Normal line, append to combined
            echo "$line" >> "$COMBINED_FILE"
        fi
    done
    echo "" >> "$COMBINED_FILE"
}

process_module() {
    local dir="$1"
    local parent_unit="$2"
    local tagger="$dir/tagger.fox"
    local abs_tagger=$(get_abs_path "$tagger")

    if [[ -n "${INCLUDED_FILES[$abs_tagger]}" ]]; then
        return
    fi
    INCLUDED_FILES["$abs_tagger"]=1

    if [[ ! -f "$tagger" ]]; then
        log "Error: Module initializer '$tagger' not found."
        exit 1
    fi

    log "Processing module: $dir (Parent Unit: $parent_unit)"

    local tagger_lines
    mapfile -t tagger_lines < "$tagger"

    # Scan for Unit Definition first
    local my_unit="$parent_unit"
    local unit_line_found=0
    for line in "${tagger_lines[@]}"; do
         local clean_line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
         local lc_line=${clean_line,,}
         if [[ "$lc_line" == unit:* ]]; then
             local val=${clean_line#*:}
             my_unit=$(echo "$val" | sed 's/^[ \t]*//;s/[ \t]*$//')
             log "Unit found: $my_unit"

             # If this is the Root Intent Tree (e.g. MyService), we Init it.
             # Only if we are not MorphLib
             if [[ "$my_unit" != "MorphLib" ]]; then
                 INTENT_ACTIVE_UNIT="$my_unit"
                 # Emit: routine_init_unit(123)
                 echo "mov rdi, 1" >> "$INTENT_INIT_CODE_FILE" # ID=1
                 echo "call MorphLib_routine_init_unit" >> "$INTENT_INIT_CODE_FILE"
                 echo "mov r13, rax" >> "$INTENT_INIT_CODE_FILE" # Save Unit Ptr in r13 (Avoid r13 Heap Root)
             fi

             unit_line_found=1
             break
         fi
    done

    # Emit Unit Start Meta if changed
    if [[ "$my_unit" != "$parent_unit" ]]; then
        echo ".meta_unit $my_unit" >> "$COMBINED_FILE"
    fi

    for line in "${tagger_lines[@]}"; do
        local clean_line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
        local lc_line=${clean_line,,}

        if [[ -z "$clean_line" ]]; then continue; fi

        # Skip Unit line
        if [[ "$lc_line" == unit:* ]]; then continue; fi

        # --- SHARD ---
        if [[ "$lc_line" == shard:* ]]; then
            if [[ -z "$INTENT_ACTIVE_UNIT" ]]; then log "Error: Shard outside Unit"; exit 1; fi
            local shard_name=${clean_line#*:}
            shard_name=$(echo "$shard_name" | sed 's/^[ \t]*//;s/[ \t]*$//')

            # Emit: routine_init_shard(456)
            echo "mov rdi, 2" >> "$INTENT_INIT_CODE_FILE" # ID=2
            echo "call MorphLib_routine_init_shard" >> "$INTENT_INIT_CODE_FILE"
            echo "mov r14, rax" >> "$INTENT_INIT_CODE_FILE" # Save Shard Ptr in r14

            # Add Shard to Unit
            echo "mov rdi, r13" >> "$INTENT_INIT_CODE_FILE" # Use r13 (Unit Ptr)
            echo "mov rsi, r14" >> "$INTENT_INIT_CODE_FILE"
            echo "call MorphLib_routine_add_shard" >> "$INTENT_INIT_CODE_FILE"

            INTENT_ACTIVE_SHARD="$shard_name"
            continue
        fi

        # --- FRAGMENT ---
        # Syntax: Fragment: name -> Ambil file.fox
        if [[ "$lc_line" == fragment:* ]]; then
             if [[ -z "$INTENT_ACTIVE_SHARD" ]]; then log "Error: Fragment outside Shard"; exit 1; fi

             # Split "name -> Ambil file"
             local rest=${clean_line#*:}
             local frag_name=$(echo "$rest" | awk -F'->' '{print $1}' | sed 's/^[ \t]*//;s/[ \t]*$//')
             local action=$(echo "$rest" | awk -F'->' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')

             # Process Action (Ambil)
             local frag_target=""
             local lc_action=${action,,}
             if [[ "$lc_action" == ambil* ]]; then
                 local target=$(echo "$action" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')
                 local full_target="$dir/$target"

                 # Process File
                 if [[ -d "$full_target" ]]; then
                     process_module "$full_target" "$my_unit"
                     # Assumption: Module has entry point? Not supported yet.
                 else
                     if [[ -f "$full_target" ]]; then process_file "$full_target";
                     elif [[ -f "$full_target.fox" ]]; then process_file "$full_target.fox";
                     fi
                 fi

                 # Fragment Target Function is "Unit_FragName"
                 frag_target="${my_unit}_${frag_name}"
             else
                 log "Error: Unknown fragment action '$action'"
                 exit 1
             fi

             # Emit: routine_init_fragment(ptr, ctx)
             echo "mov rdi, $frag_target" >> "$INTENT_INIT_CODE_FILE"
             echo "mov rsi, 0" >> "$INTENT_INIT_CODE_FILE"
             echo "call MorphLib_routine_init_fragment" >> "$INTENT_INIT_CODE_FILE"

             # Add Fragment to Shard
             echo "mov rdi, r14" >> "$INTENT_INIT_CODE_FILE"
             echo "mov rsi, rax" >> "$INTENT_INIT_CODE_FILE"
             echo "call MorphLib_routine_add_fragment" >> "$INTENT_INIT_CODE_FILE"

             continue
        fi

        if [[ "$lc_line" == ambil* ]]; then
             local target=$(echo "$clean_line" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')
             local full_target="$dir/$target"

             if [[ -d "$full_target" ]]; then
                 process_module "$full_target" "$my_unit"
             elif [[ -f "$full_target" ]]; then
                 process_file "$full_target"
             else
                 if [[ -f "$full_target.fox" ]]; then
                     process_file "$full_target.fox"
                 else
                     log "Error: Target '$full_target' not found in '$tagger'."
                     exit 1
                 fi
             fi
        fi
    done

    # Restore Parent Unit Meta if changed
    if [[ "$my_unit" != "$parent_unit" ]]; then
        if [[ -z "$parent_unit" ]]; then
            echo ".meta_unit_reset" >> "$COMBINED_FILE"
        else
            echo ".meta_unit $parent_unit" >> "$COMBINED_FILE"
        fi
    fi
}

if [[ $# -lt 1 ]]; then echo "Usage: $0 <input.fox>"; exit 1; fi
INPUT_FILE="$1"
COMBINED_FILE="combined_input.tmp"

# Clear combined file
> "$COMBINED_FILE"
> "$INTENT_INIT_CODE_FILE"

# 1. Load ISA
load_isa

# 2. Process Dependencies (Root Tagger + Input File)
process_module "." "" # Start with no unit
process_file "$INPUT_FILE"

# 3. Inject Auto-Generated Init Function
echo "" >> "$COMBINED_FILE"
echo "fungsi _auto_init_intent_tree" >> "$COMBINED_FILE"
cat "$INTENT_INIT_CODE_FILE" >> "$COMBINED_FILE"
# If we built a tree, return the Root Unit Ptr (r13)
if [[ -s "$INTENT_INIT_CODE_FILE" ]]; then
    echo "mov rax, r13" >> "$COMBINED_FILE"
else
    echo "mov rax, 0" >> "$COMBINED_FILE"
fi
echo "ret" >> "$COMBINED_FILE"
echo "tutup_fungsi" >> "$COMBINED_FILE"

log "PASS 1: Scanning Labels..."
PASS=1; init_output
while IFS= read -r line; do compile_line "$line"; done < "$COMBINED_FILE"

log "PASS 2: Compiling..."
PASS=2; init_output
while IFS= read -r line; do compile_line "$line"; done < "$COMBINED_FILE"

# Cleanup
rm -f "$COMBINED_FILE" "$INTENT_INIT_CODE_FILE"

chmod +x "$OUTPUT_FILE"
log "Success: $OUTPUT_FILE"

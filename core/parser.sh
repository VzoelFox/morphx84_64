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

# SIMD Registers (Mapped to 0-15 for ModRM encoding)
REGISTERS["xmm0"]=0
REGISTERS["xmm1"]=1
REGISTERS["xmm2"]=2
REGISTERS["xmm3"]=3
REGISTERS["xmm4"]=4
REGISTERS["xmm5"]=5
REGISTERS["xmm6"]=6
REGISTERS["xmm7"]=7
REGISTERS["xmm8"]=8
REGISTERS["xmm9"]=9
REGISTERS["xmm10"]=10
REGISTERS["xmm11"]=11
REGISTERS["xmm12"]=12
REGISTERS["xmm13"]=13
REGISTERS["xmm14"]=14
REGISTERS["xmm15"]=15

# Control Flow Stack
declare -a STACK_TYPE
declare -a STACK_ID
declare -a STACK_ELSE
STACK_PTR=0
BLOCK_COUNTER=0

# Struct Management
STRUCT_NAME=""
STRUCT_OFFSET=0

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
    # Actually, we rely on deterministic BLOCK_COUNTER.
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
    if ! is_imm "$val"; then
        local target=${LABELS["$val"]}
        if [[ -n "$target" ]]; then
            val=$target
        elif [[ $PASS -eq 2 ]]; then
            log "Error: Label '$val' not found"
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
        local target=${LABELS["$val"]}
        if [[ -n "$target" ]]; then
            val=$target
        elif [[ $PASS -eq 2 ]]; then
            log "Error: Label '$val' not found"
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
            if [[ $PASS -eq 1 ]]; then
                LABELS["$name"]=$((BASE_ADDR + CURRENT_OFFSET))
                log "Fungsi: $name -> $CURRENT_OFFSET"
            elif [[ $PASS -eq 2 ]]; then
                local addr=$((BASE_ADDR + CURRENT_OFFSET))
                printf "%x %s\n" $addr "$name" >> "$SYM_FILE"
            fi
        else
            BLOCK_COUNTER=$((BLOCK_COUNTER + 1))
            id=$BLOCK_COUNTER

            # Action: Label Start (for Loop)
            if [[ "$action" == "label_start" ]]; then
                compile_line ".L_LOOP_START_${id}:"
            fi

            # Jump Condition (for IF)
            if [[ -n "$jump_cond" ]]; then
                # Inverse logic: If definition says 'jump_condition=jne', it means "Jump to FALSE if NOT Equal"
                # This matches our Indonesian mapping (jika_sama -> jump if not same -> jne)
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
             compile_line "const ${POP_ID}_SIZE $STRUCT_OFFSET"
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
    line=${line%%;*} # Remove comments
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
    if [[ -z "$line" ]]; then return; fi

    local mnemonic=$(echo "$line" | awk '{print $1}')
    local args=$(echo "$line" | cut -d' ' -f2-)

    # Prop Directive (Inside Struktur)
    if [[ "$mnemonic" == "prop" ]]; then
        if [[ -z "$STRUCT_NAME" ]]; then log "Error: 'prop' outside 'struktur'"; exit 1; fi
        local prop_name=$(echo "$args" | awk '{print $1}')
        local prop_size=$(echo "$args" | awk '{print $2}')

        # Define Constant: STRUCT_PROP = OFFSET
        compile_line "const ${STRUCT_NAME}_${prop_name} $STRUCT_OFFSET"

        STRUCT_OFFSET=$((STRUCT_OFFSET + prop_size))
        return
    fi

    # Const Directive (Define Constant Value)
    if [[ "$mnemonic" == "const" ]]; then
        local const_name=$(echo "$args" | awk '{print $1}')
        local const_val=$(echo "$args" | awk '{print $2}')

        if [[ $PASS -eq 1 ]]; then
            # Store directly in LABELS.
            # This overrides address mapping if name conflicts.
            LABELS["$const_name"]=$const_val
        fi
        return
    fi

    # Data Directive (String Literal)
    if [[ "$mnemonic" == "data" ]]; then
        local content=$(echo "$line" | cut -d'"' -f2)
        # Use od to get hex bytes of the expanded string (handling \n, \x00, etc)
        local hex_bytes=$(printf "%b" "$content" | od -An -v -t x1)

        for byte in $hex_bytes; do
            # byte is hex string (e.g. 48)
            if [[ $PASS -eq 2 ]]; then
                printf "\\x$byte" >> "$OUTPUT_FILE"
            fi
            CURRENT_OFFSET=$((CURRENT_OFFSET + 1))
        done
        return
    fi

    # Debug Macro (Still Hardcoded as Macro System is not yet in place)
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
        if [[ $PASS -eq 1 ]]; then
            LABELS["$name"]=$((BASE_ADDR + CURRENT_OFFSET))
        elif [[ $PASS -eq 2 ]]; then
            # Write to Symbol Map: Address Name
            local addr=$((BASE_ADDR + CURRENT_OFFSET))
            # Print as hex addr
            printf "%x %s\n" $addr "$name" >> "$SYM_FILE"
        fi
        return
    fi

    # --- INSTRUCTION / STRUCTURE LOOKUP ---
    local suffix=""
    local arg1=$(echo "$args" | awk '{print $1}')
    local arg2=$(echo "$args" | awk '{print $2}')
    arg1=${arg1%,}; arg2=${arg2%,}

    # Attempt to resolve suffix for Opcode Lookup
    # But first, check if it's a structural keyword (usually no args or specific args)
    local struct_props="${ISA_OPCODES[$mnemonic]}"
    if [[ "$struct_props" == *"kind=struct"* ]]; then
        handle_structure "$mnemonic" "$struct_props" "$args"
        return
    fi

    # ... Normal Opcode Encoding ...
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
                else
                     # Assume Label -> imm32 (Address)
                     suffix=".r64.imm32"
                fi
            else
                suffix=".r64"
            fi
        elif is_mem_operand "$arg1"; then
             if [[ -n "$arg2" ]] && is_reg "$arg2"; then suffix=".mem.r64";
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
        log "Error: Unknown instruction '$mnemonic' (args: $args)"
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
        if [[ $r_val -ge 8 ]]; then
            rex=$((rex | 0x41)) # REX.B
            r_val=$((r_val - 8))
        fi
    fi

    # Handle REX for ModRM (Calculate REX.R and REX.B)
    local r_reg=-1
    local r_rm=-1
    local modrm_disp_size=0
    local modrm_disp_val=0

    if [[ $has_modrm -eq 1 ]]; then
        if [[ "$modrm_mode" == "reg,reg" ]]; then
             r_rm=$(get_reg_id "$arg1")
             r_reg=$(get_reg_id "$arg2")
        elif [[ "$modrm_mode" == "dst_reg,src_reg" ]]; then
             r_reg=$(get_reg_id "$arg1")
             r_rm=$(get_reg_id "$arg2")
        elif [[ "$modrm_mode" =~ ^[0-7]$ ]]; then
             if is_mem_operand "$arg1"; then
                 r_rm=$(get_mem_reg_id "$arg1")
             else
                 r_rm=$(get_reg_id "$arg1")
             fi
        elif [[ "$modrm_mode" == "reg,mem" ]]; then
             r_reg=$(get_reg_id "$arg1")
             r_rm=$(get_mem_reg_id "$arg2")
        elif [[ "$modrm_mode" == "mem,reg" ]]; then
             r_reg=$(get_reg_id "$arg2")
             r_rm=$(get_mem_reg_id "$arg1")
        fi

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
             mod=0
             rm_low=$((r_rm & 7))
             if [[ $rm_low -eq 4 ]]; then needs_sib=1; fi
             if [[ $rm_low -eq 5 ]]; then mod=1; disp_mode=1; modrm_disp_val=0; fi # [rbp] needs disp8(0)
        else
            # Single operand register (not mem) treated as ModRM (e.g. shift)
            mod=3
            rm_low=$((r_rm & 7))
        fi

        emit_byte $(( (mod << 6) + (r_reg_low << 3) + rm_low ))

        if [[ $needs_sib -eq 1 ]]; then
            emit_byte 0x24 # SIB: Scale=1, Index=None(4), Base=R12/RSP(4)
        fi

        if [[ $disp_mode -eq 1 ]]; then emit_byte $modrm_disp_val; fi
    fi
    # Emit Immediates
    if [[ $imm_size -eq 32 ]]; then
        if [[ $is_rel32 -eq 1 ]]; then
            local label=$(parse_operand "$arg1")
            if [[ $PASS -eq 2 ]]; then
                local target=${LABELS["$label"]}
                if [[ -z "$target" ]]; then log "Error: Label '$label' not found"; exit 1; fi
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
        # Trim
        local clean_line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')

        # Strict Check: Ambil (Capital) forbidden in source
        if [[ "$clean_line" == Ambil* ]]; then
            log "Error: 'Ambil' (Capital) forbidden in source file '$filepath'. Use 'ambil' for local imports."
            exit 1
        fi

        # Check: ambil (Lower)
        if [[ "$clean_line" == ambil* ]]; then
            local target=${clean_line#ambil }
            target=$(echo "$target" | sed 's/^[ \t]*//;s/[ \t]*$//')

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

    log "Processing module: $dir"

    local tagger_lines
    mapfile -t tagger_lines < "$tagger"

    for line in "${tagger_lines[@]}"; do
        local clean_line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')

        if [[ -z "$clean_line" ]]; then continue; fi

        # Strict Check: ambil (Lower) forbidden in tagger
        if [[ "$clean_line" == ambil* ]]; then
             log "Error: 'ambil' (Lower) forbidden in module initializer '$tagger'. Use 'Ambil'."
             exit 1
        fi

        if [[ "$clean_line" == Ambil* ]]; then
             local target=${clean_line#Ambil }
             target=$(echo "$target" | sed 's/^[ \t]*//;s/[ \t]*$//')

             local full_target="$dir/$target"

             if [[ -d "$full_target" ]]; then
                 process_module "$full_target"
             elif [[ -f "$full_target" ]]; then
                 process_file "$full_target"
             else
                 # Try with extension?
                 if [[ -f "$full_target.fox" ]]; then
                     process_file "$full_target.fox"
                 else
                     log "Error: Target '$full_target' not found in '$tagger'."
                     exit 1
                 fi
             fi
        fi
    done
}

if [[ $# -lt 1 ]]; then echo "Usage: $0 <input.fox>"; exit 1; fi
INPUT_FILE="$1"
COMBINED_FILE="combined_input.tmp"

# Clear combined file
> "$COMBINED_FILE"

# 1. Load ISA
load_isa

# 2. Process Dependencies (Root Tagger + Input File)
# We treat the root directory as the root module.
process_module "."
process_file "$INPUT_FILE"

log "PASS 1: Scanning Labels..."
PASS=1; init_output
while IFS= read -r line; do compile_line "$line"; done < "$COMBINED_FILE"

log "PASS 2: Compiling..."
PASS=2; init_output
while IFS= read -r line; do compile_line "$line"; done < "$COMBINED_FILE"

# Cleanup
rm -f "$COMBINED_FILE"

chmod +x "$OUTPUT_FILE"
log "Success: $OUTPUT_FILE"

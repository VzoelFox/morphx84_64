.intel_syntax noprefix
.global _start

.text
_start:
    # 1. Get Current Break (Heap Start)
    mov rax, 12             # sys_brk
    xor rdi, rdi            # addr = 0
    syscall
    mov r15, rax            # r15 = Base Address of Heap

    # 2. Allocate 4MB
    lea rdi, [r15 + 0x400000]
    mov rax, 12
    syscall

    # Check if alloc failed (rax == r15) ? No, sys_brk returns new break

    # 3. Setup Pointers
    # r15 = Source Buffer (Input)
    lea r14, [r15 + 0x100000] # Code Buffer (Output)
    lea r13, [r15 + 0x200000] # Symbol Table
    lea rbp, [r15 + 0x300000] # Patch Table

    # 4. Read STDIN to Source Buffer
    xor r12, r12 # Total Bytes Read
read_loop:
    mov rax, 0      # sys_read
    xor rdi, rdi    # stdin
    lea rsi, [r15 + r12]
    mov rdx, 4096
    syscall
    cmp rax, 0
    jle read_done
    add r12, rax
    jmp read_loop
read_done:
    mov byte ptr [r15 + r12], 0 # Null Terminate

    # 5. Scan Loop
    mov rbx, r15 # Read Ptr
    mov rdi, r14 # Write Ptr

scan_loop:
    movzx rcx, byte ptr [rbx]
    test rcx, rcx
    jz scan_done
    inc rbx

    # Skip Whitespace
    cmp rcx, 0x20
    je scan_loop
    cmp rcx, 0x09
    je scan_loop
    cmp rcx, 0x0A
    je scan_loop

    # Comments
    cmp rcx, 0x3B # ;
    je skip_comment
    cmp rcx, 0x23 # #
    je skip_comment

    # Labels
    cmp rcx, 0x3A # :
    je handle_label_def
    cmp rcx, 0x40 # @
    je handle_label_ref

    # Hex
    call get_hex_val
    cmp rax, 0
    js scan_loop # Ignore garbage if not caught above

    # Have High Nibble
    mov r8, rax
    shl r8, 4

    # Get Low Nibble
get_low:
    movzx rcx, byte ptr [rbx]
    test rcx, rcx
    jz error_eof
    inc rbx
    call get_hex_val
    cmp rax, 0
    js get_low # Skip intermediate garbage

    or r8, rax
    mov rax, r8
    stosb
    jmp scan_loop

skip_comment:
    movzx rcx, byte ptr [rbx]
    inc rbx
    cmp rcx, 0x0A
    je scan_loop
    test rcx, rcx
    jz scan_done
    jmp skip_comment

handle_label_def:
    call parse_hash
    mov [r13], rax      # Hash
    mov rax, rdi
    sub rax, r14        # Offset
    mov [r13+8], rax
    add r13, 16
    jmp scan_loop

handle_label_ref:
    call parse_hash
    mov [rbp], rax      # Hash
    mov rax, rdi
    sub rax, r14        # Offset
    mov [rbp+8], rax
    add rbp, 16
    mov al, 0
    stosb
    jmp scan_loop

scan_done:
    # 6. Patching
    lea rsi, [r15 + 0x300000] # Patch Iterator
    # rbp is End of Patch

patch_loop:
    cmp rsi, rbp
    je finish_output

    mov r8, [rsi]       # Hash
    mov r9, [rsi+8]     # Patch Offset

    # Find Symbol in r15 + 0x200000 -> r13
    lea rcx, [r15 + 0x200000]
find_sym:
    cmp rcx, r13
    je error_sym # Symbol not found
    cmp [rcx], r8
    je found_sym
    add rcx, 16
    jmp find_sym

found_sym:
    mov r10, [rcx+8]    # Target Offset
    # Rel = Target - PatchOffset - 1
    sub r10, r9
    dec r10

    # Patch
    mov byte ptr [r14 + r9], r10b

    add rsi, 16
    jmp patch_loop

finish_output:
    mov rax, 1          # sys_write
    mov rdi, 1          # stdout
    mov rsi, r14        # Buffer
    mov rdx, rdi        # Write Ptr
    sub rdx, r14        # Length
    syscall

    mov rax, 60
    xor rdi, rdi
    syscall

# Error Handlers
error_eof:
    mov rax, 60
    mov rdi, 2
    syscall
error_sym:
    mov rax, 60
    mov rdi, 3
    syscall

# Helpers
get_hex_val:
    cmp rcx, 0x30
    jl not_hex
    cmp rcx, 0x39
    jle is_digit
    cmp rcx, 0x41
    jl not_hex
    cmp rcx, 0x46
    jle is_upper
    cmp rcx, 0x61
    jl not_hex
    cmp rcx, 0x66
    jle is_lower
not_hex:
    mov rax, -1
    ret
is_digit:
    sub rcx, 0x30
    mov rax, rcx
    ret
is_upper:
    sub rcx, 0x37
    mov rax, rcx
    ret
is_lower:
    sub rcx, 0x57
    mov rax, rcx
    ret

parse_hash:
    xor rax, rax
hash_loop:
    movzx rcx, byte ptr [rbx]
    cmp rcx, 0x20
    jle hash_done
    cmp rcx, 0x3B
    je hash_done
    cmp rcx, 0x23
    je hash_done
    inc rbx

    mov rdx, rax
    shl rdx, 5
    add rax, rdx
    xor rax, rcx
    jmp hash_loop
hash_done:
    ret

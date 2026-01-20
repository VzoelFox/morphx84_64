.intel_syntax noprefix
.global _start

.text
_start:
    # 1. Get Current Break
    mov rax, 12
    xor rdi, rdi
    syscall
    mov r15, rax        # Base

    # 2. Alloc 4MB
    lea rdi, [r15 + 0x400000]
    mov rax, 12
    syscall

    # 3. Setup
    # r15 = Source
    lea r14, [r15 + 0x100000] # Code
    lea r13, [r15 + 0x200000] # Sym
    lea rbp, [r15 + 0x300000] # Patch

    # 4. Read STDIN
    xor r12, r12
read_loop:
    mov rax, 0
    xor rdi, rdi
    lea rsi, [r15 + r12]
    mov rdx, 4096
    syscall
    cmp rax, 0
    jle read_done
    add r12, rax
    jmp read_loop
read_done:
    mov byte ptr [r15 + r12], 0

    # 5. Scan
    mov rbx, r15 # Read
    mov rdi, r14 # Write (rdi is used by stosb)

scan_loop:
    movzx rcx, byte ptr [rbx]
    test rcx, rcx
    jz scan_done
    inc rbx

    cmp rcx, 0x20
    je scan_loop
    cmp rcx, 0x09
    je scan_loop
    cmp rcx, 0x0A
    je scan_loop

    cmp rcx, 0x3B # ;
    je skip_comment
    cmp rcx, 0x23 # #
    je skip_comment

    cmp rcx, 0x3A # :
    je handle_label_def
    cmp rcx, 0x40 # @
    je handle_label_ref

    call get_hex_val
    cmp rax, 0
    js scan_loop

    # High Nibble
    mov r8, rax
    shl r8, 4

    # Low Nibble
get_low:
    movzx rcx, byte ptr [rbx]
    test rcx, rcx
    jz error_eof
    inc rbx
    call get_hex_val
    cmp rax, 0
    js get_low

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
    mov [r13], rax
    mov rax, rdi
    sub rax, r14        # Offset from Start of Code
    mov [r13+8], rax
    add r13, 16
    jmp scan_loop

handle_label_ref:
    call parse_hash
    mov [rbp], rax
    mov rax, rdi
    sub rax, r14        # Offset from Start of Code
    mov [rbp+8], rax
    add rbp, 16
    mov al, 0
    stosb
    jmp scan_loop

scan_done:
    # 6. Patching
    # Save Output End Ptr
    mov r12, rdi # r12 = End of Code

    lea rsi, [r15 + 0x300000] # Patch Start
    # rbp is Patch End

patch_loop:
    cmp rsi, rbp
    je finish_output

    mov r8, [rsi]       # Hash
    mov r9, [rsi+8]     # Patch Offset (from Start of Code)

    # Search Symbols
    lea rcx, [r15 + 0x200000]
find_sym:
    cmp rcx, r13
    je error_sym
    cmp [rcx], r8
    je found_sym
    add rcx, 16
    jmp find_sym

found_sym:
    mov r10, [rcx+8]    # Target Offset (from Start of Code)

    # Rel = Target - PatchOffset - 1
    # r10 = Target
    # r9 = Patch
    sub r10, r9
    dec r10

    mov byte ptr [r14 + r9], r10b

    add rsi, 16
    jmp patch_loop

finish_output:
    mov rax, 1          # sys_write
    mov rdi, 1          # stdout
    mov rsi, r14        # Buffer Start
    mov rdx, r12        # Buffer End
    sub rdx, r14        # Length
    syscall

    mov rax, 60
    xor rdi, rdi
    syscall

error_eof:
    mov rax, 60
    mov rdi, 2
    syscall
error_sym:
    mov rax, 60
    mov rdi, 3
    syscall

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

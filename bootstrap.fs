\ bootstrap.fs - A minimal Forth compiler for VZOELFOX

\ --- Memory ---
500000 constant MAX-CODE
variable code-buffer
variable code-ptr
MAX-CODE allocate throw code-buffer !
code-buffer @ code-ptr !

\ --- Utils ---
: emit-byte ( c -- ) code-ptr @ c! 1 code-ptr +! ;
: emit-magic ( -- )
  $56 emit-byte $5A emit-byte $4F emit-byte $45 emit-byte
  $4C emit-byte $46 emit-byte $4F emit-byte $58 emit-byte ;
: emit-word ( w -- ) dup emit-byte 8 rshift emit-byte ;
: emit-dword ( dw -- ) dup emit-word 16 rshift emit-word ;
: emit-string ( addr len -- )
  bounds do i c@ emit-byte loop ;
: emit-qword ( qw -- ) dup emit-dword 32 rshift emit-dword ;

: str-eq? ( a1 l1 a2 l2 -- f ) compare 0= ;
: debug-print ( a l -- )
  2dup stderr write-file drop
  s"  Len: " stderr write-file drop
  dup 0 .r
  s"  " stderr write-line drop ;

\ --- Parser Utils ---
variable source-ptr
variable source-len
variable current-offset

\ Stack-based state preservation
: save-state ( -- ptr len off )
  source-ptr @ source-len @ current-offset @ ;
: restore-state ( ptr len off -- )
  current-offset ! source-len ! source-ptr ! ;

: file-exists? ( addr len -- f )
  r/o open-file if drop false else close-file throw true then ;

create temp-path 256 allot

: concat-path ( dir-a dir-l file-a file-l -- full-a full-l )
  dup >r \ save file-l
  2swap dup >r \ save dir-l (R: fl dl)
  temp-path swap move \ move dir
  r> temp-path + \ dest
  rot swap r@ move \ move file
  temp-path r> r> + ; \ full-addr full-len

: try-open ( addr len -- fd )
  \ Try relative to CWD
  2dup type s"  ? " type 2dup file-exists?
  if s" YES" type cr r/o open-file throw exit else s" NO" type cr then
  \ Try src/ prefix
  s" src/" 2swap concat-path
  2dup type s"  ? " type 2dup file-exists?
  if s" YES" type cr r/o open-file throw exit else s" NO" type cr then
  \ Fail
  s" Brainlib/" 2swap concat-path
  2dup debug-print \ Print failure path
  r/o open-file throw ;

: slurp-file ( addr len -- )
  2dup debug-print
  try-open >r
  r@ file-size throw drop
  dup . cr \ Print Size
  dup source-len !
  dup allocate throw source-ptr !
  source-ptr @ source-len @ r@ read-file throw drop
  r> close-file throw
  0 current-offset ! ;

: skip-ws
  begin
    current-offset @ source-len @ < if
      source-ptr @ current-offset @ + c@ 32 <= if
        1 current-offset +! 0
      else -1 then
    else -1 then
  until ;

: next-word ( -- addr len )
  skip-ws
  current-offset @ source-len @ >= if 0 0 exit then
  source-ptr @ current-offset @ +
  0
  begin
    current-offset @ source-len @ < if
      source-ptr @ current-offset @ + c@ 32 > if
        1+ 1 current-offset +! 0
      else -1 then
    else -1 then
  until ;

: parse-number ( addr len -- val )
  \ Hex 0x...
  over c@ [char] 0 = if
    over 1+ c@ [char] x = if
      2 /string base @ >r hex
      0 0 2swap >number 2drop drop
      r> base ! exit
    then
  then
  \ Decimal
  0 0 2swap >number 2drop drop ;

: strip-comma ( addr len -- addr len )
  dup 0= if exit then
  2dup + 1- c@ [char] , = if 1- then ;

: strip-quotes ( addr len -- addr len )
  dup 2 < if exit then
  1 /string 1- ;

: parse-data ( addr len -- )
  strip-quotes
  \ Loop chars
  bounds do
    i c@ [char] \ = if
       \ Escape? Simplified: Handle \0, \n
       \ For now assume simple strings and 0 terminator if needed
    else
       i c@ emit-byte
    then
  loop ;

\ --- Labels & Control Flow ---
wordlist constant labels-list
: add-label ( addr len val -- )
  -rot nextname
  get-current >r labels-list set-current
  create ,
  r> set-current ;
: find-label ( addr len -- val true | false )
  labels-list search-wordlist if >body @ -1 else 0 then ;

variable patches 0 patches !
: add-patch-full ( addr len offset -- )
  align here patches @ , patches ! , \ Link, Offset
  dup , \ Len
  here swap dup allot move \ String
  align ;

: resolve-patches-full
  patches @ begin dup while
    dup >r
    cell+ @ \ offset
    r@ 2 cells + @ \ len
    r@ 3 cells + \ str-addr
    swap \ offset str-addr len
    2dup find-label if
       drop nip nip
       2dup swap - 4 -
       -rot drop
       code-buffer @ + l!
    else
       2drop drop
    then
    r> @
  repeat drop ;

\ --- Encoder ---
: emit-rex ( w r b -- )
  >r swap if 8 else 0 then swap if 4 or then r> if 1 or then
  dup 0 > if $40 or emit-byte else drop then ;

: is-reg ( addr len -- id type true | addr len false )
  \ type: 0=gp, 1=xmm
  2dup s" rax" str-eq? if 2drop 0 0 -1 exit then
  2dup s" rcx" str-eq? if 2drop 1 0 -1 exit then
  2dup s" rdx" str-eq? if 2drop 2 0 -1 exit then
  2dup s" rbx" str-eq? if 2drop 3 0 -1 exit then
  2dup s" rsp" str-eq? if 2drop 4 0 -1 exit then
  2dup s" rbp" str-eq? if 2drop 5 0 -1 exit then
  2dup s" rsi" str-eq? if 2drop 6 0 -1 exit then
  2dup s" rdi" str-eq? if 2drop 7 0 -1 exit then
  2dup s" r8"  str-eq? if 2drop 8 0 -1 exit then
  2dup s" r9"  str-eq? if 2drop 9 0 -1 exit then
  2dup s" r10" str-eq? if 2drop 10 0 -1 exit then
  2dup s" r11" str-eq? if 2drop 11 0 -1 exit then
  2dup s" r12" str-eq? if 2drop 12 0 -1 exit then
  2dup s" r13" str-eq? if 2drop 13 0 -1 exit then
  2dup s" r14" str-eq? if 2drop 14 0 -1 exit then
  2dup s" r15" str-eq? if 2drop 15 0 -1 exit then
  0 ;

\ --- Recursive Compiler ---
defer compile-recurse

: compile-loop
  begin
    next-word dup 0 >
  while
    2dup type cr \ DEBUG PARSER
    \ Directives
    2dup s" Ambil" str-eq? if
       2drop next-word 2drop \ compile-recurse
    else 2dup s" fungsi" str-eq? if
       2drop next-word
       code-ptr @ code-buffer @ - add-label
    else 2dup s" tutup_fungsi" str-eq? if 2drop
    else 2dup s" Unit:" str-eq? if 2drop next-word 2drop
    else 2dup s" Shard:" str-eq? if 2drop next-word 2drop
    else 2dup s" Fragment:" str-eq? if 2drop next-word 2drop next-word 2drop next-word 2drop next-word compile-recurse
    else 2dup s" ret" str-eq? if 2drop $C3 emit-byte
    else 2dup s" syscall" str-eq? if 2drop $0F emit-byte $05 emit-byte
    else 2dup s" push" str-eq? if
       2drop next-word strip-comma is-reg if
         drop \ id
         dup 8 >= if 0 0 -1 emit-rex 8 - then
         $50 + emit-byte
       else
         \ Imm push? (68 imm32)
         parse-number
         $68 emit-byte emit-dword
       then
    else 2dup s" pop" str-eq? if
       2drop next-word strip-comma is-reg if
         drop
         dup 8 >= if 0 0 -1 emit-rex 8 - then
         $58 + emit-byte
       else 2drop then
    else 2dup s" mov" str-eq? if
       2drop
       next-word strip-comma is-reg if
         \ Dest is Reg
         >r >r \ save type, id
         next-word strip-comma is-reg if
           \ Reg, Reg
           r> r> drop
           \ Stack: src(id2) dst(id1)
           2dup
           8 >= swap 8 >= \ src dst b(dst) b(src)
           swap -1 emit-rex \ w=-1 r=src b=dst
           $89 emit-byte
           \ ModRM: 11 src dst
           swap 7 and 3 lshift swap 7 and or $C0 or emit-byte
         else
           \ Reg, Imm
           parse-number
           r> r> drop
           \ dst(id), val
           swap dup 8 >= -1 0 rot emit-rex
           7 and $B8 + emit-byte
           emit-qword
         then
       else
         2drop
       then
    else 2dup s" add" str-eq? if
       2drop
       next-word strip-comma is-reg if
         >r >r
         next-word strip-comma parse-number
         r> r> drop
         \ add reg, imm32 (81 /0)
         dup 8 >= -1 0 rot emit-rex
         $81 emit-byte
         7 and $C0 or emit-byte
         emit-dword
       else 2drop then
    else 2dup s" call" str-eq? if
       2drop next-word
       $E8 emit-byte
       code-ptr @ code-buffer @ - add-patch-full
       0 emit-dword
    else 2dup s" data" str-eq? if
       2drop next-word parse-data
    else
       \ Label definition? name:
       2dup + 1- c@ [char] : = if
         1- code-ptr @ code-buffer @ - add-label
       else
         2drop
       then
    then then then then then then then then then then then then then then
  repeat 2drop ;

: compile-file ( addr len -- )
  save-state >r >r >r
  slurp-file
  compile-loop
  source-ptr @ free throw
  r> r> r> restore-state ;

' compile-file is compile-recurse

: stub ( name-addr name-len -- )
  code-ptr @ code-buffer @ - add-label $C3 emit-byte ;

: emit-syscall-stub ( id -- )
  \ mov rax, id; syscall; ret
  $B8 emit-byte emit-dword
  $0F emit-byte $05 emit-byte
  $C3 emit-byte ;

: emit-mem-alloc ( -- )
  \ MorphLib_mem_alloc(size: rdi) -> ptr: rax
  \ Using sys_brk (12)
  \ 1. Get current brk
  $57 emit-byte \ push rdi (save size)
  $B8 emit-byte 12 emit-dword \ mov eax, 12
  $48 emit-byte $31 emit-byte $FF emit-byte \ xor rdi, rdi
  $0F emit-byte $05 emit-byte \ syscall -> rax = current_brk

  \ 2. Calculate new brk
  $5F emit-byte \ pop rdi (restore size)
  $48 emit-byte $89 emit-byte $C2 \ mov rdx, rax (save old_brk to rdx)
  $48 emit-byte $01 emit-byte $C7 \ add rdi, rax (new_brk = size + current)

  \ 3. Set new brk
  $B8 emit-byte 12 emit-dword \ mov eax, 12
  $0F emit-byte $05 emit-byte \ syscall (rdi has new_brk)

  \ 4. Return old brk (allocated ptr)
  $48 emit-byte $89 emit-byte $D0 \ mov rax, rdx
  $C3 emit-byte ;

: emit-print-newline ( -- )
  \ push 10 (\n)
  $6A emit-byte 10 emit-byte
  \ write(1, rsp, 1)
  $BF emit-byte 1 emit-dword \ mov edi, 1
  $48 emit-byte $89 emit-byte $E6 \ mov rsi, rsp
  $BA emit-byte 1 emit-dword \ mov edx, 1
  $B8 emit-byte 1 emit-dword \ mov eax, 1
  $0F emit-byte $05 emit-byte \ syscall
  \ pop
  $58 emit-byte \ pop rax
  $C3 emit-byte ;

: emit-print-decimal ( -- )
  \ Stub: just print '?' for now to avoid complex div logic in bootstrap
  $6A emit-byte 63 emit-byte \ push '?'
  $BF emit-byte 1 emit-dword
  $48 emit-byte $89 emit-byte $E6
  $BA emit-byte 1 emit-dword
  $B8 emit-byte 1 emit-dword
  $0F emit-byte $05 emit-byte
  $58 emit-byte
  $C3 emit-byte ;

: define-func ( name-addr name-len xt -- )
  \ Add label and execute generator
  -rot 2dup type cr
  code-ptr @ code-buffer @ - add-label
  execute ;

\ --- Bootstrap ---
: run-bootstrap
  emit-magic

  \ Jump to Start (Forward Reference)
  $E9 emit-byte \ JMP rel32
  s" Start" code-ptr @ code-buffer @ - add-patch-full \ Patch this later
  0 emit-dword

  \ Compile Tagged Entry
  s" src/main.fox" compile-recurse

  \ Generate Nano-Lib
  s" MorphLib_sys_write" code-ptr @ code-buffer @ - add-label 1 emit-syscall-stub
  s" MorphLib_sys_open"  code-ptr @ code-buffer @ - add-label 2 emit-syscall-stub
  s" MorphLib_sys_read"  code-ptr @ code-buffer @ - add-label 0 emit-syscall-stub
  s" MorphLib_sys_close" code-ptr @ code-buffer @ - add-label 3 emit-syscall-stub
  s" MorphLib_mem_alloc" code-ptr @ code-buffer @ - add-label emit-mem-alloc
  s" MorphLib_print_newline" code-ptr @ code-buffer @ - add-label emit-print-newline
  s" MorphLib_print_decimal" code-ptr @ code-buffer @ - add-label emit-print-decimal

  \ Stubs for others
  s" MorphLib_heap_init" stub
  s" MorphLib_sys_init_startup" stub
  s" MorphLib_daemon_init" stub
  s" _auto_init_intent_tree" stub
  s" MorphLib_routine_run_unit" stub
  s" Compiler_lexer_new" stub
  s" Compiler_lexer_next_token" stub

  resolve-patches-full

  s" output.morph" w/o create-file throw
  dup code-buffer @ code-ptr @ code-buffer @ - rot write-file throw
  close-file throw
  bye ;

run-bootstrap

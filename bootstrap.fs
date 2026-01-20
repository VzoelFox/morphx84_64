\ bootstrap.fs - A minimal Forth compiler for VZOELFOX

\ --- Memory ---
500000 constant MAX-CODE
variable code-buffer
variable code-ptr
MAX-CODE allocate throw code-buffer !
code-buffer @ code-ptr !

\ --- Utils ---
: emit-byte ( c -- ) code-ptr @ c! 1 code-ptr +! ;
: emit-word ( w -- ) dup emit-byte 8 rshift emit-byte ;
: emit-dword ( dw -- ) dup emit-word 16 rshift emit-word ;
: emit-qword ( qw -- ) dup emit-dword 32 rshift emit-dword ;

: str-eq? ( a1 l1 a2 l2 -- f ) compare 0= ;
: debug-print ( a l -- ) stderr write-file drop s"  " stderr write-line drop ;

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
  swap r@ move \ move file
  temp-path r> r> + ; \ full-addr full-len

: try-open ( addr len -- fd )
  \ Try relative to CWD
  2dup file-exists? if r/o open-file throw exit then
  \ Try src/ prefix
  s" src/" 2swap concat-path
  2dup file-exists? if r/o open-file throw exit then
  \ Fail
  s" Brainlib/" 2swap concat-path
  2dup debug-print \ Print failure path
  r/o open-file throw ;

: slurp-file ( addr len -- )
  2dup debug-print
  try-open >r
  r@ file-size throw drop
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
    dup cell+ @ swap \ offset, node
    dup 2 cells + @ swap \ len, node
    dup 3 cells + \ str-addr, node
    rot rot 2dup find-label if
       nip nip
       swap over swap - 4 -
       code-buffer @ + l!
    else
       2drop drop drop
    then
    @
  repeat drop ;

\ --- Encoder ---
: emit-rex ( w r b -- )
  0
  rot if 8 or then
  rot if 4 or then
  rot if 1 or then
  dup if $40 or emit-byte else drop then ;

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
    \ Directives
    2dup s" Ambil" str-eq? if
       2drop next-word 2drop \ compile-recurse
    else 2dup s" fungsi" str-eq? if
       2drop next-word
       code-ptr @ code-buffer @ - add-label
    else 2dup s" tutup_fungsi" str-eq? if 2drop
    else 2dup s" Unit:" str-eq? if 2drop next-word 2drop
    else 2dup s" Shard:" str-eq? if 2drop next-word 2drop
    else 2dup s" Fragment:" str-eq? if 2drop next-word 2drop next-word 2drop next-word 2drop next-word 2drop \ compile-recurse
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
           r> r>
           rot rot \ id2(src), id1(dst)
           2dup
           8 >= swap 8 >= rot \ dst>=8 src>=8
           -1 emit-rex
           $89 emit-byte
           \ ModRM: 11 src dst
           swap 7 and 3 lshift swap 7 and or $C0 or emit-byte
           drop drop
         else
           \ Reg, Imm
           parse-number
           r> r> drop
           \ dst(id), val
           swap dup 8 >= swap 0 -1 emit-rex
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
  save-state
  slurp-file
  compile-loop
  source-ptr @ free throw
  restore-state ;

' compile-file is compile-recurse

: stub ( name-addr name-len -- )
  code-ptr @ code-buffer @ - add-label $C3 emit-byte ;

\ --- Bootstrap ---
: run-bootstrap
  s" VZOELFOX" code-buffer @ swap move
  8 code-ptr +!

  \ Emit Exit (to prevent segfault on empty entry)
  $48 emit-byte $31 emit-byte $FF emit-byte \ xor rdi, rdi
  $B8 emit-byte 60 emit-dword \ mov eax, 60
  $0F emit-byte $05 emit-byte \ syscall

  \ Compile Tagged Entry
  s" src/tagger.fox"
  r/o open-file throw
  dup file-size throw drop source-len !
  source-len @ allocate throw source-ptr !
  source-ptr @ source-len @ rot dup >r read-file throw drop
  r> close-file throw
  0 current-offset !
  compile-loop
  source-ptr @ free throw

  \ Generate Stubs
  s" MorphLib_heap_init" stub
  s" MorphLib_sys_init_startup" stub
  s" MorphLib_daemon_init" stub
  s" _auto_init_intent_tree" stub
  s" MorphLib_routine_run_unit" stub
  s" MorphLib_sys_write" stub
  s" MorphLib_mem_alloc" stub
  s" MorphLib_sys_open" stub
  s" MorphLib_sys_read" stub
  s" MorphLib_sys_close" stub
  s" MorphLib_print_decimal" stub
  s" MorphLib_print_newline" stub
  s" Compiler_lexer_new" stub
  s" Compiler_lexer_next_token" stub

  resolve-patches-full

  s" output.morph" w/o create-file throw
  dup code-buffer @ code-ptr @ code-buffer @ - rot write-file throw
  close-file throw
  bye ;

run-bootstrap

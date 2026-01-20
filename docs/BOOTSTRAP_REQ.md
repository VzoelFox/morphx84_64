# Bootstrap Compiler (Stage 2) Requirements

To successfully compile the self-hosted compiler in `src/`, the `boot_compiler.v1` (written in `asm_v1`) must support the following features:

## 1. Directives
- **Ambil <file>**: Module import. Must support recursive parsing (e.g., `src/tagger.fox` imports `lexer.fox`).
- **Unit: <Name>**: Namespace definition. All labels and functions must be prefixed with `Name_`.
- **Shard: <Name>** & **Fragment: <Name>**: IntentTree definitions. These map to label metadata.
- **data "string"**: String constants with escape sequence support (\n, \0).

## 2. Structure & Control Flow
- **fungsi <Name> ... tutup_fungsi**: Function definition. Maps to global labels.
- **loop <label> ... tutup_loop**: Infinite loop with manual break? Or conditional?
  - `src/main.fox` uses `loop strlen_loop`. This looks like a named loop block.
- **jika_sama**, **jika_beda**, **jika_kurang**, **jika_lebih_sama**, **lainnya**:
  - These map to `je`, `jne`, `jl`, `jge`, `else`.
  - Must support nesting.

## 3. Instructions
- Standard x64: `mov`, `push`, `pop`, `add`, `sub`, `inc`, `dec`, `cmp`, `call`, `ret`, `syscall`.
- **movzx**: Zero-extend move (used in `strlen_loop`).
- **lea**: Load effective address.
- **henti**: Break loop (jump to end of current loop).

## 4. Operand Types
- Registers: `rax`..`r15`.
- Immediates: Numbers (decimal/hex), Labels (`Compiler_MSG_BANNER`).
- Memory: `[reg]`, `[reg+offset]`.

## 5. Metadata/Linking
- **Label Resolution**: Must resolve cross-file references (e.g., `Compiler_lexer_new` defined in `lexer.fox` called from `main.fox`).
- **Entry Point**: The compiler must generate an ELF header that jumps to the `Start` fragment of the `Init` shard.

## 6. Simplifications for Bootstrap
- **No Optimization**: The bootstrap compiler should be a "dumb" translator (1-to-1 mapping).
- **Static Buffer**: Use a large static buffer for the output binary instead of complex dynamic allocation.
- **Single Pass (with Backpatching)**: Read all source files into memory, then parse and emit code.

## 7. Roadmap
1. Implement `boot_compiler.v1` in `asm_v1`.
2. `boot_compiler.v1` compiles `src/bootstrap.fox`.
3. Resulting binary `morph_compiler` compiles `src/` again (Self-Host Verification).

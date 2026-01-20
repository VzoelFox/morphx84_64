# Codegen - Backend Compiler Architecture

## Overview

Codegen adalah **backend compiler** untuk morphx84_64 yang mentransformasi AST (dari Parser) menjadi **VZOELFOX binary executable** dengan **IntentTree runtime structure**.

## Architecture

```
AST (from Parser)
      ↓
[Trickster Pass] → Optimization & Lowering
      ↓
[Artifact Generator] → Binary Generation
      ↓
[Emitter] → Machine Code (x86-64)
      ↓
[IntentTree Builder] → Runtime Structure
      ↓
VZOELFOX Binary
```

---

## Components

### 1. **Trickster Pass** (`trickster.fox`)

**Purpose:** Optimize dan lower AST sebelum code generation

**Passes:**
- **Constant Folding:** `mov rax, 10; add rax, 5` → `mov rax, 15`
- **Dead Code Elimination:** Remove unreachable code after `ret`
- **Instruction Lowering:** Pseudo-instructions → native x86-64

**Entry Point:**
```fox
fungsi trickster_optimize
    ; Input: rdi (AST root)
    ; Output: rax (optimized AST)
```

---

### 2. **Artifact Generator** (`artifact.fox`)

**Purpose:** Generate complete VZOELFOX binary dari AST

**Process:**
1. Build symbol table (functions, labels, consts)
2. Emit machine code via Emitter
3. Build IntentTree structure
4. Write binary header & sections

**Binary Format (VZOELFOX):**
```
[0-7]    Magic: "VZOELFOX"
[8-15]   Version: 1
[16-23]  Code Size
[24-31]  Data Size
[32-39]  IntentTree Offset
[40-47]  Entry Point Offset
[48+]    Code Section
[...]    Data Section
[...]    IntentTree Section
[...]    Symbol Table
```

**Entry Point:**
```fox
fungsi artifact_generate
    ; Input: rdi (AST root)
    ; Output: rax (binary buffer), rdx (binary size)
```

---

### 3. **Machine Code Emitter** (`emitter.fox`)

**Purpose:** Encode x86-64 instructions dari AST instruction nodes

**Features:**
- REX prefix encoding (64-bit operands)
- ModR/M byte encoding (register addressing)
- Immediate value encoding
- Displacement encoding
- Register name → ID mapping

**Key Functions:**
```fox
fungsi emitter_emit_instruction
    ; Input: rdi (Emitter), rsi (AstInstruction)
    ; Output: rax (bytes written)

fungsi emitter_encode_rex
    ; Input: rdi (Emitter), rsi (REX flags)

fungsi emitter_encode_modrm
    ; Input: rdi (Emitter), rsi (mod), rdx (reg), rcx (rm)
```

**Register Encoding:**
```
rax=0, rcx=1, rdx=2, rbx=3
rsp=4, rbp=5, rsi=6, rdi=7
r8=8, r9=9, r10=10, r11=11
r12=12, r13=13, r14=14, r15=15
```

---

### 4. **IntentTree Builder** (`intenttree.fox`)

**Purpose:** Build IntentTree runtime structure dari AST hierarchy

**Structure:**
```
Unit (Module/Namespace)
  ├── ID (8 bytes)
  ├── FirstShard* (8 bytes)
  └── Status (8 bytes)
      │
      └── Shard (Organizational Grouping)
            ├── ID (8 bytes)
            ├── NextShard* (8 bytes)
            ├── FirstFragment* (8 bytes)
            └── Status (8 bytes)
                │
                └── Fragment (Executable Code)
                      ├── FuncPtr (8 bytes) → Machine code
                      ├── NextFragment* (8 bytes)
                      ├── Status (8 bytes)
                      └── Context* (8 bytes)
```

**Entry Point:**
```fox
fungsi intenttree_build
    ; Input: rdi (AST root - Unit)
    ; Output: rax (IntentTree Unit*)
```

---

## Usage

### Compile Pipeline:

```fox
; 1. Parse source to AST
mov rdi, filename
call Compiler_lexer_new
mov rdi, rax
call Compiler_parser_new
mov rdi, rax
call Compiler_parser_parse
mov r12, rax ; AST root

; 2. Optimize AST
mov rdi, r12
call Codegen_trickster_optimize
mov r12, rax

; 3. Generate binary
mov rdi, r12
call Codegen_artifact_generate
; rax = binary buffer
; rdx = binary size

; 4. Write to file
mov rdi, output_filename
mov rsi, rax
mov rdx, rdx
call write_binary_file
```

---

## Implementation Status

### ✅ **DONE:**
- Architecture design
- Stub implementations for all components
- Structure definitions
- Function signatures
- Documentation

### ⚠️ **TODO:**
- [ ] Implement Trickster passes (constant folding, DCE, lowering)
- [ ] Implement Emitter ISA lookup (integrate Brainlib)
- [ ] Implement Emitter instruction encoding (REX, ModR/M, immediates)
- [ ] Implement Artifact symbol table builder
- [ ] Implement Artifact code traversal and emission
- [ ] Implement IntentTree function pointer resolution
- [ ] Write comprehensive tests
- [ ] Integrate with self-host compiler pipeline

---

## Dependencies

**Compiler Frontend:**
- `src/parser.fox` - Provides AST
- `src/token.fox` - Token definitions
- `src/lexer.fox` - Tokenization

**Standard Library:**
- `morphlib/alloc.fox` - Memory allocation
- `morphlib/sys.fox` - System calls
- `morphlib/morphroutine.fox` - IntentTree runtime

**ISA Specification:**
- `Brainlib/*.vzoel` - x86-64 instruction definitions

---

## Testing

### Test Files (to be created):
```
tests/codegen/
├── test_trickster.fox      # Test optimization passes
├── test_emitter.fox         # Test machine code emission
├── test_artifact.fox        # Test binary generation
└── test_intenttree.fox      # Test IntentTree building
```

### Test Strategy:
1. **Unit tests:** Test individual functions in isolation
2. **Integration tests:** Test full pipeline (AST → binary)
3. **Validation tests:** Verify generated binaries execute correctly

---

## Notes

### Zero Dependencies Philosophy
- No external libraries
- Direct syscalls only
- Pure x86-64 machine code generation
- Self-contained implementation

### Alignment with IntentTree Vision
This codegen architecture follows the **morph_IntentTree.png** diagram:
- **Compile Time:** Parser → IntentAST → Trickster → Artifact
- **Run Time:** IntentTree (Unit/Shard/Fragment) → Deterministic Execution

### Future Enhancements
- [ ] Multi-pass optimization
- [ ] Register allocation optimization
- [ ] Peephole optimization
- [ ] Link-time optimization
- [ ] Debug symbol generation
- [ ] Profiling hooks

---

**Author:** morphx84_64 team
**License:** MIT
**Version:** 0.1 (Bootstrap Stage)

# Compiler Source Code (Fox Self-Hosting)

This directory contains the source code for the Fox Compiler, written in the Fox language itself.
This is the "Stage 1" self-hosting effort.

## Structure

*   `bootstrap.fox`: The entry point for the bootstrap process. It imports the current directory as a module (`Ambil .`) and defines a dummy `main` to satisfy the linker.
*   `tagger.fox`: The Module Definition. It defines the `Unit: Compiler` and the IntentTree (`Shard: Init`, `Fragment: Start`) that launches the compiler.
*   `lexer.fox`: The Lexical Analyzer. Reads source files and produces tokens.
*   `token.fox`: Token definitions and constants.
*   `main.fox`: The main application logic (`Compiler_Start`). It initializes the Lexer and runs the main loop.

## Building & Running

Use the `test_compiler.sh` script in the root directory to compile and run this compiler using the bootstrap compiler (`core/parser.sh`).

```bash
./test_compiler.sh
```

## Roadmap

1.  **Lexer:** Enhance to support full Fox syntax.
2.  **Parser:** Implement AST construction (IntentTree as Data).
3.  **Codegen:** Generate IR or target WASM/ELF directly.

# Morph Language - GitHub Linguist Submission

This document explains how to add Morph language to GitHub Linguist for official recognition.

## Language Overview

- **Name:** Morph
- **Type:** Programming Language (Assembly-based)
- **Color:** `#FF69B4` (Hot Pink) 🩷
- **Extensions:** `.elsa`, `.fox`, `.vzoel`, `.fall`
- **Syntax:** Indonesian + x86-64 Assembly
- **Repository:** https://github.com/VzoelFox/morphx84_64

## Current Status

✅ **Local Configuration Complete:**
- `.gitattributes` - Marks Morph files for GitHub
- `.github/languages.yml` - Language definition reference

⏳ **Pending Official Linguist Recognition:**
- Requires PR to: https://github.com/github/linguist

## File Extensions

| Extension | Purpose | Example |
|-----------|---------|---------|
| `.elsa` | Enhanced Language Syntax Assembly | `compiler.elsa` |
| `.fox` | Functional Object eXtensions (main) | `parser.fox`, `lexer.fox` |
| `.vzoel` | VzoelFox Embedded Language (ISA defs) | `aritmatika.vzoel` |
| `.fall` | Functional Assembly Low Level | `runtime.fall` |

## How to Submit to GitHub Linguist

### Prerequisites
1. Fork https://github.com/github/linguist
2. Clone your fork locally

### Steps

#### 1. Add Language Definition

Edit `lib/linguist/languages.yml` and add:

```yaml
Morph:
  type: programming
  color: "#FF69B4"
  extensions:
  - ".elsa"
  - ".fox"
  - ".vzoel"
  - ".fall"
  interpreters:
  - morph
  language_id: 987654321
  tm_scope: source.morph
  ace_mode: assembly_x86
```

#### 2. Add Sample Files

Create `samples/Morph/` directory with examples:
- `hello.fox` - Simple hello world
- `parser.fox` - Parser implementation sample
- `fibonacci.fox` - Algorithm example

#### 3. Run Tests

```bash
bundle install
bundle exec rake samples
bundle exec rake test
```

#### 4. Create Pull Request

Title: `Add Morph programming language`

Description:
```
This PR adds support for Morph, a self-hosting low-level programming
language with Indonesian syntax.

- Extensions: .elsa, .fox, .vzoel, .fall
- Color: Hot Pink (#FF69B4)
- Type: Programming (Assembly-based)
- Repository: https://github.com/VzoelFox/morphx84_64

Morph is a production-ready compiler with 3700+ lines of code,
supporting self-hosting compilation and IntentTree runtime.
```

## Temporary Solution (Until Official Support)

The `.gitattributes` file in this repo will force GitHub to recognize
Morph files in THIS repository. However, other repos and GitHub's
language statistics won't show Morph until it's officially added.

## Sample Code

### Hello World (hello.fox)

```fox
fungsi Start
    ; Print "Hello, World!\n"
    mov rdi, 1              ; stdout
    mov rsi, MSG_HELLO      ; message pointer
    mov rdx, 14             ; message length
    call MorphLib_sys_write

    ; Exit
    mov rax, 60
    mov rdi, 0
    syscall
tutup_fungsi

MSG_HELLO:
    data "Hello, World!\n\0"
```

### Fibonacci (fibonacci.fox)

```fox
fungsi fibonacci
    ; Input: rdi (n)
    ; Output: rax (fib(n))

    cmp rdi, 2
    jika_kurang
        mov rax, rdi
        ret
    tutup_jika

    push rdi
    dec rdi
    call fibonacci
    pop rdi

    push rax
    sub rdi, 2
    call fibonacci
    pop rbx

    add rax, rbx
    ret
tutup_fungsi
```

## Verification

After PR is merged (typically 1-2 weeks), verify:

1. Check language statistics on GitHub
2. View syntax highlighting on `.fox` files
3. Language badge will show pink color

## References

- Linguist Contribution Guide: https://github.com/github/linguist/blob/master/CONTRIBUTING.md
- Language YAML Spec: https://github.com/github/linguist/blob/master/lib/linguist/languages.yml
- Color Palette: https://github.com/github/linguist/blob/master/lib/linguist/colors.yml

## Contact

For questions about Morph language:
- Repository: https://github.com/VzoelFox/morphx84_64
- Issues: https://github.com/VzoelFox/morphx84_64/issues

---

**Status:** 🟡 Awaiting Linguist submission
**Last Updated:** 2026-01-20

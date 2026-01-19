# Laporan Audit & Analisis Kesenjangan (Gap Analysis)

**Tanggal:** 25 Oktober 2023
**Auditor:** Jules (AI Agent)
**Referensi:** `spec/morph_IntentTree.png`, `core/parser.sh`, `morphlib/morphroutine.fox`

## 1. Status Saat Ini (Current State)

### Kompilator (`core/parser.sh`)
*   **Arsitektur:** *Direct-to-Assembly* (Langsung ke Kode Mesin/Assembly).
*   **Alur Kerja:** Membaca file `.fox` baris per baris, menyelesaikan macro/label, dan langsung menulis instruksi mesin (hex) ke file binary `.morph`.
*   **Penanganan IntentTree:**
    *   Directive `Unit`, `Shard`, dan `Fragment` di dalam `tagger.fox` diparsing secara *ad-hoc*.
    *   Parser secara otomatis membangkitkan fungsi `_auto_init_intent_tree` yang berisi instruksi assembly (`mov`, `call`) untuk membangun struktur tree di heap saat *runtime*.
    *   **Tidak ada AST (Abstract Syntax Tree)** yang terbentuk di memori selama kompilasi. Struktur hanya ada sebagai urutan instruksi inisialisasi.

### Runtime (`morphlib/morphroutine.fox`)
*   **Model Eksekusi:** *Native Execution*.
*   **Mekanisme:** Runtime menelusuri Linked List dari Unit -> Shard -> Fragment.
*   **Eksekusi Fragment:** Menggunakan instruksi `call rax` (Indirect Call) di mana `rax` adalah pointer ke kode mesin native di memori.
*   **Kesesuaian:** Mendukung hierarki Unit/Shard/Fragment, namun mengharapkan *native machine code*, bukan bytecode.

## 2. Analisis Kesenjangan (Gap Analysis) vs `spec/morph_IntentTree.png`

| Komponen | Spesifikasi (Target) | Implementasi Saat Ini | Status |
| :--- | :--- | :--- | :--- |
| **Parser** | Menghasilkan **IntentAST** (Immutable Static Plan). | Menghasilkan instruksi assembly untuk inisialisasi runtime. | 🔴 Gap Besar |
| **Data Structure** | **AST + Token**. | Shell Variables & Arrays (Ad-hoc). | 🔴 Belum Ada |
| **Optimization** | **Trickster Pass** (Lowering/Optimization). | Tidak ada. Optimasi hanya terjadi manual di level kode sumber. | 🔴 Belum Ada |
| **Output** | **Artifact** (IR / Bytecode / Neutral). | Linux ELF Binary (x86_64 Machine Code). | 🔴 Gap Besar |
| **Runtime** | **VM + Scheduler** (Menginterpretasi Artifact). | **Scheduler Native** (Menjalankan Pointer Fungsi). | 🟡 Partial (Scheduler ada, VM tidak ada) |

## 3. Pertanyaan Kunci untuk Diskusi

Untuk melanjutkan ke tahap "Persiapan IntentTree sebagai AST+Token", kita perlu mendefinisikan arah teknis:

1.  **Definisi "Neutral Codegen":**
    *   Apakah kita menargetkan **Bytecode** (seperti Java/WASM) yang membutuhkan *Virtual Machine* (Interpreter Loop) di runtime?
    *   Atau apakah kita menargetkan **Intermediate Representation (IR)** yang netral secara platform, namun tetap dikompilasi menjadi **Native Code** sebelum dijalankan?
    *   *Catatan:* Jika kita memilih Bytecode, `morphroutine.fox` harus dirombak total untuk memuat Interpreter, bukan sekadar `call rax`.

2.  **Strategi Refactoring Parser:**
    *   `core/parser.sh` saat ini mencampur logika parsing, linking, dan encoding.
    *   Disarankan memecah menjadi: `lexer` (Tokenisasi) -> `parser` (AST Builder) -> `codegen` (Artifact Generator).

3.  **Format Artifact:**
    *   Apakah format file netral ini berbasis Teks (JSON/YAML/S-Expression) atau Biner Khusus?

## 4. Kesimpulan

Secara kode, repositori **stabil**. Namun secara arsitektur, kita **belum siap** untuk langsung mengimplementasikan AST tanpa merombak `core/parser.sh`.

**Rekomendasi Langkah Awal:**
1.  Mendefinisikan struktur data AST (bisa menggunakan Struct di Bash atau JSON).
2.  Memisahkan tahap Tokenisasi dari tahap Code Generation di `parser.sh`.

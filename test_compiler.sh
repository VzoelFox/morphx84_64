#!/bin/bash
echo "Compiling Compiler (Self-Hosting Phase 1)..."
bash core/parser.sh src/bootstrap.fox

if [ $? -ne 0 ]; then
    echo "Compilation Failed!"
    exit 1
fi

echo "Running Compiler..."
bash core/morph_run.sh output.morph

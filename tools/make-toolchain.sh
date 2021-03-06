#!/usr/bin/env bash

source ./detect.include

cd ..
$COMPILER assembler/qasm.c -o assembler/qasm
$COMPILER assembler/qasm2rom.c -o assembler/qasm2rom -std=c99

cd emulator
./make.bash

cd ../c
source setenv.source
./make-vasm.sh
./make-vlink.sh
./make-vbcc.sh
$COMPILER qnice/qniceconv.c -o qnice/qniceconv

echo "QNICE: Toolchain successfully made, if you do not see any error messages above."
echo "(Outputs like \"mkdir: config: File exists\" are OK.)"

#!/bin/bash
# ping.sh - Executa o comando ping para testar a conectividade

TARGET="$1"

if [ -z "$TARGET" ]; then
    echo "ERROR: Target is required"
    exit 1
fi

# Basic sanitization to prevent command injection
if [[ ! "$TARGET" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "ERROR: Invalid target format"
    exit 1
fi

echo "Pinging $TARGET..."
ping -c 4 "$TARGET"

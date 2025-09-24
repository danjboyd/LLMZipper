#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
sed -e "s|Exec=./llmzip.pl|Exec=$DIR/llmzip.pl|" \
    -e "s|Icon=./icon.png|Icon=$DIR/icon.png|" \
    "$DIR/llmzip.desktop.in" > "$DIR/llmzip.desktop"


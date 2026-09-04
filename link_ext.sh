#!/bin/sh
set -e
EXT_DIR="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
SRC="$(cd "$(dirname "$0")" && pwd)/Fidelity.lua"
DST="$EXT_DIR/Fidelity.lua"
ls -li "$DST" "$SRC" 2>/dev/null || true
rm -f "$DST"
ln "$SRC" "$DST"
ls -li "$DST" "$SRC"


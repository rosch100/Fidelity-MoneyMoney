#!/usr/bin/env python3
"""Conformance checks for this MoneyMoney Lua extension."""
from __future__ import annotations
import pathlib
import re
import sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)
def file_contains(path: pathlib.Path, pattern: str) -> bool:
    text = path.read_text(encoding="utf-8", errors="replace")
    return re.search(pattern, text, flags=re.M | re.S) is not None
def main() -> None:
    lua_files = sorted(ROOT.glob("*.lua"))
    assert_true(len(lua_files) >= 1, f"Keine .lua im Repo-Root: {ROOT}")
    for lua_path in lua_files:
        raw = lua_path.read_bytes()
        assert_true(not raw.startswith(b"\xef\xbb\xbf"), f"{lua_path}: UTF-8 BOM verboten")
        assert_true(file_contains(lua_path, r"\bWebBanking\s*\{"), f"{lua_path}: fehlendes WebBanking{{...}}")
        assert_true(file_contains(lua_path, r"\bfunction\s+SupportsBank\s*\("), f"{lua_path}: missing SupportsBank")
        has_init = file_contains(lua_path, r"\bfunction\s+InitializeSession\s*\(")
        has_init2 = file_contains(lua_path, r"\bfunction\s+InitializeSession2\s*\(")
        assert_true(has_init or has_init2, f"{lua_path}: missing InitializeSession/InitializeSession2")
    print("CONFORMANCE OK")
if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)


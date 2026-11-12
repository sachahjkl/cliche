#!/usr/bin/env bash
# Shortcut: ./build.sh [debug|release] is clichetool build.
# Every other step: odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -- <command> (help lists them).
cd "$(dirname "$0")" && mkdir -p build && exec odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -keep-executable -- build "$@"

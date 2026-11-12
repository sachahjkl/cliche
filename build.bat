@echo off
rem Shortcut: build.bat [debug|release] is clichetool build.
rem Every other step: odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -- <command> (help lists them).
cd /d "%~dp0"
if not exist build mkdir build
odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -keep-executable -- build %*

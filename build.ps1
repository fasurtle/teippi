# build.ps1 - teippi MPQDraft plugin build script
# Usage: run .\build.ps1 in the teippi directory
#
# Output: build_release\teippi.qdp
# Requires: MSYS2 + mingw-w64-i686-gcc (32-bit MinGW32)
#
# See BUILD.md for detailed explanation of each build decision.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Configuration ─────────────────────────────────────────────────────────────

# MSYS2 installation path (change if different)
$Msys2Root = "F:\Program Files\msys64"

$Gxx      = "$Msys2Root\mingw32\bin\g++.exe"
$Dlltool  = "$Msys2Root\mingw32\bin\dlltool.exe"
$Objdump  = "$Msys2Root\mingw32\bin\objdump.exe"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir    = Join-Path $ScriptDir "src"
$OutDir    = Join-Path $ScriptDir "build_release"
$OutDll    = Join-Path $OutDir "teippi.qdp"
$DefFile   = Join-Path $ScriptDir "dlltool.def"
$ExportsObj= Join-Path $OutDir "exports.o"

# ── Preflight checks ──────────────────────────────────────────────────────────

Write-Host "=== teippi build ===" -ForegroundColor Cyan

if (-not (Test-Path $Gxx)) {
    Write-Error ("MinGW32 g++ not found: $Gxx`n`n" +
        "Install i686 GCC in MSYS2 first:`n" +
        "  $Msys2Root\usr\bin\pacman.exe -S mingw-w64-i686-gcc --noconfirm`n`n" +
        "Must use mingw32 (32-bit). Do NOT use ucrt64 or mingw64.")
}

if (-not (Test-Path $Dlltool)) {
    Write-Error "dlltool not found: $Dlltool (should be installed with mingw-w64-i686-gcc)"
}

# MinGW32 requires MSYSTEM=MINGW32 and its bin directory first in PATH.
# Without this, g++ cannot find its own sysroot (libstdc++, crt, etc.)
$env:MSYSTEM = "MINGW32"
$mingw32Bin  = "$Msys2Root\mingw32\bin"
if ($env:PATH -notlike "*$mingw32Bin*") {
    $env:PATH = "$mingw32Bin;$env:PATH"
}

$gxxVer = & $Gxx --version 2>&1 | Select-Object -First 1
Write-Host "Compiler : $Gxx"
Write-Host "Version  : $gxxVer"
Write-Host ""

# ── Prepare output directory ──────────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ── Collect source files ──────────────────────────────────────────────────────
# Release build excludes: console/ scconsole.cpp test_game.cpp
# These are only needed for Debug (console UI / Scroll Lock key support).

$ExcludePattern = "console[/\\]|scconsole\.cpp|test_game\.cpp"

$Sources = Get-ChildItem -Path $SrcDir -Filter "*.cpp" -Recurse |
    Where-Object { $_.FullName -notmatch $ExcludePattern } |
    ForEach-Object { $_.FullName.Substring($SrcDir.Length + 1) }

Write-Host "Found $($Sources.Count) source files" -ForegroundColor Yellow

# ── Compiler flags ────────────────────────────────────────────────────────────
#
# -m32 -march=i686       32-bit x86 output (StarCraft 1.16.1 is a 32-bit process)
# -O2                    Optimize (Release build)
# -std=c++14             teippi uses C++14 features
# -DNOMINMAX             Prevent Windows.h min/max macro pollution
# -include gcc13_compat.h  Adds missing standard includes that GCC 13 no longer
#                          pulls in transitively (<string>, <cstdio>, <stdexcept>)
#
# IMPORTANT: compile from INSIDE src/ directory, do NOT use -I src
# Reason: MinGW32 GCC's internal header chain (limits.h -> syslimits.h) uses
# #include_next which does NOT distinguish <> from "". With -I src, #include_next
# finds teippi's src/limits.h instead of the system <limits.h>, causing a
# circular include error. Compiling from src/ avoids this entirely.

$CxxFlags = @(
    "-m32", "-march=i686",
    "-O2",
    "-std=c++14",
    "-DNOMINMAX",
    "-include", "gcc13_compat.h"
)

# ── Compile each source file ──────────────────────────────────────────────────

$ObjFiles  = [System.Collections.Generic.List[string]]::new()
$FailCount = 0

Push-Location $SrcDir
try {
    foreach ($src in $Sources) {
        $objName = $src -replace "[/\\]", "_" -replace "\.cpp$", ".o"
        $objPath = Join-Path $OutDir $objName

        $result = & $Gxx @CxxFlags -c $src -o $objPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAILED: $src" -ForegroundColor Red
            $result | Where-Object { $_ -match "error:" } | Select-Object -First 3 |
                ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $FailCount++
        } else {
            Write-Host "  OK: $src" -ForegroundColor Green
            $ObjFiles.Add($objPath)
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
if ($FailCount -gt 0) {
    Write-Error "$FailCount file(s) failed to compile. Aborting link."
}
Write-Host "Compiled: $($ObjFiles.Count) object files" -ForegroundColor Yellow

# ── Generate export stub (dlltool) ────────────────────────────────────────────
#
# Must use dlltool, NOT --export-all-symbols.
#
# --export-all-symbols exports stdcall functions as "GetMPQDraftPlugin@4"
# (with the @4 suffix). MPQDraft calls GetProcAddress("GetMPQDraftPlugin")
# without the @4, so the plugin is never found.
#
# dlltool.def maps the clean export name -> internal decorated symbol:
#   GetMPQDraftPlugin = GetMPQDraftPlugin@4
# so the DLL export table contains "GetMPQDraftPlugin" (no @4).

Write-Host "Generating export stub..." -ForegroundColor Yellow
$dtResult = & $Dlltool -d $DefFile -e $ExportsObj 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "dlltool failed: $dtResult"
}
$ObjFiles.Add($ExportsObj)

# ── Link DLL ──────────────────────────────────────────────────────────────────
#
# -shared    Produce a DLL
# -static    Statically link libstdc++, libgcc, libwinpthread into the DLL.
#            Target machines running StarCraft do NOT have MinGW runtime DLLs.
#            Without -static, LoadLibrary fails because libgcc_s_dw2-1.dll
#            and libwinpthread-1.dll are missing.
#            Final dependencies: only KERNEL32.dll, msvcrt.dll, USER32.dll
#            (all built into Windows).
#
# System libs are still dynamically linked (-lgdi32 etc.) because they are
# guaranteed to exist on any Windows installation.

Write-Host "Linking..." -ForegroundColor Yellow

$LinkArgs = @($ObjFiles) + @(
    "-shared",
    "-static",
    "-lgdi32", "-luser32", "-lkernel32", "-lwinmm",
    "-o", $OutDll
)

$linkResult = & $Gxx -m32 @LinkArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Link failed: $linkResult"
}

# ── Verify output ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Verify output ===" -ForegroundColor Cyan

$dllInfo = Get-Item $OutDll
$sizeMb  = [math]::Round($dllInfo.Length / 1MB, 1)
Write-Host "Output : $OutDll ($sizeMb MB)"

$arch = & $Objdump -f $OutDll 2>&1 | Select-String "architecture"
Write-Host "Arch   : $arch"

Write-Host "Exports:"
& $Objdump -p $OutDll 2>&1 |
    Select-String "GetMPQDraftPlugin|ApplyPatch|GetPluginAPI|Initialize|Metaplugin|GetData" |
    Where-Object { $_ -notmatch "InitializeCritical|_ZN" } |
    ForEach-Object { Write-Host "  $_" -ForegroundColor Green }

Write-Host "DLL deps:"
$deps = & $Objdump -p $OutDll 2>&1 | Select-String "DLL Name"
$deps | ForEach-Object {
    $line = $_.ToString()
    if ($line -match "libgcc|libstdc|libwinpthread") {
        Write-Host "  $line  <-- WARNING: MinGW runtime dependency!" -ForegroundColor Red
    } else {
        Write-Host "  $line" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Cyan
Write-Host "Copy build_release\teippi.qdp to MPQDraft plugins directory or StarCraft game directory."
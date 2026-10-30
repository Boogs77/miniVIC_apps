# build.ps1 - assembles the miniVIC applications with vasm6502
#
#   .\build.ps1                 all the apps\*.asm files
#   .\build.ps1 write           only the apps given (name without .asm)
#   .\build.ps1 -Test           then runs tools\<app>.test.ts in the emulator core, if it exists
#
# The path of vasm6502_oldstyle.exe is read from the VASM variable or from the first line
# of the file vasm.path (not in git). Output: bin\<app>.bin (loaded at $0FD0, started at
# $1000) and bin\<app>.lst (listing with the symbol table, used by the tests).

param([switch]$Test, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Apps)

Set-Location $PSScriptRoot

$vasm = $env:VASM
if (-not $vasm -and (Test-Path vasm.path)) { $vasm = (Get-Content vasm.path -TotalCount 1).Trim() }
if (-not $vasm -or -not (Test-Path $vasm)) {
  Write-Host "vasm6502_oldstyle not found: write its path in the file vasm.path" -ForegroundColor Red
  exit 1
}

if (-not $Apps) { $Apps = (Get-ChildItem apps\*.asm).BaseName }
New-Item -ItemType Directory -Force bin | Out-Null

$failed = @()
foreach ($a in $Apps) {
  Write-Host "== apps\$a.asm -> bin\$a.bin" -ForegroundColor Cyan
  & $vasm -Fbin -dotdir -c02 -quiet -L "bin\$a.lst" -o "bin\$a.bin" "apps\$a.asm"
  if ($LASTEXITCODE -ne 0) { $failed += $a; continue }
  $size = (Get-Item "bin\$a.bin").Length
  $end = 0x0FD0 + $size
  Write-Host ("   {0} bytes, `$0FD0-`${1:X4}" -f $size, ($end - 1))
  if ($end -gt 0x8000) { Write-Host "   past the end of the RAM!" -ForegroundColor Red; $failed += $a }
}
if ($failed) {
  Write-Host "ERRORS in: $($failed -join ', ')" -ForegroundColor Red
  exit 1
}

if ($Test) {
  foreach ($a in $Apps) {
    if (Test-Path "tools\$a.test.ts") {
      Write-Host "== test $a" -ForegroundColor Cyan
      node tools\run_test.mjs $a
      if ($LASTEXITCODE -ne 0) { $failed += $a }
    }
  }
  if ($failed) { Write-Host "TESTS FAILED: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
}
Write-Host "Done" -ForegroundColor Green

#Requires -Version 5.1
<#
.SYNOPSIS
  Install the locally built Weasel into this machine.

.DESCRIPTION
  Hosts load the TSF DLLs from %SystemRoot%, not the copies kept in the
  install directory, so a build only takes effect once those are replaced:

    output\weaselx64.dll     ->  %SystemRoot%\System32\weasel.dll   (64-bit hosts)
    output\weasel.dll        ->  %SystemRoot%\SysWOW64\weasel.dll   (32-bit hosts)
    output\WeaselServer.exe  ->  <install dir>\WeaselServer.exe

  A DLL that a running process has mapped cannot be overwritten, so the old
  file is renamed to weasel.dll.old-<timestamp> first and the new one copied
  into place. Restart the host application (game, browser, ...) to load it.

  Writing under %SystemRoot% needs an elevated shell:

    Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
      '-NoProfile', '-File', "$PWD\install-local.ps1")

  Keep this file ASCII-only on purpose: Windows PowerShell 5.1 reads a
  BOM-less script using the ANSI code page, so non-ASCII text breaks parsing.

.PARAMETER CleanBackups
  Also delete the weasel.dll.* backups in System32/SysWOW64, including those
  left by earlier runs. Backups still mapped by a running process cannot be
  deleted; they are listed so they can be removed after a logoff.

.PARAMETER Force
  Copy even when the installed file already matches the build output.

.PARAMETER OutputDir
  Build output directory, <repo>\output by default.

.PARAMETER InstallDir
  Install directory holding WeaselServer.exe. Default: the WeaselRoot value
  the installer writes to the registry.

.EXAMPLE
  .\install-local.ps1 -CleanBackups
#>
[CmdletBinding()]
param(
  [string]$OutputDir,
  [string]$InstallDir,
  [switch]$CleanBackups,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
# a 32-bit shell gets System32 redirected to SysWOW64, which would put the
# 64-bit DLL where the 32-bit one belongs
if (-not [Environment]::Is64BitProcess) {
  throw 'Run this from 64-bit PowerShell.'
}
# $PSScriptRoot is still empty while the param block is bound (Windows
# PowerShell 5.1), so the default output directory is resolved here.
if (-not $OutputDir) {
  $OutputDir = Join-Path $PSScriptRoot 'output'
}

$logPath = Join-Path $env:TEMP 'weasel-install-local.log'
Start-Transcript -Path $logPath -Force | Out-Null
"log: $logPath"

function Get-WeaselInstallDir {
  if ($InstallDir) { return $InstallDir }
  foreach ($key in 'HKLM:\SOFTWARE\Rime\Weasel',
                   'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel') {
    $root = (Get-ItemProperty -LiteralPath $key -Name WeaselRoot `
              -ErrorAction SilentlyContinue).WeaselRoot
    if ($root) { return $root }
  }
  return $null
}

function Install-TsfDll([string]$src, [string]$dst) {
  if (-not (Test-Path -LiteralPath $src)) {
    "skip $dst (no $src)"
    return
  }
  if ((Test-Path -LiteralPath $dst) -and -not $Force -and
      ((Get-FileHash -LiteralPath $src).Hash -eq
       (Get-FileHash -LiteralPath $dst).Hash)) {
    "up to date: $dst"
    return
  }
  if (Test-Path -LiteralPath $dst) {
    $backup = "$dst.old-$stamp"
    Move-Item -LiteralPath $dst -Destination $backup -Force
    "backed up: $backup"
  }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  "installed: $dst"
}

$ok = $false
try {
  $out = (Resolve-Path -LiteralPath $OutputDir).Path
  if (-not (Test-Path -LiteralPath (Join-Path $out 'weaselx64.dll'))) {
    throw "no build output in $out - run build.bat first"
  }
  "build output: $out"

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  Install-TsfDll (Join-Path $out 'weaselx64.dll') `
                 (Join-Path $env:SystemRoot 'System32\weasel.dll')
  Install-TsfDll (Join-Path $out 'weasel.dll') `
                 (Join-Path $env:SystemRoot 'SysWOW64\weasel.dll')

  # server, plus the copies the install directory keeps for repair/uninstall
  $inst = Get-WeaselInstallDir
  if ($inst -and (Test-Path -LiteralPath $inst)) {
    $serverSrc = Join-Path $out 'WeaselServer.exe'
    $serverDst = Join-Path $inst 'WeaselServer.exe'
    $serverStale =
      $Force -or -not (Test-Path -LiteralPath $serverDst) -or
      ((Get-FileHash -LiteralPath $serverSrc).Hash -ne
       (Get-FileHash -LiteralPath $serverDst).Hash)
    if ($serverStale) {
      if (Get-Process WeaselServer -ErrorAction SilentlyContinue) {
        & $serverDst /q | Out-Null
        Start-Sleep -Milliseconds 800
        $running = Get-Process WeaselServer -ErrorAction SilentlyContinue
        if ($running) {
          $running | Stop-Process -Force
          Start-Sleep -Milliseconds 300
        }
      }
      Copy-Item -LiteralPath $serverSrc -Destination $serverDst -Force
      Copy-Item -LiteralPath (Join-Path $out 'weaselx64.dll') `
                -Destination (Join-Path $inst 'weaselx64.dll') -Force
      Copy-Item -LiteralPath (Join-Path $out 'weasel.dll') `
                -Destination (Join-Path $inst 'weasel.dll') -Force
      "installed: $serverDst (+ the dll copies next to it)"
      'note: WeaselServer is not started here (it would stay elevated); it'
      '      relaunches on the next keypress.'
    } else {
      "up to date: $serverDst"
    }
  } else {
    'skip WeaselServer.exe (install directory not found; pass -InstallDir)'
  }

  if ($CleanBackups) {
    $removed = 0
    $locked = @()
    $denied = @()
    # a mapped image can only be renamed, not deleted: an elevated run that is
    # still refused is holding on a running process, not on permissions
    $elevated = ([Security.Principal.WindowsPrincipal] `
                 [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)
    # the live DLLs, never to be touched: a backup-only match must not delete
    # them, and Get-ChildItem -Filter would (DOS wildcards let 'weasel.dll.*'
    # match 'weasel.dll' itself), so match with -like and check again below
    $live = @(
      (Join-Path $env:SystemRoot 'System32\weasel.dll'),
      (Join-Path $env:SystemRoot 'SysWOW64\weasel.dll')
    )
    foreach ($dir in "$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64") {
      foreach ($f in Get-ChildItem -LiteralPath $dir -File `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'weasel.dll.*' }) {
        if ($live -contains $f.FullName) { continue }
        try {
          Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
          "deleted backup: $($f.FullName)"
          $removed++
        } catch {
          if ($elevated) { $locked += $f.FullName } else { $denied += $f.FullName }
        }
      }
    }
    "backups deleted: $removed"
    if ($denied.Count) {
      'backups not deleted (needs an elevated shell):'
      $denied | ForEach-Object { "  $_" }
    }
    if ($locked.Count) {
      'backups still mapped by a running process:'
      $locked | ForEach-Object { "  $_" }
      'restart those applications (or log off) and rerun with -CleanBackups.'
    }
  }

  'RESULT: OK'
  $ok = $true
} catch {
  "RESULT: FAILED - $($_.Exception.Message)"
} finally {
  Stop-Transcript | Out-Null
}

if ($ok) { exit 0 } else { exit 1 }

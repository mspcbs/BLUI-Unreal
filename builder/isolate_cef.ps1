<#
.SYNOPSIS
  Gives BLUI's CEF runtime unique module names so it can live side by side with the
  engine's own CEF (WebBrowser / CEF3 module) inside the same Unreal process.

.DESCRIPTION
  Windows resolves a DLL imported by bare name (e.g. "libcef.dll") to whichever module
  with that name is already loaded, regardless of folder. BLUI and the engine both ship
  "libcef.dll" + "chrome_elf.dll", so whoever loads first wins and the other one ends up
  calling into the wrong Chromium (version mismatch / double CefInitialize).

  This script renames BLUI's copies to names of identical length and patches the few
  places that reference them by name:

    libcef.dll      -> blucef.dll       (export name, runtime GetModuleHandle table,
                                         version resource, BluBrowserProcess.exe import)
    chrome_elf.dll  -> blucef_elf.dll   (blucef.dll import + runtime GetModuleHandle
                                         lookups, chrome_elf export name)

  It then generates lib/blucef.lib (an import library for blucef.dll) from the DLL's
  export table, which Blu.Build.cs links instead of libcef.lib.

  Run once per new CEF drop, after copying the CEF Release/Resources files and the
  freshly built BluBrowserProcess.exe into ThirdParty/cef/Win/shipping.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File builder/isolate_cef.ps1
#>
param(
	[string]$CefDir = (Join-Path $PSScriptRoot "..\ThirdParty\cef\Win"),
	[switch]$KeepOriginals
)

$ErrorActionPreference = "Stop"
$Shipping = Join-Path $CefDir "shipping"
$LibDir = Join-Path $CefDir "lib"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class BluPatcher
{
	// Replaces every occurrence of From with To (same length) in Data.
	// Occurrences immediately followed by SkipIfFollowedBy (e.g. ".pdb") are left alone.
	public static int Replace(byte[] Data, string From, string To, bool Utf16, string SkipIfFollowedBy)
	{
		if (From.Length != To.Length) throw new ArgumentException("Replacement must keep the same length: " + From + " -> " + To);
		Encoding Enc = Utf16 ? Encoding.Unicode : Encoding.ASCII;
		byte[] F = Enc.GetBytes(From);
		byte[] T = Enc.GetBytes(To);
		byte[] Skip = string.IsNullOrEmpty(SkipIfFollowedBy) ? null : Enc.GetBytes(SkipIfFollowedBy);
		int Count = 0;
		for (int i = 0; i <= Data.Length - F.Length; i++)
		{
			if (Data[i] != F[0]) continue;
			int k = 1;
			while (k < F.Length && Data[i + k] == F[k]) k++;
			if (k != F.Length) continue;
			if (Skip != null && Matches(Data, i + F.Length, Skip)) continue;
			Buffer.BlockCopy(T, 0, Data, i, T.Length);
			Count++;
			i += F.Length - 1;
		}
		return Count;
	}

	static bool Matches(byte[] Data, int Offset, byte[] Pattern)
	{
		if (Offset + Pattern.Length > Data.Length) return false;
		for (int i = 0; i < Pattern.Length; i++) if (Data[Offset + i] != Pattern[i]) return false;
		return true;
	}
}
"@

function Invoke-Patch([string]$Source, [string]$Target, [object[]]$Rules)
{
	$Data = [IO.File]::ReadAllBytes($Source)
	foreach ($Rule in $Rules)
	{
		$Count = [BluPatcher]::Replace($Data, $Rule.From, $Rule.To, $Rule.Utf16, $Rule.Skip)
		$Kind = if ($Rule.Utf16) { "utf16" } else { "ascii" }
		if ($Count -ne $Rule.Expected)
		{
			throw "$(Split-Path $Source -Leaf): expected $($Rule.Expected) $Kind '$($Rule.From)' but found $Count. CEF layout changed, review the rules before shipping."
		}
		Write-Host ("  {0,-22} {1,-5} {2} -> {3} x{4}" -f (Split-Path $Target -Leaf), $Kind, $Rule.From, $Rule.To, $Count)
	}
	[IO.File]::WriteAllBytes($Target, $Data)
}

function Rule($From, $To, $Utf16, $Expected, $Skip = $null)
{
	[pscustomobject]@{ From = $From; To = $To; Utf16 = $Utf16; Expected = $Expected; Skip = $Skip }
}

$LibCef = Join-Path $Shipping "libcef.dll"
$ChromeElf = Join-Path $Shipping "chrome_elf.dll"
$SubProcess = Join-Path $Shipping "BluBrowserProcess.exe"
$BluCef = Join-Path $Shipping "blucef.dll"
$BluElf = Join-Path $Shipping "blucef_elf.dll"

if (-not (Test-Path $LibCef)) { throw "No libcef.dll in $Shipping (already isolated?)" }

Write-Host "Patching CEF runtime in $Shipping"

# libcef.dll: export name + GetModuleHandle table + version resource. The PDB path is left intact so symbols still resolve.
Invoke-Patch $LibCef $BluCef @(
	(Rule "libcef.dll"     "blucef.dll"     $false 1 ".pdb"),
	(Rule "chrome_elf.dll" "blucef_elf.dll" $false 1 ".pdb"),
	(Rule "libcef.dll"     "blucef.dll"     $true  2),
	(Rule "chrome_elf.dll" "blucef_elf.dll" $true  3)
)

# chrome_elf.dll: export name + version resource
Invoke-Patch $ChromeElf $BluElf @(
	(Rule "chrome_elf.dll" "blucef_elf.dll" $false 1 ".pdb"),
	(Rule "chrome_elf.dll" "blucef_elf.dll" $true  1)
)

# BluBrowserProcess.exe: import of libcef.dll
Invoke-Patch $SubProcess $SubProcess @(
	(Rule "libcef.dll" "blucef.dll" $false 1)
)

# Import library for blucef.dll
$VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$ToolsBin = Get-ChildItem (Join-Path $VsPath "VC\Tools\MSVC") -Directory | Sort-Object Name -Descending |
	ForEach-Object { Join-Path $_.FullName "bin\Hostx64\x64" } |
	Where-Object { (Test-Path (Join-Path $_ "lib.exe")) -and (Test-Path (Join-Path $_ "dumpbin.exe")) } | Select-Object -First 1
if (-not $ToolsBin) { throw "No MSVC toolset with lib.exe/dumpbin.exe found under $VsPath" }
$DumpBin = Join-Path $ToolsBin "dumpbin.exe"
$LibExe = Join-Path $ToolsBin "lib.exe"

$Exports = & $DumpBin /exports $BluCef | ForEach-Object {
	if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)') { $Matches[1] }
}
if ($Exports.Count -lt 100) { throw "Only found $($Exports.Count) exports in blucef.dll, dumpbin parse failed" }

$DefFile = Join-Path $LibDir "blucef.def"
@("LIBRARY blucef.dll", "EXPORTS") + ($Exports | ForEach-Object { "    $_" }) | Set-Content -Path $DefFile -Encoding ASCII
$OutLib = Join-Path $LibDir "blucef.lib"
& $LibExe /nologo /machine:x64 "/def:$DefFile" "/out:$OutLib" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "lib.exe failed" }
Remove-Item $DefFile, (Join-Path $LibDir "blucef.exp") -ErrorAction SilentlyContinue
Write-Host "  blucef.lib             generated with $($Exports.Count) exports"

if (-not $KeepOriginals)
{
	Remove-Item $LibCef, $ChromeElf
	Remove-Item (Join-Path $LibDir "libcef.lib") -ErrorAction SilentlyContinue
	Write-Host "  removed libcef.dll, chrome_elf.dll, libcef.lib"
}

Write-Host "Done. BLUI CEF runtime is now isolated as blucef.dll / blucef_elf.dll"

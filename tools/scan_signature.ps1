# scan_signature.ps1 - search a PE file for the AOB patterns used by UE4SS signature lua scripts
param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$LuaFiles
)

$ErrorActionPreference = 'Stop'

function Convert-Pattern([string]$text) {
    $parts = $text.Trim() -split '\s+'
    $bytes = New-Object byte[] $parts.Count
    $mask  = New-Object bool[] $parts.Count
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq '??') { $bytes[$i] = 0; $mask[$i] = $false }
        else { $bytes[$i] = [Convert]::ToByte($parts[$i], 16); $mask[$i] = $true }
    }
    return @{ Bytes = $bytes; Mask = $mask }
}

function Find-Matches([string]$path, $pattern, [int]$maxHits = 5) {
    $len = $pattern.Bytes.Count
    $hits = New-Object System.Collections.ArrayList
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $chunkSize = 8MB
        $buf = New-Object byte[] ($chunkSize + $len)
        [long]$filePos = 0
        [long]$carry = 0
        while ($true) {
            $read = $fs.Read($buf, [int]$carry, $chunkSize)
            if ($read -le 0) { break }
            $total = [int]$carry + $read
            $limit = $total - $len
            for ($i = 0; $i -le $limit; $i++) {
                $ok = $true
                for ($k = 0; $k -lt $len; $k++) {
                    if ($pattern.Mask[$k] -and $buf[$i + $k] -ne $pattern.Bytes[$k]) { $ok = $false; break }
                }
                if ($ok) {
                    [void]$hits.Add($filePos + $i - $carry)
                    if ($hits.Count -ge $maxHits) { return $hits }
                }
            }
            $filePos += $read
            $carry = [Math]::Min($len - 1, $total)
            [Array]::Copy($buf, $total - $carry, $buf, 0, $carry)
        }
    } finally { $fs.Dispose() }
    return $hits
}

foreach ($lua in ($LuaFiles -split ',')) {
    $lua = $lua.Trim()
    $text = [System.IO.File]::ReadAllText($lua)
    $m = [regex]::Match($text, 'local\s+Pattern\s*=\s*"([^"]+)"')
    if (-not $m.Success) { Write-Host ("pattern not found in " + $lua); continue }
    $pat = Convert-Pattern $m.Groups[1].Value
    Write-Host ("=== " + (Split-Path $lua -Leaf) + "  (bytes=" + $pat.Bytes.Count + ") ===")
    $hits = Find-Matches $Exe $pat
    if ($hits.Count -eq 0) { Write-Host "  NO MATCH in new exe" }
    else { foreach ($h in $hits) { Write-Host ("  match at file offset 0x{0:X}" -f $h) } }
}

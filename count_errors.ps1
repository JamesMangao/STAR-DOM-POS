$content = Get-Content analyze_raw.txt -Raw
$lines = $content -split "`r?`n"
$codes = @{}
foreach ($line in $lines) {
    if ($line -match ' - ([a-z_]+)$') {
        $code = $matches[1]
        if ($codes.ContainsKey($code)) { $codes[$code]++ } else { $codes[$code] = 1 }
    }
}
$codes.GetEnumerator() | Sort-Object Value -Descending | Format-Table @{Name='Count';Expression={$_.Value}}, @{Name='Code';Expression={$_.Key}}
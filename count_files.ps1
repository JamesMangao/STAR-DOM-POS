$content = Get-Content analyze_raw.txt -Raw
$lines = $content -split "`r?`n"
$files = @{}
foreach ($line in $lines) {
    if ($line -match 'lib\\[^:]+') {
        $file = $matches[0]
        if ($files.ContainsKey($file)) { $files[$file]++ } else { $files[$file] = 1 }
    }
}
$files.GetEnumerator() | Sort-Object Value -Descending | Format-Table @{Name='Count';Expression={$_.Value}}, @{Name='File';Expression={$_.Key}}
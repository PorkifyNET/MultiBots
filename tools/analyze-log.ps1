param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,
    [double]$RegretThreshold = [double]::NaN,
    [double]$VarianceRatio = [double]::NaN,
    [int]$ReorderThreshold = 0,
    [string]$OutputPath,
    [string]$SnapshotStorePath,
    [string]$FlaggedSnapshotPath
)

$ErrorActionPreference = "Stop"

function Decode-LogValue([string]$Value) {
    return [Uri]::UnescapeDataString($Value)
}

function Parse-Fields([string[]]$Tokens, [int]$Start) {
    $fields = @{}
    for ($i = $Start; $i -lt $Tokens.Count; $i++) {
        $parts = $Tokens[$i] -split '=', 2
        if ($parts.Count -eq 2) { $fields[$parts[0]] = Decode-LogValue $parts[1] }
    }
    return $fields
}

$resolved = (Resolve-Path -LiteralPath $Path).Path
$lines = Get-Content -LiteralPath $resolved
if ($lines.Count -eq 0 -or $lines[0] -notmatch '^MULTIBOTS_LOG v2\b') {
    throw "Expected a MULTIBOTS_LOG v2 file: $resolved"
}

$headerTokens = $lines[0] -split ' '
$header = Parse-Fields $headerTokens 2
if ([double]::IsNaN($RegretThreshold)) {
    $RegretThreshold = if ($header.high_regret_threshold) { [double]$header.high_regret_threshold } else { 25 }
}
if ([double]::IsNaN($VarianceRatio)) {
    $VarianceRatio = if ($header.score_variance_ratio) { [double]$header.score_variance_ratio } else { 4 }
}
if ($ReorderThreshold -le 0) {
    $ReorderThreshold = if ($header.reorder_threshold) { [int]$header.reorder_threshold } else { 3 }
}

$records = [System.Collections.Generic.List[object]]::new()
foreach ($line in $lines | Select-Object -Skip 1) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $tokens = $line -split ' '
    if ($tokens.Count -lt 2) { continue }
    $records.Add([pscustomobject]@{
        Time = $tokens[0]
        Kind = $tokens[1]
        Fields = Parse-Fields $tokens 2
    })
}

$end = $records | Where-Object Kind -eq 'END' | Select-Object -Last 1
$unknown = @{}
$seenShops = @{}
$failures = [System.Collections.Generic.List[object]]::new()
$pvp = [System.Collections.Generic.List[object]]::new()
$jokerEvents = [System.Collections.Generic.List[object]]::new()
$highRegret = [System.Collections.Generic.List[object]]::new()
$invalid = [System.Collections.Generic.List[object]]::new()
$variance = [System.Collections.Generic.List[object]]::new()
$reorders = @{}
$flagged = [System.Collections.Generic.List[object]]::new()
$previousPlay = $null
$lastHand = $null

foreach ($record in $records) {
    $f = $record.Fields
    if ($f.regret -and [double]$f.regret -ge $RegretThreshold) {
        $highRegret.Add($record)
        $flagged.Add($record)
    }
    switch ($record.Kind) {
        'SHOP_DECISION' {
            $shopId = if ($f.shop_id) { $f.shop_id } else { "line:$($records.IndexOf($record))" }
            if (-not $seenShops.ContainsKey($shopId)) {
                $seenShops[$shopId] = $true
                $supported = @{}
				$shopUnknown = $false
                foreach ($key in @($f.supported -split ',' | Where-Object { $_ -and $_ -ne 'none' })) {
                    $supported[$key] = 1 + [int]($supported[$key])
                }
                foreach ($key in @($f.offered -split ',' | Where-Object { $_ -and $_ -ne 'none' })) {
                    if ([int]($supported[$key]) -gt 0) { $supported[$key]-- }
					else { $unknown[$key] = 1 + [int]($unknown[$key]); $shopUnknown = $true }
                }
				if ($shopUnknown) { $flagged.Add($record) }
            }
        }
        'BLIND_FAILURE' {
            $target = [double]($f.target)
            $score = [double]($f.score)
            $deficit = if ($target -gt 0) { [Math]::Max([double]0, ($target - $score) / $target * 100) } else { 0 }
			$handsRemaining = if ($null -ne $f.hands_remaining -and $f.hands_remaining -ne '') {
				[int]$f.hands_remaining
			} elseif ($lastHand -and $lastHand.Fields.action -eq 'play') {
				[Math]::Max(0, [int]$lastHand.Fields.hands_remaining - 1)
			} else { 0 }
			$discardsRemaining = if ($null -ne $f.discards_remaining -and $f.discards_remaining -ne '') {
				[int]$f.discards_remaining
			} elseif ($lastHand -and $lastHand.Fields.discards_remaining) {
				[int]$lastHand.Fields.discards_remaining
			} else { 0 }
			$consumablesRemaining = if ($null -ne $f.consumables_remaining -and $f.consumables_remaining -ne '') {
				[int]$f.consumables_remaining
			} else {
				@($f.consumables -split ',' | Where-Object { $_ -and $_ -ne 'none' }).Count
			}
			$handsAvailable = if ($f.hands_available) { [int]$f.hands_available } else { 0 }
			$discardsAvailable = if ($f.discards_available) { [int]$f.discards_available } else { 0 }
			$anomalies = [System.Collections.Generic.List[string]]::new()
			if ($deficit -lt 5) { $anomalies.Add('near miss <5%') }
			elseif ($deficit -lt 10) { $anomalies.Add('near miss <10%') }
			if ($handsRemaining -gt 0) { $anomalies.Add("unused hands=$handsRemaining") }
			if ($discardsRemaining -gt 0) { $anomalies.Add("unused discards=$discardsRemaining") }
			if ($consumablesRemaining -gt 0) { $anomalies.Add("unused consumables=$consumablesRemaining") }
			$halfDiscards = $discardsAvailable -gt 0 -and $discardsRemaining -ge [Math]::Ceiling($discardsAvailable / 2)
			if ($handsRemaining -gt 0 -or $halfDiscards -or
				($deficit -lt 10 -and ($discardsRemaining -gt 0 -or $consumablesRemaining -gt 0))) {
				$anomalies.Add('suspicious resource conservation')
			}
			$failures.Add([pscustomobject]@{
				Record = $record; Deficit = $deficit; Anomalies = $anomalies
				HandsRemaining = $handsRemaining; DiscardsRemaining = $discardsRemaining
				ConsumablesRemaining = $consumablesRemaining
			})
            $flagged.Add($record)
        }
        'PVP' { $pvp.Add($record) }
        'CRASH' { $invalid.Add($record); $flagged.Add($record) }
        'INVALID' { $invalid.Add($record); $flagged.Add($record) }
        'DECISION' {
			if ($f.action -eq 'buy_pack' -and $f.revealed) {
				$modeled = @{}
				$packUnknown = $false
				foreach ($entry in @($f.modeled -split ',' | Where-Object { $_ })) {
					$modeled[($entry -split ':', 2)[0]] = $true
				}
				foreach ($key in @($f.revealed -split ',' | Where-Object { $_ -match '^[jcpv]_' })) {
					if (-not $modeled.ContainsKey($key)) {
						$unknown[$key] = 1 + [int]($unknown[$key]); $packUnknown = $true
					}
				}
				if ($packUnknown) { $flagged.Add($record) }
			}
            if ($f.action -in @('buy_joker', 'sell_joker', 'destroy_joker')) { $jokerEvents.Add($record) }
            if ($f.action -eq 'reorder_jokers') {
                $key = "$($f.ante):$($f.round)"
                if (-not $reorders.ContainsKey($key)) {
                    $reorders[$key] = [pscustomobject]@{ Count = 0; Copy = $false; Records = [System.Collections.Generic.List[object]]::new() }
                }
                $reorders[$key].Count++
                $reorders[$key].Records.Add($record)
                if (("$($f.from),$($f.to)") -match 'j_(blueprint|brainstorm)') { $reorders[$key].Copy = $true }
            }
            if ($f.action -eq 'play') {
                $score = [double]($f.score)
				$planKey = if ($f.plan_primary) { $f.plan_primary } else { $f.plan }
				$previousPlanKey = if ($previousPlay -and $previousPlay.Fields.plan_primary) { $previousPlay.Fields.plan_primary } elseif ($previousPlay) { $previousPlay.Fields.plan } else { $null }
                if ($previousPlay -and $previousPlanKey -ne $planKey -and $score -gt 0) {
                    $previousScore = [double]$previousPlay.Fields.score
                    if ($previousScore -gt 0) {
                        $ratio = [Math]::Max($score / $previousScore, $previousScore / $score)
                        if ($ratio -ge $VarianceRatio) {
                            $variance.Add([pscustomobject]@{ Record = $record; Ratio = $ratio })
                            $flagged.Add($record)
                        }
                    }
                }
                $previousPlay = $record
            }
			if ($f.action -in @('play', 'discard')) { $lastHand = $record }
        }
    }
}

foreach ($entry in $reorders.GetEnumerator()) {
    if ($entry.Value.Copy -and $entry.Value.Count -ge $ReorderThreshold) {
        foreach ($record in $entry.Value.Records) { $flagged.Add($record) }
    }
}

$priority = [System.Collections.Generic.List[string]]::new()
foreach ($failure in $failures) {
    $f = $failure.Record.Fields
	$suffix = if ($failure.Anomalies.Count -gt 0) { ' (' + ($failure.Anomalies -join '; ') + ')' } else { '' }
    $priority.Add("Ante $($f.ante) $($f.blind) failed by $($failure.Deficit.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))%$suffix")
}
foreach ($record in $highRegret) {
    $priority.Add("Decision $($record.Fields.decision_id) had regret $(([double]$record.Fields.regret).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))")
}
foreach ($entry in $reorders.GetEnumerator() | Sort-Object Name) {
    if ($entry.Value.Copy -and $entry.Value.Count -ge $ReorderThreshold) {
        $priority.Add("Blueprint/Brainstorm caused $($entry.Value.Count) Joker reorder events in $($entry.Name)")
    }
}
$unknownTotal = ($unknown.Values | Measure-Object -Sum).Sum
if (-not $unknownTotal) { $unknownTotal = 0 }
$unknownUnique = $unknown.Count
if ($unknownTotal -gt 0) { $priority.Add("$unknownUnique unique unsupported objects across $unknownTotal encounters") }
foreach ($item in $variance) {
    $priority.Add("Decision $($item.Record.Fields.decision_id) followed a plan change with $($item.Ratio.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))x score variance")
}

$wins = @($pvp | Where-Object { [double]$_.Fields.bot_score -ge [double]$_.Fields.player_score }).Count
$losses = $pvp.Count - $wins
$report = [System.Collections.Generic.List[string]]::new()
$report.Add('MATCH QUALITY REPORT')
$report.Add('')
$report.Add("Result: $(if ($end) { $end.Fields.result } else { 'incomplete' }), Ante $(if ($end) { $end.Fields.ante } else { '?' })")
$report.Add('')
$report.Add('High-priority review:')
$report.Add('')
if ($priority.Count -eq 0) { $report.Add('No high-priority strategy issues detected.') }
for ($i = 0; $i -lt $priority.Count; $i++) { $report.Add("$($i + 1). $($priority[$i])") }
$report.Add($(if ($invalid.Count -eq 0) { 'No crashes or invalid actions' } else { "$($invalid.Count) crashes or invalid actions" }))
$report.Add('')
$report.Add("PvP: $wins wins, $losses losses")
foreach ($round in $pvp) {
    $margin = [double]$round.Fields.bot_score - [double]$round.Fields.player_score
    $report.Add("- Ante $($round.Fields.ante): $(if ($margin -ge 0) { 'win' } else { 'loss' }) by $([Math]::Abs($margin).ToString('0'))")
}
$report.Add("Joker purchases/sales/destructions: $($jokerEvents.Count)")
foreach ($event in $jokerEvents) { $report.Add("- $($event.Fields.action) $($event.Fields.value)") }
$report.Add("Unsupported objects: $unknownUnique unique, $unknownTotal encounters")
foreach ($item in $unknown.GetEnumerator() | Sort-Object Name) { $report.Add("- $($item.Name): $($item.Value)") }
$report.Add("High-regret threshold: $($RegretThreshold.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))")

if (-not $OutputPath) { $OutputPath = [IO.Path]::ChangeExtension($resolved, '.report.txt') }
[IO.File]::WriteAllLines($OutputPath, $report)

$snapshotStore = @{}
if (-not $SnapshotStorePath) { $SnapshotStorePath = [IO.Path]::ChangeExtension($resolved, '.snapshots.log') }
if (Test-Path -LiteralPath $SnapshotStorePath) {
	foreach ($line in Get-Content -LiteralPath $SnapshotStorePath | Select-Object -Skip 1) {
		if ([string]::IsNullOrWhiteSpace($line)) { continue }
		$tokens = $line -split ' '
		if ($tokens.Count -lt 2 -or $tokens[1] -ne 'SNAPSHOT') { continue }
		$fields = Parse-Fields $tokens 2
		if ($fields.snapshot_id) { $snapshotStore[$fields.snapshot_id] = $fields.snapshot }
	}
}
if (-not $FlaggedSnapshotPath) {
	$FlaggedSnapshotPath = [IO.Path]::ChangeExtension($resolved, '.flagged-snapshots.log')
}
$snapshotLines = [System.Collections.Generic.List[string]]::new()
$seenDecisionIds = @{}
foreach ($record in $flagged) {
    $id = if ($record.Fields.decision_id) { $record.Fields.decision_id } else { "$($record.Kind):$($record.Time)" }
    if ($seenDecisionIds.ContainsKey($id)) { continue }
    $seenDecisionIds[$id] = $true
	$snapshotId = if ($record.Fields.snapshot_id) { $record.Fields.snapshot_id } else { $id }
	$snapshot = if ($snapshotStore.ContainsKey($snapshotId)) { $snapshotStore[$snapshotId] } else { $record.Fields.snapshot }
    $snapshotLines.Add("decision_id=$id snapshot_id=$snapshotId kind=$($record.Kind) action=$($record.Fields.action) regret=$($record.Fields.regret)")
    $snapshotLines.Add("snapshot=$snapshot")
}
[IO.File]::WriteAllLines($FlaggedSnapshotPath, $snapshotLines)

$report -join [Environment]::NewLine

<#
domain-check.ps1 - bulk domain availability checker (RDAP based)

USAGE:
  # from a file (one domain per line; commas/spaces/blank lines OK):
  .\domain-check.ps1 -InputFile .\list.txt

  # inline:
  .\domain-check.ps1 -Domains foo.com,bar.io,baz.dev

  # from clipboard (paste your bulk list, then run):
  .\domain-check.ps1 -Clipboard

  # pipe:
  Get-Content list.txt | .\domain-check.ps1

OUTPUT: console table + results.csv next to the script.
  AVAILABLE = not registered   TAKEN = registered   UNKNOWN = no RDAP / error
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromPipeline=$true)][string[]]$Domains,
  [string]$InputFile,
  [switch]$Clipboard,
  [int]$Concurrency = 12,
  [string]$OutCsv = "$PSScriptRoot\results.csv"
)

begin { $collected = New-Object System.Collections.Generic.List[string] }
process { if ($Domains) { $collected.AddRange($Domains) } }

end {
  # ---- gather raw input ----
  $raw = @()
  if ($InputFile)  { $raw += Get-Content -Path $InputFile }
  if ($Clipboard)  { $raw += (Get-Clipboard) }
  if ($collected.Count) { $raw += $collected }

  # ---- normalize: split on whitespace/comma, strip scheme/path/www, lowercase, dedupe ----
  $list = $raw |
    ForEach-Object { $_ -split '[\s,;]+' } |
    Where-Object { $_ } |
    ForEach-Object {
      ($_ -replace '^https?://','' -replace '^www\.','' -replace '/.*$','').Trim().ToLower()
    } |
    Where-Object { $_ -match '^[a-z0-9.-]+\.[a-z]{2,}$' } |
    Select-Object -Unique

  if (-not $list) { Write-Host "No valid domains found in input." -ForegroundColor Yellow; return }

  # ---- load IANA RDAP bootstrap: which TLDs actually have an RDAP server ----
  # (a 404 only means "available" for TLDs in this set; otherwise it just means no RDAP)
  $supported = @{}
  try {
    $b = Invoke-RestMethod "https://data.iana.org/rdap/dns.json" -TimeoutSec 25
    foreach ($svc in $b.services) { foreach ($tld in $svc[0]) { $supported[$tld.ToLower()] = $true } }
  } catch { Write-Host "Warning: couldn't load IANA RDAP bootstrap; results may be UNKNOWN." -ForegroundColor Yellow }

  Write-Host "Checking $($list.Count) domain(s) with concurrency $Concurrency..." -ForegroundColor Cyan

  # ---- worker: RDAP + independent DNS-NS cross-check per domain ----
  # AVAILABLE is reported ONLY when BOTH agree (RDAP 404 AND no NS delegation).
  # Any sign of registration (RDAP 200, or NS records present) => TAKEN. Never the reverse.
  $worker = {
    param($domain,$supported)
    $r = [pscustomobject]@{ Domain=$domain; Status='UNKNOWN'; Detail='' }
    $tld = ($domain -split '\.')[-1]

    # --- signal 1: DNS NS delegation. Registered domains are delegated (have NS). ---
    # null = lookup inconclusive, $true = has NS (registered), $false = NXDOMAIN (not delegated)
    $hasNS = $null
    try {
      $ns = Resolve-DnsName -Name $domain -Type NS -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -eq 'NS' }
      $hasNS = [bool]$ns
    } catch {
      if ("$($_.Exception.Message)" -match 'does not exist|NXDOMAIN|not exist') { $hasNS = $false }
      else { $hasNS = $null }
    }

    # delegated => definitively registered, regardless of RDAP
    if ($hasNS -eq $true) { $r.Status='TAKEN'; $r.Detail='ns-delegated'; return $r }

    # --- signal 2: RDAP (authoritative when the TLD has an RDAP server) ---
    if (-not $supported.ContainsKey($tld)) {
      # no RDAP for this TLD: we can only trust NS. No NS isn't proof of free here.
      if ($hasNS -eq $false) { $r.Status='UNKNOWN'; $r.Detail="no rdap for .$tld (no NS)" }
      else                   { $r.Status='UNKNOWN'; $r.Detail="no rdap for .$tld" }
      return $r
    }

    $rdap = 'unknown'
    try {
      $resp = Invoke-WebRequest -Uri "https://rdap.org/domain/$domain" -Method Get `
                -TimeoutSec 20 -ErrorAction Stop -UseBasicParsing
      if ($resp.StatusCode -eq 200) { $rdap = 'taken' }
    } catch {
      $code = $null
      try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      switch ($code) {
        404     { $rdap = 'free' }
        429     { $rdap = 'unknown'; $r.Detail='rate-limited' }
        default { $rdap = 'unknown'; $r.Detail = if ($code) {"http $code"} else {'no rdap/timeout'} }
      }
    }

    # --- combine. AVAILABLE requires BOTH RDAP=free AND no NS. ---
    if ($rdap -eq 'taken') {
      $r.Status='TAKEN'
    }
    elseif ($rdap -eq 'free' -and $hasNS -eq $false) {
      $r.Status='AVAILABLE'; $r.Detail='rdap+dns confirmed'
    }
    elseif ($rdap -eq 'free' -and $hasNS -eq $null) {
      # RDAP says free but DNS was inconclusive -> don't risk a false available
      $r.Status='UNKNOWN'; $r.Detail='rdap free, dns inconclusive'
    }
    else {
      if (-not $r.Detail) { $r.Detail='unresolved' }
    }
    $r
  }

  # ---- runspace pool ----
  $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
  $pool.Open()
  $jobs = foreach ($d in $list) {
    $ps = [powershell]::Create().AddScript($worker).AddArgument($d).AddArgument($supported)
    $ps.RunspacePool = $pool
    [pscustomobject]@{ PS=$ps; Handle=$ps.BeginInvoke() }
  }
  $results = foreach ($j in $jobs) {
    $out = $j.PS.EndInvoke($j.Handle); $j.PS.Dispose(); $out
  }
  $pool.Close(); $pool.Dispose()

  # ---- report ----
  $results = $results | Sort-Object Status, Domain
  $results | Format-Table -AutoSize | Out-Host

  $a = ($results | ? Status -eq 'AVAILABLE').Count
  $t = ($results | ? Status -eq 'TAKEN').Count
  $u = ($results | ? Status -eq 'UNKNOWN').Count
  Write-Host ("Summary: AVAILABLE={0}  TAKEN={1}  UNKNOWN={2}" -f $a,$t,$u) -ForegroundColor Green

  $results | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
  Write-Host "CSV: $OutCsv" -ForegroundColor DarkGray
}

#Requires -Version 7
<#
Measures .vpx load timings on Windows, using the same phase boundaries and the same content
fingerprint as the macos harness in tools/vpxio-bench, so the numbers are directly comparable.

    # once per build you want to compare
    .\vpx-bench.ps1 -Stash master        # after building upstream/master
    .\vpx-bench.ps1 -Stash order         # after building perf-vpx-load-order

    # then
    .\vpx-bench.ps1 -Run -Out warm.tsv -Tables 'T:\A.vpx','T:\B.vpx'
    .\vpx-bench.ps1 -Run -Out cold.tsv -Tables 'T:\A.vpx','T:\B.vpx' -Cold

    .\vpx-bench.ps1 -Summarise warm.tsv

Run this from OUTSIDE the repo. -Stash copies the built binaries to a work folder, so switching
git branches afterwards cannot delete either the script or the builds.

Phases, matching the macos harness exactly:
  open_parse  "LoadGameFromFilename ..."          -> "PinTable Data loaded"
  extract     "PinTable Data loaded"              -> "Images, Sounds and Items loaded"
  to_startup  "LoadGameFromFilename ..."          -> "Startup done"

Notes worth knowing before you start:
  * File logging is on by default (Editor/EnableLog defaults to true). If you have turned it off
    in Editor Options, this cannot measure anything.
  * -Cold needs Sysinternals RAMMap (RAMMap64.exe) on PATH and an elevated shell. Without it the
    script refuses rather than quietly producing warm numbers labelled cold.
  * The log is a rolling appender capped at 5 MB. This tracks a byte offset and resets it if the
    file shrinks, so a roll mid-run degrades one sample instead of corrupting the whole run.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
   [Parameter(ParameterSetName = 'Stash', Mandatory)][string] $Stash,
   [Parameter(ParameterSetName = 'Stash')][string] $BuildDir = 'build',
   # Provenance is taken from the repo containing -BuildDir, not the current directory, because
   # the mingw and MSVC builds usually live in two separate checkouts. Override only if the build
   # tree is outside its repo.
   [Parameter(ParameterSetName = 'Stash')][string] $Sha,

   [Parameter(ParameterSetName = 'Run', Mandatory)][switch] $Run,
   [Parameter(ParameterSetName = 'Run', Mandatory)][string] $Out,
   [Parameter(ParameterSetName = 'Run', Mandatory)][string[]] $Tables,
   [Parameter(ParameterSetName = 'Run')][int] $Reps = 3,
   [Parameter(ParameterSetName = 'Run')][switch] $Cold,
   [Parameter(ParameterSetName = 'Run')][int] $TimeoutSec = 600,
   # Set this if auto-discovery finds the wrong log. Do not mix PLATFORM=windows and
   # PLATFORM=windows-mingw builds in one invocation: they may log to different paths, and
   # picking the newest vpinball.log would then follow whichever build ran last.
   [Parameter(ParameterSetName = 'Run')][string] $LogPath,
   # Which stashed variants to include. Defaults to all of them. Use this to keep the MSVC and
   # mingw builds in separate runs, since they may log to different paths.
   [Parameter(ParameterSetName = 'Run')][string[]] $Variants,

   [Parameter(ParameterSetName = 'Summarise', Mandatory)][string] $Summarise,

   # Test hook: parse an existing log and print one row, to check this against the macos harness.
   [Parameter(ParameterSetName = 'ParseLog', Mandatory)][string] $ParseLog,
   [Parameter(ParameterSetName = 'ParseLog')][long] $Mark = 0,
   [Parameter(ParameterSetName = 'ParseLog')][string] $Label = 'test',

   [string] $WorkDir = (Join-Path $HOME 'vpx-bench')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$VariantDir = Join-Path $WorkDir 'variants'

function Get-VpxLogPath {
   $base = Join-Path $env:APPDATA 'VPinballX'
   if (-not (Test-Path $base)) { throw "no $base. Launch VPX once so it creates its preferences folder." }
   $log = Get-ChildItem -Path $base -Filter 'vpinball.log' -Recurse -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
   if (-not $log) { throw "no vpinball.log under $base. Is 'Enable Log' on in Editor Options?" }
   return $log.FullName
}

function Invoke-Stash {
   if (-not (Test-Path $BuildDir)) { throw "no build dir '$BuildDir'. Run this from the repo root, or pass -BuildDir." }
   $exe = Get-ChildItem -Path $BuildDir -Filter 'VPinballX*.exe' -Recurse -File |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
   if (-not $exe) { throw "no VPinballX*.exe under '$BuildDir'. Build first." }

   $src  = $exe.Directory.FullName
   $dest = Join-Path $VariantDir $Stash
   if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
   New-Item -ItemType Directory -Force -Path $dest | Out-Null
   # Copy the whole output folder: the exe alone will not run without its dlls and plugins.
   Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force

   # Resolve provenance from the build tree's own repo. Running git in the current directory
   # would label this build with whichever checkout the shell happened to be sitting in.
   $meta = $Sha
   if (-not $meta) {
      $top = (git -C $BuildDir rev-parse --show-toplevel 2>$null)
      if ($top) {
         $h = (git -C $BuildDir rev-parse --short HEAD 2>$null)
         $b = (git -C $BuildDir rev-parse --abbrev-ref HEAD 2>$null)
         $dirty = if ((git -C $BuildDir status --porcelain -- src standalone third-party CMakeLists.txt 2>$null)) { ' DIRTY' } else { '' }
         $meta = "$h $b$dirty $top"
      }
   }
   if (-not $meta) {
      Write-Warning "Could not determine the commit for '$Stash' from '$BuildDir'."
      Write-Warning "Pass -Sha so the results are not recorded against an unknown build."
      $meta = 'unknown'
   }
   Set-Content -Path (Join-Path $VariantDir "$Stash.sha") -Value $meta -NoNewline

   $stashed = Get-ChildItem -Path $dest -Filter 'VPinballX*.exe' -Recurse -File | Select-Object -First 1
   Write-Host "  stashed '$Stash'"
   Write-Host "    commit $meta"
   Write-Host "    from   $src"
   Write-Host "    exe    $($stashed.FullName)"
   Write-Host "    size   $([math]::Round((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)) MB"
   if ($meta -match 'DIRTY') { Write-Warning "That checkout has uncommitted changes under src/, so the sha does not describe it." }
}

function Clear-FileCache {
   $rammap = Get-Command 'RAMMap64.exe' -ErrorAction SilentlyContinue
   if (-not $rammap) { $rammap = Get-Command 'RAMMap.exe' -ErrorAction SilentlyContinue }
   if (-not $rammap) {
      throw "-Cold needs Sysinternals RAMMap on PATH (RAMMap64.exe). Get it from " +
            "https://learn.microsoft.com/sysinternals/downloads/rammap . Refusing to emit warm " +
            "numbers labelled cold."
   }
   $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
   if (-not $admin) { throw "-Cold needs an elevated shell, RAMMap cannot empty the standby list otherwise." }

   & $rammap.Source -Et | Out-Null   # empty standby list, this is the file cache
   & $rammap.Source -Ew | Out-Null   # empty working sets
   Start-Sleep -Milliseconds 500
}

# Mirrors the macos harness byte for byte so fingerprints can be compared across platforms.
function Get-Phases {
   param([string] $LogPath, [long] $Mark, [string] $Label)

   $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
   try {
      if ($fs.Length -lt $Mark) { $Mark = 0 }   # log rolled
      $fs.Seek($Mark, 'Begin') | Out-Null
      $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
   } finally { $fs.Dispose() }

   # "2026-08-24 09:15:22.123 INFO  [12345] [Foo@42] message"
   $rx   = [regex]'^(\S+ \S+) (\w+) +\[[^\]]*\] \[[^\]]*\] (.*)$'
   $want = @('LoadGameFromFilename ', 'PinTable Data loaded', 'Images, Sounds and Items loaded', 'Startup done')
   $t = @{}; $content = [System.Collections.Generic.List[string]]::new(); $errors = 0

   foreach ($line in $text -split "`r?`n") {
      $m = $rx.Match($line.TrimEnd())
      if (-not $m.Success) { continue }
      $sev = $m.Groups[2].Value; $msg = $m.Groups[3].Value
      if ($sev -in @('ERROR', 'FATAL')) { $errors++ }
      if ($msg -match 'Duplicate' -or $msg -match 'was replaced by') { $content.Add($msg) }
      foreach ($k in $want) {
         if ($msg.StartsWith($k) -and -not $t.ContainsKey($k)) {
            # plog emits 3 fractional digits, but accept 6 too. Python's %f is lenient about
            # this and .NET's ParseExact is not, so an exact single format silently threw here.
            $t[$k] = [datetime]::ParseExact($m.Groups[1].Value,
                        [string[]]@('yyyy-MM-dd HH:mm:ss.fff', 'yyyy-MM-dd HH:mm:ss.ffffff'),
                        [Globalization.CultureInfo]::InvariantCulture, 'None')
         }
      }
   }

   function span($a, $b) {
      if ($t.ContainsKey($a) -and $t.ContainsKey($b)) { return ($t[$b] - $t[$a]).TotalSeconds }
      return [double]::NaN
   }

   # Ordinal sort and LF join, to match Python's sorted() and "\n".join()
   $sorted = [string[]]$content
   [Array]::Sort($sorted, [StringComparer]::Ordinal)
   $joined = [string]::Join("`n", $sorted)
   $sha    = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($joined))
   $fp     = -join ($sha | ForEach-Object { $_.ToString('x2') })

   return @($Label,
            ('open_parse={0:F3}' -f (span $want[0] $want[1])),
            ('extract={0:F3}'    -f (span $want[1] $want[2])),
            ('to_startup={0:F3}' -f (span $want[0] $want[3])),
            "content=$($fp.Substring(0,12))",
            "errors=$errors") -join "`t"
}

function Invoke-Run {
   $log = if ($LogPath) {
      if (-not (Test-Path $LogPath)) { throw "no such log: $LogPath" }
      (Resolve-Path $LogPath).Path
   } else { Get-VpxLogPath }
   Write-Host "  log: $log"
   $foundAny = $false
   if (-not (Test-Path $VariantDir)) { throw "nothing stashed. Build a variant then run -Stash <name>." }
   # Named $stashed, not $variants: PowerShell variable names are case-insensitive, so a local
   # $variants IS the -Variants parameter, and assigning to it silently threw the filter away.
   $stashed = Get-ChildItem -Path $VariantDir -Directory | Select-Object -ExpandProperty Name
   if (-not $stashed) { throw "nothing stashed under $VariantDir." }
   if ($Variants) {
      # Accept both 'a','b' and 'a,b': invoking via `pwsh -File` passes one literal string where
      # native invocation would have built an array.
      $want = @($Variants | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
                Where-Object { $_ })
      $missing = $want | Where-Object { $_ -notin $stashed }
      if ($missing) { throw "not stashed: $($missing -join ', '). Have: $($stashed -join ', ')" }
      $stashed = $want
   }
   Write-Host "  running variants: $($stashed -join ', ')"
   foreach ($tb in $Tables) { if (-not (Test-Path $tb)) { throw "no such table: $tb" } }

   $lines = [System.Collections.Generic.List[string]]::new()
   foreach ($tb in $Tables) { $lines.Add("# table`t$([IO.Path]::GetFileNameWithoutExtension($tb))") }
   $lines.Add("# cache`t$(if ($Cold) { 'cold-rammap-each' } else { 'warm-no-flush' })")
   $lines.Add("# reps`t$Reps")
   $lines.Add("# log`t$log")
   $seen = @{}
   foreach ($v in $stashed) {
      $shaFile = Join-Path $VariantDir "$v.sha"
      $sha = if (Test-Path $shaFile) { Get-Content $shaFile -Raw } else { 'unknown' }
      $lines.Add("# variant`t$v`t$sha")
      Write-Host "  variant $v -> $sha"
      if ($sha -eq 'unknown') { Write-Warning "Variant '$v' has no recorded commit." }
      $seen[$v] = $sha
   }
   # Two checkouts mean two chances to compare different commits by accident.
   $baseShas = $seen.Values | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique
   if ($baseShas.Count -lt $stashed.Count) {
      Write-Warning "Two or more variants report the same commit. Check you rebuilt between stashes."
   }
   Set-Content -Path $Out -Value $lines

   $total = $Reps * $Tables.Count * $stashed.Count
   $n = 0
   foreach ($r in 1..$Reps) {
      foreach ($tb in $Tables) {
         $tname = ([IO.Path]::GetFileNameWithoutExtension($tb) -replace ' ', '_')
         if ($tname.Length -gt 24) { $tname = $tname.Substring(0, 24) }
         # rep, then table, then build, so the builds for one table sit adjacent in time.
         # Alternate the build order every rep: without -Cold the SMB client cache survives
         # between builds within a rep, so a fixed order systematically favours whichever build
         # runs second. Measured on a 2.5G share this inflated the second build's open_parse
         # advantage from nothing to 1.5s.
         $seq = if ($r % 2 -eq 0) { @($stashed) } else { @($stashed)[($stashed.Count-1)..0] }
         foreach ($v in $seq) {
            $n++
            Write-Host ("# {0}/{1} rep {2} {3} {4} {5}" -f $n, $total, $r, $tname, $v, (Get-Date -Format 'HH:mm:ss'))
            if ($Cold) { Clear-FileCache }
            Start-Sleep -Seconds 2

            $mark = (Get-Item $log).Length
            $exe  = Get-ChildItem -Path (Join-Path $VariantDir $v) -Filter 'VPinballX*.exe' -Recurse -File |
                       Select-Object -First 1
            $p = Start-Process -FilePath $exe.FullName -ArgumentList '-Play', "`"$tb`"" -PassThru

            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            $done = $false
            while ((Get-Date) -lt $deadline) {
               Start-Sleep -Milliseconds 200
               $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
               try {
                  if ($fs.Length -gt $mark) {
                     $fs.Seek($mark, 'Begin') | Out-Null
                     if ((New-Object System.IO.StreamReader($fs)).ReadToEnd() -match 'Startup done') { $done = $true }
                  }
               } finally { $fs.Dispose() }
               if ($done) { break }
               if ($p.HasExited) { break }
            }
            if (-not $done) { Write-Warning "  no 'Startup done' within ${TimeoutSec}s, sample will show NaN" }

            Start-Sleep -Seconds 1
            if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            $p.WaitForExit(10000) | Out-Null
            Start-Sleep -Milliseconds 500

            $row = Get-Phases -LogPath $log -Mark $mark -Label "r$r`t$tname`t$v"
            if ($row -notmatch 'NaN') { $foundAny = $true }
            Add-Content -Path $Out -Value $row
            Write-Host "  $row"
         }
      }
   }
   if (-not $foundAny) {
      Write-Warning "Every sample is NaN. The most likely cause is that this build logs somewhere"
      Write-Warning "other than $log. Find its vpinball.log and pass -LogPath."
   }
   Write-Host ""
   Write-Host "wrote $Out"
   Invoke-Summarise -Path $Out
}

function Invoke-Summarise {
   param([string] $Path)
   $rows = Get-Content $Path | Where-Object { $_ -notmatch '^#' -and $_.Trim() }
   $g = @{}
   foreach ($line in $rows) {
      $f = $line -split "`t"
      $kv = @{}
      foreach ($p in $f[3..($f.Count - 1)]) { $x = $p -split '=', 2; $kv[$x[0]] = $x[1] }
      $key = "$($f[1])|$($f[2])"
      if (-not $g.ContainsKey($key)) { $g[$key] = @{ extract = @(); startup = @(); fp = @(); err = @() } }
      $g[$key].extract += [double]$kv['extract']
      $g[$key].startup += [double]$kv['to_startup']
      $g[$key].fp      += $kv['content']
      $g[$key].err     += $kv['errors']
   }
   # @() is load-bearing: with one sample, Sort-Object returns a scalar and strict mode makes
   # .Count on it an error rather than 1.
   function med($a) { $s = @($a | Sort-Object); return $s[[int][math]::Floor($s.Count / 2)] }
   Write-Host ""
   Write-Host ("  {0,-26} {1,-22} {2,12} {3,16}  {4}" -f 'table', 'build', 'extract', 'startup', 'fingerprint')
   foreach ($k in ($g.Keys | Sort-Object)) {
      $t, $v = $k -split '\|'
      $e = med $g[$k].extract; $s = med $g[$k].startup
      $ex = @($g[$k].extract)
      $spread = if ($ex.Count -gt 1 -and $e -gt 0) {
                   '{0,5:F1}%' -f ((($ex | Measure-Object -Max).Maximum -
                                    ($ex | Measure-Object -Min).Minimum) / $e * 100)
                } else { '  n/a' }
      $fps = @($g[$k].fp | Select-Object -Unique) -join ','
      $ers = @($g[$k].err | Select-Object -Unique) -join ','
      Write-Host ("  {0,-26} {1,-22} {2,9:F3}s {3,-6} {4,9:F3}s  {5} errors={6}" -f
                  $t, $v, $e, $spread, $s, $fps, $ers)
   }
   Write-Host ""
   Write-Host "  A fingerprint differing between builds on the same table is a correctness"
   Write-Host "  problem and matters more than any timing here."
}

switch ($PSCmdlet.ParameterSetName) {
   'Stash'     { Invoke-Stash }
   'Run'       { Invoke-Run }
   'Summarise' { Invoke-Summarise -Path $Summarise }
   'ParseLog'  { Get-Phases -LogPath $ParseLog -Mark $Mark -Label $Label }
}

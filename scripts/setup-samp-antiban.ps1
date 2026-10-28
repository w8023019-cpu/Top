# ============================================================================
#  setup-samp-antiban.ps1 — Reset GPCI / HWID SA-MP (input: samp_antiban)
# ----------------------------------------------------------------------------
#  Sebelum 1.1.28 tombol "Reset Anti-Ban SAMP & GPCI" di aplikasi cuma
#  mengirim workflow biasa (samp=ya, durasi 60 menit) — TIDAK pernah memanggil
#  logika -ResetAntiBan yang sudah ada di Patch-GTA-SAMP.ps1. Jadi GPCI tidak
#  pernah berubah. Script ini menjalankan reset itu dengan benar.
#
#  Urutan:
#   1) Kalau Patch-GTA-SAMP.ps1 sudah dibuat setup-samp.ps1, pakai itu.
#   2) Tetap lakukan spoof inti di sini supaya bekerja walau `samp=tidak`.
#   3) Isolasi metric adapter VPN agar trafik UDP SA-MP tidak lewat tunnel.
#   4) Tulis out/samp-antiban.json + status.samp_antiban.
#
#  Catatan: mengganti MachineGuid berdampak pada sebagian lisensi Windows.
#  Ini memang perilaku anti-ban lama; jalankan hanya saat diperlukan.
# ============================================================================
$XyTag = 'XyRDP:samp-antiban'
. "$PSScriptRoot/lib-common.ps1"
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$steps = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$newMachineGuid = [guid]::NewGuid().ToString()
$newHwGuid = "{$([guid]::NewGuid().ToString())}"
$newPlayer = "XyPlayer_$(Get-Random -Min 1000 -Max 9999)"

function Step([string]$Label, [scriptblock]$Block) {
  try { & $Block; $steps.Add($Label) | Out-Null; Log "OK   $Label" }
  catch { $errors.Add("$Label -> $($_.Exception.Message)") | Out-Null; Log "SKIP $Label -> $($_.Exception.Message)" }
}

# ---------------------------------------------------- 1. Pakai patcher bila ada
$patcher = 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1'
if (Test-Path $patcher) {
  Step 'Patch-GTA-SAMP.ps1 -ResetAntiBan' {
    & $patcher -ResetAntiBan
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
  }
} else {
  Log '  Patch-GTA-SAMP.ps1 belum ada (samp=tidak?) — pakai reset mandiri'
}

# ------------------------------------------------------- 2. Spoof identitas mesin
Step 'MachineGuid / ProductId / HwProfileGuid baru' {
  $randProd = "{0:D5}-{1:D3}-{2:D7}-{3:D5}" -f (Get-Random -Min 10000 -Max 99999), (Get-Random -Min 100 -Max 999), (Get-Random -Min 1000000 -Max 9999999), (Get-Random -Min 10000 -Max 99999)
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -Value $newMachineGuid -ErrorAction SilentlyContinue
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography' -Name 'MachineGuid' -Value $newMachineGuid -ErrorAction SilentlyContinue
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductId' -Value $randProd -ErrorAction SilentlyContinue
  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001' -Name 'HwProfileGuid' -Value $newHwGuid -ErrorAction SilentlyContinue
}

# --------------------------------------------- 3. PlayerName SAMP + path gta_sa
Step 'PlayerName SAMP & path gta_sa.exe untuk semua profil' {
  $gtaExe = 'C:\Games\GTA San Andreas\gta_sa.exe'
  $regPaths = @('HKCU:\Software\SAMP')
  Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object {
    $_.PSChildName -notmatch '_Classes$' -and $_.PSChildName -ne '.DEFAULT'
  } | ForEach-Object { $regPaths += "Registry::HKEY_USERS\$($_.PSChildName)\Software\SAMP" }
  foreach ($k in ($regPaths | Select-Object -Unique)) {
    New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $k -Name 'PlayerName' -Value $newPlayer -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $k -Name 'gta_sa_exe' -Value $gtaExe -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
  }
}

# --------------------------------------------------- 4. Isolasi adapter VPN / TTL
Step 'Metric adaptor VPN (anti deteksi proxy SA-MP)' {
  Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'Tailscale|OpenVPN|TAP' -or $_.InterfaceDescription -match 'Tailscale|OpenVPN|TAP-Windows|Wintun'
  } | ForEach-Object {
    Set-NetIPInterface -InterfaceIndex $_.ifIndex -AutomaticMetric Disabled -InterfaceMetric 5000 -ErrorAction SilentlyContinue
  }
  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'DefaultTTL' -Value 128 -Type DWord -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 5. Laporan
$report = [ordered]@{
  status     = if ($errors.Count -eq 0) { 'ok' } else { 'partial' }
  machine_guid_prefix = $newMachineGuid.Substring(0, 8)
  player_name = $newPlayer
  steps      = @($steps)
  errors     = @($errors)
  note       = 'GPCI/HWID direset. Tidak menjamin bebas ban bila IP datacenter tetap terdeteksi server; WARP split-tunnel bisa dipilih manual di Control Center.'
  updated_at = (Get-Date).ToUniversalTime().ToString('o')
}
try {
  $outDir = Join-Path (Get-Workspace) 'out'
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  ($report | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $outDir 'samp-antiban.json') -Encoding utf8
  Update-Status @{ samp_antiban = $report } | Out-Null
} catch { Log "  tulis laporan gagal: $($_.Exception.Message)" }

Log "SELESAI — reset anti-ban: $($report.status), $($steps.Count) langkah."
exit 0

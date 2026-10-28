# ============================================================================
#  setup-public-tunnel.ps1 — akses Portmap / Railway (1.1.28)
# ----------------------------------------------------------------------------
#  Sebelum ini pilihan "Portmap" dan "Railway" ADA di aplikasi Android, tapi
#  workflow rdp-6h.yml cuma menerima `akses=tailscale` dan setup-akses.ps1
#  hanya mengerti Tailscale. Akibatnya dispatch ditolak 422 / sesi tidak
#  pernah mempublikasikan endpoint. Script ini menutup celah itu.
#
#  Dua mode:
#   A) PORTMAP_OVPN_CONFIG berisi .ovpn (dari portmap.io / OpenVPN) ->
#      pasang OpenVPN, sambungkan, lalu ambil host/port dari baris `remote`.
#   B) Tanpa .ovpn -> host+port dari input dipublikasikan apa adanya.
#      Untuk Railway TCP Proxy / bore.pub, endpoint disiapkan di luar runner;
#      script hanya memastikan RDP listening dan menulis status yang benar.
#
#  PERINGATAN: mode ini mengekspos RDP ke jalur publik. Pastikan password kuat
#  (RDP_PASSWORD) dan firewall/ACL tunnel membatasi siapa yang bisa masuk.
#  Tetap kami sarankan Tailscale.
# ============================================================================
$XyTag = 'XyRDP:tunnel'
. "$PSScriptRoot/lib-common.ps1"
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$mode = if ($env:AKSES) { $env:AKSES.Trim().ToLowerInvariant() } else { 'tailscale' }
if ($mode -eq 'tailscale') { Log 'akses=tailscale, tidak ada yang dilakukan'; exit 0 }

$work = 'C:\ProgramData\RdpFree\access'
New-Item -ItemType Directory -Path $work -Force | Out-Null

$hostIn = if ($env:PORTMAP_HOST) { $env:PORTMAP_HOST.Trim() } else { '' }
$portRaw = if ($env:PORTMAP_PORT) { ($env:PORTMAP_PORT -replace '[^0-9]', '').Trim() } else { '' }
$portIn = if ($portRaw) { [int]$portRaw } else { 3389 }
if ($portIn -le 0 -or $portIn -gt 65535) { $portIn = 3389 }

$ovpn = if ($env:PORTMAP_OVPN_CONFIG) { $env:PORTMAP_OVPN_CONFIG.Trim() } else { '' }
$ovpnConnected = $false
$notes = [System.Collections.Generic.List[string]]::new()

# ------------------------------------------------------- 1. Pastikan RDP listen
try {
  & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server' /v fDenyTSConnections /t REG_DWORD /d 0 /f 2>&1 | Out-Null
  Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name TermService -ErrorAction SilentlyContinue
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Out-Null
  $deadline = (Get-Date).AddSeconds(60)
  do {
    $listener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    if ($listener) { break }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  if ($listener) { Log '  RDP 3389 listening' } else { $notes.Add('Listener RDP 3389 belum aktif saat tunnel dibuat') }
} catch { $notes.Add("RDP listener: $($_.Exception.Message)") }

# ------------------------------------------------------------ 2. OpenVPN (jika ada)
if ($ovpn.Length -gt 60 -and $ovpn -match 'client|remote') {
  try {
    $cfg = Join-Path $work 'client.ovpn'
    # .ovpn dari secret bisa datang base64 atau plain — dukung keduanya.
    try {
      $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ovpn))
      if ($decoded -match 'client|remote') { $ovpn = $decoded }
    } catch {}
    Set-Content -Path $cfg -Value $ovpn -Encoding ascii
    Log "  konfigurasi .ovpn ditulis ($($ovpn.Length) karakter)"
    # Ambil endpoint dari baris `remote host port` bila input host kosong.
    if (-not $hostIn) {
      $remoteLine = Get-Content $cfg | Where-Object { $_ -match '^\s*remote\s+' } | Select-Object -First 1
      if ($remoteLine) {
        $parts = ($remoteLine.Trim() -split '\s+')
        $hostIn = $parts[1]
        if ($parts.Count -gt 2 -and $parts[2] -match '^\d+$') { $portIn = [int]$parts[2] }
        Log "  endpoint dari .ovpn: ${hostIn}:${portIn}"
      }
    }
    $openvpnExe = @(
      'C:\Program Files\OpenVPN\bin\openvpn.exe',
      'C:\Program Files (x86)\OpenVPN\bin\openvpn.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $openvpnExe) {
      $winget = Get-Command winget -ErrorAction SilentlyContinue
      if ($winget) {
        Log '  pasang OpenVPN lewat winget...'
        & $winget.Source install --id OpenVPNTechnologies.OpenVPN --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
      }
      $openvpnExe = Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter 'openvpn.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    }
    if ($openvpnExe) {
      $log = Join-Path $work 'openvpn.log'
      $p = Start-Process -FilePath $openvpnExe -ArgumentList @('--config', "`"$cfg`"", '--log', "`"$log`"") -PassThru -WindowStyle Hidden
      $deadline = (Get-Date).AddSeconds(90)
      do {
        Start-Sleep -Seconds 4
        $tap = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'TAP|Wintun|OpenVPN' -and $_.Status -eq 'Up' }
        if ($tap) { $ovpnConnected = $true; break }
        if ($p.HasExited) { break }
      } while ((Get-Date) -lt $deadline)
      if ($ovpnConnected) { Log '  OpenVPN tersambung (adapter TAP/Wintun up)' }
      else { $notes.Add('OpenVPN belum menunjukkan adapter aktif; cek openvpn.log di runner') }
    } else { $notes.Add('OpenVPN tidak terpasang; hanya endpoint eksternal yang dipublikasikan') }
  } catch { $notes.Add("OpenVPN: $($_.Exception.Message)") }
} else {
  $notes.Add('Secret PORTMAP_OVPN_CONFIG kosong — memakai host/port dari input aplikasi')
}

# ------------------------------------------------------- 3. Firewall koneksi masuk
if ($hostIn) {
  try {
    $ruleName = 'XyRDP Public Tunnel RDP 3389'
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
      New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any -ErrorAction Stop | Out-Null
      Log "  firewall: izinkan TCP 3389 untuk tunnel ($mode)"
    }
  } catch { $notes.Add("Firewall: $($_.Exception.Message)") }
}

# ------------------------------------------------------------- 4. Publikasi status
$addr = if ($hostIn) { "${hostIn}:${portIn}" } else { '' }
$state = if ($ovpnConnected -or ($hostIn -and $hostIn -notmatch '^(auto|bore\.pub)$')) { 'ok' } else { 'pending' }
$note = if ($notes.Count) { ($notes -join ' | ') } else { 'Endpoint publik aktif.' }
$note += ' Peringatan: akses publik butuh password RDP kuat; Tailscale lebih aman.'

$access = [ordered]@{
  mode     = $mode
  portmap  = [ordered]@{ status = $state; host = $hostIn; port = $portIn; note = $note }
  tunnel   = [ordered]@{
    status  = $state
    host    = $hostIn
    port    = $portIn
    address = $addr
    selftest = if ($ovpnConnected) { 'ok' } else { 'external' }
    outside = $mode
  }
  tailscale = [ordered]@{ status = 'disabled'; note = "akses=$mode, Tailscale tidak dipakai" }
}
try {
  Update-Status @{ akses = $access } | Out-Null
  $report = [ordered]@{
    status = $state; mode = $mode; host = $hostIn; port = $portIn; address = $addr
    openvpn_connected = $ovpnConnected; notes = @($notes)
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
  }
  $outDir = Join-Path (Get-Workspace) 'out'
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  ($report | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $outDir 'public-tunnel.json') -Encoding utf8
  Log "  status akses publik ditulis: $state $addr"
} catch { Log "  tulis status akses gagal: $($_.Exception.Message)" }

Log "SELESAI — akses ${mode}: ${state} ${addr}"
exit 0

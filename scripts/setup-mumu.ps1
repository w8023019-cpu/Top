# ============================================================================
#  setup-mumu.ps1 — MuMu Player 12 (input: mumu, default tidak)
# ----------------------------------------------------------------------------
#  Sebelum 1.1.28 aplikasi tidak punya opsi MuMu sama sekali; setup-games.ps1
#  hanya menyiapkan MEmu. Script ini menambahkan MuMU sebagai emulator kedua.
#
#  SUMBER INSTALLER: selalu diambil dari halaman unduhan resmi
#  (mumuplayer.com / mumu.163.com). Tidak ada URL pihak ketiga hardcode,
#  supaya link kadaluwarsa tidak bikin step gagal diam-diam.
#
#  KETERBATASAN JUJUR (ditulis ke status & README desktop):
#  runner GitHub Actions Windows umumnya TIDAK mengekspos VT-x/AMD-V
#  (nested virtualization). MuMu bisa terpasang tapi mesin Androidnya bisa
#  gagal boot. Fallback resmi tetap MEmu dari setup-games.ps1, dan status
#  aplikasi menandai ini dengan jelas — tidak diklaim "siap main".
# ============================================================================
$XyTag = 'XyRDP:mumu'
. "$PSScriptRoot/lib-common.ps1"
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$work   = 'C:\ProgramData\XyRDP\mumu'
$outDir = Join-Path (Get-Workspace) 'out'
New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$report = [ordered]@{
  status     = 'skipped'
  installer  = ''
  source     = ''
  exe        = ''
  fallback   = 'MEmu (setup-games.ps1)'
  note       = ''
  updated_at = (Get-Date).ToUniversalTime().ToString('o')
}

function Save-MuMuReport {
  try {
    ($report | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $outDir 'mumu.json') -Encoding utf8
    Update-Status @{ mumu = $report } | Out-Null
  } catch { Log "  tulis laporan MuMu gagal: $($_.Exception.Message)" }
}

function Resolve-OfficialInstaller {
  $pages = @(
    'https://www.mumuplayer.com/download/',
    'https://mumu.163.com/download/'
  )
  $allowed = '(^|\.)(mumuplayer\.com|mumu\.163\.com|gdl\.netease\.com|netease\.com|126\.net|163\.com)$'
  foreach ($page in $pages) {
    try {
      Log "  cek halaman resmi: $page"
      $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
      # Halaman resmi sering menaruh URL dalam bentuk JSON ter-escape
      # (https:\/\/...). Samakan dulu supaya regex sederhana cukup.
      $flat = $html -replace '\\/', '/' -replace '\\u002F', '/' -replace '\\u002f', '/'
      $found = [regex]::Matches($flat, 'https?://[^"''<>\s]+?\.exe', 'IgnoreCase')
      foreach ($m in $found) {
        $u = $m.Value.Trim().TrimEnd(',', ';', ')')
        try {
          $hostName = ([Uri]$u).Host.ToLowerInvariant()
          if ($hostName -match $allowed) { return $u }
        } catch {}
      }
    } catch { Log "  halaman $page gagal dibaca: $($_.Exception.Message)" }
  }
  return $null
}

try {
  # 1. Coba winget lebih dulu (paling aman: paket terverifikasi + hash).
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    try {
      Log '  cari paket MuMu lewat winget...'
      $raw = & $winget.Source search --name 'MuMu' --accept-source-agreements 2>&1 | Out-String
      $lines = $raw -split "`r?`n" | Where-Object { $_ -match 'MuMu' -and $_ -notmatch '^(\s*|-)' }
      $candidate = $lines | Select-Object -First 1
      if ($candidate) {
        $id = ($candidate -split '\s{2,}')[1]
        if ($id) {
          Log "  winget install id=$id"
          & $winget.Source install --id $id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
          if ($LASTEXITCODE -eq 0) {
            $report.source = "winget:$id"
            $report.status = 'installed'
          }
        }
      }
    } catch { Log "  winget gagal: $($_.Exception.Message)" }
  }

  # 2. Kalau winget tidak menyediakan, ambil dari halaman resmi.
  if ($report.status -ne 'installed') {
    $url = Resolve-OfficialInstaller
    if (-not $url) { throw 'link installer resmi MuMu tidak ditemukan di halaman unduhan' }
    $setup = Join-Path $work 'MuMuInstaller.exe'
    Log "  unduh resmi: $url"
    if (-not (Get-File $url $setup 300)) { throw 'unduhan installer MuMu gagal' }
    $sizeMb = [math]::Round((Get-Item $setup).Length / 1MB, 2)
    Log "  installer ${sizeMb} MB di $setup"
    $sig = Get-AuthenticodeSignature $setup -ErrorAction SilentlyContinue
    if ($sig -and $sig.Status -ne 'Valid') { Log "  peringatan: signature installer = $($sig.Status)" }
    $report.installer = $setup
    $report.source = $url

    $proc = Start-Process -FilePath $setup -ArgumentList @('/S', '/norestart') -PassThru -ErrorAction SilentlyContinue
    if ($proc) {
      if (-not $proc.WaitForExit(600000)) {
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        Log '  installer melewati 10 menit -> dihentikan'
      } else { Log "  installer selesai, exit $($proc.ExitCode)" }
      $report.status = 'installed'
    } else { throw 'installer tidak bisa dijalankan' }
  }

  # 3. Cari executable utama + buat shortcut desktop.
  $candidates = @(
    'C:\Program Files\MuMuPlayer\MuMuPlayer.exe',
    'C:\Program Files\MuMuPlayer 12\MuMuPlayer.exe',
    'C:\Program Files\NetEase\MuMuPlayer-12.0\shell\MuMuPlayer.exe',
    'C:\Program Files (x86)\MuMuPlayer\MuMuPlayer.exe',
    'C:\Program Files\NetEase\MuMuPlayer-12.0\shell\MuMuManager.exe'
  )
  $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $exe) {
    $exe = Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter 'MuMuPlayer.exe' -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
  }
  if ($exe) {
    $report.exe = $exe
    try {
      $desk = [Environment]::GetFolderPath('CommonDesktopDirectory')
      $wsh = New-Object -ComObject WScript.Shell
      $lnk = $wsh.CreateShortcut((Join-Path $desk 'MuMu Player 12.lnk'))
      $lnk.TargetPath = $exe
      $lnk.WorkingDirectory = Split-Path $exe -Parent
      $lnk.IconLocation = "$exe,0"
      $lnk.Description = 'MuMu Player 12 — Android Emulator (XyRDP)'
      $lnk.Save()
      Log "  shortcut dibuat -> $exe"
    } catch { Log "  shortcut gagal: $($_.Exception.Message)" }
  }

  $report.note = 'Terpasang. Runner GitHub umumnya tanpa VT-x/AMD-V sehingga mesin Android bisa gagal boot; fallback MEmu sudah disiapkan setup-games.ps1. Cek Hardware Acceleration di menu MuMu bila tersedia.'
  $report.status = 'ready'
  Save-MuMuReport

  # 4. README jujur di desktop (biar user nggak bingung kalau emulator gagal boot).
  try {
    $desk = [Environment]::GetFolderPath('CommonDesktopDirectory')
    @(
      'MuMu Player 12 — XyRDP',
      '',
      'Emulator Android kedua (MEmu tetap tersedia sebagai fallback).',
      'Runner GitHub Actions biasanya tidak punya virtualisasi sarang (VT-x/AMD-V).',
      'Kalau MuMu gagal boot:',
      '  1) Buka Settings > Engine, matikan Hardware Acceleration / pakai mode kompatibilitas.',
      '  2) Atau pakai shortcut MEmu di folder C:\Games\MEmu.',
      '  3) Untuk game berat, jalankan langsung di Windows (RDP) tanpa emulator.',
      '',
      "Status: $($report.status) | Fallback: $($report.fallback)"
    ) | Set-Content -Path (Join-Path $desk 'MuMu - Baca Dulu.txt') -Encoding utf8
  } catch {}
} catch {
  $report.status = 'fallback'
  $report.note = "MuMu tidak dapat dipasang otomatis: $($_.Exception.Message). MEmu dari setup-games.ps1 tetap tersedia."
  Log "  GAGAL: $($_.Exception.Message)"
  Save-MuMuReport
}

Log "SELESAI — MuMu: $($report.status)"
exit 0

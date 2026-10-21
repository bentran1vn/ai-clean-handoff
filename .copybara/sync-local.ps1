# Launcher cho Windows: gọi sync-local.sh bằng Git Bash (dùng chung git credential của Windows).
# Ví dụ:
#   .\.copybara\sync-local.ps1
#   .\.copybara\sync-local.ps1 --push
#   .\.copybara\sync-local.ps1 --init 1a2b3c4
#
# Nếu Copybara gặp lỗi path trên Windows, chạy trong WSL thay thế:
#   wsl ./.copybara/sync-local.sh
# (WSL cần cài riêng git credential, Java 25, Node + Claude Code bên trong WSL)

$ErrorActionPreference = "Stop"

$candidates = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
  "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $bash) {
  # Tránh C:\Windows\System32\bash.exe (đó là WSL, không phải Git Bash)
  $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue |
         Where-Object { $_.Source -notlike "*\System32\*" } | Select-Object -First 1
  if ($cmd) { $bash = $cmd.Source }
}

if (-not $bash) {
  Write-Error "Không tìm thấy Git Bash. Cài Git for Windows: https://git-scm.com/download/win"
  exit 1
}

$script = (Join-Path $PSScriptRoot "sync-local.sh") -replace '\\', '/'
& $bash $script @args
exit $LASTEXITCODE

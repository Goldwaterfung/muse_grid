param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$AppVersion,
    [string]$BuildDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $BuildDirectory) {
    $BuildDirectory = Join-Path $repoRoot 'build\windows\x64\runner\Release'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot 'build\installer'
}
if (-not [System.IO.Path]::IsPathRooted($BuildDirectory)) {
    $BuildDirectory = Join-Path $repoRoot $BuildDirectory
}
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot $OutputDirectory
}
$BuildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$iconPath = Join-Path $repoRoot 'windows\runner\resources\app_icon.ico'

if (-not (Test-Path (Join-Path $BuildDirectory 'muse_grid.exe'))) {
    throw "Flutter Windows release output was not found at '$BuildDirectory'. Run 'flutter build windows --release' first."
}
if (-not (Test-Path $iconPath)) {
    throw "Windows app icon was not found at '$iconPath'."
}

$compiler = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
if ($compiler) {
    $compilerPath = $compiler.Source
} else {
    $knownPaths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    $compilerPath = $knownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $compilerPath) {
    throw 'Inno Setup 6 was not found. Install it or add ISCC.exe to PATH.'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$installerPath = Join-Path $OutputDirectory "muse-grid-windows-$AppVersion-setup.exe"
$installerDefinition = Join-Path $PSScriptRoot 'windows_installer.iss'

& $compilerPath `
    "/DAppVersion=$AppVersion" `
    "/DBuildDirectory=$BuildDirectory" `
    "/DOutputDirectory=$OutputDirectory" `
    "/DIconPath=$iconPath" `
    $installerDefinition
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path $installerPath)) {
    throw "Inno Setup completed without creating '$installerPath'."
}

Write-Output "Created $installerPath"

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Installer
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$buildDir = Join-Path $root "build"
$distDir = Join-Path $root "dist"
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    throw "C# compiler tidak ditemukan: $csc"
}

if ($Clean) {
    foreach ($path in @($buildDir, $distDir)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

New-Item -ItemType Directory -Path $buildDir, $distDir -Force | Out-Null

$source = Join-Path $root "desktop\Skiptify.Desktop.cs"
$logo = Join-Path $root "Skiptify Logo.png"
$icon = Join-Path $root "Skiptify.ico"
if (-not (Test-Path -LiteralPath $logo -PathType Leaf)) {
    throw "Logo tidak ditemukan: $logo"
}
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) {
    throw "Ikon aplikasi tidak ditemukan: $icon"
}
$output = Join-Path $distDir "Skiptify.exe"
$references = @(
    "System.dll",
    "System.Core.dll",
    "System.Drawing.dll",
    "System.Runtime.Serialization.dll",
    "System.Windows.Forms.dll"
) | ForEach-Object { "/reference:$($_)" }

$resource = "/resource:$logo,SkiptifyDesktop.SkiptifyLogo"
$win32Icon = "/win32icon:$icon"
& $csc /nologo /target:winexe /platform:x64 /optimize+ /debug- /out:$output $win32Icon $resource @references $source
if ($LASTEXITCODE -ne 0) {
    throw "Kompilasi Skiptify gagal dengan kode $LASTEXITCODE."
}

Copy-Item -LiteralPath $output -Destination (Join-Path $buildDir "Skiptify.exe") -Force
Copy-Item -LiteralPath $icon -Destination (Join-Path $distDir "Skiptify.ico") -Force
Copy-Item -LiteralPath (Join-Path $root "desktop\App.config") -Destination (Join-Path $distDir "Skiptify.exe.config") -Force
Copy-Item -LiteralPath (Join-Path $root "desktop\App.config") -Destination (Join-Path $buildDir "Skiptify.exe.config") -Force

Copy-Item -LiteralPath (Join-Path $root "skiptify\skiptify.ps1") -Destination (Join-Path $distDir "skiptify.ps1") -Force
Copy-Item -LiteralPath (Join-Path $root "skiptify\Start Skiptify.vbs") -Destination (Join-Path $distDir "Start Skiptify.vbs") -Force
Copy-Item -LiteralPath (Join-Path $root "skiptify\Stop Skiptify.vbs") -Destination (Join-Path $distDir "Stop Skiptify.vbs") -Force

if ($Installer) {
    $isccCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    )
    $iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $iscc) {
        throw "Inno Setup 6 tidak ditemukan. Instal Inno Setup lalu jalankan .\build.ps1 -Installer."
    }
    & $iscc (Join-Path $root "installer\Skiptify.iss")
    if ($LASTEXITCODE -ne 0) {
        throw "Pembuatan installer gagal dengan kode $LASTEXITCODE."
    }
}

Write-Host "Build selesai: $output"

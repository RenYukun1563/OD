param(
    [ValidateSet("deps", "opendtect", "all")]
    [string]$Target = "all"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Resolve-Path (Join-Path $ScriptDir "..\..")
$CiDir = Join-Path $RootDir ".ci"
$DepsRoot = if ($env:DEPS_ROOT) { $env:DEPS_ROOT } else { Join-Path $CiDir "deps\od8-windows-x64" }
$BuildRoot = if ($env:BUILD_ROOT) { $env:BUILD_ROOT } else { Join-Path $CiDir "build" }
$InstallRoot = if ($env:INSTALL_ROOT) { $env:INSTALL_ROOT } else { Join-Path $CiDir ("install\OpendTect-{0}-windows-x64" -f ($(if ($env:ODT_VERSION) { $env:ODT_VERSION } else { "8.0" }))) }
$ArtifactRoot = if ($env:ARTIFACT_ROOT) { $env:ARTIFACT_ROOT } else { Join-Path $CiDir "artifacts" }

$QtVersion = if ($env:QT_VERSION) { $env:QT_VERSION } else { "6.8.3" }
$OsgVersion = if ($env:OSG_VERSION) { $env:OSG_VERSION } else { "3.6.5" }
$ProjVersion = if ($env:PROJ_VERSION) { $env:PROJ_VERSION } else { "9.6.0" }
$SqliteVersion = if ($env:SQLITE_VERSION) { $env:SQLITE_VERSION } else { "3490100" }
$Hdf5Version = if ($env:HDF5_VERSION) { $env:HDF5_VERSION } else { "1.14.6" }
$ZlibVersion = if ($env:ZLIB_VERSION) { $env:ZLIB_VERSION } else { "1.3.1" }
$BuildType = if ($env:BUILD_TYPE) { $env:BUILD_TYPE } else { "Release" }
$Parallel = if ($env:PARALLEL) { [int]$env:PARALLEL } else { [Environment]::ProcessorCount }
$OdtVersion = if ($env:ODT_VERSION) { $env:ODT_VERSION } else { "8.0" }

$QtRoot = Join-Path $DepsRoot "Qt\$QtVersion\msvc2022_64"
$SqliteRoot = Join-Path $DepsRoot "sqlite"
$ProjRoot = Join-Path $DepsRoot "proj"
$Hdf5Root = Join-Path $DepsRoot "hdf5"
$OsgRoot = Join-Path $DepsRoot "osg"
$ZlibRoot = Join-Path $DepsRoot "zlib"
$SourceRoot = Join-Path $DepsRoot "src"

New-Item -ItemType Directory -Force -Path $DepsRoot, $BuildRoot, $InstallRoot, $ArtifactRoot, $SourceRoot | Out-Null

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [object[]]$Arguments = @()
    )

    Write-Host ">> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

function Get-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    if (Test-Path -LiteralPath $OutFile) {
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    Invoke-Native curl.exe @("-L", "--fail", "--retry", "5", "--retry-delay", "5", $Url, "-o", $OutFile)
}

function Expand-CleanArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    if ($Archive.EndsWith(".zip", [StringComparison]::OrdinalIgnoreCase)) {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
    }
    else {
        Invoke-Native tar.exe @("-xf", $Archive, "-C", $Destination, "--strip-components=1")
    }
}

function Find-CMakeSourceRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath (Join-Path $Path "CMakeLists.txt")) {
        return $Path
    }

    $candidate = Get-ChildItem -LiteralPath $Path -Recurse -Filter CMakeLists.txt -File |
        Where-Object { $_.FullName.Substring($Path.Length).TrimStart('\').Split('\').Count -le 3 } |
        Select-Object -First 1

    if (-not $candidate) {
        throw "Cannot find CMakeLists.txt under $Path"
    }

    return $candidate.Directory.FullName
}

function Invoke-CMakeBuildInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Build,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [string[]]$ExtraArgs = @()
    )

    $configureArgs = @(
        "-S", $Source,
        "-B", $Build,
        "-G", "Ninja Multi-Config",
        "-DCMAKE_INSTALL_PREFIX=$Prefix",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
    ) + $ExtraArgs
    Invoke-Native cmake $configureArgs
    Invoke-Native cmake @("--build", $Build, "--config", $BuildType, "--parallel", $Parallel)
    Invoke-Native cmake @("--install", $Build, "--config", $BuildType)
}

function Install-Qt {
    $stamp = Join-Path $QtRoot ".od-qt-$QtVersion.stamp"
    if (Test-Path -LiteralPath $stamp) {
        return
    }

    Invoke-Native python @("-m", "pip", "install", "--upgrade", "pip", "aqtinstall")
    Invoke-Native python @(
        "-m", "aqt", "install-qt", "windows", "desktop", $QtVersion, "win64_msvc2022_64",
        "-O", (Join-Path $DepsRoot "Qt"),
        "-m", "qtcharts", "qtpositioning", "qtwebchannel", "qtwebengine", "qtimageformats"
    )
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

function Install-Sqlite {
    $stamp = Join-Path $SqliteRoot ".od-sqlite-$SqliteVersion-tools.stamp"
    if (Test-Path -LiteralPath $stamp) {
        return
    }

    $amalgamationZip = Join-Path $SourceRoot "sqlite-amalgamation-$SqliteVersion.zip"
    $dllZip = Join-Path $SourceRoot "sqlite-dll-win-x64-$SqliteVersion.zip"
    $toolsZip = Join-Path $SourceRoot "sqlite-tools-win-x64-$SqliteVersion.zip"
    Get-File "https://www.sqlite.org/2025/sqlite-amalgamation-$SqliteVersion.zip" $amalgamationZip
    Get-File "https://www.sqlite.org/2025/sqlite-dll-win-x64-$SqliteVersion.zip" $dllZip
    Get-File "https://www.sqlite.org/2025/sqlite-tools-win-x64-$SqliteVersion.zip" $toolsZip

    $sqliteSrc = Join-Path $BuildRoot "sqlite-src"
    $sqliteDll = Join-Path $BuildRoot "sqlite-dll"
    $sqliteTools = Join-Path $BuildRoot "sqlite-tools"
    Expand-CleanArchive $amalgamationZip $sqliteSrc
    Expand-CleanArchive $dllZip $sqliteDll
    Expand-CleanArchive $toolsZip $sqliteTools

    $headersDirItem = Get-ChildItem -LiteralPath $sqliteSrc -Directory | Select-Object -First 1
    $headersDir = if ($headersDirItem) { $headersDirItem.FullName } else { $sqliteSrc }

    New-Item -ItemType Directory -Force -Path `
        (Join-Path $SqliteRoot "include"), `
        (Join-Path $SqliteRoot "lib"), `
        (Join-Path $SqliteRoot "bin") | Out-Null

    Copy-Item -LiteralPath (Join-Path $headersDir "sqlite3.h") -Destination (Join-Path $SqliteRoot "include") -Force
    Copy-Item -LiteralPath (Join-Path $headersDir "sqlite3ext.h") -Destination (Join-Path $SqliteRoot "include") -Force
    $dllFile = Get-ChildItem -LiteralPath $sqliteDll -Recurse -Filter sqlite3.dll | Select-Object -First 1
    $defFileItem = Get-ChildItem -LiteralPath $sqliteDll -Recurse -Filter sqlite3.def | Select-Object -First 1
    $exeFile = Get-ChildItem -LiteralPath $sqliteTools -Recurse -Filter sqlite3.exe | Select-Object -First 1
    if (-not $dllFile -or -not $defFileItem -or -not $exeFile) {
        throw "SQLite archives did not contain sqlite3.dll, sqlite3.def, and sqlite3.exe"
    }

    Copy-Item -LiteralPath $dllFile.FullName -Destination (Join-Path $SqliteRoot "bin\sqlite3.dll") -Force
    Copy-Item -LiteralPath $exeFile.FullName -Destination (Join-Path $SqliteRoot "bin\sqlite3.exe") -Force

    $defFile = $defFileItem.FullName
    Invoke-Native lib.exe @("/nologo", "/def:$defFile", "/machine:x64", "/out:$(Join-Path $SqliteRoot 'lib\sqlite3.lib')")
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

function Build-Proj {
    $stamp = Join-Path $ProjRoot ".od-proj-$ProjVersion.stamp"
    if (Test-Path -LiteralPath $stamp) {
        return
    }

    $tarball = Join-Path $SourceRoot "proj-$ProjVersion.tar.gz"
    Get-File "https://download.osgeo.org/proj/proj-$ProjVersion.tar.gz" $tarball
    $projSrc = Join-Path $BuildRoot "proj-src"
    Expand-CleanArchive $tarball $projSrc
    $projCmakeSrc = Find-CMakeSourceRoot $projSrc

    Invoke-CMakeBuildInstall $projCmakeSrc (Join-Path $BuildRoot "proj") $ProjRoot @(
        "-DBUILD_SHARED_LIBS=ON",
        "-DSQLite3_ROOT=$SqliteRoot",
        "-DEXE_SQLITE3=$(Join-Path $SqliteRoot 'bin\sqlite3.exe')",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_APPS=OFF",
        "-DENABLE_CURL=OFF",
        "-DENABLE_TIFF=OFF",
        "-DENABLE_NETWORK=OFF"
    )
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

function Build-Hdf5 {
    $stamp = Join-Path $Hdf5Root ".od-hdf5-$Hdf5Version.stamp"
    if (Test-Path -LiteralPath $stamp) {
        return
    }

    $tarball = Join-Path $SourceRoot "hdf5-$Hdf5Version.tar.gz"
    Get-File "https://github.com/HDFGroup/hdf5/releases/download/hdf5_$Hdf5Version/hdf5-$Hdf5Version.tar.gz" $tarball
    $hdf5Src = Join-Path $BuildRoot "hdf5-src"
    Expand-CleanArchive $tarball $hdf5Src
    $hdf5CmakeSrc = Find-CMakeSourceRoot $hdf5Src

    Invoke-CMakeBuildInstall $hdf5CmakeSrc (Join-Path $BuildRoot "hdf5") $Hdf5Root @(
        "-DBUILD_SHARED_LIBS=ON",
        "-DZLIB_ROOT=$ZlibRoot",
        "-DZLIB_LIBRARY=$(Join-Path $ZlibRoot 'lib\zlib.lib')",
        "-DZLIB_INCLUDE_DIR=$(Join-Path $ZlibRoot 'include')",
        "-DHDF5_ENABLE_Z_LIB_SUPPORT=ON",
        "-DHDF5_ENABLE_SZIP_SUPPORT=OFF",
        "-DHDF5_ENABLE_SZIP_ENCODING=OFF",
        "-DHDF5_BUILD_CPP_LIB=ON",
        "-DHDF5_BUILD_HL_LIB=OFF",
        "-DHDF5_BUILD_TOOLS=OFF",
        "-DHDF5_BUILD_EXAMPLES=OFF",
        "-DHDF5_BUILD_FORTRAN=OFF",
        "-DHDF5_INSTALL_CMAKE_DIR=cmake/hdf5",
        "-DBUILD_TESTING=OFF"
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Hdf5Root "cmake\hdf5\hdf5-config.cmake"))) {
        throw "HDF5 CMake package was not installed under $Hdf5Root\cmake\hdf5"
    }
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

function Build-Zlib {
    $stamp = Join-Path $ZlibRoot ".od-zlib-$ZlibVersion.stamp"
    if (Test-Path -LiteralPath $stamp) {
        return
    }

    $tarball = Join-Path $SourceRoot "zlib-$ZlibVersion.tar.gz"
    Get-File "https://github.com/madler/zlib/archive/refs/tags/v$ZlibVersion.tar.gz" $tarball
    $zlibSrc = Join-Path $BuildRoot "zlib-src"
    Expand-CleanArchive $tarball $zlibSrc
    $zlibCmakeSrc = Find-CMakeSourceRoot $zlibSrc

    Invoke-CMakeBuildInstall $zlibCmakeSrc (Join-Path $BuildRoot "zlib") $ZlibRoot @(
        "-DBUILD_SHARED_LIBS=ON"
    )

    if (-not (Test-Path -LiteralPath (Join-Path $ZlibRoot "lib\zlib.lib"))) {
        throw "zlib import library was not installed under $ZlibRoot\lib"
    }
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

function Build-Osg {
    $stamp = Join-Path $OsgRoot ".od-osg-$OsgVersion.stamp"
    if (Test-Path -LiteralPath $stamp) {
        return
    }

    $tarball = Join-Path $SourceRoot "OpenSceneGraph-$OsgVersion.tar.gz"
    Get-File "https://github.com/openscenegraph/OpenSceneGraph/archive/OpenSceneGraph-$OsgVersion.tar.gz" $tarball
    $osgSrc = Join-Path $BuildRoot "osg-src"
    Expand-CleanArchive $tarball $osgSrc
    Patch-OsgMsvcFpos $osgSrc
    $osgCmakeSrc = Find-CMakeSourceRoot $osgSrc

    Invoke-CMakeBuildInstall $osgCmakeSrc (Join-Path $BuildRoot "osg") $OsgRoot @(
        "-DBUILD_SHARED_LIBS=ON",
        "-DDYNAMIC_OPENSCENEGRAPH=ON",
        "-DBUILD_OSG_APPLICATIONS=OFF",
        "-DBUILD_OSG_EXAMPLES=OFF",
        "-DBUILD_DOCUMENTATION=OFF"
    )
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

function Patch-OsgMsvcFpos {
    param([Parameter(Mandatory = $true)][string]$OsgSourceRoot)

    $archiveCpp = Join-Path $OsgSourceRoot "src\osgPlugins\osga\OSGA_Archive.cpp"
    if (-not (Test-Path -LiteralPath $archiveCpp)) {
        throw "Cannot find OpenSceneGraph OSGA_Archive.cpp under $OsgSourceRoot"
    }

    $oldLine = "std::streamoff offset = pos.operator std::streamoff( ) - _FPOSOFF( position );"
    $newLine = "std::streamoff offset = 0;"
    $content = Get-Content -Raw -LiteralPath $archiveCpp
    if ($content.Contains($oldLine)) {
        $content = $content.Replace($oldLine, $newLine)
        Set-Content -LiteralPath $archiveCpp -Encoding ASCII -Value $content
    }
    elseif (-not $content.Contains($newLine)) {
        throw "OpenSceneGraph OSGA_Archive.cpp did not match the expected _FPOSOFF patch context."
    }
}

function Build-Deps {
    Install-Qt
    Install-Sqlite
    Build-Proj
    Build-Zlib
    Build-Hdf5
    Build-Osg
}

function Copy-RuntimeDlls {
    param([Parameter(Mandatory = $true)][string]$RuntimeDir)

    foreach ($dir in @(
        (Join-Path $QtRoot "bin"),
        (Join-Path $OsgRoot "bin"),
        (Join-Path $ProjRoot "bin"),
        (Join-Path $SqliteRoot "bin"),
        (Join-Path $Hdf5Root "bin"),
        (Join-Path $ZlibRoot "bin")
    )) {
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Filter *.dll -File | Copy-Item -Destination $RuntimeDir -Force
        }
    }
}

function Build-OpendTect {
    $env:Path = "$QtRoot\bin;$OsgRoot\bin;$ProjRoot\bin;$SqliteRoot\bin;$Hdf5Root\bin;$ZlibRoot\bin;$env:Path"
    $prefixPath = @($QtRoot, $OsgRoot, $ProjRoot, $SqliteRoot, $Hdf5Root, $ZlibRoot) -join ';'
    $odBuild = Join-Path $BuildRoot "opendtect"
    $packageRoot = Join-Path $ArtifactRoot "packages"

    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $InstallRoot, $packageRoot | Out-Null

    Invoke-Native cmake @(
        "-S", $RootDir,
        "-B", $odBuild,
        "-G", "Ninja Multi-Config",
        "-DCMAKE_INSTALL_PREFIX=$InstallRoot",
        "-DPACKAGE_DIR=$packageRoot",
        "-DCMAKE_PREFIX_PATH=$prefixPath",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL",
        "-DQT_ROOT=$QtRoot",
        "-DOSG_ROOT=$OsgRoot",
        "-DPROJ_ROOT=$ProjRoot",
        "-DSQLite3_ROOT=$SqliteRoot",
        "-DHDF5_ROOT=$Hdf5Root",
        "-DHDF5_DIR=$(Join-Path $Hdf5Root 'cmake\hdf5')",
        "-DZLIB_ROOT=$ZlibRoot",
        "-DZLIB_LIBRARY=$(Join-Path $ZlibRoot 'lib\zlib.lib')",
        "-DOD_NO_PROJ=OFF",
        "-DOD_NO_OSG=OFF",
        "-DOD_NO_QT=OFF",
        "-DOD_NO_QSQL=OFF",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_DOCUMENTATION=OFF",
        "-DBUILD_USERDOC=OFF",
        "-DUSE_QtWebEngine=ON"
    )

    Invoke-Native cmake @("--build", $odBuild, "--config", $BuildType, "--parallel", $Parallel)
    Invoke-Native cmake @("--install", $odBuild, "--config", $BuildType)

    $runtimeDir = Join-Path $InstallRoot "bin\win64\$BuildType"
    Copy-RuntimeDlls $runtimeDir

    $odMain = Join-Path $runtimeDir "od_main.exe"
    if (-not (Test-Path -LiteralPath $odMain)) {
        throw "Cannot find od_main.exe in $runtimeDir"
    }

    $hdf5Plugin = Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter "ODHDF5.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hdf5Plugin) {
        throw "ODHDF5 plugin was not built into the portable bundle."
    }

    $cmdLauncher = Join-Path $InstallRoot "run-opendtect.cmd"
    Set-Content -LiteralPath $cmdLauncher -Encoding ASCII -Value @(
        "@echo off",
        "setlocal",
        "set HERE=%~dp0",
        "set PATH=%HERE%bin\win64\$BuildType;%PATH%",
        "start ""OpendTect"" ""%HERE%bin\win64\$BuildType\od_main.exe"" %*"
    )

    $zipName = "OpendTect-$OdtVersion-windows-x64.zip"
    $zipPath = Join-Path $ArtifactRoot $zipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Push-Location (Split-Path -Parent $InstallRoot)
    try {
        Invoke-Native 7z @("a", "-tzip", "-mx5", $zipPath, (Split-Path -Leaf $InstallRoot))
    }
    finally {
        Pop-Location
    }

    if ($env:BUILD_OFFICIAL_PACKAGES -eq "1") {
        try {
            Invoke-Native cmake @("--build", $odBuild, "--config", $BuildType, "--target", "packages", "--parallel", $Parallel)
            Get-ChildItem -LiteralPath $packageRoot -File -ErrorAction SilentlyContinue |
                Copy-Item -Destination $ArtifactRoot -Force
        }
        catch {
            Write-Warning "OpendTect packages target failed; portable zip was still created. $($_.Exception.Message)"
            $global:LASTEXITCODE = 0
        }
    }
    else {
        Write-Host "Skipping optional OpendTect packages target. Portable zip was created at $zipPath."
        $global:LASTEXITCODE = 0
    }
}

switch ($Target) {
    "deps" { Build-Deps }
    "opendtect" { Build-OpendTect }
    "all" {
        Build-Deps
        Build-OpendTect
    }
}

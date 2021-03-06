Param(
    [switch] $Release,
    [string] $SigningCertThumbprint,
    [string] $TimestampServer
)

$ErrorActionPreference = 'Stop'

# Options
$configuration = 'Release'
$artifactsDir = Join-Path (Resolve-Path .) 'artifacts'
$packagesDir = Join-Path $artifactsDir 'Packages'
$testResultsDir = Join-Path $artifactsDir 'Test results'

# Detection
. $PSScriptRoot\build\Get-DetectedCiVersion.ps1
$versionInfo = Get-DetectedCiVersion -Release:$Release
Update-CiServerBuildName $versionInfo.ProductVersion
Write-Host "Building using version $($versionInfo.ProductVersion)"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$visualStudioInstallation = & $vswhere -latest -version [16,] -requires Microsoft.Component.MSBuild -products * -property installationPath
if (!$visualStudioInstallation) { throw 'Cannot find installation of Visual Studio 2019 or newer.' }
$msbuild = Join-Path $visualStudioInstallation 'MSBuild\Current\Bin\MSBuild.exe'
$vstest = Join-Path $visualStudioInstallation 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\VSTest.Console.exe'

$msbuildArgs = @(
    '/p:PackageOutputPath=' + $packagesDir
    '/p:RepositoryCommit=' + $versionInfo.CommitHash
    '/p:Version=' + $versionInfo.ProductVersion
    '/p:PackageVersion=' + $versionInfo.PackageVersion
    '/p:FileVersion=' + $versionInfo.FileVersion
    '/p:Configuration=' + $configuration
    '/v:minimal'
)

# Build
& $msbuild /t:build /restore @msbuildArgs
if ($LastExitCode) { exit 1 }

if ($SigningCertThumbprint) {
    . build\SignTool.ps1
    SignTool $SigningCertThumbprint $TimestampServer (
        Get-ChildItem src\AmbientTasks\bin\$configuration -Recurse -Include AmbientTasks.dll)
}

# Pack
Remove-Item -Recurse -Force $packagesDir -ErrorAction Ignore

& $msbuild /t:pack /p:NoBuild=true @msbuildArgs
if ($LastExitCode) { exit 1 }

if ($SigningCertThumbprint) {
    # Hoping to use dotnet tool instead of this (https://github.com/NuGet/Home/issues/8263)
    $nuget = 'tools\nuget.exe'
    if (-not (Test-Path $nuget)) {
        New-Item -ItemType Directory -Force -Path tools
        Invoke-WebRequest -Uri https://dist.nuget.org/win-x86-commandline/latest/nuget.exe -OutFile $nuget
    }

    foreach ($package in Get-ChildItem -Recurse $packagesDir -Include *.nupkg) {
        & $nuget sign $package -CertificateFingerprint $SigningCertThumbprint -Timestamper $TimestampServer
    }
}

# Test
dotnet tool install altcover.global --tool-path tools
$altcover = 'tools\altcover'

if ($env:CODECOV_TOKEN) {
    dotnet tool install Codecov.Tool --tool-path tools
    $codecov = 'tools\codecov'
}

Remove-Item -Recurse -Force $testResultsDir -ErrorAction Ignore

foreach ($testAssembly in Get-ChildItem -Recurse -Path src\*.Tests\bin\$configuration -Include *.Tests.dll) {
    $directory = Split-Path $testAssembly
    $tfm = (Split-Path -Leaf $directory)

    $savedDirectory = '__Saved'
    Remove-Item -Recurse -Force $savedDirectory -ErrorAction Ignore
    & $altcover --inputDirectory=$directory --inplace --outputDirectory=$savedDirectory --opencover --xmlReport=$testResultsDir\coverage.$tfm.xml --assemblyExcludeFilter='AmbientTasks.Tests|NUnit3.TestAdapter'
    if ($LastExitCode) { exit 1 }
    Remove-Item -Recurse -Force $savedDirectory -ErrorAction Ignore

    & $vstest $testAssembly /Logger:'console;verbosity=minimal' /Logger:"trx;LogFileName=$tfm.trx" /ResultsDirectory:$testResultsDir
    if ($LastExitCode) { $testsFailed = true }

    & $altcover runner --collect --recorderDirectory=$directory
    if ($LastExitCode) { exit 1 }

    if ($env:CODECOV_TOKEN) {
        # Workaround for https://github.com/codecov/codecov-exe/issues/71
        $codecovFullPath = Join-Path (Get-Location) $codecov
        Push-Location $testResultsDir

        & $codecovFullPath --name $tfm --file coverage.$tfm.xml --token $env:CODECOV_TOKEN
        if ($LastExitCode) { exit 1 }

        # Workaround for https://github.com/codecov/codecov-exe/issues/71
        Pop-Location
    }
}

if ($testsFailed) { exit 1 }

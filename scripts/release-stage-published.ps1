[CmdletBinding()]
param(
    # \A and \z rather than ^ and $, and [0-9] rather than \d, for the reasons
    # in package-package-managers.ps1.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string] $Version,

    # The commit of package-package-managers.ps1 the package names as its
    # source (see that script's -PackageSourceRef).
    [ValidatePattern('\A[0-9A-Za-z][0-9A-Za-z._/-]*\z')]
    [string] $PackageSourceRef,

    # An empty or missing directory for the verified download.
    [string] $DownloadDirectory
)

# Rebuilds the package-manager metadata and the Chocolatey package for a
# release that is already published, from the installers on its release page
# and without building anything: the Release workflow cannot be rerun for that
# because it replaces the published assets (docs/chocolatey-publishing.md).
# The release is verified first by the same script the Release workflow ends
# with, so the installers a package names have the checksums, build provenance
# and signer the release promises. Afterwards
# scripts/release-publish-chocolatey.ps1 packs and pushes.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
    $DownloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "noctty-chocolatey-release-$Version-$([guid]::NewGuid().ToString('N'))"
}
$DownloadDirectory = [System.IO.Path]::GetFullPath($DownloadDirectory)

# Throws on any failure: a missing or draft or prerelease release, an unexpected
# asset set, a digest, checksum, provenance or Authenticode mismatch.
& (Join-Path $PSScriptRoot 'verify-published-release.ps1') -Version $Version -DownloadDirectory $DownloadDirectory

# The layout package-package-managers.ps1 and release-publish-chocolatey.ps1
# read: one directory per architecture, the icon beside the x64 files.
$artifactRoot = Join-Path $repoRoot 'dist/artifacts'
$architectures = @(Get-WindowsPackageArchitectures)
foreach ($architecture in $architectures) {
    $architectureDirectory = Join-Path $artifactRoot "noctty-$Version-windows-$architecture"
    New-Item -ItemType Directory -Path $architectureDirectory -Force | Out-Null
    foreach ($kind in @('setup', 'portable', 'checksums')) {
        $name = New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind $kind
        Copy-Item -LiteralPath (Join-Path $DownloadDirectory $name) -Destination (Join-Path $architectureDirectory $name) -Force
    }
}
Copy-Item `
    -LiteralPath (Join-Path $DownloadDirectory 'noctty-icon.svg') `
    -Destination (Join-Path $artifactRoot "noctty-$Version-windows-x64/noctty-icon.svg") `
    -Force

$packageArguments = @{
    Version       = $Version
    Architectures = $architectures
}
if ($PackageSourceRef) {
    $packageArguments.PackageSourceRef = $PackageSourceRef
}
& (Join-Path $PSScriptRoot 'package-package-managers.ps1') @packageArguments

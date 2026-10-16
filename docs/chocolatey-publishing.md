# Publish noctty on Chocolatey

Every stable release builds a Chocolatey package, `noctty`, and the last step of
the `Release` workflow pushes it to the community repository. It has never been
pushed: the step skips with `CHOCO_API_KEY is not configured`, as it did for
1.3.132. Nothing else is missing. On 2026-10-16 no package with the id
`noctty` existed on the community repository (the public feed's
`FindPackagesById()?id='noctty'` returned an empty list), so the id is free to
claim with the first push.

## What the package is

The package downloads the signed Inno Setup installer for the machine's
architecture (x64 or arm64) from the GitHub release, checks it against the
release's SHA-256, and runs it silently. Chocolatey's own uninstaller removes
it through the installer's entry in Apps. The package contains no binaries, so
it needs no `VERIFICATION.txt`. The id is `noctty`, the title `Noctty`, the
license is the repository's MIT `LICENSE` at the release tag, and the icon is
the website's `https://noctty.com/assets/favicon.svg`, because the validator
rejects an icon served from GitHub.

## Steps for the maintainer

1. Create a community account at
   <https://community.chocolatey.org/account/Register> and confirm the email.
   The first push makes that account the package's owner.
2. Sign in, open your account page (<https://community.chocolatey.org/account>)
   and copy your API key.
3. Store it as a secret of the `release` environment only, and paste it at the
   prompt rather than on the command line:

   ```powershell
   gh secret set CHOCO_API_KEY --repo amanthanvi/noctty --env release
   ```

4. Wait for the next stable release; its last step pushes the package. Or, to
   publish 1.3.132 now, run the manual block under "What happens after the
   first push" with `$version = "1.3.132"`: it packs the installers already on
   the release page. Do not rerun the 1.3.132 `Release` run instead. A rerun
   rebuilds the installers and replaces the assets on the release page with
   new bytes whose hashes no longer match the Scoop and WinGet manifests
   already published for 1.3.132. It would also run the workflow and scripts
   as they were at 1.3.132, which push a package naming a GitHub-hosted icon
   that the validator rejects.

## What happens after the first push

Every version on the community repository is reviewed before it is listed. An
automatic validator and an install test start about 30 minutes after the push,
then a human moderator reviews it. Expect weeks, not days, for a first package:
another project recorded 28 and 54 days for its first two approvals in 2026.
Follow the state at `https://community.chocolatey.org/packages/noctty/<version>`
under **Package Status**; `Submitted` means it is still queued.

If a moderator asks for changes, the status turns to **Waiting for
Maintainer** and the email says what to change. The fix goes into
`scripts/package-package-managers.ps1` through a pull request, and Chocolatey
wants the corrected package under the same version. The release workflow
cannot send it: it skips any version the feed already lists, and rerunning a
release would rebuild its installers. Rebuild the package by hand instead,
from the installers already published, with `gh` and `choco` installed and the
fix merged:

```powershell
$version = "1.3.133"   # the version the moderator asked about
$ErrorActionPreference = "Stop"
function Assert-Exit([string] $What) { if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" } }
git switch main; Assert-Exit "git switch"
git pull --ff-only; Assert-Exit "git pull"
$generator = (git rev-parse HEAD).Trim(); Assert-Exit "git rev-parse"
foreach ($arch in "x64", "arm64") {
    gh release download "v$version" --repo amanthanvi/noctty --dir "dist/artifacts/noctty-$version-windows-$arch" --clobber `
        --pattern "noctty-$version-windows-$arch-setup.exe" `
        --pattern "noctty-$version-windows-$arch-portable.zip" `
        --pattern "SHA256SUMS-windows-$arch.txt"
    Assert-Exit "gh release download ($arch)"
}
gh release download "v$version" --repo amanthanvi/noctty --dir "dist/artifacts/noctty-$version-windows-x64" --clobber --pattern "noctty-icon.svg"
Assert-Exit "gh release download (icon)"
./scripts/package-package-managers.ps1 -Version $version -Architectures x64, arm64 -PackageSourceRef $generator
$out = "dist/artifacts/chocolatey-$(Get-Date -Format yyyyMMddHHmmss)"
choco pack "dist/artifacts/noctty-$version-windows-x64/package-managers/chocolatey/noctty.nuspec" --output-directory $out
Assert-Exit "choco pack"
$key = Read-Host -Prompt "Chocolatey API key" -AsSecureString
choco push "$out/noctty.$version.nupkg" --source https://push.chocolatey.org/ --api-key ([Net.NetworkCredential]::new("", $key).Password)
Assert-Exit "choco push"
```

The package script checks every downloaded installer against the release's
`SHA256SUMS` before it writes the checksums into the package, so the
resubmitted package installs exactly the bytes on the release page. Its
`packageSourceUrl` names the commit of the generator that built it, so a
moderator can reproduce the corrected package; every other link still points
at the original release.

Until a first version is approved, Chocolatey refuses every further push with
`403`: one of the causes it documents is "Package has a version in moderation
and no approved versions"
([common errors](https://docs.chocolatey.org/en-us/community-repository/maintainers/common-errors/)).
The releases in that window still publish everywhere else. The Chocolatey step
runs last so that it cannot hold back WinGet; it fails, the run turns red, and
its message names the possible causes of a `403`. Those versions simply never
reach Chocolatey, and the first release after the approval pushes again.

A `403` can also mean an invalid or revoked API key, or that another account
owns the id. A `409 Conflict` is treated as success only when the feed then
holds the version, because Chocolatey also answers `409` for a package that
fails its basic validation.

$ErrorActionPreference = 'Stop'
$repository = 'WOLF5ER/NewLook'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('NewLook-release-' + [guid]::NewGuid())
$asset = Join-Path $temporary 'NewLook.exe'
$report = Join-Path $temporary 'smoke.txt'

Push-Location $PSScriptRoot
try {
    if (git status --porcelain) { throw 'Commit the release sources before publishing.' }
    $commit = git rev-parse HEAD
    if ($LASTEXITCODE) { throw 'Could not resolve the local commit.' }
    $remote = gh api "repos/$repository/commits/main" --jq .sha
    if ($LASTEXITCODE -or $remote -ne $commit) { throw "Push this commit to $repository main before publishing." }
    $version = Get-Content -LiteralPath .\VERSION -TotalCount 1
    $tag = "v$version"
    [void][IO.Directory]::CreateDirectory($temporary)
    & .\Build-NewLook.ps1 -OutputPath $asset -Version $version
    $process = Start-Process -FilePath $asset -ArgumentList ('--smoke-test "' + $report + '"') -PassThru
    if (!$process.WaitForExit(30000)) {
        $process.Kill()
        throw 'The EXE smoke test timed out.'
    }
    if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Encoding UTF8 }
    if ($process.ExitCode) { throw 'The EXE smoke test failed.' }
    gh release create $tag $asset --repo $repository --target $commit --title "NewLook $version" --notes "Windows 10/11. Download NewLook.exe to launch NewLook. Local data is preserved on update."
    if ($LASTEXITCODE) { throw 'GitHub did not publish the release.' }
} finally {
    Pop-Location
    foreach ($file in $asset, $report) {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary) }
}

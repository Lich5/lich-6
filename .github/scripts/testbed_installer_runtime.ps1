param([Parameter(Mandatory = $true)][ValidateSet('Acquire', 'Install')][string]$Stage)

# Disposable installer parity setup. Retire this helper with the accepted native
# Windows receipt, when testbed/webui-65175b76-20261111 is retired; never merge it.
$ErrorActionPreference = 'Stop'
$repository = 'elanthia-online/Ruby4Lich5'
$sourceSha = '213d91fbf4389a701c148135828167645f88efb7'
$sourceDigest = 'f10dd860021ecd9e4b7d0368a60194ddbf863ecaa0e9e6219f179d975a3af56d'
$candidateTag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-42439882153-1'
$manifestDigest = 'sha256:f25737c70e4fbb347bb9a6ffad8f6aff644679d85c61f40c59fae022914bcb29'
$bundleDigest = 'sha256:9e76eb871c7a02d54b8b8202b9f92e77da35fcda26b94b5dd751a6b781a4d1fb'
$rubyDigest = 'sha256:7e079519349b06c445d6993542ae0b6e186ce1d9f3a24029e4aab004dba3bee2'
$work = Join-Path $env:RUNNER_TEMP 'lich-installer-runtime'
$receipt = Join-Path $env:GITHUB_WORKSPACE 'tmp/windows-webui/runtime-setup'
New-Item -ItemType Directory -Force $work, $receipt | Out-Null
Start-Transcript -Path (Join-Path $receipt "$Stage.log") | Out-Null

try {
  if ($Stage -eq 'Acquire') {
    # Bootstrap only the exact reviewed producer source, then reuse its real
    # acquisition, validation, upstream restoration and bake/smoke recipe.
    $archive = Join-Path $work 'producer.zip'
    Invoke-WebRequest -Uri "https://api.github.com/repos/$repository/zipball/$sourceSha" -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceDigest) {
      throw 'Pinned installer producer source checksum mismatch.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $work 'producer')
  }
  $producer = @(Get-ChildItem -LiteralPath (Join-Path $work 'producer') -Directory)
  if ($producer.Count -ne 1) { throw 'Expected one pinned producer source tree.' }
  $producer = $producer[0].FullName
  . (Join-Path $producer 'accepted-gem-manifest.ps1')
  . (Join-Path $producer 'gem-candidate-bundle.ps1')
  $manifest = Join-Path $receipt 'accepted-gem-manifest.json'
  $bundle = Join-Path $work 'gembundle'

  if ($Stage -eq 'Acquire') {
    $provenance = Join-Path $receipt 'installer-provenance.json'
    Invoke-VerifiedDownload -Url "https://github.com/$repository/releases/download/R4L5-v040.004.006/installer-provenance.json" `
      -ExpectedDigest 'sha256:db923fc6dd9c552d0ea6ac56bb6118a0265d0f7857d4369a39b97ca6ccae2df2' -DestinationPath $provenance | Out-Null
    Read-LiveAcceptedGemManifest -Repository $repository -DestinationPath $manifest -ExpectedDigest $manifestDigest | Out-Null
    $releaseJson = Invoke-CandidateGh -Arguments @('api', "repos/$repository/releases/tags/$candidateTag")
    $releaseJson | Set-Content (Join-Path $receipt 'candidate-release.json') -Encoding utf8
    $release = $releaseJson | ConvertFrom-Json
    $selection = Resolve-AcceptedGemCandidate -Release $release -AcceptedManifestPath $manifest -Repository $repository -Tag $candidateTag
    if ($selection.archive_digest -cne $bundleDigest -or $selection.source_sha -cne '26a2c718165249c73096e7979d4073e5dfee27fc') {
      throw 'Accepted candidate no longer matches the published installer.'
    }
    $zip = Join-Path $work 'accepted-gems.zip'
    Invoke-VerifiedDownload -Url $selection.archive_url -ExpectedDigest $bundleDigest -DestinationPath $zip | Out-Null
    $metadata = Read-AcceptedGemCandidate -Release $release -AcceptedManifestPath $manifest -Repository $repository `
      -Tag $candidateTag -ArchivePath $zip -Directory $bundle -RubySeries '4.0'
    if ($metadata.ruby_installer_version -cne '4.0.9-1') { throw 'Bundle is not the installer Ruby 4.0.9-1 cohort.' }
    Copy-Item (Join-Path $bundle 'gem-build-metadata.json'), (Join-Path $bundle 'resolution-lock.json'), `
      (Join-Path $bundle 'runtime-gems-install-targets.txt'), (Join-Path $bundle 'delivery-map.json') -Destination $receipt
    Invoke-VerifiedDownload -Url 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-4.0.9-1/rubyinstaller-4.0.9-1-x64.exe' `
      -ExpectedDigest $rubyDigest -DestinationPath (Join-Path $work 'rubyinstaller.exe') | Out-Null
    # These pure Ruby test tools are isolated from the baked runtime cohort.
    # SHA-256 values are the existing Gemfile.lock CHECKSUMS, not a new solve.
    $testPackages = [ordered]@{
      'diff-lcs-1.6.2' = '9ae0d2cba7d4df3075fe8cd8602a8604993efc0dfa934cff568969efb1909962'
      'rspec-support-3.13.7' = '0640e5570872aafefd79867901deeeeb40b0c9875a36b983d85f54fb7381c47c'
      'rspec-core-3.13.6' = 'a8823c6411667b60a8bca135364351dda34cd55e44ff94c4be4633b37d828b2d'
      'rspec-expectations-3.13.5' = '33a4d3a1d95060aea4c94e9f237030a8f9eae5615e9bd85718fe3a09e4b58836'
      'rspec-mocks-3.13.8' = '086ad3d3d17533f4237643de0b5c42f04b66348c28bf6b9c2d3f4a3b01af1d47'
      'rspec-3.13.2' = '206284a08ad798e61f86d7ca3e376718d52c0bc944626b2349266f239f820587'
    }
    New-Item -ItemType Directory -Path (Join-Path $work 'test-packages') | Out-Null
    foreach ($package in $testPackages.GetEnumerator()) {
      Invoke-VerifiedDownload -Url "https://rubygems.org/downloads/$($package.Key).gem" -ExpectedDigest "sha256:$($package.Value)" `
        -DestinationPath (Join-Path $work "test-packages/$($package.Key).gem") | Out-Null
    }
    [ordered]@{ producer_sha = $sourceSha; producer_sha256 = $sourceDigest; candidate = $candidateTag;
      manifest_digest = $manifestDigest; bundle_digest = $bundleDigest; ruby_exe_digest = $rubyDigest } |
      ConvertTo-Json | Set-Content (Join-Path $receipt 'acquisition.json') -Encoding utf8
  } else {
    # No credentials are passed into the downloaded runtime or gem executables.
    if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) { throw 'Runtime execution must use the credential-free install step.' }
    foreach ($name in @('GEM_HOME', 'GEM_PATH', 'RUBYOPT', 'RUBYLIB', 'BUNDLE_GEMFILE')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    $rubyRoot = Join-Path $work 'ruby'
    $installer = Start-Process -FilePath (Join-Path $work 'rubyinstaller.exe') -Wait -PassThru -ArgumentList `
      '/verysilent', '/norestart', '/currentuser', "/dir=`"$rubyRoot`"", '/components=ruby', '/tasks=nomodpath,noassocfiles,noridkinstall'
    if ($installer.ExitCode -ne 0) { throw "Stock RubyInstaller failed: $($installer.ExitCode)" }
    $rubyBin = Join-Path $rubyRoot 'bin'
    $ruby = Join-Path $rubyBin 'ruby.exe'
    $env:Path = "$rubyBin;$env:Path"
    $version = & $ruby -e 'print RUBY_VERSION'
    if ($LASTEXITCODE -ne 0 -or $version -cne '4.0.9') { throw 'Stock RubyInstaller did not produce Ruby 4.0.9.' }
    $runtimeHome = & $ruby -e 'print Gem.dir'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve installed runtime gem home.' }
    $env:GEM_HOME = $runtimeHome
    $env:GEM_PATH = $runtimeHome
    foreach ($validator in @('check_ruby_inventory', 'require_runtime_contract')) {
      & $ruby (Join-Path $producer "bin/$validator.rb") (Join-Path $bundle 'resolution-lock.json')
      if ($LASTEXITCODE -ne 0) { throw "Producer prerequisite failed: $validator" }
    }
    & $ruby (Join-Path $producer 'bin/check_installer_inventory.rb') $manifest $bundle
    if ($LASTEXITCODE -ne 0) { throw 'Producer installer inventory prerequisite failed.' }
    foreach ($target in (Get-Content (Join-Path $bundle 'runtime-gems-install-targets.txt') | Where-Object { $_.Trim() })) {
      & $ruby (Join-Path $rubyBin 'gem') install --local --ignore-dependencies --no-document --force (Join-Path $bundle $target)
      if ($LASTEXITCODE -ne 0) { throw "Runtime gem bake failed: $target" }
    }
    & $ruby (Join-Path $producer 'bin/smoke_runtime.rb') (Join-Path $bundle 'resolution-lock.json')
    if ($LASTEXITCODE -ne 0) { throw 'Producer baked runtime smoke failed.' }
    $testHome = Join-Path $work 'test-gems'
    foreach ($package in (Get-ChildItem (Join-Path $work 'test-packages') -Filter '*.gem')) {
      & $ruby (Join-Path $rubyBin 'gem') install --local --ignore-dependencies --no-document --install-dir $testHome $package.FullName
      if ($LASTEXITCODE -ne 0) { throw "Isolated test dependency failed: $($package.Name)" }
    }
    $env:GEM_PATH = "$runtimeHome;$testHome"
    & $ruby (Join-Path $PSScriptRoot 'testbed_installer_runtime_check.rb') (Join-Path $receipt 'installed-runtime.json')
    if ($LASTEXITCODE -ne 0) { throw 'Installed runtime cannot satisfy the real live accepted startup policy.' }
    @("GEM_HOME=$runtimeHome", "GEM_PATH=$env:GEM_PATH", "LICH_TESTBED_RUBY=$ruby", "LICH_TESTBED_RSPEC=$(Join-Path $testHome 'bin/rspec')") |
      Out-File $env:GITHUB_ENV -Append -Encoding utf8
    $rubyBin | Out-File $env:GITHUB_PATH -Append -Encoding utf8
  }
} catch {
  $_ | Out-String | Set-Content (Join-Path $receipt "$Stage-error.txt") -Encoding utf8
  throw
} finally {
  Stop-Transcript | Out-Null
}

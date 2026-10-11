# fetch-fonts.ps1 - (re)fetch the LICENSE in frontend/fonts/
#
# Opt-in, like every other network call this project makes: the fonts are
# COMMITTED, so a build never needs them and a CI box never touches the network.
# Run this when a font is added, upgraded, or when a subset is rerolled.
#
#   .\scripts\fetch-fonts.ps1                # fetch what is missing
#   .\scripts\fetch-fonts.ps1 -Force        # refetch everything
#
# Source is the @fontsource/* npm packages through jsdelivr rather than the
# upstream GitHub releases, because fontsource ships the files ALREADY SUBSETTED
# to the Latin and Arabic ranges and that is the only thing making this 120 KB
# instead of 600. The licences permit it: OFL 1.1, and the notices are in
# frontend/fonts/LICENSE.md.
[CmdletBinding()]
param(
	[switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$dir = Join-Path $script:FluxRoot 'frontend\fonts'
if (-not (Test-Path -LiteralPath $dir)) {
	New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# name -> url. Keep the names stable: they are referenced by css/fonts.css and by
# the packer, so renaming one means changing both.
$fonts = [ordered]@{
	'inter-latin-400.woff2'       = 'https://cdn.jsdelivr.net/npm/@fontsource/inter@5.1.0/files/inter-latin-400-normal.woff2'
	'inter-latin-600.woff2'       = 'https://cdn.jsdelivr.net/npm/@fontsource/inter@5.1.0/files/inter-latin-600-normal.woff2'
	'vazirmatn-arabic-400.woff2'  = 'https://cdn.jsdelivr.net/npm/@fontsource/vazirmatn@5.0.0/files/vazirmatn-arabic-400-normal.woff2'
	'vazirmatn-arabic-600.woff2'  = 'https://cdn.jsdelivr.net/npm/@fontsource/vazirmatn@5.0.0/files/vazirmatn-arabic-600-normal.woff2'
	'vazirmatn-latin-400.woff2'   = 'https://cdn.jsdelivr.net/npm/@fontsource/vazirmatn@5.0.0/files/vazirmatn-latin-400-normal.woff2'
	'jetbrains-mono-latin-400.woff2' = 'https://cdn.jsdelivr.net/npm/@fontsource/jetbrains-mono@5.2.5/files/jetbrains-mono-latin-400-normal.woff2'
}

Write-Step 'fonts'
$fetched = 0
foreach ($name in $fonts.Keys) {
	$target = Join-Path $dir $name
	if ((Test-Path -LiteralPath $target) -and -not $Force) {
		Write-Host "    ok  $name already present" -ForegroundColor DarkGray
		continue
	}
	try {
		$ProgressPreference = 'SilentlyContinue'
		Invoke-WebRequest -Uri $fonts[$name] -OutFile $target -TimeoutSec 60 -UseBasicParsing
		Write-Ok "$name  $([math]::Round((Get-Item -LiteralPath $target).Length / 1kb, 1)) KB"
		$fetched++
	}
	catch {
		Write-Err2 "$name failed: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
		exit 1
	}
}

$total = (Get-ChildItem -LiteralPath $dir -Filter '*.woff2' -File |
	Measure-Object -Property Length -Sum).Sum
Write-Ok "$((Get-ChildItem -LiteralPath $dir -Filter '*.woff2' -File).Count) files, $([math]::Round($total / 1kb, 1)) KB total, $fetched fetched"
Write-Host '    licences: frontend\fonts\LICENSE.md (OFL 1.1 - Inter, Vazirmatn, JetBrains Mono)' -ForegroundColor DarkGray

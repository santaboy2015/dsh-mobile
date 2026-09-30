# build.ps1 — assemble the DSH Mobile APK with the Android SDK build-tools
# directly. No Gradle, no Android Studio project, no network access required.
#
# Pipeline:
#   aapt2 compile   res/            -> res.zip
#   aapt2 link      res.zip         -> base.apk (resources + manifest + R.java)
#   javac           src/ + R.java   -> classes/
#   d8              classes/        -> classes.dex
#   zip             + classes.dex   -> unsigned apk
#   zipalign        -> aligned
#   apksigner       -> signed apk
#
# Everything it needs is discovered at runtime and reported on failure, so a
# missing SDK component names itself instead of producing a cryptic exit code.

[CmdletBinding()]
param(
    [string]$Sdk = "",
    [string]$Jdk = "",
    # Empty means "pick the newest installed". 34.0.0 ships R8 8.2.2, which
    # throws an internal NPE when driven by a JDK 23 runtime; 36.0.0 ships R8
    # 8.10.9 and dexes the same classes cleanly. If you pin an older
    # build-tools and hit that NPE, do not go hunting in the app code for it.
    [string]$BuildTools = "",
    [int]   $CompileSdk = 34,
    [int]   $MinSdk     = 24,
    [int]   $TargetSdk  = 34,
    # Restrict cleartext HTTP to specific hosts (comma-separated). Empty keeps
    # the default: cleartext allowed anywhere, with WireGuard carrying
    # confidentiality and the firewall rule as the real boundary. See the
    # header of android/res/xml/network_security_config.template.xml.
    [string[]]$CleartextHosts = @(),
    [string]$Out = "out"
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

function Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Fail($message) { Write-Host "!!  $message" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------- default paths
# Every path below is discovered rather than hardcoded, so a clone builds on
# any machine that has the SDK and a JDK without editing this script.

if ([string]::IsNullOrWhiteSpace($Sdk)) {
    if ($env:ANDROID_HOME)          { $Sdk = $env:ANDROID_HOME }
    elseif ($env:ANDROID_SDK_ROOT)  { $Sdk = $env:ANDROID_SDK_ROOT }
    else                            { $Sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
}

if ([string]::IsNullOrWhiteSpace($Jdk)) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
        $Jdk = $env:JAVA_HOME
    } else {
        # $env:ProgramFiles is the x86 view under a 32-bit host and under some
        # launchers ("C:\Program Files (x86)"), so a JDK installed to the real
        # 64-bit location would be invisible. Check both, plus the registry.
        $programDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) |
                       Where-Object { $_ } | Select-Object -Unique

        $roots = @()
        foreach ($p in $programDirs) {
            $roots += @("$p\Java", "$p\Eclipse Adoptium", "$p\Microsoft", "$p\Amazon Corretto",
                        "$p\Zulu", "$p\BellSoft\LibericaJDK")
        }
        $roots += @("$env:LOCALAPPDATA\Programs\Eclipse Adoptium",
                    "$env:LOCALAPPDATA\Programs\Microsoft",
                    "$env:USERPROFILE\.jdks")

        $candidates = @()
        foreach ($r in $roots) {
            if (Test-Path $r) {
                $candidates += @(Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') })
            }
        }

        # Last resort: whatever the registry says the JRE/JDK home is.
        foreach ($hive in @('HKLM:\SOFTWARE\JavaSoft\JDK', 'HKLM:\SOFTWARE\JavaSoft\Java Development Kit')) {
            if (Test-Path $hive) {
                $candidates += @(Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
                    $home = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).JavaHome
                    if ($home -and (Test-Path (Join-Path $home 'bin\javac.exe'))) {
                        Get-Item $home
                    }
                })
            }
        }

        $candidates = @($candidates | Where-Object { $_ } | Sort-Object FullName -Unique)
        if ($candidates.Count -eq 0) {
            Fail "no JDK found. Install one (Temurin 17+ recommended), or pass -Jdk 'C:\path\to\jdk'"
        }
        # Newest by numeric component, so jdk-23 beats jdk-17 and jdk-9 beats
        # jdk-8. [version] cannot parse a bare "23", hence the manual compare.
        function Get-JdkRank([string]$name) {
            $tail = [regex]::Match($name, '(\d+(?:\.\d+)*)\s*$')
            if (-not $tail.Success) { return @(0) }
            return @($tail.Groups[1].Value -split '\.' | ForEach-Object { [int]$_ })
        }
        $Jdk = ($candidates |
                Sort-Object -Property @{ Expression = { Get-JdkRank $_.Name } } -Descending |
                Select-Object -First 1).FullName
    }
}

if ([string]::IsNullOrWhiteSpace($BuildTools)) {
    $btRoot = Join-Path $Sdk 'build-tools'
    if (-not (Test-Path $btRoot)) { Fail "no build-tools under $btRoot — install them via sdkmanager" }
    $installed = @(Get-ChildItem $btRoot -Directory -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty Name)
    if ($installed.Count -eq 0) { Fail "build-tools directory is empty: $btRoot" }
    $BuildTools = $installed | Sort-Object { [version]($_ -replace '[^0-9.].*$','') } -Descending |
                  Select-Object -First 1
}

# ---------------------------------------------------------------- toolchain
$bt = Join-Path $Sdk "build-tools\$BuildTools"
$aapt2     = Join-Path $bt 'aapt2.exe'
$d8        = Join-Path $bt 'd8.bat'
$zipalign  = Join-Path $bt 'zipalign.exe'
$apksigner = Join-Path $bt 'apksigner.bat'
$androidJar = Join-Path $Sdk "platforms\android-$CompileSdk\android.jar"

$javac   = Join-Path $Jdk 'bin\javac.exe'
$keytool = Join-Path $Jdk 'bin\keytool.exe'
$jar     = Join-Path $Jdk 'bin\jar.exe'

$missing = @()
foreach ($tool in @($aapt2, $d8, $zipalign, $apksigner, $androidJar, $javac, $keytool, $jar)) {
    if (-not (Test-Path $tool)) { $missing += $tool }
}
if ($missing.Count -gt 0) {
    Write-Host "Missing toolchain pieces:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" }
    Fail "install the Android SDK build-tools $BuildTools and platform android-$CompileSdk, or pass -Sdk/-Jdk"
}
Write-Host "SDK    : $Sdk"
Write-Host "JDK    : $Jdk"
Write-Host "Tools  : $bt"
Write-Host ""

# ---------------------------------------------------------------- workspace
$stage = Join-Path $root $Out
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$dirRes    = Join-Path $stage 'res'
$dirGen    = Join-Path $stage 'gen'
$dirClass  = Join-Path $stage 'classes'
$dirDex    = Join-Path $stage 'dex'
foreach ($d in @($dirRes, $dirGen, $dirClass, $dirDex)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$resZip    = Join-Path $dirRes   'resources.zip'
$baseApk   = Join-Path $stage    'base.apk'
$unapk     = Join-Path $stage    'unsigned.apk'
$aligned   = Join-Path $stage    'aligned.apk'
$finalApk  = Join-Path $root     'DSH-Mobile.apk'
$keystore  = Join-Path $root     'debug.keystore'
$dirStageRes = Join-Path $stage  'res-src'

# ------------------------------------------------- network security config
# Rendered from network_security_config.template.xml so the cleartext scope is
# a build input rather than a hand-edit. Two reasons this is generated:
#   1. the build must reject the .template file as a resource (aapt2 cannot
#      have a dot in a resource name), and
#   2. narrowing cleartext is a per-user decision, not something to patch by
#      hand in a checkout.
$nscTemplate = Join-Path $root 'android\res\xml\network_security_config.template.xml'
$nscTarget   = Join-Path $root 'android\res\xml\network_security_config.xml'

$hosts = @($CleartextHosts |
           ForEach-Object { $_ -split ',' } |
           ForEach-Object { $_.Trim() } |
           Where-Object { $_ -ne '' })

$nsc = Get-Content $nscTemplate -Raw
if ($hosts.Count -eq 0) {
    $nsc = $nsc.Replace('@@CLEARTEXT_BASE@@', 'true').Replace('@@DOMAIN_CONFIGS@@', '')
    Write-Host "Cleartext: any host (default; firewall rule is the boundary)"
} else {
    $blocks = foreach ($h in $hosts) {
        # An IPv4 literal must not carry includeSubdomains — Android's config
        # parser rejects that combination.
        $isIp = $h -match '^\d{1,3}(\.\d{1,3}){3}$'
        $attrs = if ($isIp) { "        <domain>$h</domain>" }
                 else       { "        <domain includeSubdomains=`"true`">$h</domain>" }
        @"
    <domain-config cleartextTrafficPermitted="true">
$attrs
    </domain-config>
"@
    }
    $nsc = $nsc.Replace('@@CLEARTEXT_BASE@@', 'false')
    $nsc = $nsc.Replace('@@DOMAIN_CONFIGS@@', ($blocks -join "`r`n"))
    Write-Host "Cleartext: DENIED except $($hosts -join ', ')"
}
# UTF8Encoding($false) = no BOM. aapt2 rejects a BOM-prefixed XML with
# "not well-formed (invalid token)", and PowerShell's -Encoding UTF8 adds one.
[System.IO.File]::WriteAllText($nscTarget, $nsc, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- resources
Step "Compiling resources"
# aapt2 compiles a whole directory, so the .template file has to be filtered
# out before it is handed over — a dot in a resource name is a hard error.
Copy-Item (Join-Path $root 'android\res') $dirStageRes -Recurse -Force
Get-ChildItem $dirStageRes -Recurse -Filter '*.template.xml' |
    Remove-Item -Force
& $aapt2 compile --dir $dirStageRes -o $resZip
if ($LASTEXITCODE -ne 0) { Fail "aapt2 compile failed" }

Step "Linking resources and manifest"
& $aapt2 link `
    -o $baseApk `
    -I $androidJar `
    --manifest (Join-Path $root 'android\AndroidManifest.xml') `
    -R $resZip `
    --java $dirGen `
    --min-sdk-version $MinSdk `
    --target-sdk-version $TargetSdk `
    --version-code 1 `
    --version-name 1.0 `
    --auto-add-overlay
if ($LASTEXITCODE -ne 0) { Fail "aapt2 link failed" }

# ------------------------------------------------------------------- javac
Step "Compiling Java sources"
$sources = @(Get-ChildItem (Join-Path $root 'android\src') -Recurse -Filter *.java |
             Select-Object -ExpandProperty FullName)
$sources += @(Get-ChildItem $dirGen -Recurse -Filter *.java |
              Select-Object -ExpandProperty FullName)
Write-Host "    $($sources.Count) source files"

$argFile = Join-Path $stage 'javac.args'
$sources | ForEach-Object { '"' + ($_ -replace '\\', '/') + '"' } |
    Set-Content -Path $argFile -Encoding ASCII

& $javac `
    --release 11 `
    -nowarn `
    -encoding UTF-8 `
    -cp $androidJar `
    -d $dirClass `
    "@$argFile"
if ($LASTEXITCODE -ne 0) { Fail "javac failed" }

# --------------------------------------------------------------------- dex
Step "Dexing"
$classFiles = @(Get-ChildItem $dirClass -Recurse -Filter *.class |
                Select-Object -ExpandProperty FullName)
Write-Host "    $($classFiles.Count) class files"
& $d8 `
    --lib $androidJar `
    --min-api $MinSdk `
    --output $dirDex `
    $classFiles
if ($LASTEXITCODE -ne 0) { Fail "d8 failed" }

if (-not (Test-Path (Join-Path $dirDex 'classes.dex'))) { Fail "d8 produced no classes.dex" }

# -------------------------------------------------------- package the apk
Step "Packaging classes.dex into the APK"
Copy-Item $baseApk $unapk -Force
# `jar --update` appends to an existing zip without touching aapt2's
# uncompressed, aligned resources.arsc entry.
& $jar --update --file $unapk -C $dirDex classes.dex
if ($LASTEXITCODE -ne 0) { Fail "jar update failed" }

# ---------------------------------------------------------- align and sign
Step "Aligning"
& $zipalign -f -p 4 $unapk $aligned
if ($LASTEXITCODE -ne 0) { Fail "zipalign failed" }

if (-not (Test-Path $keystore)) {
    Step "Creating debug keystore (self-signed, 10000 days)"
    & $keytool -genkeypair `
        -keystore $keystore `
        -alias dshdebug `
        -keyalg RSA `
        -keysize 2048 `
        -validity 10000 `
        -storepass android `
        -keypass android `
        -dname "CN=DSH Mobile Debug,O=DSH,C=US"
    if ($LASTEXITCODE -ne 0) { Fail "keytool failed" }
}

Step "Signing"
if (Test-Path $finalApk) { Remove-Item $finalApk -Force }
& $apksigner sign `
    --ks $keystore `
    --ks-key-alias dshdebug `
    --ks-pass pass:android `
    --key-pass pass:android `
    --out $finalApk `
    $aligned
if ($LASTEXITCODE -ne 0) { Fail "apksigner sign failed" }

Step "Verifying signature"
& $apksigner verify --verbose $finalApk
if ($LASTEXITCODE -ne 0) { Fail "apksigner verify failed" }

# ------------------------------------------------------------------ report
$apk = Get-Item $finalApk
Write-Host ""
Write-Host "Built: $($apk.FullName)" -ForegroundColor Green
Write-Host ("Size : {0:N0} bytes ({1:N1} KB)" -f $apk.Length, ($apk.Length / 1KB))
Write-Host ""
Write-Host "Install over USB debugging:" -ForegroundColor Cyan
Write-Host "  & '$Sdk\platform-tools\adb.exe' install -r '$($apk.FullName)'"

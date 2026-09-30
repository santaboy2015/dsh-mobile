#!/usr/bin/env bash
# build.sh — assemble the DSH Mobile APK with the Android SDK build-tools
# directly. No Gradle, no Android Studio project, no network access required.
#
# POSIX counterpart to build.ps1. Same pipeline:
#   aapt2 compile   res/            -> resources.zip
#   aapt2 link      resources.zip   -> base.apk (resources + manifest + R.java)
#   javac           src/ + R.java   -> classes/
#   d8              classes/        -> classes.dex
#   zip             + classes.dex   -> unsigned apk
#   zipalign        -> aligned
#   apksigner       -> signed apk
#
# Verified on Linux and macOS. Requires bash 4+, a JDK 17+, and the Android SDK.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

build_tools=""
compile_sdk=34
min_sdk=24
target_sdk=34
out="out"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
jdk="${JAVA_HOME:-}"
cleartext_hosts=""

die() { printf '!!  %s\n' "$1" >&2; exit 1; }
step() { printf '==> %s\n' "$1"; }

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

  --sdk PATH               Android SDK root        (default: $ANDROID_HOME, else per-OS default)
  --jdk PATH               JDK root                (default: $JAVA_HOME, else autodetected)
  --build-tools VERSION    build-tools version     (default: newest installed)
  --compile-sdk N          compile SDK platform   (default: 34)
  --min-sdk N              minimum SDK            (default: 24)
  --target-sdk N           target SDK             (default: 34)
  --cleartext-hosts LIST   comma-separated hosts allowed cleartext HTTP
                           (default: any host — see SECURITY.md)
  --out DIR                staging directory       (default: out)
  -h, --help               this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sdk)            sdk="$2"; shift 2 ;;
        --jdk)            jdk="$2"; shift 2 ;;
        --build-tools)    build_tools="$2"; shift 2 ;;
        --compile-sdk)    compile_sdk="$2"; shift 2 ;;
        --min-sdk)        min_sdk="$2"; shift 2 ;;
        --target-sdk)     target_sdk="$2"; shift 2 ;;
        --cleartext-hosts) cleartext_hosts="$2"; shift 2 ;;
        --out)            out="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# ------------------------------------------------------------- default paths
os="$(uname -s)"
if [ -z "$sdk" ]; then
    case "$os" in
        Darwin) sdk="$HOME/Library/Android/sdk" ;;
        *)      sdk="$HOME/Android/Sdk" ;;
    esac
fi

if [ -z "$jdk" ]; then
    if [ "$os" = "Darwin" ] && [ -x /usr/libexec/java_home ]; then
        jdk="$(/usr/libexec/java_home 2>/dev/null || true)"
    fi
    if [ -z "$jdk" ]; then
        for c in /usr/lib/jvm/* /opt/java/* /opt/homebrew/opt/openjdk*; do
            [ -x "$c/bin/javac" ] && jdk="$c"
        done
    fi
fi

[ -n "$jdk" ] && [ -x "$jdk/bin/javac" ] || \
    die "no JDK found. Install a JDK 17+, set JAVA_HOME, or pass --jdk PATH"

bt_root="$sdk/build-tools"
[ -d "$bt_root" ] || die "no build-tools under $bt_root — install them via sdkmanager"
if [ -z "$build_tools" ]; then
    build_tools="$(ls -1 "$bt_root" | sort -V | tail -n 1)"
fi

bt="$bt_root/$build_tools"
aapt2="$bt/aapt2"
d8="$bt/d8"
zipalign="$bt/zipalign"
apksigner="$bt/apksigner"
android_jar="$sdk/platforms/android-$compile_sdk/android.jar"

javac="$jdk/bin/javac"
keytool="$jdk/bin/keytool"
jar="$jdk/bin/jar"

missing=""
for tool in "$aapt2" "$d8" "$zipalign" "$apksigner" "$android_jar" "$javac" "$keytool" "$jar"; do
    [ -e "$tool" ] || missing="$missing
  $tool"
done
if [ -n "$missing" ]; then
    printf 'Missing toolchain pieces:%s\n' "$missing" >&2
    die "install build-tools $build_tools and platform android-$compile_sdk, or pass --sdk/--jdk"
fi

printf 'SDK    : %s\nJDK    : %s\nTools  : %s\n\n' "$sdk" "$jdk" "$bt"

# ---------------------------------------------------------------- workspace
stage="$root/$out"
rm -rf "$stage"
mkdir -p "$stage/res" "$stage/gen" "$stage/classes" "$stage/dex" "$stage/res-src"

res_zip="$stage/res/resources.zip"
base_apk="$stage/base.apk"
unsigned_apk="$stage/unsigned.apk"
aligned_apk="$stage/aligned.apk"
final_apk="$root/DSH-Mobile.apk"
keystore="$root/debug.keystore"

# ------------------------------------------------- network security config
# Rendered from the .template so the cleartext scope is a build input. See the
# template header and SECURITY.md for why the default is not scoped.
nsc_template="$root/android/res/xml/network_security_config.template.xml"
nsc_target="$root/android/res/xml/network_security_config.xml"

if [ -z "$cleartext_hosts" ]; then
    # Drop the marker line so the template's trailing newline still closes cleanly.
    sed -e '/@@DOMAIN_CONFIGS@@/d' "$nsc_template" > "$nsc_target"
    printf 'Cleartext: any host (default; firewall rule is the boundary)\n'
else
    # The base stays permissive in both modes: it is documented, and a deny-all
    # base would make the allowlist below unreachable. The allowlist is a
    # convenience, not a security boundary — see SECURITY.md.
    sed -e '/@@DOMAIN_CONFIGS@@/d' "$nsc_template" |
    awk -v hosts="$cleartext_hosts" '
        /<\/network-security-config>/ {
            n = split(hosts, list, ",")
            for (i = 1; i <= n; i++) {
                h = list[i]
                gsub(/^[ \t]+|[ \t]+$/, "", h)
                if (h == "") continue
                print "    <domain-config cleartextTrafficPermitted=\"true\">"
                if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                    print "        <domain>" h "</domain>"
                else
                    print "        <domain includeSubdomains=\"true\">" h "</domain>"
                print "    </domain-config>"
            }
        }
        { print }
    ' > "$nsc_target"
    printf 'Cleartext: any host, with these pinned in the allowlist: %s\n' "$cleartext_hosts"
fi

# ---------------------------------------------------------------- resources
step "Compiling resources"
# aapt2 compiles a whole directory, so the .template file must be filtered out
# first — a dot in a resource name is a hard error.
cp -R "$root/android/res/." "$stage/res-src/"
find "$stage/res-src" -name '*.template.xml' -delete
"$aapt2" compile --dir "$stage/res-src" -o "$res_zip"

step "Linking resources and manifest"
"$aapt2" link \
    -o "$base_apk" \
    -I "$android_jar" \
    --manifest "$root/android/AndroidManifest.xml" \
    -R "$res_zip" \
    --java "$stage/gen" \
    --min-sdk-version "$min_sdk" \
    --target-sdk-version "$target_sdk" \
    --version-code 1 \
    --version-name 1.0 \
    --auto-add-overlay

# ------------------------------------------------------------------- javac
step "Compiling Java sources"
arg_file="$stage/javac.args"
: > "$arg_file"
count=0
while IFS= read -r -d '' src; do
    printf '"%s"\n' "$src" >> "$arg_file"
    count=$((count + 1))
done < <(find "$root/android/src" "$stage/gen" -name '*.java' -print0)
printf '    %s source files\n' "$count"

"$javac" \
    --release 11 \
    -nowarn \
    -encoding UTF-8 \
    -cp "$android_jar" \
    -d "$stage/classes" \
    "@$arg_file"

# --------------------------------------------------------------------- dex
step "Dexing"
class_arg_file="$stage/d8.args"
find "$stage/classes" -name '*.class' > "$class_arg_file"
printf '    %s class files\n' "$(wc -l < "$class_arg_file" | tr -d ' ')"
"$d8" \
    --lib "$android_jar" \
    --min-api "$min_sdk" \
    --output "$stage/dex" \
    "@$class_arg_file"

[ -f "$stage/dex/classes.dex" ] || die "d8 produced no classes.dex"

# -------------------------------------------------------- package the apk
step "Packaging classes.dex into the APK"
cp "$base_apk" "$unsigned_apk"
# `jar --update` appends to an existing zip without touching aapt2's
# uncompressed, aligned resources.arsc entry.
"$jar" --update --file "$unsigned_apk" -C "$stage/dex" classes.dex

# ---------------------------------------------------------- align and sign
step "Aligning"
"$zipalign" -f -p 4 "$unsigned_apk" "$aligned_apk"

if [ ! -f "$keystore" ]; then
    step "Creating debug keystore (self-signed, 10000 days)"
    "$keytool" -genkeypair \
        -keystore "$keystore" \
        -alias dshdebug \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -storepass android \
        -keypass android \
        -dname "CN=DSH Mobile Debug,O=DSH,C=US"
fi

step "Signing"
rm -f "$final_apk"
"$apksigner" sign \
    --ks "$keystore" \
    --ks-key-alias dshdebug \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$final_apk" \
    "$aligned_apk"

step "Verifying signature"
"$apksigner" verify --verbose "$final_apk"

# ------------------------------------------------------------------ report
size="$(wc -c < "$final_apk" | tr -d ' ')"
printf '\nBuilt: %s\n' "$final_apk"
printf 'Size : %s bytes (%s KB)\n\n' "$size" "$((size / 1024))"
printf 'Install over USB debugging:\n  adb install -r %s\n' "$final_apk"

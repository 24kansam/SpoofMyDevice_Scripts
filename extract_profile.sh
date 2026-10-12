#!/usr/bin/env bash
# macOS/Linux equivalent of extract_profile.bat. Requires adb on PATH.
# Usage: bash extract_profile.sh > profile.json
set -euo pipefail
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
command -v adb >/dev/null 2>&1 || fail 'adb is not installed or is not on PATH.'
printf 'Detecting connected devices...\n' >&2
device_output=$(adb devices) || fail 'Could not list ADB devices.'
devices=()
while read -r serial state rest; do
    if [[ "$state" == device ]]; then devices+=("$serial"); fi
done <<< "$(printf '%s' "$device_output" | tr -d '\r')"
count=${#devices[@]}
(( count > 0 )) || fail 'No authorized devices connected via ADB.'
if (( count == 1 )); then
    TARGET_SERIAL=${devices[0]}
    printf 'Found 1 device: %s\n' "$TARGET_SERIAL" >&2
else
    printf 'Multiple devices detected:\n' >&2
    for (( i=0; i<count; i++ )); do
        model_name=$(adb -s "${devices[i]}" shell getprop ro.product.model) || fail 'Could not read device model.'
        printf '[%s] %s - %s\n' "$((i+1))" "${devices[i]}" "$(printf '%s' "$model_name" | tr -d '\r')" >&2
    done
    while :; do
        printf 'Select a device (1-%s): ' "$count" >&2
        IFS= read -r choice || fail 'No device selection received.'
        TARGET_SERIAL=
        for (( i=0; i<count; i++ )); do
            if [[ "$choice" == "$((i+1))" ]]; then
                TARGET_SERIAL=${devices[i]}
                break
            fi
        done
        [[ -n "$TARGET_SERIAL" ]] && break
        printf 'Invalid selection. Please try again.\n' >&2
    done
    printf 'Selected device: %s\n' "$TARGET_SERIAL" >&2
fi
fetch_prop() {
    local value
    value=$(adb -s "$TARGET_SERIAL" shell getprop "$1") || fail "Could not read property $1."
    printf '%s' "$value" | tr -d '\r'
}
# Indexed arrays support the Bash 3.2 included with macOS.
names=()
values=()
while read -r name prop; do
    value=$(fetch_prop "$prop") || exit 1
    names+=("$name")
    values+=("$value")
    case "$name" in
        deviceCode) deviceCode=$value ;;
        manufacturer) manufacturer=$value ;;
        model) model=$value ;;
        boardPlatform) boardPlatform=$value ;;
        buildRelease) buildRelease=$value ;;
    esac
done <<'PROPERTIES'
brand ro.product.brand
manufacturer ro.product.manufacturer
model ro.product.model
productName ro.product.name
deviceCode ro.product.device
board ro.product.board
hardware ro.hardware
boardPlatform ro.board.platform
buildFingerprint ro.build.fingerprint
buildId ro.build.id
buildDisplayId ro.build.display.id
buildIncremental ro.build.version.incremental
buildRelease ro.build.version.release
buildSdk ro.build.version.sdk
securityPatch ro.build.version.security_patch
buildDescription ro.build.description
buildFlavor ro.build.flavor
buildProduct ro.build.product
buildCharacteristics ro.build.characteristics
PROPERTIES
screenWidth=0
screenHeight=0
screenDensity=0
size_output=$(adb -s "$TARGET_SERIAL" shell wm size) || fail 'Could not read screen size.'
density_output=$(adb -s "$TARGET_SERIAL" shell wm density) || fail 'Could not read screen density.'
# Last matching line wins, preserving wm overrides as in the batch file.
while IFS= read -r line; do
    if [[ "$line" =~ size:[[:space:]]*([0-9]+)x([0-9]+) ]]; then
        screenWidth=${BASH_REMATCH[1]}
        screenHeight=${BASH_REMATCH[2]}
    fi
done <<< "$size_output"
while IFS= read -r line; do
    if [[ "$line" =~ density:[[:space:]]*([0-9]+) ]]; then
        screenDensity=${BASH_REMATCH[1]}
    fi
done <<< "$density_output"
names+=(screenWidth screenHeight screenDensity)
values+=("$screenWidth" "$screenHeight" "$screenDensity")
while read -r name prop; do
    value=$(fetch_prop "$prop") || exit 1
    case "$name" in
        operatorAlpha|operatorNumeric|simOperatorAlpha|simOperatorNumeric|simCountryIso)
            value=${value%%,*} ;;
        socModel)
            [[ -n "$value" ]] || value=$boardPlatform
            socModel=$value ;;
    esac
    names+=("$name")
    values+=("$value")
done <<'PROPERTIES'
operatorAlpha gsm.operator.alpha
operatorNumeric gsm.operator.numeric
simOperatorAlpha gsm.sim.operator.alpha
simOperatorNumeric gsm.sim.operator.numeric
simCountryIso gsm.sim.operator.iso-country
timezone persist.sys.timezone
socModel ro.soc.model
socManufacturer ro.soc.manufacturer
PROPERTIES
json_string() {
    local value=$1 code char escape octal
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    # Escape all JSON control characters; Bash strings cannot contain NUL.
    for (( code=1; code<32; code++ )); do
        printf -v escape '\\u%04x' "$code"
        printf -v octal '%03o' "$code"
        printf -v char '%b' "\\$octal"
        value=${value//"$char"/"$escape"}
    done
    printf '"%s"' "$value"
}
json_integer() {
    local value=$1
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    # Avoid invalid JSON leading zeros and shell integer/octal limits.
    while [[ ${#value} -gt 1 && "$value" == 0* ]]; do value=${value#0}; done
    printf '%s' "$value"
}
printf '{\n    "id": '
json_string "$deviceCode"
printf ',\n    "brandLabel": '
json_string "$manufacturer"
printf ',\n    "modelLabel": '
json_string "$model"
printf ',\n    "summary": '
json_string "$socModel - Android $buildRelease"
printf ',\n    "profile": {\n'
for (( i=0; i<${#names[@]}; i++ )); do
    printf '        "%s": ' "${names[i]}"
    case "${names[i]}" in
        buildSdk|screenWidth|screenHeight|screenDensity) json_integer "${values[i]}" ;;
        *) json_string "${values[i]}" ;;
    esac
    if (( i+1 < ${#names[@]} )); then printf ','; fi
    printf '\n'
done
printf '    }\n}\n'

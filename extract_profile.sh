#!/usr/bin/env bash
# macOS/Linux equivalent of extract_profile.bat. Requires adb on PATH.
# Usage: bash extract_profile.sh [> profile.json]
set -euo pipefail
ACTION=com.spoofmydevice.ACTION_SEND_CONFIG
RECEIVER_PACKAGE=com.spoofmydevice
SKIP_PAUSE=false
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
INPUT_FD=0
if { exec 3<> /dev/tty; } 2>/dev/null; then INPUT_FD=3; fi
pause_on_exit() {
    local status=$?
    trap - EXIT
    if (( BASH_SUBSHELL == 0 )) && [[ "$SKIP_PAUSE" == false ]]; then
        log "Finished (exit status $status). Press any key to exit..."
        IFS= read -r -s -n 1 -u "$INPUT_FD" || log 'Input closed; no key can be read.'
        printf '\n' >&2
    fi
    exit "$status"
}
trap pause_on_exit EXIT
trap 'log "ERROR: Unexpected failure on line $LINENO (status $?)."' ERR
command -v adb >/dev/null 2>&1 || fail 'adb is not installed or is not on PATH.'
# Bound discovery calls to the remaining deadline, including stalled ADB connections.
discovery_adb() (
    local remaining=$((DETECTION_DEADLINE - SECONDS)) limit worker watchdog status
    (( remaining > 0 )) || return 124
    limit=$remaining
    (( limit <= 5 )) || limit=5
    adb "$@" &
    worker=$!
    ( sleep "$limit"; kill "$worker" 2>/dev/null || true ) >/dev/null 2>&1 &
    watchdog=$!
    status=0
    wait "$worker" || status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
)
has_registered_receiver() {
    # Match the package and action within the same live ReceiverList block.
    awk -v package="$RECEIVER_PACKAGE" -v action="$ACTION" '
        function finish() { if (inblock && owner && filter) found=1 }
        /Registered Receivers:/ { active=1; next }
        active && /Receiver Resolver Table:|Historical broadcasts|Active broadcasts|Pending broadcasts|Sticky broadcasts/ { finish(); inblock=0; exit }
        active && /ReceiverList\{/ { finish(); inblock=1; owner=0; filter=0 }
        active && inblock {
            if (index($0, action)) filter=1
            line=$0
            while ((pos=index(line, package)) > 0) {
                before=substr(line, 1, pos-1); after=substr(line, pos+length(package))
                if ((before == "" || before !~ /[[:alnum:]_.]$/) && (after == "" || after !~ /^[[:alnum:]_.]/)) owner=1
                line=after
            }
        }
        END { finish(); exit !found }
    '
}
DETECTION_DEADLINE=$((SECONDS + 90))
RECEIVER_SERIAL=
log "Waiting up to 90 seconds for an active registered receiver for $ACTION..."
while (( SECONDS < DETECTION_DEADLINE )); do
    found=()
    if device_output=$(discovery_adb devices); then
        devices=()
        while read -r serial state rest; do
            if [[ "$state" == device ]]; then devices+=("$serial"); fi
        done <<< "$(printf '%s' "$device_output" | tr -d '\r')"
        for serial in "${devices[@]}"; do
            (( SECONDS < DETECTION_DEADLINE )) || break
            if live_output=$(discovery_adb -s "$serial" shell dumpsys activity broadcasts); then
                if printf '%s\n' "$live_output" | has_registered_receiver; then found+=("$serial"); fi
            else
                log "WARNING: Receiver check failed on $serial."
            fi
        done
    else
        log 'WARNING: Could not list ADB devices; retrying.'
    fi
    (( SECONDS < DETECTION_DEADLINE )) || break
    (( ${#found[@]} <= 1 )) || fail "Multiple devices have active registered receivers: ${found[*]}. Keep the receiving app active on only one device."
    if (( ${#found[@]} == 1 )); then RECEIVER_SERIAL=${found[0]}; break; fi
    sleep 1
done
if [[ -z "$RECEIVER_SERIAL" ]]; then
    SKIP_PAUSE=true
    fail 'No active registered receiver detected within 90 seconds.'
fi
log "Receiver device: $RECEIVER_SERIAL"
device_output=$(adb devices) || fail 'Could not list source devices.'
devices=()
while read -r serial state rest; do
    if [[ "$state" == device && "$serial" != "$RECEIVER_SERIAL" ]]; then devices+=("$serial"); fi
done <<< "$(printf '%s' "$device_output" | tr -d '\r')"
count=${#devices[@]}
(( count > 0 )) || fail 'No authorized source device connected besides the receiver device.'
if (( count == 1 )); then
    TARGET_SERIAL=${devices[0]}
else
    log 'Select a profile source device (receiver excluded):'
    for (( i=0; i<count; i++ )); do
        model_name=$(adb -s "${devices[i]}" shell getprop ro.product.model) || fail 'Could not read device model.'
        printf '[%s] %s - %s\n' "$((i+1))" "${devices[i]}" "$(printf '%s' "$model_name" | tr -d '\r')" >&2
    done
    while :; do
        printf 'Select a source device (1-%s): ' "$count" >&2
        IFS= read -r -u "$INPUT_FD" choice || fail 'No device selection received.'
        TARGET_SERIAL=
        for (( i=0; i<count; i++ )); do
            if [[ "$choice" == "$((i+1))" ]]; then TARGET_SERIAL=${devices[i]}; break; fi
        done
        [[ -n "$TARGET_SERIAL" ]] && break
        log 'Invalid selection. Please try again.'
    done
fi
log "Profile source device: $TARGET_SERIAL"
fetch_prop() {
    local value
    log "Reading property $1"
    value=$(adb -s "$TARGET_SERIAL" shell getprop "$1") || fail "Could not read property $1."
    [[ -n "$value" ]] || log "WARNING: $1 is empty."
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
log "Reading screen size and density from $TARGET_SERIAL"
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
log "Screen: ${screenWidth}x${screenHeight}, density $screenDensity"
if [[ "$screenWidth" == 0 || "$screenHeight" == 0 || "$screenDensity" == 0 ]]; then
    log "WARNING: Missing screen metrics default to zero."
fi
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
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log "WARNING: Invalid or missing integer value; defaulting to zero."
        value=0
    fi
    # Avoid invalid JSON leading zeros and shell integer/octal limits.
    while [[ ${#value} -gt 1 && "$value" == 0* ]]; do value=${value#0}; done
    printf '%s' "$value"
}
generate_json() {
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
}
config_data=$(generate_json) || fail "Could not serialize profile JSON."
printf '%s\n' "$config_data"
log "Profile extraction complete (${#config_data} characters)."

# adb joins shell arguments: quote JSON for the device shell, including apostrophes.
shell_quote() {
    local value=$1
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}
# Keep the original destination pinned and confirm its live receiver before delivery.
live_output=$(adb -s "$RECEIVER_SERIAL" shell dumpsys activity broadcasts) || fail "Could not recheck receiver device $RECEIVER_SERIAL. Nothing was sent."
printf '%s\n' "$live_output" | has_registered_receiver || fail "Registered receiver is no longer active on $RECEIVER_SERIAL. Nothing was sent."
receiver_available=true
log "Sending JSON to receiver device $RECEIVER_SERIAL in the broadcast content extra..."
broadcast_ok=false
if broadcast_output=$(adb -s "$RECEIVER_SERIAL" shell "am broadcast --user current --include-stopped-packages -a $ACTION --es content $(shell_quote "$config_data")" 2>&1); then
    printf '%s\n' "$broadcast_output" >&2
    if [[ "$broadcast_output" == *'Broadcast completed:'* && "$broadcast_output" != *'Error'* && "$broadcast_output" != *'Exception'* && "$broadcast_output" != *'Permission Denial'* ]]; then broadcast_ok=true; fi
else
    log "WARNING: ADB broadcast failed: $broadcast_output"
fi
if [[ "$receiver_available" == true && "$broadcast_ok" == true ]]; then
    log 'Broadcast dispatched to an available receiver. App-side import is not acknowledged by ADB.'
else
    log 'WARNING: No available receiver could be verified, or the broadcast failed.'
    printf 'Create output.json in %s instead? [y/N]: ' "$PWD" >&2
    answer=
    IFS= read -r -u "$INPUT_FD" answer || true
    case "$answer" in
        y|Y|yes|YES|Yes)
            output_path=$PWD/output.json
            if [[ -d "$output_path" ]]; then fail "Cannot write $output_path: it is a directory."; fi
            if [[ -e "$output_path" || -L "$output_path" ]]; then
                printf 'output.json already exists. Overwrite it? [y/N]: ' >&2
                answer=
                IFS= read -r -u "$INPUT_FD" answer || true
                case "$answer" in y|Y|yes|YES|Yes) ;; *) fail 'Existing output.json was preserved.' ;; esac
            fi
            temp_output=$(mktemp "$PWD/.output.json.XXXXXX") || fail 'Could not create temporary output file.'
            if printf '%s\n' "$config_data" > "$temp_output" && mv -f "$temp_output" "$output_path"; then
                log "Saved $output_path"
            else
                rm -f "$temp_output"
                fail "Could not write $output_path. Check directory permissions and disk space."
            fi
            ;;
        *) fail 'JSON file declined; broadcast delivery was not verified.' ;;
    esac
fi

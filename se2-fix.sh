#!/usr/bin/env bash
# Space Engineers 2 on Proton: unofficial fixes for
#   1. ray tracing / DLSS greyed out on NVIDIA (game reads "0 RTX cores")
#   2. the false "Low Memory Detected" (swap/pagefile) warning
#
# Patches YOUR copies of Game2/NvApiWrapper.dll and Game2/VRage.Platform.Windows.dll
# (see README.md). The patch sites are located by byte pattern, not by a list of
# known game builds, so future builds work as long as Keen leaves that code alone.
# Needs only bash, coreutils and grep.
#
#   se2-fix.sh [PATH]             apply the fixes
#   se2-fix.sh --restore [PATH]   undo them
#   se2-fix.sh --status [PATH]    show what is installed
#
# PATH is optional and may be the Game2 folder or the SpaceEngineers2 install
# folder. Without it the game is found through your Steam libraries
# (SE2_DIR=/path/to/SpaceEngineers2 also works).
set -euo pipefail

LAUNCH_OPTIONS='DOTNET_ReadyToRunExcludeList=VRage.Platform.Windows %command%'

# Colours only on a terminal, and never when NO_COLOR is set (https://no-color.org).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

die() { echo "${RED}${BOLD}ERROR:${RESET}${RED} $*${RESET}" >&2; exit 1; }
say() { echo "  $1  ${BOLD}$2${RESET}: $3${RESET}"; }   # icon name message

find_game_dir() {
    local root vdf lib
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
                "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        for vdf in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
            [[ -f "$vdf" ]] || continue
            while IFS= read -r lib; do
                if [[ -d "$lib/steamapps/common/SpaceEngineers2/Game2" ]]; then
                    echo "$lib/steamapps/common/SpaceEngineers2/Game2"
                    return 0
                fi
            done < <(echo "$root"; sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf")
        done
    done
    return 1
}

# --- byte pattern search --------------------------------------------------
# A file is turned into " xx xx xx ..." (3 characters per byte), so a match at
# character offset N is byte N/3. Patterns are written as hex bytes with ".."
# as a wildcard byte.

hexdump_file() { od -An -v -tx1 "$1" | tr -d '\n'; }

to_regex() {
    local b re=""
    for b in $1; do
        [[ "$b" == ".." ]] && re+=" [0-9a-f]{2}" || re+=" $b"
    done
    echo "$re"
}

# Prints the byte offset of every match of pattern $2 in hex dump $1.
find_offsets() {
    grep -obE "$(to_regex "$2")" <<<"$1" | cut -d: -f1 | while read -r o; do echo $((o / 3)); done || true
}

byte_at() { echo "${1:$(( $2 * 3 + 1 )):2}"; }   # hex dump, byte offset

write_bytes() {   # file offset "xx xx ..."
    local b out=""
    for b in $3; do out+="\\x$b"; done
    printf "$out" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}

# --- the two fixes ----------------------------------------------------------
# Each fix defines: the file, the original pattern, the patched pattern, and
# make_patch(), which sets PATCH_OFFSET and PATCH_BYTES from a hex dump of the
# original file.

# 1. NvApiWrapper asks NVAPI for the BOOST clock (ClockType=2). dxvk-nvapi only
#    implements CURRENT, so the call fails, the wrapper never asks for the RTX
#    core count, and the game disables ray tracing (and with it DLSS).
#      and eax,0xfffffff2 ; mov [rsp+..],0x30108 ; or eax,0x2
#    becomes
#      and eax,0xfffffff0 ; mov [rsp+..],0x30108 ; or eax,0x0   (ClockType=CURRENT)
NV_FILE="NvApiWrapper.dll"
NV_NAME="ray tracing / DLSS (NvApiWrapper.dll)"
NV_ORIG="83 e0 f2 c7 84 24 .. .. .. .. 08 01 03 00 83 c8 02"
NV_PATCHED="83 e0 f0 c7 84 24 .. .. .. .. 08 01 03 00 83 c8 00"
nv_make_patch() {
    local o
    o=$(find_offsets "$1" "$NV_ORIG")
    PATCH_OFFSET=$o
    PATCH_BYTES="83 e0 f0 c7 84 24 $(byte_at "$1" $((o+6))) $(byte_at "$1" $((o+7))) $(byte_at "$1" $((o+8))) $(byte_at "$1" $((o+9))) 08 01 03 00 83 c8 00"
}

# 2. WinMemoryEngineComponent.TryGetSwapConfiguration reads the Windows
#    "PagingFiles" registry value as REG_MULTI_SZ. Wine stores it as REG_SZ, so
#    the game sees no pagefile and shows "Low Memory Detected". The IL for
#      meetsRequirements = attainable >= 8 GiB + Math.Max(0, vram)
#    becomes
#      meetsRequirements = (attainable >= 8 GiB + vram) | CrashReporter.IsRunningWine()
#    (same length; Math.Max is dropped to make room, VRAM is never negative).
#    The IsRunningWine token is taken from its only caller, IsVirtualProcess:
#      ldarg.1; ldnull; stind.ref; call IsRunningWine; brtrue.s +2; ldc.i4.0; ret; call ..; ldstr
MEM_FILE="VRage.Platform.Windows.dll"
MEM_NAME="Low Memory warning (VRage.Platform.Windows.dll)"
MEM_ORIG="21 00 00 00 00 02 00 00 00 16 6a 03 28 .. .. .. 0a 58 13 .. 05 09 11 .. fe 04 16 fe 01 52"
MEM_PATCHED="21 00 00 00 00 02 00 00 00 03 58 13 .. 05 09 11 .. fe 04 16 fe 01 28 .. .. .. 06 60 00 52"
MEM_WINE_CALLER="03 14 51 28 .. .. .. 06 2d 02 16 2a 28 .. .. .. 0a 72"
mem_make_patch() {
    local o w loc tok
    o=$(find_offsets "$1" "$MEM_ORIG")
    w=$(find_offsets "$1" "$MEM_WINE_CALLER")
    [[ -n "$w" && $(wc -w <<<"$w") -eq 1 ]] || die "Could not locate IsRunningWine in $MEM_FILE. Nothing was changed."
    loc=$(byte_at "$1" $((o+19)))
    [[ "$(byte_at "$1" $((o+23)))" == "$loc" ]] || die "Unexpected IL in $MEM_FILE. Nothing was changed."
    tok="$(byte_at "$1" $((w+4))) $(byte_at "$1" $((w+5))) $(byte_at "$1" $((w+6))) 06"
    PATCH_OFFSET=$o
    PATCH_BYTES="21 00 00 00 00 02 00 00 00 03 58 13 $loc 05 09 11 $loc fe 04 16 fe 01 28 $tok 60 00"
}

# Sets STATE to original / patched / unknown for fix $1 (NV or MEM) on file $2.
identify() {
    local orig="${1}_ORIG" patched="${1}_PATCHED" hex no np
    hex=$(hexdump_file "$2")
    no=$(find_offsets "$hex" "${!orig}" | wc -l)
    np=$(find_offsets "$hex" "${!patched}" | wc -l)
    if   [[ $no -eq 1 && $np -eq 0 ]]; then STATE="original"
    elif [[ $no -eq 0 && $np -eq 1 ]]; then STATE="patched"
    else STATE="unknown"
    fi
    HEX="$hex"
}

# Writes the patched version of original file $2 to $3 for fix $1.
build_patched() {
    local mk="${1,,}_make_patch" hex
    hex=$(hexdump_file "$2")
    "$mk" "$hex"
    cp -p "$2" "$3"
    write_bytes "$3" "$PATCH_OFFSET" "$PATCH_BYTES"
}

# A backup is only trusted if patching it gives exactly the current file.
backup_matches() {   # fix file
    local tmp ok=1
    [[ -f "$2.orig" ]] || return 1
    identify "$1" "$2.orig"
    [[ "$STATE" == "original" ]] || return 1
    tmp="$2.check.$$"
    build_patched "$1" "$2.orig" "$tmp"
    cmp -s "$tmp" "$2" && ok=0
    rm -f "$tmp"
    return $ok
}

# --- main ---------------------------------------------------------------------

mode="apply"
target=""
for arg in "$@"; do
    case "$arg" in
        --status)  mode="status" ;;
        --restore) mode="restore" ;;
        -h|--help) sed -n '2,18p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "Unknown option: $arg (use --status or --restore)" ;;
        *)         [[ -z "$target" ]] || die "Only one path can be given"; target="$arg" ;;
    esac
done

target="${target:-${SE2_DIR:-}}"
if [[ -z "$target" ]]; then
    target="$(find_game_dir)" \
        || die "Space Engineers 2 not found. Pass the path, e.g.: se2-fix.sh /path/to/SpaceEngineers2"
fi
[[ -f "$target" ]] && target="$(dirname "$target")"
[[ -d "$target/Game2" ]] && target="$target/Game2"
[[ -f "$target/$NV_FILE" && -f "$target/$MEM_FILE" ]] || die "Game2 folder not found at: $target"
game2="$target"

if pgrep -f 'SpaceEngineers2\.exe' >/dev/null 2>&1; then
    die "Space Engineers 2 is running. Close it first."
fi

echo "${BOLD}${CYAN}Space Engineers 2 Linux patches${RESET}"
echo "${DIM}Game2: $game2${RESET}"
changed=0
for fix in NV MEM; do
    file_var="${fix}_FILE" name_var="${fix}_NAME"
    file="$game2/${!file_var}"
    name="${!name_var}"
    identify "$fix" "$file"
    state="$STATE"

    case "$mode" in
        status)
            backup="${DIM}none"
            if [[ -f "$file.orig" ]]; then
                if [[ "$state" == "patched" ]] && backup_matches "$fix" "$file"; then
                    backup="${GREEN}valid"
                else
                    backup="${YELLOW}stale (from another game build, ignored)"
                fi
            fi
            case "$state" in
                patched)  say "${GREEN}●${RESET}" "$name" "${GREEN}patched${RESET}, backup: $backup" ;;
                original) say "${YELLOW}○${RESET}" "$name" "${YELLOW}not patched${RESET}, backup: $backup" ;;
                *)        say "${RED}?${RESET}" "$name" "${RED}code not recognised${RESET}, backup: $backup" ;;
            esac
            ;;
        restore)
            if [[ "$state" == "original" ]]; then
                say "${DIM}○${RESET}" "$name" "${DIM}already original"
                rm -f "$file.orig"
            elif [[ "$state" == "patched" ]] && backup_matches "$fix" "$file"; then
                cp -p "$file.orig" "$file"
                rm -f "$file.orig"
                say "${GREEN}✔${RESET}" "$name" "${GREEN}restored"
                changed=1
            else
                say "${RED}✘${RESET}" "$name" "${RED}no matching backup.${RESET} Use Steam's 'Verify integrity of game files'."
            fi
            ;;
        apply)
            if [[ "$state" == "patched" ]]; then
                say "${GREEN}●${RESET}" "$name" "${DIM}already patched"
                continue
            fi
            if [[ "$state" != "original" ]]; then
                say "${YELLOW}⚠${RESET}" "$name" "${YELLOW}skipped: code not recognised (Keen may have changed or fixed it)"
                continue
            fi
            tmp="$file.tmp.$$"
            trap 'rm -f "$tmp"' EXIT
            build_patched "$fix" "$file" "$tmp"
            identify "$fix" "$tmp"
            [[ "$STATE" == "patched" ]] || die "Patched $name failed verification. Nothing was changed."
            cp -p "$file" "$file.orig"
            mv "$tmp" "$file"
            trap - EXIT
            say "${GREEN}✔${RESET}" "$name" "${GREEN}patched${RESET} ${DIM}(original saved as ${!file_var}.orig)"
            changed=1
            ;;
    esac
done

case "$mode" in
    apply)
        cat <<EOF

${BOLD}Next steps in Steam${RESET} (right-click Space Engineers 2 -> Properties):

  ${BOLD}1.${RESET} General -> Launch Options ${DIM}(needed for the Low Memory fix)${RESET}:

        ${CYAN}${BOLD}$LAUNCH_OPTIONS${RESET}

  ${BOLD}2.${RESET} NVIDIA, for ray tracing / DLSS: Compatibility -> ${CYAN}${BOLD}GE-Proton 11${RESET} or newer
     ${DIM}(it ships wine-nvml, which the fix needs)${RESET}
EOF
        ;;
    restore)
        [[ $changed -eq 0 ]] || echo "
${YELLOW}Remove the ${BOLD}DOTNET_ReadyToRunExcludeList${RESET}${YELLOW} launch option in Steam.${RESET}"
        ;;
esac

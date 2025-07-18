#!/usr/bin/env bash
# apparmor.d - Full set of apparmor profiles
# Copyright (C) 2024-2025 Alexandre Pujol <alexandre@pujol.io>
# SPDX-License-Identifier: GPL-2.0-only

# Usage: make check
# shellcheck disable=SC2044

set -eu -o pipefail

RES=$(mktemp)
echo "false" >"$RES"
MAX_JOBS=$(nproc)
declare WITH_CHECK
readonly RES MAX_JOBS APPARMORD="apparmor.d"
readonly reset="\033[0m" fgRed="\033[0;31m" fgYellow="\033[0;33m" fgWhite="\033[0;37m" BgWhite="\033[1;37m"
_msg() { printf '%b%s%b\n' "$BgWhite" "$*" "$reset"; }
_warn() {
    local type="$1" file="$2"
    shift 2
    printf '%bwarning%b %s(%b%s%b): %s\n' "$fgYellow" "$reset" "$type" "$fgWhite" "$file" "$reset" "$*"
}
_err() {
    local type="$1" file="$2"
    shift 2
    printf '  %berror%b %s(%b%s%b): %s\n' "$fgRed" "$reset" "$type" "$fgWhite" "$file" "$reset" "$*"
    echo "true" >"$RES"
}

_in_array() {
    local item needle="$1"
    shift
    for item in "$@"; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}

_is_enabled() {
    _in_array "$1" "${WITH_CHECK[@]}"
}

_wait() {
    local -n job=$1
    job=$((job + 1))
    if ((job >= MAX_JOBS)); then
        wait -n
        job=$((job - 1))
    fi
}

_check() {
    local file="$1"
    local line_number=0

    while IFS= read -r line; do
        line_number=$((line_number + 1))

        # Rules checks
        _check_abstractions
        _check_directory_mark
        _check_equivalent
        _check_too_wide

        # Guidelines check
        _check_abi
        _check_include
        _check_profile
        _check_subprofiles

        # Style check
        if [[ $line_number -lt 10 ]]; then
            _check_header
        fi
        _check_tabs
        _check_trailing
        _check_indentation
        _check_vim

    done <"$file"

    # Results
    _res_abi
    _res_include
    _res_profile
    _res_subprofiles
    _res_header
    _res_vim
}

# Rules checks: security, compatibility and rule issues

readonly ABS="abstractions"
readonly ABS_DANGEROUS=(dbus dbus-session dbus-system dbus-accessibility user-tmp)
declare -A ABS_DEPRECATED=(
    ["nameservice"]="nameservice-strict"
    ["bash"]="shell"
    ["X"]="X-strict"
    ["dbus-accessibility-strict"]="bus-accessibility"
    ["dbus-network-manager-strict"]="bus/org.freedesktop.NetworkManager"
    ["dbus-session-strict"]="bus-session"
    ["dbus-system-strict"]="bus-system"
)
_check_abstractions() {
    _is_enabled abstractions || return 0

    local absname
    for absname in "${ABS_DANGEROUS[@]}"; do
        if [[ "$line" == *"<$ABS/$absname>"* ]]; then
            _err security "$file:$line_number" "dangerous abstraction '<$ABS/$absname>'"
        fi
    done
    for absname in "${!ABS_DEPRECATED[@]}"; do
        if [[ "$line" == *"<$ABS/$absname>"* ]]; then
            _err security "$file:$line_number" "deprecated abstraction '<$ABS/$absname>', use '<$ABS/${ABS_DEPRECATED[$absname]}>' instead"
        fi
    done
}

readonly DIRECTORIES=('@{HOME}' '@{MOUNTS}' '@{bin}' '@{sbin}' '@{lib}' '@{tmp}' '_dirs}' '_DIR}')
_check_directory_mark() {
    _is_enabled directory_mark || return 0
    for pattern in "${DIRECTORIES[@]}"; do
        if [[ "$line" == *"$pattern"* ]]; then
            [[ "$line" == *'='* ]] && continue
            if [[ ! "$line" == *"$pattern/"* ]]; then
                _err issue "$file:$line_number" "missing directory mark: '$pattern' instead of '$pattern/'"
            fi
        fi
    done
}

declare -A EQUIVALENTS=(
    ["awk"]="{m,g,}awk"
    ["gawk"]="{m,g,}awk"
    ["grep"]="{,e}grep"
    ["which"]="which{,.debianutils}"
)
_check_equivalent() {
    _is_enabled equivalent || return 0
    local prgmname
    for prgmname in "${!EQUIVALENTS[@]}"; do
        if [[ "$line" == *"/$prgmname "* ]]; then
            if [[ ! "$line" == *"${EQUIVALENTS[$prgmname]}"* ]]; then
                _err compatibility "$file:$line_number" "missing equivalent program: '@{bin}/$prgmname' instead of '@{bin}/${EQUIVALENTS[$prgmname]}'"
            fi
        fi
    done
}

readonly TOOWIDE=('/**' '/tmp/**' '/var/tmp/**' '@{tmp}/**' '/etc/**' '/dev/shm/**' '@{run}/user/@{uid}/**')
_check_too_wide() {
    _is_enabled too_wide || return 0
    for pattern in "${TOOWIDE[@]}"; do
        if [[ "$line" == *" $pattern "* ]]; then
            _err security "$file:$line_number" "rule too wide: '$pattern'"
        fi
    done
}

# Guidelines check: https://apparmor.pujol.io/development/guidelines/

RES_ABI=false
readonly ABI_SYNTAX='abi <abi/4.0>,'
_check_abi() {
    _is_enabled abi || return 0
    if [[ "$line" == *"$ABI_SYNTAX" ]]; then
        RES_ABI=true
    fi
}
_res_abi() {
    _is_enabled abi || return 0
    if ! $RES_ABI; then
        _err guideline "$file" "missing 'abi <abi/4.0>,'"
    fi
}

RES_INCLUDE=false
_check_include() {
    _is_enabled include || return 0
    if [[ "$line" == *"${include}"* ]]; then
        RES_INCLUDE=true
    fi
}
_res_include() {
    _is_enabled include || return 0
    if ! $RES_INCLUDE; then
        _err guideline "$file" "missing '$include'"
    fi
}

RES_PROFILE=false
_check_profile() {
    _is_enabled profile || return 0
    if [[ "$line" =~ ^"profile $name" ]]; then
        RES_PROFILE=true
    fi
}
_res_profile() {
    _is_enabled profile || return 0
    if ! $RES_PROFILE; then
        _err guideline "$file" "missing profile name: 'profile $name'"
    fi
}

# Style check

readonly HEADERS=(
    "# apparmor.d - Full set of apparmor profiles"
    "# Copyright (C) "
    "# SPDX-License-Identifier: GPL-2.0-only"
)
_RES_HEADER=(false false false)
_check_header() {
    _is_enabled header || return 0
    for idx in "${!HEADERS[@]}"; do
        if [[ "$line" == "${HEADERS[$idx]}"* ]]; then
            _RES_HEADER[idx]=true
            break
        fi
    done
}
_res_header() {
    _is_enabled header || return 0
    for idx in "${!_RES_HEADER[@]}"; do
        if ${_RES_HEADER[$idx]}; then
            continue
        fi
        _err style "$file" "missing header: '${HEADERS[$idx]}'"
    done
}

_check_tabs() {
    _is_enabled tabs || return 0
    if [[ "$line" =~ $'\t' ]]; then
        _err style "$file:$line_number" "tabs are not allowed"
    fi
}

_check_trailing() {
    _is_enabled trailing || return 0
    if [[ "$line" =~ [[:space:]]+$ ]]; then
        _err style "$file:$line_number" "line has trailing whitespace"
    fi
}

_CHECK_IN_PROFILE=false
_CHECK_FIRST_LINE_AFTER_PROFILE=true
_check_indentation() {
    _is_enabled indentation || return 0
    if [[ "$line" =~ ^profile ]]; then
        _CHECK_IN_PROFILE=true
        _CHECK_FIRST_LINE_AFTER_PROFILE=true

    elif $_CHECK_IN_PROFILE; then
        if $_CHECK_FIRST_LINE_AFTER_PROFILE; then
            local leading_spaces="${line%%[! ]*}"
            local num_spaces=${#leading_spaces}
            if ((num_spaces != 2)); then
                _err style "$file:$line_number" "profile must have a two-space indentation"
            fi
            _CHECK_FIRST_LINE_AFTER_PROFILE=false

        else
            local leading_spaces="${line%%[! ]*}"
            local num_spaces=${#leading_spaces}

            if ((num_spaces % 2 != 0)); then
                ok=false
                for offset in 5 11; do
                    num_spaces=$((num_spaces - offset))
                    if ((num_spaces < 0)); then
                        break
                    fi
                    if ((num_spaces % 2 == 0)); then
                        ok=true
                        break
                    fi
                done

                if ! $ok; then
                    _err style "$file:$line_number" "invalid indentation"
                fi
            fi
        fi
    fi
}

_CHEK_IN_SUBPROFILE=false
declare -A _RES_SUBPROFILES
_check_subprofiles() {
    _is_enabled subprofiles || return 0
    if [[ "$line" =~ ^('  ')+'profile '(.*)' {' ]]; then
        indentation="${BASH_REMATCH[1]}"
        subprofile="${BASH_REMATCH[2]}"
        subprofile="${subprofile%% *}"
        include="${indentation}include if exists <local/${name}_${subprofile}>"
        _RES_SUBPROFILES["$subprofile"]="$name//$subprofile does not contain '$include'"
        _CHEK_IN_SUBPROFILE=true
    elif $_CHEK_IN_SUBPROFILE; then
        if [[ "$line" == *"$include" ]]; then
            _RES_SUBPROFILES["$subprofile"]=true

        fi
    fi
}
_res_subprofiles() {
    _is_enabled subprofiles || return 0
    for msg in "${_RES_SUBPROFILES[@]}"; do
        if [[ $msg == true ]]; then
            continue
        fi
        _err guideline "$file" "$msg"
    done
}

readonly VIM_SYNTAX="# vim:syntax=apparmor"
RES_VIM=false
_check_vim() {
    _is_enabled vim || return 0
    if [[ "$line" =~ ^"$VIM_SYNTAX" ]]; then
        RES_VIM=true
    fi
}
_res_vim() {
    _is_enabled vim || return 0
    if ! $RES_VIM; then
        _err style "$file" "missing vim syntax: '$VIM_SYNTAX'"
    fi
}

check_sbin() {
    local file name jobs
    mapfile -t sbin <tests/sbin.list
    _msg "Ensuring '@{bin} and '@{sbin}' are correctly used in profiles"

    jobs=0
    for name in "${sbin[@]}"; do
        (
            mapfile -t files < <(grep --line-number --recursive -E "(^|[[:space:]])@{bin}/$name([[:space:]]|$)" apparmor.d | cut -d: -f1,2)
            for file in "${files[@]}"; do
                _err compatibility "$file" "contains '@{bin}/$name' instead of '@{sbin}/$name'"
            done
        ) &
        _wait jobs
    done
    wait

    local pattern='[[:alnum:]_.-]+' # Pattern for valid file names
    jobs=0
    mapfile -t files < <(grep --line-number --recursive -E "(^|[[:space:]])@{sbin}/$pattern([[:space:]]|$)" apparmor.d | cut -d: -f1,2)
    for file in "${files[@]}"; do
        (
            while read -r match; do
                name="${match/\@\{sbin\}\//}"
                if ! _in_array "$name" "${sbin[@]}"; then
                    _err compatibility "$file" "contains '@{sbin}/$name' but it is not in sbin.list"
                fi
            done < <(grep --only-matching -E "@\{sbin\}/$pattern" "${file%%:*}")
        ) &
        _wait jobs
    done
    wait
}

check_profiles() {
    _msg "Checking profiles"
    mapfile -t files < <(
        find "$APPARMORD" \( -path "$APPARMORD/abstractions" -o -path "$APPARMORD/local" -o -path "$APPARMORD/tunables" -o -path "$APPARMORD/mappings" \) \
            -prune -o -type f -print
    )
    jobs=0
    WITH_CHECK=(
        abstractions equivalent
        abi include profile header tabs trailing indentation subprofiles vim
    )
    for file in "${files[@]}"; do
        (
            name="$(basename "$file")"
            name="${name/.apparmor.d/}"
            include="include if exists <local/$name>"
            _check "$file"
        ) &
        _wait jobs
    done
    wait
}

check_abstractions() {
    _msg "Checking abstractions"
    mapfile -t files < <(find "$APPARMORD/abstractions" -type f -not -path "$APPARMORD/abstractions/*.d/*" 2>/dev/null || true)
    jobs=0
    WITH_CHECK=(
        abstractions equivalent
        abi include header tabs trailing indentation vim
    )
    for file in "${files[@]}"; do
        (
            name="$(basename "$file")"
            absdir="${file/${APPARMORD}\//}"
            include="include if exists <${absdir}.d>"
            _check "$file"
        ) &
        _wait jobs
    done
    wait

    mapfile -t files < <(
        find "$APPARMORD/abstractions" -type f -path "$APPARMORD/abstractions/*.d/*" 2>/dev/null || true
        find "$APPARMORD/mappings" -type f 2>/dev/null || true
    )
    # shellcheck disable=SC2034
    jobs=0
    WITH_CHECK=(
        abstractions equivalent
        header tabs trailing indentation vim
    )
    for file in "${files[@]}"; do
        _check "$file" &
        _wait jobs
    done
    wait
}

check_sbin
check_profiles
check_abstractions

FAIL=$(cat "$RES")
if [[ "$FAIL" == "true" ]]; then
    exit 1
fi

#!/usr/bin/env bash
# tui.sh — Whiptail TUI wrappers for AGMind installer wizard.
# Dependencies: common.sh (colors, log_*)
# Provides: wt_menu, wt_radio, wt_checklist, wt_input, wt_password,
#           wt_yesno, wt_msg, wt_gauge, wt_info
# Falls back to plain text if whiptail is unavailable or NON_INTERACTIVE=true.
set -euo pipefail

# ============================================================================
# THEME — Black & Green (Matrix/hacker style)
# ============================================================================

export NEWT_COLORS='
root=green,black
border=green,black
window=green,black
shadow=black,black
title=brightgreen,black
button=black,green
actbutton=black,brightgreen
compactbutton=green,black
checkbox=green,black
actcheckbox=black,brightgreen
entry=brightgreen,black
label=green,black
listbox=green,black
actlistbox=black,green
sellistbox=brightgreen,black
actsellistbox=black,brightgreen
textbox=green,black
acttextbox=black,green
helpline=brightgreen,black
roottext=brightgreen,black
emptyscale=black,black
fullscale=green,black
disentry=gray,black
'

# ============================================================================
# SIZING — adaptive to terminal
# ============================================================================

_wt_height=""
_wt_width=""

wt_get_size() {
    local term_h term_w
    term_h="$(tput lines 2>/dev/null || true)"
    term_w="$(tput cols 2>/dev/null || true)"
    # Fallback if tput returns non-numeric (no TTY, sudo, pipe)
    if ! [[ "$term_h" =~ ^[0-9]+$ ]]; then term_h=24; fi
    if ! [[ "$term_w" =~ ^[0-9]+$ ]]; then term_w=80; fi
    # Clamp: height 12-40, width 60-120
    if [[ "$term_h" -lt 12 ]]; then _wt_height=12;
    elif [[ "$term_h" -gt 40 ]]; then _wt_height=40;
    else _wt_height="$term_h"; fi
    if [[ "$term_w" -lt 60 ]]; then _wt_width=60;
    elif [[ "$term_w" -gt 120 ]]; then _wt_width=120;
    else _wt_width="$term_w"; fi
}

# Ensure sizes are set
wt_get_size

# ============================================================================
# AVAILABILITY CHECK
# ============================================================================

_wt_available() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then return 1; fi
    command -v whiptail &>/dev/null
}

# ============================================================================
# MENU — single selection from numbered items
# Usage: result=$(wt_menu "Title" "Description" "tag1" "label1" "tag2" "label2" ...)
# Returns: selected tag via stdout
# ============================================================================

wt_menu() {
    local title="$1" desc="$2"
    shift 2

    if ! _wt_available; then
        # Fallback: plain text
        echo "$desc" >&2
        local i=0
        local -a tags=()
        while [[ $# -gt 0 ]]; do
            i=$((i + 1))
            tags+=("$1")
            echo "  ${i}) $2" >&2
            shift 2
        done
        local choice
        read -rp "Выбор: " choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#tags[@]}" ]]; then
            echo "${tags[$((choice - 1))]}"
        else
            echo "${tags[0]}"
        fi
        return
    fi

    wt_get_size
    local list_h=$(( _wt_height - 8 ))
    if [[ "$list_h" -lt 4 ]]; then list_h=4; fi

    local result
    result=$(whiptail --title "$title" --menu "$desc" \
        "$_wt_height" "$_wt_width" "$list_h" \
        "$@" \
        3>&1 1>&2 2>&3) || true
    echo "$result"
}

# ============================================================================
# RADIOLIST — single selection with descriptions (radio buttons)
# Usage: result=$(wt_radio "Title" "Desc" "tag1" "label1" "ON" "tag2" "label2" "OFF" ...)
# Returns: selected tag
# ============================================================================

wt_radio() {
    local title="$1" desc="$2"
    shift 2

    if ! _wt_available; then
        echo "$desc" >&2
        local i=0
        local -a tags=()
        while [[ $# -gt 0 ]]; do
            i=$((i + 1))
            tags+=("$1")
            local marker=" "
            if [[ "$3" == "ON" ]]; then marker="*"; fi
            echo "  ${i}) [${marker}] $2" >&2
            shift 3
        done
        local choice
        read -rp "Выбор: " choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#tags[@]}" ]]; then
            echo "${tags[$((choice - 1))]}"
        else
            # Return the ON item
            echo "${tags[0]}"
        fi
        return
    fi

    wt_get_size
    local list_h=$(( _wt_height - 8 ))
    if [[ "$list_h" -lt 4 ]]; then list_h=4; fi

    local result
    result=$(whiptail --title "$title" --radiolist "$desc" \
        "$_wt_height" "$_wt_width" "$list_h" \
        "$@" \
        3>&1 1>&2 2>&3) || true
    echo "$result"
}

# ============================================================================
# CHECKLIST — multi-selection with checkboxes
# Usage: result=$(wt_checklist "Title" "Desc" "tag1" "label1" "ON" "tag2" "label2" "OFF" ...)
# Returns: space-separated selected tags (quoted by whiptail)
# ============================================================================

wt_checklist() {
    local title="$1" desc="$2"
    shift 2

    if ! _wt_available; then
        echo "$desc" >&2
        local i=0
        local -a tags=() defaults=()
        while [[ $# -gt 0 ]]; do
            i=$((i + 1))
            tags+=("$1")
            local marker=" "
            if [[ "$3" == "ON" ]]; then marker="x"; fi
            defaults+=("$3")
            echo "  ${i}) [${marker}] $2" >&2
            shift 3
        done
        local choice
        read -rp "Введите номера через пробел: " choice </dev/tty
        if [[ -z "$choice" ]]; then
            # Return defaults
            local result=""
            for ((j=0; j<${#tags[@]}; j++)); do
                if [[ "${defaults[$j]}" == "ON" ]]; then result+="${tags[$j]} "; fi
            done
            echo "$result"
        else
            local result=""
            for num in $choice; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 && "$num" -le "${#tags[@]}" ]]; then
                    result+="${tags[$((num - 1))]} "
                fi
            done
            echo "$result"
        fi
        return
    fi

    wt_get_size
    local list_h=$(( _wt_height - 8 ))
    if [[ "$list_h" -lt 4 ]]; then list_h=4; fi

    local result
    result=$(whiptail --title "$title" --checklist "$desc" \
        "$_wt_height" "$_wt_width" "$list_h" \
        "$@" \
        3>&1 1>&2 2>&3) || true
    echo "$result"
}

# ============================================================================
# INPUT — free text input
# Usage: result=$(wt_input "Title" "Prompt text" "default_value")
# Returns: entered text
# ============================================================================

wt_input() {
    local title="$1" prompt="$2" default="${3:-}"

    if ! _wt_available; then
        local val
        read -rp "${prompt} [${default}]: " val </dev/tty
        echo "${val:-$default}"
        return
    fi

    wt_get_size
    local result
    result=$(whiptail --title "$title" --inputbox "$prompt" \
        $(( _wt_height > 12 ? 10 : 8 )) "$_wt_width" "$default" \
        3>&1 1>&2 2>&3) || true
    echo "${result:-$default}"
}

# ============================================================================
# PASSWORD — hidden input
# Usage: result=$(wt_password "Title" "Enter password:")
# ============================================================================

wt_password() {
    local title="$1" prompt="$2"

    if ! _wt_available; then
        local val
        read -rsp "${prompt} " val </dev/tty
        echo ""  >&2
        echo "$val"
        return
    fi

    wt_get_size
    local result
    result=$(whiptail --title "$title" --passwordbox "$prompt" \
        $(( _wt_height > 12 ? 10 : 8 )) "$_wt_width" \
        3>&1 1>&2 2>&3) || true
    echo "$result"
}

# ============================================================================
# YESNO — yes/no confirmation
# Usage: wt_yesno "Title" "Question text" [--defaultno]
# Returns: 0=yes, 1=no
# ============================================================================

wt_yesno() {
    local title="$1" question="$2" default_flag="${3:-}"

    if ! _wt_available; then
        local suffix="[Y/n]"
        if [[ "$default_flag" == "--defaultno" ]]; then suffix="[y/N]"; fi
        local ans
        read -rp "${question} ${suffix}: " ans </dev/tty
        case "${ans,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)
                if [[ "$default_flag" == "--defaultno" ]]; then return 1; fi
                return 0
                ;;
        esac
    fi

    wt_get_size
    whiptail --title "$title" --yesno "$question" \
        $(( _wt_height > 12 ? 10 : 8 )) "$_wt_width" \
        ${default_flag:+$default_flag}
}

# ============================================================================
# MSGBOX — informational message
# Usage: wt_msg "Title" "Message text"
# ============================================================================

wt_msg() {
    local title="$1" msg="$2"

    if ! _wt_available; then
        echo "=== ${title} ===" >&2
        echo "$msg" >&2
        return
    fi

    wt_get_size
    whiptail --title "$title" --msgbox "$msg" \
        "$_wt_height" "$_wt_width"
}

# ============================================================================
# INFOBOX — non-blocking message (no OK button)
# Usage: wt_info "Title" "Processing..."
# ============================================================================

wt_info() {
    local title="$1" msg="$2"

    if ! _wt_available; then
        echo "→ ${msg}" >&2
        return
    fi

    wt_get_size
    whiptail --title "$title" --infobox "$msg" \
        8 "$_wt_width"
}

# ============================================================================
# GAUGE — progress bar
# Usage: echo "50" | wt_gauge "Title" "Working..."
#   or pipe percentages line by line
# ============================================================================

wt_gauge() {
    local title="$1" msg="$2"

    if ! _wt_available; then
        echo "→ ${msg}" >&2
        cat >/dev/null  # consume stdin
        return
    fi

    wt_get_size
    whiptail --title "$title" --gauge "$msg" \
        8 "$_wt_width" 0
}

# ============================================================================
# PARSE — strip whiptail quotes from checklist output
# Usage: wt_parse "\"item1\" \"item2\"" → item1 item2
# ============================================================================

wt_parse() {
    echo "$1" | tr -d '"'
}

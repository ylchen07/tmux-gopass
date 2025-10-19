#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${CURRENT_DIR}/utils.sh"

OPT_HIDE_PREVIEW="$(get_tmux_option "@pass-hide-preview" "off")"
OPT_HIDE_PW_FROM_PREVIEW="$(get_tmux_option "@pass-hide-pw-from-preview" "on")"
OPT_DISABLE_SPINNER="$(get_tmux_option "@pass-enable-spinner" "on")"

spinner_pid=""

# Taken from:
# https://github.com/yardnsm/dotfiles/blob/master/_setup/utils/spinner.sh
show_spinner() {
    local -r MSG="$1"
    local -r FRAMES="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local -r DELAY=0.05

    local i=0
    local current_symbol

    trap 'exit 0' SIGTERM

    while true; do
        current_symbol="${FRAMES:i++%${#FRAMES}:1}"
        printf "\\e[0;34m%s\\e[0m  %s" "$current_symbol" "$MSG"
        printf "\\r"
        sleep $DELAY
    done

    return $?
}

spinner_start() {
    if [ "$OPT_DISABLE_SPINNER" = "on" ]; then
        tput civis
        show_spinner "$1" &
        spinner_pid=$!
    fi
}

spinner_stop() {
    if [ "$OPT_DISABLE_SPINNER" = "on" ]; then
        tput cnorm
        kill "$spinner_pid" &>/dev/null
        spinner_pid=""
    fi
}

ensure_gopass() {
    if ! command -v gopass >/dev/null 2>&1; then
        display_message "install gopass to use this plugin"
        exit 1
    fi
}

get_items() {
    local items

    if items="$(gopass ls --flat 2>/dev/null)"; then
        printf "%s\n" "$items" | sed '/^[[:space:]]*$/d' | sort
        return 0
    fi

    local -r store_root="${PASSWORD_STORE_DIR:-$HOME/.password-store}"

    if [[ ! -d "$store_root" ]]; then
        return 1
    fi

    pushd "$store_root" 1>/dev/null || return 1
    find . -type f -name '*.gpg' | sed 's/\.gpg//' | sed 's/^\.\///' | sort
    popd 1>/dev/null || return 1
}

get_password() {
    gopass show --password "${1}" 2>/dev/null | head -n1
}

get_otp() {
    gopass otp "${1}" 2>/dev/null | head -n1
}

get_login() {
    local keys="user login username"
    local match

    for candidate in $keys; do
        match=$(gopass show "${1}" 2>/dev/null | grep -i "$candidate" | cut -d ':' -f 2 | xargs)

        if [[ -n $match ]]; then break; fi
    done

    echo "$match"
}

build_preview_command() {
    if [[ "$OPT_HIDE_PW_FROM_PREVIEW" == "on" ]]; then
        echo 'gopass show {} | tail -n +2'
    else
        echo 'gopass show {}'
    fi
}

copy_password_with_gopass() {
    local -r entry="$1"

    spinner_start "Copying password"
    if ! gopass show --clip "$entry" >/dev/null 2>&1; then
        spinner_stop
        display_message "failed to copy password with gopass"
        return 1
    fi
    spinner_stop
    return 0
}

send_to_pane() {
    local -r pane="$1"
    local -r value="$2"

    tmux send-keys -t "$pane" -- "$value"
}

handle_password_copy() {
    local -r entry="$1"

    copy_password_with_gopass "$entry"
}

handle_password_selection() {
    local -r pane="$1"
    local -r entry="$2"

    spinner_start "Fetching password"
    local password
    password="$(get_password "$entry")"
    spinner_stop

    if [[ -z "$password" ]]; then
        display_message "password not found for $entry"
        return
    fi

    send_to_pane "$pane" "$password"
}

handle_login_selection() {
    local -r pane="$1"
    local -r entry="$2"

    spinner_start "Fetching username"
    local login
    login="$(get_login "$entry")"
    spinner_stop

    send_to_pane "$pane" "$login"
}

handle_otp_selection() {
    local -r pane="$1"
    local -r entry="$2"

    spinner_start "Fetching otp"
    local otp
    otp="$(get_otp "$entry")"
    spinner_stop

    if [[ -z "$otp" ]]; then
        display_message "otp not found for $entry"
        return
    fi

    send_to_pane "$pane" "$otp"
}

main() {
    local -r ACTIVE_PANE="$1"
    local standalone="false"

    if [[ -z "$TMUX" ]] || [[ -z "$ACTIVE_PANE" ]]; then
        standalone="true"
    fi

    ensure_gopass

    local items
    local sel
    local key
    local entry
    local fzf_expect_keys
    local header
    local -a fzf_args=(
        --inline-info
        --no-multi
        --tiebreak=begin
        --bind=tab:toggle-preview
        --preview="$(build_preview_command)"
    )

    if [[ "$standalone" == "true" ]]; then
        header='enter=copy'
        fzf_expect_keys='enter'
    else
        header='enter=copy, ctrl-y=paste, tab=preview, alt-enter=user, alt-space=otp'
        fzf_expect_keys='enter,ctrl-y,alt-enter,alt-space'
        fzf_args+=(
            --bind=alt-enter:accept
            --bind=ctrl-y:accept
        )
    fi

    fzf_args+=(
        --header="$header"
        --expect="$fzf_expect_keys"
    )

    if [[ "$OPT_HIDE_PREVIEW" == "on" ]]; then
        fzf_args+=("--preview-window=hidden")
    fi

    spinner_start "Fetching items"
    if ! items="$(get_items)"; then
        spinner_stop
        display_message "unable to list gopass entries"
        exit 1
    fi
    spinner_stop

    if [[ -z "$items" ]]; then
        display_message "no entries found"
        exit 0
    fi

    sel="$(printf "%s\n" "$items" |
        fzf "${fzf_args[@]}")"
    local -r fzf_status=$?

    if ((fzf_status > 0)); then
        echo "error: unable to complete command - check/report errors above"
        echo "You can also set the fzf path in options (see readme)."
        read -r
        exit
    fi

    key=$(head -1 <<<"$sel")
    entry=$(tail -n +2 <<<"$sel")

    if [[ -z "$entry" ]]; then
        exit 0
    fi

    case $key in

    enter)
        handle_password_copy "$entry"
        ;;

    ctrl-y)
        handle_password_selection "$ACTIVE_PANE" "$entry"
        ;;

    alt-enter)
        handle_login_selection "$ACTIVE_PANE" "$entry"
        ;;

    alt-space)
        handle_otp_selection "$ACTIVE_PANE" "$entry"
        ;;

    esac
}

main "$@"

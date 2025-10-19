#!/usr/bin/env bash

get_tmux_option() {
    local option=$1
    local default_value=$2
    local option_value

    if ! command -v tmux >/dev/null 2>&1; then
        echo "$default_value"
        return
    fi

    option_value=$(tmux show-option -gqv "$option")

    if [[ -z "$option_value" ]]; then
        echo "$default_value"
    else
        echo "$option_value"
    fi
}

display_message() {
    local -r msg="tmux-gopass: $1"

    if [[ -n "$TMUX" ]] && command -v tmux >/dev/null 2>&1; then
        tmux display-message "$msg"
    else
        printf '%s\n' "$msg" >&2
    fi
}

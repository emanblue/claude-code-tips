#!/usr/bin/env bash
# Revision 2 — safer, more robust, preserves existing visual output/format
# Context/status bar for Claude CLI

set -euo pipefail
IFS=$'\n\t'

# Color theme: gray, orange, blue, teal, green, lavender, rose, gold, slate, cyan
# Preview colors with: bash scripts/color-preview.sh
# PROGRESS_BAR_DYNAMIC: if set to 1, the progress bar width will be chosen
# dynamically from the terminal width (min 8, max 40). Default: 0 (fixed width).
COLOR="${COLOR:-blue}"
PROGRESS_BAR_DYNAMIC="${PROGRESS_BAR_DYNAMIC:-0}"

C_RESET='\033[0m'
C_GRAY='\033[38;5;245m'
C_BAR_EMPTY='\033[38;5;238m'

case "$COLOR" in
    orange)   C_ACCENT='\033[38;5;173m' ;;
    blue)     C_ACCENT='\033[38;5;74m' ;;
    teal)     C_ACCENT='\033[38;5;66m' ;;
    green)    C_ACCENT='\033[38;5;71m' ;;
    lavender) C_ACCENT='\033[38;5;139m' ;;
    rose)     C_ACCENT='\033[38;5;132m' ;;
    gold)     C_ACCENT='\033[38;5;136m' ;;
    slate)    C_ACCENT='\033[38;5;60m' ;;
    cyan)     C_ACCENT='\033[38;5;37m' ;;
    *)        C_ACCENT="$C_GRAY" ;;
esac

# Dependencies
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "error: 'jq' is required but not installed" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    printf '%s\n' "error: 'git' is required but not installed" >&2
    exit 1
fi

input="$(cat -)"

# Extract JSON fields safely (defaults if missing)
read -r model cwd transcript_path max_context < <(
    jq -r '
        (.model.display_name // .model.id // "?"),
        (.cwd // ""),
        (.transcript_path // ""),
        (.context_window.context_window_size // 200000)
    ' <<< "$input"
)

# Normalize directory display
if [[ -n "${cwd:-}" ]]; then
    dir="$(basename "$cwd" 2>/dev/null || echo "?")"
else
    dir="?"
fi

# Cross-platform mtime
get_mtime() {
    local file="$1"
    if stat -f %m "$file" >/dev/null 2>&1; then
        stat -f %m "$file" 2>/dev/null
    else
        stat -c %Y "$file" 2>/dev/null
    fi
}

# Determine bar width (fixed by default, optional dynamic)
get_bar_width() {
    # default fixed width (preserve original visuals)
    local default_width=10
    if [[ "${PROGRESS_BAR_DYNAMIC}" != "1" ]]; then
        printf '%d' "$default_width"
        return
    fi

    # attempt to read terminal width, fallback to 80
    local cols=80
    if [[ -n "${COLUMNS:-}" && "${COLUMNS}" =~ ^[0-9]+$ ]]; then
        cols="$COLUMNS"
    elif command -v tput >/dev/null 2>&1; then
        cols="$(tput cols 2>/dev/null || echo 80)"
    fi

    # allocate ~30% of terminal width to bar; clamp between 8 and 40
    local width=$(( cols * 30 / 100 ))
    (( width < 8 )) && width=8
    (( width > 40 )) && width=40
    printf '%d' "$width"
}

# Build progress bar
# Arguments: pct width
build_progress_bar() {
    local pct="$1"
    local bar_width="$2"
    local bar=""

    # compute filled segments and possible partial
    local filled_count=$(( pct * bar_width / 100 ))
    local partial_threshold=$(( (pct * bar_width) % 100 ))

    for ((i=0; i<bar_width; i++)); do
        if (( i < filled_count )); then
            bar+="${C_ACCENT}█${C_RESET}"
        elif (( i == filled_count )) && (( partial_threshold >= 30 )); then
            bar+="${C_ACCENT}▄${C_RESET}"
        else
            bar+="${C_BAR_EMPTY}░${C_RESET}"
        fi
    done
    printf '%s' "$bar"
}

# Human-readable relative time
format_time_ago() {
    local diff=$1
    if [[ $diff -lt 60 ]]; then
        echo "<1m ago"
    elif [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60))m ago"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

# Git branch, uncommitted files, and sync status (defensive)
branch=""
git_status=""
if [[ -n "${cwd:-}" && -d "$cwd" ]]; then
    branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
    if [[ -n "$branch" ]]; then
        git_porcelain="$(git -C "$cwd" --no-optional-locks status --porcelain -uall 2>/dev/null || true)"
        # count non-empty lines robustly
        file_count="$(printf '%s\n' "$git_porcelain" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
        file_count="${file_count:-0}"

        sync_status=""
        upstream="$(git -C "$cwd" rev-parse --abbrev-ref @{upstream} 2>/dev/null || true)"
        if [[ -n "$upstream" ]]; then
            fetch_head="$cwd/.git/FETCH_HEAD"
            fetch_ago=""
            if [[ -f "$fetch_head" ]]; then
                fetch_time="$(get_mtime "$fetch_head" || true)"
                if [[ -n "$fetch_time" ]]; then
                    now="$(date +%s)"
                    diff=$((now - fetch_time))
                    fetch_ago="$(format_time_ago "$diff")"
                fi
            fi

            counts="$(git -C "$cwd" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || true)"
            if [[ -n "$counts" ]]; then
                ahead="$(printf '%s' "$counts" | cut -f1)"
                behind="$(printf '%s' "$counts" | cut -f2)"
            else
                ahead=0
                behind=0
            fi
            ahead="${ahead:-0}"
            behind="${behind:-0}"

            if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
                sync_status="synced"
                [[ -n "$fetch_ago" ]] && sync_status+=" ${fetch_ago}"
            elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
                sync_status="${ahead} ahead"
            elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
                sync_status="${behind} behind"
            else
                sync_status="${ahead} ahead, ${behind} behind"
            fi
        else
            sync_status="no upstream"
        fi

        if [[ "$file_count" -eq 0 ]]; then
            git_status="(0 files uncommitted, ${sync_status})"
        elif [[ "$file_count" -eq 1 ]]; then
            single_file="$(printf '%s\n' "$git_porcelain" | sed '/^[[:space:]]*$/d' | head -n1 | sed 's/^...//')"
            git_status="(${single_file} uncommitted, ${sync_status})"
        else
            git_status="(${file_count} files uncommitted, ${sync_status})"
        fi
    fi
fi

# Format context window size for display
max_context="${max_context:-200000}"
if ! [[ "$max_context" =~ ^[0-9]+$ ]]; then
    max_context=200000
fi

max_k=$(( max_context / 1000 ))
if [[ $max_k -ge 1000 ]]; then
    max_display="$((max_k / 1000))M"
else
    max_display="${max_k}k"
fi

# Calculate context usage from transcript (defensive)
pct=0
pct_prefix=""
if [[ -n "${transcript_path:-}" && -f "$transcript_path" ]]; then
    context_length="$(jq -s '
        map(select(.message.usage and .isSidechain != true and .isApiErrorMessage != true)) |
        if length > 0 then
            (.[-1].message.usage.input_tokens // 0) +
            (.[-1].message.usage.cache_read_input_tokens // 0) +
            (.[-1].message.usage.cache_creation_input_tokens // 0)
        else 0 end
    ' < "$transcript_path" 2>/dev/null || echo 0)"
    context_length="${context_length:-0}"

    if [[ "$context_length" -gt 0 ]]; then
        if [[ "$max_context" -gt 0 ]]; then
            pct=$(( context_length * 100 / max_context ))
            pct_prefix=""
        else
            pct=100
            pct_prefix=""
        fi
    else
        baseline=20000
        if [[ "$max_context" -gt 0 ]]; then
            pct=$(( baseline * 100 / max_context ))
        else
            pct=100
        fi
        pct_prefix="~"
    fi
else
    baseline=20000
    if [[ "$max_context" -gt 0 ]]; then
        pct=$(( baseline * 100 / max_context ))
    else
        pct=100
    fi
    pct_prefix="~"
fi

if [[ $pct -gt 100 ]]; then pct=100; fi
bar_width="$(get_bar_width)"
bar="$(build_progress_bar "$pct" "$bar_width")"
ctx="${bar} ${C_GRAY}${pct_prefix}${pct}% of ${max_display} tokens"

# Output colored status line (preserve established format)
output="${C_ACCENT}${model}${C_GRAY} | 📁${dir}"
[[ -n "${branch:-}" ]] && output+=" | 🔀${branch} ${git_status}"
output+=" | ${ctx}${C_RESET}"
printf '%b\n' "$output"

# Display user's last message (text only, skip unhelpful messages)
if [[ -n "${transcript_path:-}" && -f "$transcript_path" ]]; then
    plain_output="${model} | 📁${dir}"
    [[ -n "${branch:-}" ]] && plain_output+=" | 🔀${branch} ${git_status}"
    plain_output+=" | xxxxxxxxxx ${pct}% of ${max_display} tokens"
    max_len=${#plain_output}

    last_user_msg="$(jq -rs '
        def is_unhelpful:
            startswith("[Request interrupted") or
            startswith("[Request cancelled") or
            . == "";

        [.[] | select(.type == "user") |
         select(.message.content | type == "string" or
                (type == "array" and any(.[]; .type == "text")))] |
        reverse |
        map(.message.content |
            if type == "string" then .
            else [.[] | select(.type == "text") | .text] | join(" ") end |
            gsub("\n"; " ") | gsub("  +"; " ")) |
        map(select(is_unhelpful | not)) |
        first // ""
    ' < "$transcript_path" 2>/dev/null || echo "")"

    if [[ -n "$last_user_msg" ]]; then
        if [[ ${#last_user_msg} -gt $max_len ]]; then
            printf '💬 %s...\n' "${last_user_msg:0:$((max_len - 3))}"
        else
            printf '💬 %s\n' "$last_user_msg"
        fi
    fi
fi

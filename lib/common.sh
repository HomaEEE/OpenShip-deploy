#!/usr/bin/env bash
# ==============================================================================
# OpenShip Installer — Common Utilities, Logging & Prompts
# ==============================================================================

log() {
    echo -e "  ${BLUE}·${NC} $*"
}

success() {
    echo -e "  ${GREEN}✓${NC} $*"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC}  $*"
}

error() {
    echo -e "  ${RED}✗${NC} $*" >&2
}

die() {
    echo
    error "$*"
    echo -e "  ${DIM}Log: ${LOG_FILE}${NC}"
    echo
    exit 1
}

section() {
    local title=" $* "
    local width=$(( _TW < 72 ? _TW : 72 ))
    local pad=$(( (width - ${#title} - 2) / 2 ))
    local line
    printf -v line '%*s' "$width" ''
    line="${line// /─}"
    local prefix="${line:0:$pad}"
    local suffix="${line:0:$(( width - pad - ${#title} ))}"
    echo
    echo -e "${BOLD}${CYAN}${prefix}${title}${suffix}${NC}"
    echo
}

run_task() {
    local msg="$1"
    shift
    local pid i=0
    local frames=(
        "[■         ]"
        "[■■        ]"
        "[■■■       ]"
        "[ ■■■      ]"
        "[  ■■■     ]"
        "[   ■■■    ]"
        "[    ■■■   ]"
        "[     ■■■  ]"
        "[      ■■■ ]"
        "[       ■■■]"
        "[        ■■]"
        "[         ■]"
    )

    ("$@") >> "$LOG_FILE" 2>&1 &
    pid=$!

    if [[ -e /dev/tty && -w /dev/tty ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r  ${CYAN}%s${NC} %s..." "${frames[i]}" "$msg" >/dev/tty 2>/dev/null || break
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
        wait "$pid"
        local status=$?
        if (( status == 0 )); then
            printf "\r\033[K  ${GREEN}✔${NC} %s\n" "$msg" >/dev/tty 2>/dev/null || success "$msg"
        else
            printf "\r\033[K  ${RED}✖${NC} %s (failed, exit %d)\n" "$msg" "$status" >/dev/tty 2>/dev/null || error "$msg failed"
            return "$status"
        fi
    else
        log "${msg}..."
        wait "$pid"
        local status=$?
        if (( status == 0 )); then
            success "$msg"
        else
            error "$msg (failed, exit $status)"
            return "$status"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_no=$1

    echo
    error "Installation failed."
    error "Line: ${line_no}"
    error "Exit code: ${exit_code}"
    error "Log: ${LOG_FILE}"
    echo

    exit "$exit_code"
}

trap 'on_error ${LINENO}' ERR

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n]: " answer </dev/tty
        answer="${answer//[$'\r\n\t ']/}"
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N]: " answer </dev/tty
        answer="${answer//[$'\r\n\t ']/}"
        answer="${answer:-N}"
    fi

    case "${answer,,}" in
        y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value </dev/tty
    value="${value//[$'\r\n']/}"

    echo "${value:-$default}"
}

ask_password() {
    local prompt="$1"
    local password=""
    local char=""

    if [[ ! -e /dev/tty || ! -r /dev/tty ]]; then
        read -r -s -p "$prompt" password
        echo
        echo "${password//[$'\r\n']/}"
        return
    fi

    printf "%s" "$prompt" >/dev/tty

    while IFS= read -r -s -n 1 char </dev/tty; do
        if [[ -z "$char" || "$char" == $'\r' || "$char" == $'\n' ]]; then
            printf "\n" >/dev/tty
            break
        fi

        # Backspace / Delete (127 or \b)
        if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
            if (( ${#password} > 0 )); then
                password="${password%?}"
                printf "\b \b" >/dev/tty
            fi
        else
            password+="$char"
            printf "*" >/dev/tty
        fi
    done

    echo "${password//[$'\r\n']/}"
}

valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]
}

valid_ssh_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( "$1" >= 1 && "$1" <= 65535 ))
}

# ------------------------------------------------------------------------------
# Root
# ------------------------------------------------------------------------------

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "Run this installer as root or with sudo."
    fi
}

# ------------------------------------------------------------------------------
# OS
# ------------------------------------------------------------------------------


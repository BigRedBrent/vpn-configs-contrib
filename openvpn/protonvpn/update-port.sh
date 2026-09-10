#!/usr/bin/env bash

set -euo pipefail

. /etc/transmission/environment-variables.sh
ENABLE_PORT_CHECK="${ENABLE_PORT_CHECK:-false}"
TRANSMISSION_PASSWD_FILE=/config/transmission-credentials.txt
transmission_username=$(head -1 "${TRANSMISSION_PASSWD_FILE}")
transmission_passwd=$(tail -1 "${TRANSMISSION_PASSWD_FILE}")
transmission_settings_file=${TRANSMISSION_HOME}/settings.json
transmission_auth=""
new_port="unset"
last_port="unset"
current_port="unset"
double_check="false"
check_port_retry="false"
check_port_first_try="true"
check_port_last="unset"

# Uncomment to force enabling port checking:
#ENABLE_PORT_CHECK="true"

log() { echo -e "update-port:\t$1"; }

box_out() {
    local s="$*"
    printf "\033[36m╭─%s─╮\n\033[36m│ \033[34m%s\033[36m │\n\033[36m╰─%s─╯\033[0;39m\n" "${s//?/─}" "$s" "${s//?/─}"
}

install_package() {
    if command -v "$1" > /dev/null 2>&1; then
        #log "Updating $1..."
        #apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "$1" >/dev/null 2>&1
        return 0
    fi
    log "$1 not found – installing now..."
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "$1" >/dev/null 2>&1
    if ! command -v "$1" > /dev/null 2>&1; then
        log "Failed to install $1! $1 is required to configure ProtonVPN port forwarding."
        log "Port forwarding for ProtonVPN has not been configured."
        return 1
    fi
    log "$1 has been successfully installed."
    return 0
}

open_port() {
    timeout 5 natpmpc -a 1 0 udp 60 > /dev/null 2>&1 && timeout 5 natpmpc -a 1 0 tcp 60
}

remote() {
    if [[ -n "$transmission_auth" ]]; then
        timeout 5 "$tr_cmd" "$TRANSMISSION_RPC_PORT" --auth "$transmission_auth" --json "$@"
    else
        timeout 5 "$tr_cmd" "$TRANSMISSION_RPC_PORT" --json "$@"
    fi
}

# Accepts both the pre-4.1 and JSON-RPC 2.0 response shapes.
rpc_ok() {
    jq -e '
        if has("error") then false
        elif (.result | type) == "string" then .result == "success"
        elif (.result | type) == "object" then true
        else false
        end
    ' > /dev/null 2>&1
}

# Handles arguments/result nesting and peer-port/peer_port spelling.
session_port() {
    remote --session-info | jq -r '
        [.arguments, .result]
        | map(select(type == "object"))
        | .[0]
        | (.peer_port // .["peer-port"]) // empty
    ' 2>/dev/null || true
}

bind_trans() {
    # Ensure Transmission is responsive
    if ! remote --list | rpc_ok; then
        return 1
    fi

    # Set last_port if unset
    if [[ "$last_port" == "unset" ]]; then
        last_port="$(session_port)"
        if ! [[ "$last_port" =~ ^[0-9]+$ && "$last_port" -gt 1024 ]]; then
            last_port="unset"
        fi
    fi

    # Check if port is already bound to Transmission
    if [[ "$(session_port)" == "$new_port" ]]; then
        return 0
    fi

    # Bind port to Transmission
    if ! remote --port "$new_port" | rpc_ok; then
        return 1
    fi

    # Verify that port was bound to Transmission
    sleep 1
    if [[ "$(session_port)" == "$new_port" ]]; then
        return 0
    fi
    box_out "Command to change port to $new_port returned success but actually failed!"
    return 1
}

set_firewall() {
    if [[ "${ENABLE_UFW,,}" != "true" ]]; then
        return 0
    fi

    # Remove any rules for the old port.
    if [[ "$last_port" =~ ^[0-9]+$ && "$last_port" -gt 1024 && "$current_port" != "$last_port" ]]; then
        if timeout 5 ufw status | grep -w "$last_port" | grep -q ALLOW; then
            log "Removing allow rule for port $last_port"
            if ! timeout 5 ufw delete allow "$last_port"; then
                log "Failed while removing allow rule for port $last_port"
            fi
        fi
        if timeout 5 ufw status | grep -w "$last_port" | grep -q DENY; then
            log "Removing deny rule for port $last_port"
            if ! timeout 5 ufw delete deny "$last_port"; then
                log "Failed while removing deny rule for port $last_port"
            fi
        fi
    fi

    # Allow new port
    if [[ "$current_port" =~ ^[0-9]+$ && "$current_port" -gt 1024 ]]; then

        # A stale deny from an older version would otherwise block this port
        if timeout 5 ufw status | grep -w "$current_port" | grep -q DENY; then
            log "Removing stale deny rule for port $current_port"
            if ! timeout 5 ufw delete deny "$current_port"; then
                log "Failed while removing deny rule for port $current_port"
            fi
        fi

        if ! timeout 5 ufw status | grep -w "$current_port" | grep -q ALLOW; then
            log "Allowing $current_port through the firewall"
            if ! timeout 5 ufw allow "$current_port"; then
                log "Failed while allowing port $current_port"
            fi
        fi
    fi
}

update_port() {
    new_port="$(open_port | sed -nr '1,//s/Mapped public port ([0-9]{4,5}) protocol.*/\1/p')"
    if [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -gt 1024 ]]; then
        if [[ "$new_port" != "$current_port" ]]; then
            if [[ "$double_check" != "true" ]]; then
                if bind_trans; then
                    if [[ "$current_port" != "unset" ]]; then
                        last_port="$current_port"
                    fi
                    current_port="$new_port"
                    double_check="true"
                    box_out "The forwarded port is: $current_port"
                else
                    box_out "Attempt to change port to $new_port failed!"
                fi
            else
                double_check="false"
            fi
        else
            double_check="true"
        fi
    else
        box_out "No valid port returned from natpmpc"
    fi
}

check_port() {
    if [[ "${ENABLE_PORT_CHECK,,}" != "true" ]]; then
        return 0
    fi
    [[ "$current_port" =~ ^[0-9]+$ ]] || return 0
    if [[ "$current_port" != "$check_port_last" ]]; then
        check_port_retry="false"
    elif [[ "$check_port_retry" != "true" ]]; then
        return 0
    fi
    check_port_last="$current_port"
    local result rc
    result=$(curl -4 -s --fail --max-time 15 "https://portcheck.transmissionbt.com/$current_port" 2>/dev/null)
    rc=$?
    if [[ "$result" == "1" ]]; then
        check_port_retry="false"
        box_out "Port $current_port verified open"
        return 0
    elif [[ "$result" == "0" ]]; then
        log "Port $current_port tested closed"
        if [[ "$check_port_first_try" == "true" ]]; then
            check_port_first_try="false"
            local pmp_ip ext_ip
            pmp_ip=$(timeout 5 natpmpc -g 10.2.0.1 2>/dev/null | sed -nr 's/.*[Pp]ublic IP address *: *([0-9.]+).*/\1/p' | head -1)
            ext_ip=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null)
            log "natpmpc says public IP is: ${pmp_ip:-unknown}"
            log "actual outbound IP is:     ${ext_ip:-unknown}"
            if [[ -n "$pmp_ip" && -n "$ext_ip" && "$pmp_ip" != "$ext_ip" ]]; then
                log "MISMATCH — port opened on $pmp_ip but traffic exits via $ext_ip"
            fi
        fi
    elif (( rc != 0 )); then
        log "Port check inconclusive: portcheck server unreachable (curl exit $rc)"
    else
        log "Port check inconclusive: unexpected response ('$result')"
    fi
    if [[ "$check_port_retry" != "true" ]]; then
        check_port_retry="true"
    else
        check_port_retry="false"
    fi
}

log "Waiting for healthcheck to pass before updating ports..."
while ! /etc/scripts/healthcheck.sh; do
    log "Not healthy yet. Retrying in 5 seconds..."
    sleep 5
    log "Retrying healthcheck..."
done
log "Healthcheck passed! Starting port update..."

# Install packages if they are not already installed
install_package natpmpc || exit 1
install_package jq || exit 1
if [[ "${ENABLE_UFW,,}" == "true" ]]; then
    install_package ufw || exit 1
fi

if [[ "$(jq -r '.["rpc-authentication-required"] // .rpc_authentication_required' "$transmission_settings_file")" == "true" ]]; then
    transmission_auth="$transmission_username:$transmission_passwd"
fi

tr_cmd=$(command -v transmission-remote)
if [[ -z "$tr_cmd" ]]; then
    log "Error: transmission-remote not found in PATH"
    exit 1
fi

box_out "ProtonVPN Port Forwarding"

# Disable exiting on errors to allow the script to keep running even if commands fail
set +e

while true; do
    update_port
    set_firewall
    check_port
    sleep 45
done

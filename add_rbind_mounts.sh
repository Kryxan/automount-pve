#!/bin/bash

# ---------------------------------------------------------------------------
# add_rbind_mounts.sh — helper to add recursive /mnt bind mounts to LXC containers
# Repo: https://github.com/Kryxan/automount-pve
# Safe, interactive: scans /etc/pve/lxc/*.conf and offers to add
#   lxc.mount.entry: /mnt mnt none rbind,create=dir 0 0
# If an mpX entry already binds /mnt (e.g. mp0: /mnt,mp=/mnt), you can choose
# to remove it and replace with the recursive bind.
set -euo pipefail

CONFIG_DIR=/etc/pve/lxc
RbindLine="lxc.mount.entry: /mnt mnt none rbind,create=dir 0 0"

log()  { echo "[rbind] $*"; }
warn() { echo "[rbind] WARNING: $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    warn "Must run as root."
    exit 1
fi

shopt -s nullglob
configs=(${CONFIG_DIR}/*.conf)
shopt -u nullglob

if [[ ${#configs[@]} -eq 0 ]]; then
    log "No container configs found in ${CONFIG_DIR}."
    exit 0
fi

add_rbind() {
    local cfg="$1" replace_mp="$2" tmp
    tmp="${cfg}.tmp"

    # Start from current file
    cp "${cfg}" "${tmp}"

    if [[ "${replace_mp}" == "yes" ]]; then
        # Remove mpX entries that mount /mnt.
        # [[:space:]]* is POSIX ERE; \s is a GNU extension and not portable.
        # /? handles optional trailing slash on the host path (mp0: /mnt/,mp=…)
        sed -i -E '/^mp[0-9]+:[[:space:]]*\/mnt\/?(,|$)/d' "${tmp}"
    fi

    # If line already present, nothing to do
    if grep -Fxq "${RbindLine}" "${tmp}"; then
        rm -f "${tmp}"
        return 0
    fi

    printf '\n%s\n' "${RbindLine}" >> "${tmp}"
    mv "${tmp}" "${cfg}"
    log "Updated ${cfg}: added recursive bind for /mnt"
}

for cfg in "${configs[@]}"; do
    ctid="$(basename "${cfg}" .conf)"
    has_rbind=false
    has_mp_mnt=false

    grep -Fxq "${RbindLine}" "${cfg}" && has_rbind=true
    # [[:space:]]* is POSIX ERE; \s is not portable across grep -E implementations.
    # /? handles optional trailing slash (mp0: /mnt/,mp=…)
    grep -Eq '^mp[0-9]+:[[:space:]]*/mnt/?(,|$)' "${cfg}" && has_mp_mnt=true

    if ${has_rbind}; then
        log "CT ${ctid}: already has recursive /mnt bind — skipping"
        continue
    fi

    if ${has_mp_mnt}; then
        echo "CT ${ctid}: found mpX bind on /mnt. Replace with recursive bind? [Y/n] "
        read -r ans
        ans=${ans:-y}
        if [[ "${ans,,}" =~ ^y ]]; then
            add_rbind "${cfg}" "yes"
        else
            log "CT ${ctid}: skipped (mp entry retained)"
        fi
    else
        echo "CT ${ctid}: add recursive bind for /mnt? [Y/n] "
        read -r ans
        ans=${ans:-y}
        if [[ "${ans,,}" =~ ^y ]]; then
            add_rbind "${cfg}" "no"
        else
            log "CT ${ctid}: skipped"
        fi
    fi

    # Prompt to restart the container? We only log instructions
    log "Note: restart CT ${ctid} for mount changes to take effect."
done

log "Done."

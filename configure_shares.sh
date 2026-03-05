#!/bin/bash

# ---------------------------------------------------------------------------
# configure_shares.sh — Interactively configure SMB (ksmbd) and/or NFS
# sharing for the /mnt mount tree used by automount-pve.
#
# Repo: https://github.com/Kryxan/automount-pve
# This shares /mnt as a single export so that dynamically-mounted USB
# volumes automatically become visible to clients.
#
# Can be run interactively (prompts) or unattended with flags:
#   --smb          enable SMB sharing (no prompt)
#   --nfs          enable NFS sharing (no prompt)
#   --no-smb       disable SMB sharing (no prompt)
#   --no-nfs       disable NFS sharing (no prompt)
#   --subnet CIDR  allowed subnet (default: auto-detect local /24)
set -euo pipefail

MOUNT_PARENT="/mnt"
SHARE_NAME="mnt"
NFS_EXPORTS="/etc/exports.d/automount-pve.exports"
KSMBD_CONF="/etc/ksmbd/ksmbd.conf"
SAMBA_CONF="/etc/samba/smb.conf"

ENABLE_SMB=""
ENABLE_NFS=""
SUBNET=""

# ---------------------------------------------------------------------------
# Parse CLI flags (for unattended / re-run from installer)
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --smb)     ENABLE_SMB=yes ;;
        --no-smb)  ENABLE_SMB=no  ;;
        --nfs)     ENABLE_NFS=yes ;;
        --no-nfs)  ENABLE_NFS=no  ;;
        --subnet)  shift; SUBNET="${1:-}" ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[configure_shares] $*"; }
warn() { echo "[configure_shares] WARNING: $*" >&2; }

detect_subnet() {
    # Grab the first non-loopback IPv4 address and derive a /24
    local ip
    ip=$(ip -4 -o addr show scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
    if [[ -n "${ip}" ]]; then
        echo "${ip%.*}.0/24"
    else
        echo "192.168.1.0/24"
    fi
}

prompt_yn() {
    # $1=prompt  $2=default (y/n)
    local answer
    while true; do
        read -rp "$1 [$([ "$2" = y ] && echo 'Y/n' || echo 'y/N')]: " answer
        answer="${answer:-$2}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Interactive prompts (only when flags were not provided)
# ---------------------------------------------------------------------------
if [[ -z "${ENABLE_SMB}" ]]; then
    if prompt_yn "Configure SMB (Samba/ksmbd) sharing for ${MOUNT_PARENT}?" y; then
        ENABLE_SMB=yes
    else
        ENABLE_SMB=no
    fi
fi

if [[ -z "${ENABLE_NFS}" ]]; then
    if prompt_yn "Configure NFS sharing for ${MOUNT_PARENT}?" y; then
        ENABLE_NFS=yes
    else
        ENABLE_NFS=no
    fi
fi

if [[ "${ENABLE_SMB}" == "no" && "${ENABLE_NFS}" == "no" ]]; then
    log "No shares requested. Nothing to do."
    exit 0
fi

if [[ -z "${SUBNET}" ]]; then
    local_subnet=$(detect_subnet)
    if [[ -t 0 ]]; then
        read -rp "Allowed subnet [${local_subnet}]: " SUBNET
        SUBNET="${SUBNET:-${local_subnet}}"
    else
        SUBNET="${local_subnet}"
    fi
fi

log "Sharing ${MOUNT_PARENT} — SMB=${ENABLE_SMB} NFS=${ENABLE_NFS} subnet=${SUBNET}"

# ---------------------------------------------------------------------------
# SMB — prefer ksmbd, fall back to Samba
# ---------------------------------------------------------------------------
if [[ "${ENABLE_SMB}" == "yes" ]]; then
    # Detect which SMB server is available (prefer Samba over ksmbd)
    SMB_ENGINE=""
    if command -v smbd >/dev/null 2>&1; then
        SMB_ENGINE=samba
    elif command -v ksmbd.control >/dev/null 2>&1; then
        SMB_ENGINE=ksmbd
    fi

    if [[ -z "${SMB_ENGINE}" ]]; then
        warn "Neither ksmbd nor Samba is installed."
        if [[ -t 0 ]]; then
            echo "  To install ksmbd: apt install ksmbd-tools"
            echo "  To install Samba: apt install samba"
            if prompt_yn "Attempt to install ksmbd-tools now?" y; then
                apt-get update -qq && apt-get install -y ksmbd-tools
                SMB_ENGINE=ksmbd
            elif prompt_yn "Attempt to install samba now?" n; then
                apt-get update -qq && apt-get install -y samba
                SMB_ENGINE=samba
            fi
        fi
    fi

    if [[ "${SMB_ENGINE}" == "ksmbd" ]]; then
        log "Configuring ksmbd (${KSMBD_CONF})"
        mkdir -p "$(dirname "${KSMBD_CONF}")"
        # Extract subnet base for hosts allow (strip CIDR, keep e.g. "192.168.1.")
        HOSTS_ALLOW="${SUBNET%.*}. 127."
        cat > "${KSMBD_CONF}" <<EOF
[global]
   follow symlinks = yes
   wide links = yes
   netbios name = files
   server string = Proxmox USB Automount Share
   workgroup = WORKGROUP
   map to guest = Bad User
   guest account = nobody
   hosts allow = ${HOSTS_ALLOW}

[${SHARE_NAME}]
   path = ${MOUNT_PARENT}
   comment = Automounted USB storage
   read only = no
   guest ok = yes
   force user = root
   force group = root
   create mask = 0664
   directory mask = 0775
   follow symlinks = yes
   wide links = yes
EOF
        # Restart ksmbd
        if systemctl is-active --quiet ksmbd 2>/dev/null; then
            ksmbd.control -r 2>/dev/null && log "ksmbd reloaded" || systemctl restart ksmbd
        else
            systemctl enable --now ksmbd 2>/dev/null || warn "Could not start ksmbd"
        fi

    elif [[ "${SMB_ENGINE}" == "samba" ]]; then
        log "Configuring Samba (${SAMBA_CONF})"
        # Only touch the [mnt] share section; leave the rest of smb.conf alone
        # Remove existing [mnt] block if present
        if grep -q "^\[${SHARE_NAME}\]" "${SAMBA_CONF}" 2>/dev/null; then
            sed -i "/^\[${SHARE_NAME}\]/,/^\[/{ /^\[${SHARE_NAME}\]/d; /^\[/!d; }" "${SAMBA_CONF}"
        fi
        cat >> "${SAMBA_CONF}" <<EOF

[${SHARE_NAME}]
   path = ${MOUNT_PARENT}
   comment = Automounted USB storage
   browseable = yes
   read only = no
   guest ok = yes
   force user = root
   force group = root
   create mask = 0664
   directory mask = 0775
   follow symlinks = yes
   wide links = yes
   hosts allow = ${SUBNET} 127.0.0.0/8
EOF
        systemctl enable --now smbd 2>/dev/null || warn "Could not start smbd"
        systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
    else
        warn "No SMB server available — skipping SMB configuration."
    fi
fi

# ---------------------------------------------------------------------------
# NFS
# ---------------------------------------------------------------------------
if [[ "${ENABLE_NFS}" == "yes" ]]; then
    if ! command -v exportfs >/dev/null 2>&1; then
        warn "NFS server tools not installed."
        if [[ -t 0 ]]; then
            if prompt_yn "Attempt to install nfs-kernel-server now?" y; then
                apt-get update -qq && apt-get install -y nfs-kernel-server
            fi
        fi
    fi

    if command -v exportfs >/dev/null 2>&1; then
        log "Configuring NFS export (${NFS_EXPORTS})"
        mkdir -p "$(dirname "${NFS_EXPORTS}")"

        # crossmnt causes the server to automatically export sub-mounts (USB drives)
        cat > "${NFS_EXPORTS}" <<EOF
# automount-pve: export /mnt with crossmnt so USB sub-mounts are visible
${MOUNT_PARENT}  ${SUBNET}(rw,sync,no_subtree_check,no_root_squash,crossmnt,fsid=0)
EOF
        exportfs -ra 2>/dev/null || true
        systemctl enable --now nfs-kernel-server 2>/dev/null || warn "Could not start nfs-kernel-server"
        log "NFS export active"
    else
        warn "exportfs not found — skipping NFS configuration."
    fi
fi

log "Share configuration complete."

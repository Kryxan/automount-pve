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
#   --guest-mode M SMB access mode: guest | users | subnet
#   --wide-links   enable wide links in SMB share
#   --no-wide-links disable wide links in SMB share
#   --root-squash   use root_squash for NFS (default)
#   --no-root-squash use no_root_squash for NFS
#   --nfs-insecure  allow insecure NFS ports
set -euo pipefail

MOUNT_PARENT="/mnt"
SHARE_NAME="mnt"
NFS_EXPORTS="/etc/exports.d/automount-pve.exports"
KSMBD_CONF="/etc/ksmbd/ksmbd.conf"
SAMBA_CONF="/etc/samba/smb.conf"

ENABLE_SMB=""
ENABLE_NFS=""
SUBNET=""

# SMB security options (set by prompts or flags)
SMB_GUEST_MODE=""        # guest | users | subnet
SMB_WIDE_LINKS=""        # yes | no
SMB_VALID_USERS=""       # username or @group

# NFS security options
NFS_ROOT_SQUASH=""       # root_squash | no_root_squash
NFS_INSECURE=""          # insecure | (empty for secure)

# Config-merge markers
MARKER_BEGIN="# BEGIN automount-pve"
MARKER_END="# END automount-pve"

# ---------------------------------------------------------------------------
# Parse CLI flags (for unattended / re-run from installer)
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --smb)     ENABLE_SMB=yes ;;
        --no-smb)  ENABLE_SMB=no  ;;
        --nfs)     ENABLE_NFS=yes ;;
        --no-nfs)  ENABLE_NFS=no  ;;
        --subnet)        shift; SUBNET="${1:-}" ;;
        --guest-mode)    shift; SMB_GUEST_MODE="${1:-}" ;;
        --wide-links)    SMB_WIDE_LINKS=yes ;;
        --no-wide-links) SMB_WIDE_LINKS=no ;;
        --root-squash)   NFS_ROOT_SQUASH=root_squash ;;
        --no-root-squash) NFS_ROOT_SQUASH=no_root_squash ;;
        --nfs-insecure)  NFS_INSECURE=insecure ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
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

prompt_choice() {
    # $1=prompt $2=valid choices string $3=default
    local prompt="$1" choices="$2" default="$3" answer
    while true; do
        read -rp "${prompt} [${default}]: " answer
        answer="${answer:-${default}}"
        if [[ "${choices}" == *"${answer}"* ]]; then
            echo "${answer}"
            return 0
        fi
        echo "Invalid choice. Options: ${choices}" >&2
    done
}

backup_file() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        local ts
        ts="$(date +%Y%m%d%H%M%S)"
        local backup="${file}.bak.${ts}"
        cp -a "${file}" "${backup}"
        log "Backed up ${file} → ${backup}"
    fi
}

remove_marked_block() {
    local file="$1"
    if [[ -f "${file}" ]] && grep -qF "${MARKER_BEGIN}" "${file}"; then
        sed -i "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "${file}"
        log "Removed existing automount-pve block from ${file}"
    fi
}

# ---------------------------------------------------------------------------
# Interactive prompts (only when flags were not provided)
# ---------------------------------------------------------------------------
if [[ -z "${ENABLE_SMB}" ]] && [[ -t 0 ]]; then
    if prompt_yn "Configure SMB (Samba/ksmbd) sharing for ${MOUNT_PARENT}?" y; then
        ENABLE_SMB=yes
    else
        ENABLE_SMB=no
    fi
elif [[ -z "${ENABLE_SMB}" ]]; then
    ENABLE_SMB=no
fi

if [[ -z "${ENABLE_NFS}" ]] && [[ -t 0 ]]; then
    if prompt_yn "Configure NFS sharing for ${MOUNT_PARENT}?" y; then
        ENABLE_NFS=yes
    else
        ENABLE_NFS=no
    fi
elif [[ -z "${ENABLE_NFS}" ]]; then
    ENABLE_NFS=no
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

# ===========================================================================
# SMB Configuration
# ===========================================================================
if [[ "${ENABLE_SMB}" == "yes" ]]; then
    # Detect which SMB server is available (prefer Samba over ksmbd)
    SMB_ENGINE=""
    if command -v smbd >/dev/null 2>&1; then
        SMB_ENGINE=samba
    elif command -v ksmbd.control >/dev/null 2>&1; then
        SMB_ENGINE=ksmbd
    fi

    if [[ -z "${SMB_ENGINE}" ]]; then
        warn "Neither Samba nor ksmbd is installed."
        if [[ -t 0 ]]; then
            echo "  To install Samba: apt install samba"
            if prompt_yn "Install samba now?" n; then
                apt-get update -qq && apt-get install -y samba
                SMB_ENGINE=samba
            fi
        fi
    fi

    if [[ -n "${SMB_ENGINE}" ]]; then
        # --- Security prompts (before any config changes) ---
        if [[ -z "${SMB_GUEST_MODE}" ]] && [[ -t 0 ]]; then
            echo ""
            echo "SMB access control — choose how clients authenticate:"
            echo "  A) Guest access (anyone can read/write — easy but insecure)"
            echo "  B) Require valid Samba users (more secure)"
            echo "  C) Guest access restricted to LAN subnet only (${SUBNET})"
            echo ""
            local_choice=$(prompt_choice "Select access mode (A/B/C)" "AaBbCc" "C")
            case "${local_choice,,}" in
                a) SMB_GUEST_MODE=guest ;;
                b) SMB_GUEST_MODE=users ;;
                c) SMB_GUEST_MODE=subnet ;;
            esac
        fi
        SMB_GUEST_MODE="${SMB_GUEST_MODE:-subnet}"

        if [[ "${SMB_GUEST_MODE}" == "users" && -z "${SMB_VALID_USERS}" ]] && [[ -t 0 ]]; then
            read -rp "Samba valid users (e.g. 'user1 user2' or '@group') [root]: " SMB_VALID_USERS
        fi
        SMB_VALID_USERS="${SMB_VALID_USERS:-root}"

        if [[ -z "${SMB_WIDE_LINKS}" ]] && [[ -t 0 ]]; then
            echo ""
            echo "Symlink support in SMB shares:"
            echo "  Enabling 'wide links' and 'follow symlinks' allows symlinks"
            echo "  inside ${MOUNT_PARENT} to point to locations outside that directory."
            echo ""
            echo "  SECURITY WARNING: This means an attacker who can create a symlink"
            echo "  on a USB drive could potentially expose any file on the system"
            echo "  (e.g. /etc/shadow) to SMB clients."
            echo ""
            if prompt_yn "Enable wide links and follow symlinks?" n; then
                SMB_WIDE_LINKS=yes
            else
                SMB_WIDE_LINKS=no
            fi
        fi
        SMB_WIDE_LINKS="${SMB_WIDE_LINKS:-no}"
    fi

    if [[ "${SMB_ENGINE}" == "ksmbd" ]]; then
        log "Configuring ksmbd (${KSMBD_CONF})"
        backup_file "${KSMBD_CONF}"
        mkdir -p "$(dirname "${KSMBD_CONF}")"
        HOSTS_ALLOW="${SUBNET%.*}. 127."
        cat > "${KSMBD_CONF}" <<EOF
${MARKER_BEGIN}
[global]
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
${MARKER_END}
EOF
        if systemctl is-active --quiet ksmbd 2>/dev/null; then
            if ksmbd.control -r 2>/dev/null; then
                log "ksmbd reloaded"
            else
                systemctl restart ksmbd
            fi
        else
            systemctl enable --now ksmbd 2>/dev/null || warn "Could not start ksmbd"
        fi

    elif [[ "${SMB_ENGINE}" == "samba" ]]; then
        log "Configuring Samba (${SAMBA_CONF})"

        # Detect if smb.conf has been customized from package default
        local_customized=false
        if [[ -f "${SAMBA_CONF}" ]]; then
            if command -v dpkg >/dev/null 2>&1; then
                if dpkg -V samba-common 2>/dev/null | grep -q "smb.conf"; then
                    local_customized=true
                fi
            else
                local_total=$(grep -c '^\[' "${SAMBA_CONF}" 2>/dev/null || echo 0)
                local_standard=$(grep -cE '^\[(global|homes|printers|print\$)\]' "${SAMBA_CONF}" 2>/dev/null || echo 0)
                if (( local_total > local_standard )); then
                    local_customized=true
                fi
            fi
        fi

        if [[ "${local_customized}" == true ]]; then
            log "Detected customized smb.conf — preserving existing settings"
        else
            log "smb.conf appears to be default — safe to modify"
        fi

        # 1. Backup original config
        backup_file "${SAMBA_CONF}"

        # 2. Remove existing automount-pve block (idempotent)
        remove_marked_block "${SAMBA_CONF}"

        # 3. Comment out conflicting lines in [global] if customized
        if [[ "${local_customized}" == true ]]; then
            for local_key in "workgroup" "server string" "map to guest" "guest account" "unix extensions" "allow insecure wide links"; do
                if grep -qi "^[[:space:]]*${local_key}[[:space:]]*=" "${SAMBA_CONF}" 2>/dev/null; then
                    sed -i "/^\[global\]/,/^\[/{
                        /^[[:space:]]*${local_key}[[:space:]]*=/I s/^/# automount-pve-disabled: /
                    }" "${SAMBA_CONF}"
                    log "Commented out conflicting '${local_key}' in ${SAMBA_CONF}"
                fi
            done
        fi

        # 4. Build and append the configuration block
        {
            echo ""
            echo "${MARKER_BEGIN}"
            echo "[global]"
            echo "   workgroup = WORKGROUP"
            echo "   server string = Files"
            case "${SMB_GUEST_MODE}" in
                guest|subnet)
                    echo "   map to guest = Bad User"
                    echo "   guest account = nobody"
                    ;;
            esac
            if [[ "${SMB_WIDE_LINKS}" == "yes" ]]; then
                echo "   unix extensions = no"
                echo "   allow insecure wide links = yes"
            fi
            if [[ "${SMB_GUEST_MODE}" == "subnet" ]]; then
                echo "   hosts allow = ${SUBNET} 127.0.0.0/8"
            fi
            echo ""
            echo "[${SHARE_NAME}]"
            echo "   path = ${MOUNT_PARENT}"
            echo "   comment = Automounted USB storage"
            echo "   browseable = yes"
            echo "   writable = yes"
            case "${SMB_GUEST_MODE}" in
                guest|subnet)
                    echo "   guest ok = yes"
                    echo "   force user = root"
                    echo "   force group = root"
                    ;;
                users)
                    echo "   guest ok = no"
                    echo "   valid users = ${SMB_VALID_USERS}"
                    ;;
            esac
            echo "   create mask = 0664"
            echo "   directory mask = 0775"
            if [[ "${SMB_WIDE_LINKS}" == "yes" ]]; then
                echo "   wide links = yes"
                echo "   follow symlinks = yes"
            fi
            echo "${MARKER_END}"
        } >> "${SAMBA_CONF}"
        log "Appended automount-pve SMB configuration to ${SAMBA_CONF}"

        # 5. Restart/reload Samba
        systemctl enable --now smbd 2>/dev/null || warn "Could not start smbd"
        systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
        log "Samba configuration applied"
    else
        warn "No SMB server available — skipping SMB configuration."
    fi
fi

# ===========================================================================
# NFS Configuration
# ===========================================================================
if [[ "${ENABLE_NFS}" == "yes" ]]; then
    if ! command -v exportfs >/dev/null 2>&1; then
        warn "NFS server tools not installed."
        if [[ -t 0 ]]; then
            if prompt_yn "Install nfs-kernel-server now?" y; then
                apt-get update -qq && apt-get install -y nfs-kernel-server
            fi
        fi
    fi

    if command -v exportfs >/dev/null 2>&1; then
        # Check for existing custom exports in /etc/exports
        if [[ -f /etc/exports ]]; then
            local_custom_lines=$(grep -cvE '^[[:space:]]*(#|$)' /etc/exports 2>/dev/null || echo 0)
            if (( local_custom_lines > 0 )); then
                log "Detected ${local_custom_lines} existing export(s) in /etc/exports — these will NOT be modified."
            fi
        fi

        # --- NFS security prompts ---
        if [[ -z "${NFS_ROOT_SQUASH}" ]] && [[ -t 0 ]]; then
            echo ""
            echo "NFS root squash:"
            echo "  root_squash    — remote root is mapped to nobody (more secure)"
            echo "  no_root_squash — remote root retains root privileges (less secure)"
            echo ""
            if prompt_yn "Enable root_squash (recommended)?" y; then
                NFS_ROOT_SQUASH=root_squash
            else
                NFS_ROOT_SQUASH=no_root_squash
            fi
        fi
        NFS_ROOT_SQUASH="${NFS_ROOT_SQUASH:-root_squash}"

        if [[ -z "${NFS_INSECURE}" ]] && [[ -t 0 ]]; then
            echo ""
            echo "NFS port security:"
            echo "  'secure'   — only accept connections from ports < 1024 (default)"
            echo "  'insecure' — accept connections from any port (needed for macOS clients)"
            echo ""
            if prompt_yn "Allow insecure ports (for macOS compatibility)?" n; then
                NFS_INSECURE=insecure
            else
                NFS_INSECURE=""
            fi
        fi

        log "Configuring NFS export (${NFS_EXPORTS})"
        mkdir -p "$(dirname "${NFS_EXPORTS}")"

        # Backup existing export file
        backup_file "${NFS_EXPORTS}"

        # Remove existing automount-pve block (idempotent)
        remove_marked_block "${NFS_EXPORTS}"

        # Build NFS options
        # crossmnt causes the server to automatically export sub-mounts (USB drives)
        local_nfs_opts="rw,sync,no_subtree_check,crossmnt,fsid=0"
        local_nfs_opts+=",${NFS_ROOT_SQUASH}"
        if [[ "${NFS_INSECURE}" == "insecure" ]]; then
            local_nfs_opts+=",insecure"
        fi

        # Write export file with markers
        cat > "${NFS_EXPORTS}" <<EOF
${MARKER_BEGIN}
# automount-pve: export ${MOUNT_PARENT} with crossmnt so USB sub-mounts are visible
${MOUNT_PARENT}  ${SUBNET}(${local_nfs_opts})
${MARKER_END}
EOF
        exportfs -ra 2>/dev/null || true
        systemctl enable --now nfs-kernel-server 2>/dev/null || warn "Could not start nfs-kernel-server"
        log "NFS export active"
    else
        warn "exportfs not found — skipping NFS configuration."
    fi
fi

log "Share configuration complete."

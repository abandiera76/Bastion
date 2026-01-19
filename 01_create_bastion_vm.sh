#!/bin/bash

# ==========================
# Password utente cloud-init
# ==========================
read -s -p "Inserisci la password: " password1
echo
read -s -p "Reinserisci la password: " password2
echo

if [ "$password1" != "$password2" ]; then
    echo "Le password non corrispondono. Riprova."
    exit 1
fi

echo "Ricordati di conservare questa password in un luogo sicuro"
SECURE_PASS=$password1

# ==========================
# Parametri di rete VM
# ==========================
read -rp "Indirizzo IP della VM (es. 192.168.1.1): " VM_IP
read -rp "Subnet CIDR (solo numero, es. 24): " VM_SUBNET
read -rp "Gateway (es. 192.168.1.254): " VM_GW
read -rp "DNS (es. 10.31.8.121 oppure \"192.168.1.10 8.8.8.8\"): " VM_DNS

# ==========================
# Bridge di rete
# ==========================
read -rp "Bridge Proxmox (default: vmbr0): " VM_BRIDGE
VM_BRIDGE=${VM_BRIDGE:-vmbr0}

echo "Userò il bridge: $VM_BRIDGE"

# ==========================
# Datastore con default local-lvm
# ==========================
read -rp "Datastore Proxmox (default: local-lvm): " DATASTORE
DATASTORE=${DATASTORE:-local-lvm}

echo "Userò il datastore: $DATASTORE"

# ==========================
# VMID parametrizado
# ==========================
read -rp "ID della VM Proxmox (default: 9001): " qm_id
qm_id=${qm_id:-9001}

echo "Userò la VMID: $qm_id"

# ==========================
# Proxy opzionale
# ==========================
read -rp "Vuoi configurare un proxy sull'host? [s/N]: " USE_PROXY_HOST

PROXY_URL=""
NO_PROXY=""
USE_PROXY_VM="n"

if [[ "$USE_PROXY_HOST" == "s" || "$USE_PROXY_HOST" == "S" ]]; then
    read -rp "Inserisci indirizzo del proxy (es. http://proxyoipproxy:3128): " PROXY_URL
    read -rp "Inserisci no_proxy (default: localhost,127.0.0.1): " NO_PROXY
    NO_PROXY=${NO_PROXY:-"localhost,127.0.0.1"}

    # Configuro sull'host
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export no_proxy="$NO_PROXY"

    echo "Proxy (host) configurato:"
    echo "  http_proxy=$http_proxy"
    echo "  https_proxy=$https_proxy"
    echo "  no_proxy=$no_proxy"

    # Chiedo se applicarlo anche alla VM
    read -rp "Vuoi applicare il proxy anche nella VM? [s/N]: " USE_PROXY_VM
else
    echo "Nessun proxy configurato sull'host."
fi

# ==========================
# Immagine cloud
# ==========================
export OS_IMAGE="noble-server-cloudimg-amd64.img"
export OS_URL="https://cloud-images.ubuntu.com/noble/current/$OS_IMAGE"

cd /tmp || exit 1

wget "$OS_URL"

apt install -y libguestfs-tools

# ==========================
# Customizzazione immagine base
# ==========================
virt-customize -a /tmp/$OS_IMAGE --install qemu-guest-agent
virt-customize -a /tmp/$OS_IMAGE --timezone Europe/Rome
virt-customize -a /tmp/$OS_IMAGE \
  --run-command 'systemctl enable ssh' \
  --run-command 'sed -i "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
  --run-command 'sed -i "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config.d/60-cloudimg-settings.conf' \
  --run-command 'systemctl restart ssh'

# ==========================
# Proxy dentro la VM (se richiesto)
# ==========================
if [[ "$USE_PROXY_VM" == "s" || "$USE_PROXY_VM" == "S" ]]; then
    echo "Inserisco configurazione proxy dentro la VM..."
    virt-customize -a /tmp/$OS_IMAGE \
      --append-line "/etc/environment:http_proxy=$PROXY_URL" \
      --append-line "/etc/environment:https_proxy=$PROXY_URL" \
      --append-line "/etc/environment:no_proxy=$NO_PROXY" \
      --append-line "/etc/apt/apt.conf.d/95proxies:Acquire::http::Proxy \"$PROXY_URL\";" \
      --append-line "/etc/apt/apt.conf.d/95proxies:Acquire::https::Proxy \"$PROXY_URL\";"
else
    echo "Nessun proxy verrà applicato dentro la VM."
fi

# ==========================
# Creazione VM Proxmox
# ==========================
qm create $qm_id --name bastion --memory 2048 --cores 2

# Import disco
qm importdisk $qm_id /tmp/$OS_IMAGE "$DATASTORE"

# Recupero unused0
DISK_VOLID=$(qm config $qm_id | awk '/unused0:/{print $2}')

if [ -z "$DISK_VOLID" ]; then
    echo "ERRORE: nessun disco unused0 trovato dopo qm importdisk. Controlla lo storage $DATASTORE."
    exit 1
fi

qm set $qm_id --scsihw virtio-scsi-pci --scsi0 "$DISK_VOLID"
qm set $qm_id --ide2 "$DATASTORE:cloudinit"
qm set $qm_id --boot c --bootdisk scsi0
qm set $qm_id --serial0 socket --vga serial0
qm set $qm_id --agent enabled=1

# Cloud-init user
qm set $qm_id --ciuser ebit --cipassword "$SECURE_PASS"

# ==========================
# Config rete cloud-init
# ==========================
qm set $qm_id \
  --net0 "virtio,bridge=${VM_BRIDGE}" \
  --ipconfig0 "ip=$VM_IP/$VM_SUBNET,gw=$VM_GW" \
  --nameserver "$VM_DNS"

# ==========================
# Resize e start
# ==========================
qm resize $qm_id scsi0 5G
qm start $qm_id

rm -f "$OS_IMAGE"

echo "Adesso è possibile collegarsi al server in ssh"
echo "Utente: ebit"
echo "IP: $VM_IP"

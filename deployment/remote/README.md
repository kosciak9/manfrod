# Manfrod Remote Deployment (Raspberry Pi 4)

This directory contains everything needed to set up a Raspberry Pi 4 running Arch Linux ARM to host Manfrod.

## Components

- **Arch Linux ARM** (aarch64) - Base operating system
- **ParadeDB** - PostgreSQL with pg_search/pg_analytics extensions (via Podman)
- **Tailscale** - Secure networking and SSH
- **Podman** - Container runtime (rootless)

## Prerequisites

On your workstation:

```bash
# Arch Linux / Fedora
sudo pacman -S ansible   # or: sudo dnf install ansible

# macOS
brew install ansible

# All platforms - install required collections
cd deployment/remote/ansible
ansible-galaxy collection install -r requirements.yml
```

## Quick Start

### 1. Flash SD Card

```bash
# Insert SD card and identify device (e.g., /dev/sda)
lsblk

# Flash Arch Linux ARM (DESTROYS ALL DATA)
cd deployment/remote
./flash-sd.sh /dev/sda
```

### 2. Set Up Ansible Vault

```bash
cd ansible

# Create vault password file (gitignored)
echo 'your-secure-vault-password' > .vault_pass
chmod 600 .vault_pass

# Edit secrets with real values
vim inventory/group_vars/all/vault.yml

# Required secrets:
# - vault_manfrod_password: Password for manfrod user
# - vault_root_password: New root password
# - vault_postgres_password: PostgreSQL password
# - vault_tailscale_authkey: Get from https://login.tailscale.com/admin/settings/keys

# Encrypt the vault file
ansible-vault encrypt inventory/group_vars/all/vault.yml --vault-password-file .vault_pass
```

### 3. Boot Raspberry Pi

1. Insert SD card into Raspberry Pi 4
2. Connect ethernet cable
3. Connect power (minimum 3A USB-C supply)
4. Wait ~60 seconds for boot

### 4. Find Pi's IP Address

```bash
# Option 1: Network scan
nmap -sn 192.168.1.0/24 | grep -B2 "alarm\|Raspberry"

# Option 2: Check router's DHCP leases

# Option 3: Connect monitor/keyboard and run `ip addr`
```

### 5. Update Inventory

Edit `ansible/inventory/hosts.yml`:

```yaml
all:
  hosts:
    lissandra:
      ansible_host: 192.168.1.XXX  # <-- Replace with actual IP
```

### 6. Run Bootstrap Playbook

```bash
cd ansible

# Bootstrap: creates users, hardens SSH, configures system
ansible-playbook playbooks/bootstrap.yml --vault-password-file .vault_pass
```

### 7. Update Inventory for Site Playbook

Edit `ansible/inventory/hosts.yml`:

```yaml
all:
  hosts:
    lissandra:
      ansible_host: 192.168.1.XXX
      ansible_user: kosciak  # <-- Change from 'alarm' to 'kosciak'

  children:
    bootstrap:
      hosts:
        # lissandra:  # <-- Comment out

    configured:
      hosts:
        lissandra:  # <-- Uncomment/add here
```

### 8. Run Site Playbook

```bash
# Full setup: Podman, ParadeDB, Tailscale
ansible-playbook playbooks/site.yml --vault-password-file .vault_pass
```

### 9. Verify Deployment

```bash
# SSH via Tailscale
ssh kosciak@lissandra  # Using MagicDNS
# or
ssh kosciak@100.x.y.z  # Using Tailscale IP

# Check ParadeDB
sudo -u manfrod podman ps
sudo -u manfrod podman logs manfrod-db

# Check PostgreSQL
sudo -u manfrod podman exec manfrod-db psql -U manfrod -d manfrod_prod -c "SELECT version();"
```

## Directory Structure

```
deployment/remote/
├── README.md              # This file
├── flash-sd.sh            # SD card preparation script
└── ansible/
    ├── ansible.cfg        # Ansible configuration
    ├── requirements.yml   # Galaxy collections
    ├── .vault_pass        # Vault password (gitignored)
    ├── inventory/
    │   ├── hosts.yml      # Host definitions
    │   └── group_vars/
    │       └── all/
    │           ├── vars.yml   # Non-secret variables
    │           └── vault.yml  # Encrypted secrets
    └── playbooks/
        ├── bootstrap.yml  # First-boot setup
        └── site.yml       # Main configuration
```

## Users

| User | Purpose | SSH Access | Sudo |
|------|---------|------------|------|
| `kosciak` | Admin | Yes (key only) | Yes |
| `manfrod` | App/Bot | No | Yes |
| `alarm` | Default (disabled) | No | No |
| `root` | System | No | N/A |

## Services

| Service | Type | Management |
|---------|------|------------|
| ParadeDB | Podman (user) | `systemctl --user status container-manfrod-db` (as manfrod) |
| Tailscale | System | `systemctl status tailscaled` |
| SSH | System | `systemctl status sshd` |
| Firewall | System | `systemctl status nftables` |

## Database Access

PostgreSQL is only accessible from localhost. Connect via:

```bash
# On the Pi (as manfrod user)
podman exec -it manfrod-db psql -U manfrod -d manfrod_prod

# Or via Tailscale SSH tunnel from workstation
ssh -L 5432:127.0.0.1:5432 kosciak@lissandra
# Then connect to localhost:5432
```

## Maintenance

### View Logs

```bash
# ParadeDB logs
sudo -u manfrod podman logs -f manfrod-db

# Tailscale logs
journalctl -u tailscaled -f

# System logs
journalctl -f
```

### Update System

```bash
# SSH into Pi
ssh kosciak@lissandra

# Update packages
sudo pacman -Syu

# Update ParadeDB container
sudo -u manfrod podman pull docker.io/paradedb/paradedb:v0.21.5-pg18
sudo -u manfrod systemctl --user restart container-manfrod-db
```

### Backup Database

```bash
# On the Pi
sudo -u manfrod podman exec manfrod-db pg_dump -U manfrod manfrod_prod > backup.sql

# Or via SSH
ssh kosciak@lissandra "sudo -u manfrod podman exec manfrod-db pg_dump -U manfrod manfrod_prod" > backup.sql
```

### Re-run Ansible

```bash
# From workstation
cd deployment/remote/ansible
ansible-playbook playbooks/site.yml --vault-password-file .vault_pass
```

## Troubleshooting

### Can't SSH to Pi

1. Check Pi is powered and ethernet connected
2. Verify IP address is correct
3. Try password auth (if SSH key injection failed):
   ```bash
   ssh alarm@192.168.1.XXX  # Password: alarm
   ```

### Ansible Connection Failed

```bash
# Test connectivity
ansible lissandra -m ping --vault-password-file .vault_pass

# Verbose mode
ansible-playbook playbooks/bootstrap.yml -vvv --vault-password-file .vault_pass
```

### ParadeDB Won't Start

```bash
# Check container logs
sudo -u manfrod podman logs manfrod-db

# Check systemd service
sudo -u manfrod systemctl --user status container-manfrod-db
sudo -u manfrod journalctl --user -u container-manfrod-db
```

### Tailscale Issues

```bash
# Check status
sudo tailscale status

# Re-authenticate (need new auth key)
sudo tailscale up --authkey=tskey-auth-NEW_KEY
```

## Security Notes

1. **SSH** - Only `kosciak` can SSH in, key authentication only
2. **PostgreSQL** - Only accessible from localhost (127.0.0.1)
3. **Tailscale** - Provides encrypted tunnel for remote access
4. **Firewall** - nftables blocks all except SSH and Tailscale
5. **Secrets** - Stored in Ansible Vault, never in plaintext

## Files to Keep Secret

These files should NEVER be committed to git:

- `ansible/.vault_pass` - Vault password
- `ansible/inventory/group_vars/all/vault.yml` - Encrypted, but still sensitive
- Any backup files containing database dumps

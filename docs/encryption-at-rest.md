# Encryption at rest — runbook (Phase 48)

AGmind stores sensitive data in Docker named volumes (Postgres Dify DB, Weaviate vectors, MinIO объекты, Dify uploads). By default these volumes sit on the root filesystem unencrypted. For enterprise deployments where **152-ФЗ** (RU personal data) or internal security policy demand encryption-at-rest, add LUKS under `/var/lib/docker`.

This doc is a **procedure**, not automated — LUKS requires interactive passphrase entry (or key file) and wipes the disk. Running install.sh can't do it non-destructively.

## Scope decision matrix

| Scenario | Needed? | How |
|---|---|---|
| DGX Spark dev box (single user, local data) | ❌ | Skip. Physical access = game over anyway |
| LAN corporate deploy, no PII | ⚠️ Optional | Full-disk LUKS at OS install is simpler |
| LAN corporate with PD/ПДн | ✅ Required | Per-volume LUKS (this runbook) |
| VPS | ⚠️ Cloud-provider-encrypted disks first, then LUKS as second layer if threat model requires |
| Offline / airgapped | ✅ Required if physical transport | LUKS + GPG-signed backups |

## Threat model covered

- ✅ Stolen drive / decommissioned hardware
- ✅ Physical theft of server
- ✅ Backup media leak (if backups also encrypted)

## NOT covered (don't pretend they are)

- ❌ Live memory dump / forensic attach — LUKS is decrypted when running
- ❌ Root-level compromise of running system — key is in memory
- ❌ Backup media leak **if** backups unencrypted (`scripts/backup.sh` currently produces plain tar.gz!)
- ❌ Supply-chain compromise of container images

---

## Scenario 1 — Fresh install with encrypted /var/lib/docker

Prerequisites: fresh disk or partition, root access, **before** install.sh.

### 1.1 Create dedicated LUKS partition

```bash
# Assume /dev/nvme1n1 is the target drive (adjust!)
sudo cryptsetup luksFormat --type luks2 --hash sha512 --pbkdf argon2id /dev/nvme1n1
# Enter strong passphrase (16+ chars), confirm

sudo cryptsetup luksOpen /dev/nvme1n1 cryptdocker
sudo mkfs.ext4 -L docker_data /dev/mapper/cryptdocker
```

### 1.2 Persist unlock via keyfile (optional, trades convenience vs security)

For unattended boot (OOM reboots etc.) use keyfile stored on **separate encrypted partition** or **TPM/FIDO2** device. Do not store keyfile unencrypted on the same disk.

```bash
sudo dd if=/dev/urandom of=/root/docker.key bs=4096 count=1
sudo chmod 400 /root/docker.key
sudo cryptsetup luksAddKey /dev/nvme1n1 /root/docker.key

echo "cryptdocker UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /root/docker.key luks" | \
  sudo tee -a /etc/crypttab
echo "/dev/mapper/cryptdocker /var/lib/docker ext4 defaults 0 2" | \
  sudo tee -a /etc/fstab
```

**Security trade-off:** with keyfile on /root, attacker with root / rescue boot still unlocks. True encryption-at-rest wants interactive passphrase or TPM-sealed key. Decide per threat model.

### 1.3 Mount and install Docker

```bash
sudo systemctl stop docker
sudo mv /var/lib/docker /var/lib/docker.orig
sudo mkdir /var/lib/docker
sudo mount /dev/mapper/cryptdocker /var/lib/docker
sudo rsync -a /var/lib/docker.orig/ /var/lib/docker/
sudo systemctl start docker
# verify
sudo docker info | grep "Docker Root Dir"
# /var/lib/docker (on encrypted volume)
```

### 1.4 Run install.sh as usual

```bash
sudo bash install.sh
```

All Docker volumes now live on LUKS-encrypted disk.

---

## Scenario 2 — Post-install migration (live stack)

**High-risk procedure — make a full backup first.** Downtime ≈ 15-60 min depending on volume size.

### 2.1 Snapshot

```bash
sudo /opt/agmind/scripts/backup.sh --include-models   # full backup
# Copy backup off-host before starting
```

### 2.2 Stop stack

```bash
cd /opt/agmind/docker
sudo docker compose down
```

### 2.3 Move volumes to encrypted disk

Follow Scenario 1.1-1.3 but use rsync on `/var/lib/docker`:

```bash
# After creating /dev/mapper/cryptdocker and mounting at /var/lib/docker.new
sudo rsync -aHAXv /var/lib/docker/ /var/lib/docker.new/
sudo umount /var/lib/docker.new
sudo mv /var/lib/docker /var/lib/docker.old
sudo mv /var/lib/docker.new /var/lib/docker  # wait, do proper mount via fstab
# Update /etc/fstab, reboot, verify
```

### 2.4 Start stack back

```bash
cd /opt/agmind/docker && sudo docker compose up -d
sudo agmind status
```

If anything breaks — `rm /var/lib/docker`, revert to `/var/lib/docker.old`, restore from backup.

---

## Scenario 3 — VPS with cloud-encrypted disk + LUKS layer

Cloud providers (AWS EBS, GCP PD, Hetzner encrypted volumes) do transparent disk encryption at rest with provider-managed keys. This protects against drive-level theft but **not** against cloud-admin compromise.

Adding LUKS on top gives **customer-managed keys** — provider sysadmins can't decrypt.

Steps identical to Scenario 1, but the backing device is `/dev/xvdf` (EBS) or equivalent.

**Key storage:** VPS reboots need unattended unlock. Options:
- Store keyfile on small **unencrypted** boot partition (pragmatic, protects against drive theft only)
- TPM-sealed key (AWS Nitro Enclaves, GCP Shielded VMs) — serious work
- Manual passphrase at each boot via `dropbear-ssh` (downtime cost)

---

## Backup encryption (gap to close)

`scripts/backup.sh` currently produces unencrypted tar.gz. If backups leave the host, they reintroduce the very threat LUKS addresses.

**Quick fix** (recommended to apply alongside LUKS):

```bash
# In backup.sh, before final rotation:
gpg --batch --symmetric --cipher-algo AES256 \
    --passphrase-file /etc/agmind/backup.key \
    "$backup_dir.tar"
shred -u "$backup_dir.tar"  # paranoid wipe of plain version
```

Store the passphrase file:
```bash
head -c 64 /dev/urandom | base64 | sudo tee /etc/agmind/backup.key
sudo chmod 400 /etc/agmind/backup.key
```

Document the passphrase out-of-band (physical safe, key escrow). If lost — backups are useless.

Formal integration of GPG into backup.sh is a **separate phase** (v3.1 or when first customer requires). This doc calls the gap out.

---

## Verification procedure

After applying Scenario 1 or 2:

```bash
# Disk shows encrypted
sudo cryptsetup status cryptdocker
# Docker root is on it
sudo docker info | grep "Docker Root Dir"
# Reboot test — must come up without user intervention (if keyfile) or prompt (if passphrase)
sudo reboot
# ...after reboot:
sudo docker ps  # all agmind-* should be Up

# Cold-storage verification: unmount, try to read directly
sudo umount /var/lib/docker
sudo cryptsetup luksClose cryptdocker
# At this point /dev/nvme1n1 is raw encrypted — mount attempt must fail
sudo mount /dev/nvme1n1 /mnt 2>&1 | grep "wrong fs type"  # expected: yes
```

---

## Rollback

If LUKS breaks boot / Docker won't start:

1. Boot rescue medium
2. `sudo cryptsetup luksOpen /dev/nvme1n1 cryptdocker` (passphrase)
3. Mount, extract /var/lib/docker, rsync back to plain partition
4. Update /etc/fstab to remove encrypted mount, remove /etc/crypttab entry
5. Reboot normally

Keep a **paper copy** of the passphrase in a sealed envelope in a physical safe. Sysadmin rotation without proper handoff = total data loss.

---

## Compliance crossref

| Requirement | This doc covers |
|---|---|
| 152-ФЗ ст. 19 (защита ПДн) | Partially — need to combine with consent management + access control (see Phase 47) |
| GDPR Art. 32 (security of processing) | Partially — encryption-at-rest is one of several measures |
| ISO 27001 A.8.24 (cryptography) | Yes |
| FSTEC УЗ-3/УЗ-2 | Additional controls required (FSTEC-certified crypto, not generic LUKS) |

For RU public-sector customers specifically, LUKS with openssl is **not** FSTEC-certified — they need КриптоПро Диск or vipnet-compatible. Out of scope here; mention to prospect early.

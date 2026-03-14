---
sidebar_position: 4
---

# Offline Installation

Deploy AGMind in air-gapped environments without internet access.

## Prerequisites

You need a machine with internet access to prepare the offline bundle.

## Prepare Offline Bundle

On a machine with internet:

```bash
# 1. Clone the installer
git clone https://github.com/agmind/agmind-installer.git
cd agmind-installer

# 2. Pull all Docker images
source versions.env
docker compose -f templates/docker-compose.yml pull

# 3. Save images to a tar archive
docker save $(docker compose -f templates/docker-compose.yml config --images) \
  | gzip > agmind-images.tar.gz

# 4. Package everything
tar czf agmind-offline-bundle.tar.gz \
  --exclude='.git' \
  --exclude='agmind-images.tar.gz' \
  . agmind-images.tar.gz
```

## Install on Air-Gapped Host

```bash
# 1. Transfer the bundle to the target machine
scp agmind-offline-bundle.tar.gz user@target:/tmp/

# 2. Extract
cd /tmp && tar xzf agmind-offline-bundle.tar.gz

# 3. Load Docker images
docker load < agmind-images.tar.gz

# 4. Install
export DEPLOY_PROFILE=offline
sudo -E bash install.sh
```

## Updating Offline

1. On internet-connected machine: pull new images, create new bundle
2. Transfer to air-gapped host
3. Load new images: `docker load < new-images.tar.gz`
4. Run update: `sudo /opt/agmind/scripts/update.sh`

## Pre-downloading LLM Models

```bash
# On internet machine, pull models
docker run --rm -v ollama_models:/root/.ollama ollama/ollama:0.6.2 pull llama3.2
docker run --rm -v ollama_models:/root/.ollama ollama/ollama:0.6.2 pull nomic-embed-text

# Save the volume
docker run --rm -v ollama_models:/data -v $(pwd):/backup \
  alpine tar czf /backup/ollama-models.tar.gz -C /data .

# On air-gapped host, restore
docker volume create agmind_ollama_data
docker run --rm -v agmind_ollama_data:/data -v $(pwd):/backup \
  alpine tar xzf /backup/ollama-models.tar.gz -C /data
```

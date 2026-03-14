---
sidebar_position: 3
---

# GPU Setup

AGMind auto-detects GPU hardware and configures Ollama for accelerated LLM inference.

## Supported GPUs

| Vendor | Detection | Requirements |
|--------|-----------|--------------|
| NVIDIA | `nvidia-smi` | NVIDIA Driver 535+, nvidia-container-toolkit |
| AMD | `/dev/kfd`, `rocminfo` | ROCm 5.7+ |
| Intel Arc | `/dev/dri`, `clinfo` | Intel compute-runtime |
| Apple Silicon | Detected, warns | Use native Ollama (not Docker) |
| CPU | Fallback | No additional requirements |

## Auto-Detection

During installation, `detect_gpu()` runs automatically:

1. Checks for `FORCE_GPU_TYPE` environment override
2. Checks `SKIP_GPU_DETECT` flag
3. Probes NVIDIA → AMD → Intel → Apple → CPU fallback
4. Writes result to `.agmind_gpu_profile`

## Manual Override

```bash
# Force specific GPU type
export FORCE_GPU_TYPE=nvidia  # nvidia|amd|intel|cpu

# Skip GPU detection entirely
export SKIP_GPU_DETECT=true
```

## NVIDIA Setup

### Install NVIDIA Container Toolkit

```bash
# Add NVIDIA repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### Verify

```bash
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

## AMD ROCm Setup

```bash
# Install ROCm
sudo apt install rocm-dev
# Verify
rocminfo
```

AGMind configures Ollama with `OLLAMA_ROCM=1` and mounts `/dev/kfd` and `/dev/dri`.

## Troubleshooting

### GPU not detected

```bash
# Check detection result
cat /opt/agmind/.agmind_gpu_profile

# Re-run detection
sudo bash -c 'source lib/detect.sh && detect_gpu'
```

### Ollama not using GPU

```bash
# Check Ollama logs
docker compose -f /opt/agmind/docker/docker-compose.yml logs ollama | grep -i gpu

# Verify GPU passthrough
docker compose exec ollama nvidia-smi  # NVIDIA
docker compose exec ollama rocm-smi    # AMD
```

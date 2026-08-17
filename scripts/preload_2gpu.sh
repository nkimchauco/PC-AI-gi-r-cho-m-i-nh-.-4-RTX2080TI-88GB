#!/bin/bash
# preload_2gpu.sh — Unbind GPU1+GPU3 tam thoi -> Load + TEST 27B tren 2 GPU (GPU0+GPU2) -> Bind lai
# Dung: sudo bash /home/mrcong/AiServer/preload_2gpu.sh
set -e

echo "==> [0/8] Cho nvidia driver + 4 GPU san sang (toi da 120s)"
for i in $(seq 1 40); do
  GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c "GPU")
  [ "$GPU_COUNT" -eq 4 ] && break
  sleep 3
done
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c "GPU")
if [ "$GPU_COUNT" -ne 4 ]; then
  echo "❌ Khong du 4 GPU sau 120s (hien co: $GPU_COUNT) - thoat"
  exit 1
fi
echo "   ✅ Du 4 GPU - bat dau"

echo "==> [1/8] Tat info.service + ollama + persistenced"
systemctl stop info.service 2>/dev/null || true
systemctl stop ollama 2>/dev/null || true
for i in $(seq 1 40); do
  systemctl is-active --quiet ollama 2>/dev/null || break
  sleep 3
done
systemctl stop nvidia-persistenced 2>/dev/null || true
sleep 1
fuser -kv /dev/nvidia* 2>/dev/null || true
sleep 1

echo "==> [2/8] Go nvidia_drm + nvidia_modeset (neu con loaded)"
modprobe -r nvidia_drm 2>/dev/null || echo "   (nvidia_drm khong loaded)"
modprobe -r nvidia_modeset 2>/dev/null || echo "   (nvidia_modeset khong loaded)"

echo "==> [3/8] Unbind GPU1 (0b:00) + GPU3 (43:00) khoi nvidia"
for dev in 0000:0b:00.0 0000:0b:00.1 0000:0b:00.2 0000:0b:00.3 0000:43:00.0 0000:43:00.1 0000:43:00.2 0000:43:00.3; do
  if [ -L "/sys/bus/pci/devices/$dev/driver" ]; then
    drv=$(basename $(readlink "/sys/bus/pci/devices/$dev/driver"))
    echo "$dev" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null && echo "   $dev: unbind $drv OK" || echo "   $dev: unbind $drv FAIL"
  else
    echo "   $dev: chua co driver"
  fi
done
sleep 2

echo "==> [4/8] Start ollama (chi thay 2 GPU: GPU0+GPU2) + Load + TEST 27B (CHAY NEN)"
systemctl start ollama 2>/dev/null || true
sleep 3
nohup python3 - > /tmp/preload_2gpu_model.log 2>&1 <<'PYEOF' &
import json, urllib.request, time, secrets
model = "qwen38:27b-q6_k-mtp"
ready = False
for i in range(20):
    try:
        urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=3)
        ready = True
        break
    except Exception:
        time.sleep(3)
if not ready:
    print("LOI: ollama chua san sang sau 60s")
    raise SystemExit(1)
body = json.dumps({
    "model": model, "messages": [{"role": "user", "content": "hi"}],
    "stream": False, "options": {"num_predict": 1, "num_ctx": 262144, "num_batch": 1024}
}).encode()
req = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=body, headers={"Content-Type": "application/json"})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=900) as r:
        json.loads(r.read().decode())
    print(f"{time.time()-t0:.0f}s - preload OK ({model})")
except Exception as e:
    print(f"preload LOI: {e}")
PYEOF
echo "   (model load dang chay nen - log: /tmp/preload_2gpu_model.log)"
for i in $(seq 1 40); do
  nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null | grep -q "llama-server" && break
  sleep 3
done
sleep 2

echo "==> [5/8] Bind GPU1 (0b:00) + GPU3 (43:00) lai nvidia"
for dev in 0000:0b:00.0 0000:43:00.0; do
  echo nvidia > /sys/bus/pci/devices/$dev/driver_override 2>/dev/null || true
done
for dev in 0000:0b:00.1 0000:43:00.1; do
  echo snd_hda_intel > /sys/bus/pci/devices/$dev/driver_override 2>/dev/null || true
done
for dev in 0000:0b:00.2 0000:43:00.2; do
  echo xhci_hcd > /sys/bus/pci/devices/$dev/driver_override 2>/dev/null || true
done
for dev in 0000:0b:00.3 0000:43:00.3; do
  echo nvidia-gpu > /sys/bus/pci/devices/$dev/driver_override 2>/dev/null || true
done
modprobe i2c_nvidia_gpu 2>/dev/null || true
for dev in 0000:0b:00.0 0000:0b:00.1 0000:0b:00.2 0000:0b:00.3 0000:43:00.0 0000:43:00.1 0000:43:00.2 0000:43:00.3; do
  f=${dev##*.}
  case $f in
    0) drv="nvidia" ;;
    1) drv="snd_hda_intel" ;;
    2) drv="xhci_hcd" ;;
    3) drv="nvidia-gpu" ;;
  esac
  if [ ! -L "/sys/bus/pci/devices/$dev/driver" ]; then
    timeout 8 bash -c "echo $dev > /sys/bus/pci/drivers/$drv/bind" 2>/dev/null && echo "   $dev: bind $drv OK" || echo "   $dev: bind $drv FAIL (check modprobe $drv)"
    [ "$f" = "0" ] && sleep 2
  else
    echo "   $dev: da bind $(basename $(readlink "/sys/bus/pci/devices/$dev/driver"))"
  fi
done
sleep 2

echo "==> [6/8] Xoa driver_override (giong trang thai vua boot)"
for dev in 0000:0b:00.0 0000:0b:00.1 0000:0b:00.2 0000:0b:00.3 0000:43:00.0 0000:43:00.1 0000:43:00.2 0000:43:00.3; do
  echo "" > /sys/bus/pci/devices/$dev/driver_override 2>/dev/null || true
done

echo "==> [7/8] Go vfio module (neu con) + Persistence Mode + Bat lai info.service"
modprobe -r vfio_pci 2>/dev/null || true
modprobe -r vfio_pci_core 2>/dev/null || true
modprobe -r vfio_iommu_type1 2>/dev/null || true
modprobe -r vfio 2>/dev/null || true
nvidia-smi -pm 1 2>/dev/null || true
systemctl start info.service 2>/dev/null || true

echo "==> [8/8] KET QUA"
nvidia-smi -L
echo "---"
for dev in 0000:0b:00.0 0000:43:00.0; do
  echo -n "   $dev -> override="
  cat /sys/bus/pci/devices/$dev/driver_override 2>/dev/null || echo -n "(none)"
  echo -n " | driver="
  readlink /sys/bus/pci/devices/$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo "NO DRIVER"
  echo ""
done
echo "-> Model 27B dang giu tren 2 GPU (GPU0+GPU2). GPU1+GPU3 ranh."

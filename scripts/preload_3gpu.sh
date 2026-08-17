#!/bin/bash
# preload_3gpu.sh — Unbind GPU3 tam thoi -> Load model 35B tren 3 GPU -> Bind GPU3 lai nvidia
# Muc dich: warmup GPU (fix bug P0 idle) + giu model 35B resident tren 3 GPU, GPU3 ranh cho VM
# KHONG bind vfio cho GPU3 - chi unbind tam de ollama khong thay GPU3
# Dung: sudo bash /home/mrcong/AiServer/preload_3gpu.sh
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

echo "==> [1/8] Tat info.service + ollama + persistenced (giai phong GPU3 truoc khi unbind)"
systemctl stop info.service 2>/dev/null || true
systemctl stop ollama 2>/dev/null || true
# Cho ollama stop han (toi da 120s) truoc khi unbind - tranh device busy/treo
for i in $(seq 1 40); do
  systemctl is-active --quiet ollama 2>/dev/null || break
  sleep 3
done
systemctl stop nvidia-persistenced 2>/dev/null || true
sleep 1
# Giet holder /dev/nvidia* - thieu buoc nay -> NVRM "non-zero usage count" -> treo unbind
fuser -kv /dev/nvidia* 2>/dev/null || true
sleep 1

echo "==> [2/8] Go nvidia_drm + nvidia_modeset (neu con loaded)"
modprobe -r nvidia_drm 2>/dev/null || echo "   (nvidia_drm khong loaded)"
modprobe -r nvidia_modeset 2>/dev/null || echo "   (nvidia_modeset khong loaded)"

echo "==> [3/8] Unbind GPU3 (4 function) khoi nvidia (KHONG bind vfio)"
for f in 0 1 2 3; do
  dev="0000:43:00.$f"
  if [ -L "/sys/bus/pci/devices/$dev/driver" ]; then
    drv=$(basename $(readlink "/sys/bus/pci/devices/$dev/driver"))
    echo "$dev" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null && echo "   $dev: unbind $drv OK" || echo "   $dev: unbind $drv FAIL"
  else
    echo "   $dev: chua co driver"
  fi
done
sleep 2  # cho device detach xong

echo "==> [4/8] Start ollama (chi thay 3 GPU) + Load model 35B (CHAY NEN)"
systemctl start ollama 2>/dev/null || true  # da stop o buoc 1 - chi can start, khong restart (tranh timeout)
sleep 3
nohup python3 - > /tmp/preload_3gpu_model.log 2>&1 <<'EOF' &
import json, urllib.request, time
model = "qwen36:35b-vision"
# Retry: cho ollama serve san sang (toi da 60s)
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
    "model": model,
    "messages": [{"role": "user", "content": "hi"}],
    "stream": False,
    "options": {"num_predict": 1, "num_ctx": 262144, "num_batch": 3072}
}).encode()
req = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=body,
                             headers={"Content-Type": "application/json"})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=900) as r:
        json.loads(r.read().decode())
    print(f"{time.time()-t0:.0f}s - preload OK ({model})")
except Exception as e:
    print(f"preload LOI: {e}")
EOF
echo "   (model load dang chay nen - log: /tmp/preload_3gpu_model.log)"
# Cho llama-server MO CUDA context (da enumerate GPU xong) - toi da 120s
# Dung nvidia-smi compute-apps lam tin hieu - chinh xac hon pgrep (spawn != enumerate xong)
for i in $(seq 1 40); do
  nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null | grep -q "llama-server" && break
  sleep 3
done
sleep 2  # on dinh them truoc khi bind GPU3

echo "==> [5/8] Bind GPU3 lai nvidia (4 function)"
echo nvidia > /sys/bus/pci/devices/0000:43:00.0/driver_override 2>/dev/null || true
echo snd_hda_intel > /sys/bus/pci/devices/0000:43:00.1/driver_override 2>/dev/null || true
echo xhci_hcd > /sys/bus/pci/devices/0000:43:00.2/driver_override 2>/dev/null || true
echo nvidia-gpu > /sys/bus/pci/devices/0000:43:00.3/driver_override 2>/dev/null || true
modprobe i2c_nvidia_gpu 2>/dev/null || true
for f in 0 1 2 3; do
  dev="0000:43:00.$f"
  case $f in
    0) drv="nvidia" ;;
    1) drv="snd_hda_intel" ;;
    2) drv="xhci_hcd" ;;
    3) drv="nvidia-gpu" ;;
  esac
  if [ ! -L "/sys/bus/pci/devices/$dev/driver" ]; then
    timeout 8 bash -c "echo $dev > /sys/bus/pci/drivers/$drv/bind" 2>/dev/null && echo "   $dev: bind $drv OK" || echo "   $dev: bind $drv FAIL (check modprobe $drv)"
    [ "$f" = "0" ] && sleep 2  # nvidia probe GPU3 xong moi bind function khac
  else
    echo "   $dev: da bind $(basename $(readlink "/sys/bus/pci/devices/$dev/driver"))"
  fi
done
sleep 2

echo "==> [6/8] Xoa driver_override (giong trang thai vua boot)"
for f in 0 1 2 3; do
  echo "" > /sys/bus/pci/devices/0000:43:00.$f/driver_override 2>/dev/null || true
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
for f in 0 1 2 3; do
  echo -n "   43:00.$f -> override="
  cat /sys/bus/pci/devices/0000:43:00.$f/driver_override 2>/dev/null || echo -n "(none)"
  echo -n " | driver="
  readlink /sys/bus/pci/devices/0000:43:00.$f/driver 2>/dev/null | xargs basename 2>/dev/null || echo "NO DRIVER"
  echo ""
done
echo "-> Model 35B dang giu tren 3 GPU (P8 khi idle). GPU3 ranh - muon VM chay: gpu3_vfio.sh"

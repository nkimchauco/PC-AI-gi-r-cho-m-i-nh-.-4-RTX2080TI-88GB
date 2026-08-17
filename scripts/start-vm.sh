#!/bin/bash
# start-vm.sh — Tu dong: chuyen GPU3 sang vfio-pci -> Start VM win10
# Logic moi 2026-08-15: nhung toan bo logic gpu3_vfio.sh (unbind + bind vfio, KHONG dong ollama)
# Dung: sudo bash /home/mrcong/AiServer/start-vm.sh
set -e

if virsh list --all | grep -q "win10-gpu.*running"; then
  echo "VM win10-gpu dang chay roi - khong can lam gi."
  exit 0
fi

echo "==> [1/3] Chuyen GPU3 sang vfio-pci"

echo "==> [0/8] Tat info.service + persistenced (KHONG dong ollama - VM dung GPU3 rieng)"
systemctl stop info.service 2>/dev/null || true
systemctl stop nvidia-persistenced 2>/dev/null || true
sleep 1
# Giet holder /dev/nvidia* (persistenced) - thieu buoc nay -> NVRM "non-zero usage count" -> treo unbind vinh vien
# KHONG dung fuser -kv (se giet llama-server = mat model) - persistenced da stop nen unbind an toan
sleep 1

echo "==> [1/8] Go nvidia_drm + nvidia_modeset (tranh treo unbind - giu ref nvidia)"
modprobe -r nvidia_drm 2>/dev/null || echo "   (nvidia_drm khong loaded)"
modprobe -r nvidia_modeset 2>/dev/null || echo "   (nvidia_modeset khong loaded)"

echo "==> [2/8] Kiem tra GPU3 khong con process nao dung"
if nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader 2>/dev/null | grep -qi "$(nvidia-smi -L 2>/dev/null | grep "GPU 3:" | grep -o 'GPU-[a-f0-9-]*')"; then
  echo "   CANH BAO: GPU3 van con process dung! (fuser -kv /dev/nvidia* de giai phong)"
  exit 1
else
  echo "   GPU3 trong - OK"
fi

echo "==> [3/8] Unbind GPU3 (4 function) khoi driver hien tai"
for f in 0 1 2 3; do
  dev="0000:43:00.$f"
  if [ -L "/sys/bus/pci/devices/$dev/driver" ]; then
    drv=$(basename $(readlink "/sys/bus/pci/devices/$dev/driver"))
    echo "$dev" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null && echo "   $dev: unbind $drv OK" || echo "   $dev: unbind $drv FAIL"
  else
    echo "   $dev: chua co driver"
  fi
done
sleep 2  # cho device detach xong truoc khi override

echo "==> [4/8] Load vfio-pci + Set override vfio-pci (ca 4 function)"
modprobe vfio-pci 2>/dev/null || true
for f in 0 1 2 3; do
  echo vfio-pci > /sys/bus/pci/devices/0000:43:00.$f/driver_override 2>/dev/null || true
done

echo "==> [5/8] Bind GPU3 (4 function) vao vfio-pci"
for f in 0 1 2 3; do
  dev="0000:43:00.$f"
  timeout 8 bash -c "echo $dev > /sys/bus/pci/drivers/vfio-pci/bind" 2>/dev/null && echo "   bind $dev OK" || echo "   (bind $dev fail/da bind)"
  [ "$f" = "0" ] && sleep 2  # vfio-pci probe xong function .0 roi moi bind function khac
done

echo "==> [6/8] Cho driver on dinh + Bat Persistence Mode"
sleep 2  # cho driver on dinh truoc khi hoi nvidia-smi
nvidia-smi -pm 1

echo "==> [7/8] Bat lai info.service"
systemctl start info.service 2>/dev/null || true

echo "==> [8/8] KET QUA"
sleep 1  # cho moi thu on dinh truoc khi verify
nvidia-smi -L
echo "---"
for f in 0 1 2 3; do
  echo -n "   43:00.$f -> override="
  cat /sys/bus/pci/devices/0000:43:00.$f/driver_override 2>/dev/null || echo -n "(none)"
  echo -n " | driver="
  readlink /sys/bus/pci/devices/0000:43:00.$f/driver 2>/dev/null | xargs basename 2>/dev/null || echo "NO DRIVER"
  echo ""
done
echo "-> Start VM: virsh start win10-gpu"
echo "Ghi chu: ollama van chay tren 3 GPU - khong bi anh huong"

echo "==> Check GPU3 da vfio chua"
if [ "$(basename $(readlink /sys/bus/pci/devices/0000:43:00.0/driver 2>/dev/null) 2>/dev/null)" != "vfio-pci" ]; then
  echo "❌ GPU3 chua o vfio-pci - dung lai, khong start VM"
  exit 1
fi
echo "   ✅ GPU3 vfio-pci OK"

echo "==> [2/3] Start VM win10-gpu"
virsh start win10-gpu

echo "==> [3/3] XONG - VM da mo"
virsh list --all | grep win10

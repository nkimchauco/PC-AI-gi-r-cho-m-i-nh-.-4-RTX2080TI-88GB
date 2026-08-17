#!/bin/bash
# preload_4gpu.sh — Kiem tra du 4 GPU -> Load model Qwen 122B (MTP)
# Neu khong du 4 GPU: bao loi va thoat (khong load)
# Dung: sudo bash /home/mrcong/AiServer/preload_4gpu.sh
set -e

echo "==> [1/3] Kiem tra so GPU nvidia"
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c "GPU")
echo "   So GPU: $GPU_COUNT"

if [ "$GPU_COUNT" -ne 4 ]; then
  echo "❌ Không đủ 4 GPU để load QWEN 122B (hien co: $GPU_COUNT)"
  exit 1
fi
echo "   ✅ Du 4 GPU - stop + start ollama de nhan du 4 GPU"
systemctl stop ollama 2>/dev/null || true
# Cho ollama stop han (toi da 120s)
for i in $(seq 1 40); do
  systemctl is-active --quiet ollama 2>/dev/null || break
  sleep 3
done
systemctl start ollama 2>/dev/null || true
sleep 3

echo "==> [2/3] Load Qwen 122B (74G - MTP) qua Ollama (CHAY NEN)"
nohup python3 - > /tmp/preload_4gpu_model.log 2>&1 <<'EOF' &
import json, urllib.request, time
model = "qwen3.5-122b-a10b-q4_k_s-mtp"
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
    "options": {"num_predict": 1, "num_ctx": 262144, "num_batch": 1536}
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
echo "   (model load dang chay nen - log: /tmp/preload_4gpu_model.log)"
sleep 10  # cho llama-server enumerate xong 4 GPU truoc khi verify

echo "==> [3/3] KET QUA"
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

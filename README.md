# 🤖 AI giá rẻ cho mọi nhà — X399 AI Server, 88GB VRAM, 4× RTX 2080 Ti mod 22GB

Một máy chủ AI tự build từ linh kiện "đồ cũ", chạy model LLM lớn trên **4 GPU song song** và **Windows 10 VM với GPU passthrough** trên cùng một cỗ máy — không cần reboot để chuyển đổi giữa AI và VM.

> **Tóm tắt:** 88GB VRAM (4× RTX 2080 Ti mod 11GB→22GB) · Threadripper 2950X · 128GB RAM · chạy Qwen 122B-A10B MoE @ ~45–60 tok/s · VM Windows 10 với GPU passthrough nóng (hot-switch, không reboot).

---

## 🧱 Cấu hình phần cứng

| Component | Thông số |
|---|---|
| Mainboard | MSI MEG X399 CREATION |
| CPU | AMD Threadripper 2950X (16C/32T) |
| RAM | 4× Kingston 32GB DDR4-3200 = **128GB** |
| GPU | 4× RTX 2080 Ti **22GB** (mod 11GB→22GB) = **88GB VRAM** |
| PSU | ASUS TUF Gaming 1200G 1200W Gold |
| NVMe | Patriot P410 1TB Gen4 (chạy PCIe 3.0 trên X399) |
| OS | Ubuntu Server 26.04 (headless, SSH port 1984) |

### Chi tiết GPU

- **Card:** Gigabyte RTX 2080 Ti blower, VRAM mod lên 22GB (hàn thêm chip 2GB phía sau, 12 chip × 2GB). Test bằng `cuda_memtest` full pattern (Test0→Test10) đều **PASS** — ổn định.
- **Power limit:** 200W/card (từ 250W) — tiết kiệm ~100W tổng, nhiệt mát hơn, performance gần như không đổi.
- **PCIe layout:** khe 1 & 3 chạy **x16**, khe 2 & 4 chỉ **x8** (giới hạn cứng của mainboard X399 CREATION).
- **VRAM bandwidth:** ~490 GB/s/card (~80% spec 616 GB/s) — đúng chuẩn 2080 Ti.

### Bố trí PCIe thực tế

| Khe | GPU | PCIe link |
|---|---|---|
| 1 (gần CPU) | GPU3 | **x16** |
| 2 | GPU2 | x8 |
| 3 | GPU1 | **x16** |
| 4 | GPU0 | x8 |

---

## 🦙 Khả năng chạy model AI (Ollama)

**Ollama 0.32.13** trên 4 GPU (LLM backend llama.cpp với CUDA multi-GPU + MTP speculative decoding).

### Models chính đang chạy

| Model | Dung lượng | Vai trò |
|---|---|---|
| `qwen3.5-122b-a10b-q4_k_s-mtp` | 74GB | Model lớn nhất — MoE 122B (10B active) |
| `qwen36:35b-vision` | 30GB | Vision/chat |
| `qwen38:27b-q6_k-mtp` | 23GB | Agent (dense, đủ thông minh để loop tool) |

### Cấu hình tối ưu (đã tinh chỉnh qua nhiều vòng benchmark)

```ini
LLAMA_ARG_FIT_TARGET=1536,512,512,512   ; phân bổ weights cân bằng 4 GPU
LLAMA_ARG_SCHED_SPREAD=1                ; dàn layer đều cả 4 card
num_batch=1536                          ; (PARAMETER trong Modelfile)
PARAMETER draft_num_predict 4           ; bật MTP speculative decoding
```

- 122B chạy **49/50 layers trên GPU** (chỉ MTP draft head ~2GB nằm trên CPU).
- Context lên tới **256K tokens** (KV cache nằm vừa 88GB VRAM).
- Hot-switch GPU: GPU3 có thể chuyển qua lại **vfio ↔ nvidia** trong lúc máy đang chạy (FLR reset + driver_override) — dành GPU cho VM khi cần, không reboot.

### Benchmark thực tế

**Qwen 3.5 122B-A10B (Q4_K_S, 4 GPU, 256K ctx):**

| Prompt | Prefill (tok/s) | Generation (tok/s) |
|---|---|---|
| 2K | 790–981 | 43.9–60.8 |
| 32K | ~770 | ~38 |
| 64K | ~640 | ~34 |

**Qwen 36 35B-A3B MoE (MTP):** gen ~110 tok/s, prefill ~1.500 tok/s (3 GPU).

**Qwen 27B Q6 dense:** chạy full GPU @ 262K context, gen ~38 tok/s — model agent mặc định.

> Kinh nghiệm: với llama.cpp multi-GPU, chỉnh `FIT_TARGET` thấp hơn (~512MB/GPU phụ) + batch vừa phải cho kết quả **nhanh hơn ~10–30%** so với target cao — vì compute buffer nhỏ hơn và weights được xếp tối ưu hơn.

---

## 🪟 Windows 10 VM (GPU passthrough + hot-switch)

Chạy **KVM/libvirt + OVMF**, VM Windows 10 có GPU vật lý riêng (RTX 2080 Ti mod 22GB), dùng chung bộ xử lý 16C/32T và RAM 128GB của host.

### Storage

| Ổ | File | Dung lượng | Mục đích |
|---|---|---|---|
| C: | `win10.qcow2` | 32GB | Windows + phần mềm |
| D: | `data.qcow2` | 32GB | Dữ liệu, profile người dùng (Windows profile đã chuyển sang D:) |
| E: | `game.qcow2` | 390GB | Game / ứng dụng nặng |

- **Virtio-blk + discard/TRIM**: xóa file trong Windows → file ảnh tự co lại trên host (không cần zero hóa thủ công).
- SSH vào VM trực tiếp (X399 → Win10) để quản trị headless.
- **Hook libvirt**: khi tắt VM, GPU3 tự động trả về driver nvidia cho AI — chuỗi thao tác hoàn toàn tự động.

### GPU passthrough hiệu năng thật (FurMark)

| Cấu hình | Score | FPS | Max power | Nhiệt |
|---|---|---|---|---|
| VM + raw disk | 7742 | 128 | ~250W | 74°C |
| **VM + NVMe raw + HugePages** | **9188** | **153** | 258W | 72°C |

→ **+18.7%** chỉ nhờ tối ưu host (raw disk + hugepages). Passthrough **không bottleneck**: card mod 22GB chạy đúng chuẩn stock.

### Chuyển đổi AI ↔ VM không reboot

```
[AI 4 GPU] --chạy VM--> GPU3 chuyển sang vfio → VM dùng GPU3
[VM tắt]   --hook tự động--> GPU3 trả về nvidia → AI lại đủ 4 GPU
```

Các script: `gpu4-mode.sh` / `bind-gpu3-vfio.sh` / `start-vm.sh` (preload model 3 GPU hoặc 4 GPU tùy trạng thái).

---

## 🏗️ Kiến trúc tổng thể

```
┌─────────────────────────────────────────────┐
│            X399 AI Server                   │
│  Ubuntu 26.04 · Threadripper 2950X · 128GB  │
│                                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐     │
│  │ GPU0    │  │ GPU1    │  │ GPU2    │     │
│  │ 2080Ti  │  │ 2080Ti  │  │ 2080Ti  │     │
│  │ 22GB    │  │ 22GB    │  │ 22GB    │     │
│  └─────────┘  └─────────┘  └─────────┘     │
│  Ollama 122B (4 GPU)  ⇄  ┌─────────┐       │
│                         │ GPU3    │◄──────►│ VM Win10
│                         │ 2080Ti  │  vfio  │ (KVM + GPU
│                         │ 22GB    │        │  passthrough)
│                         └─────────┘        │
└─────────────────────────────────────────────┘
```

---

## 📈 Tổng kết

- 💰 **Chi phí thấp, hiệu năng cao**: 4× 2080 Ti mod 22GB = 88GB VRAM với chi phí bằng một phần nhỏ so với GPU mới.
- 🤖 **LLM lớn chạy local**: Qwen 122B-A10B @ ~45–60 tok/s, context 256K — đủ dùng cho agent + chat + vision.
- 🪟 **Windows VM "miễn phí"** trên cùng máy, GPU passthrough không bottleneck, chuyển đổi AI/VM không cần reboot.
- 🔧 Toàn bộ quy trình đều được script hóa (switch GPU, preload model, backup, restore).

---

*Dự án cá nhân — build & test từ tháng 7/2026. Mọi đóng góp ý tưởng đều hoan nghênh!*

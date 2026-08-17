# 🖥️ PC AI giá rẻ cho mọi nhà — 4× RTX 2080 Ti 88GB

Một máy chủ AI tự build từ linh kiện "đồ cũ", chạy model LLM lớn trên **4 GPU song song** và **Windows 10 VM với GPU passthrough** trên cùng một cỗ máy — không cần reboot để chuyển đổi giữa AI và VM.

> **Tóm tắt:** 88GB VRAM (4× RTX 2080 Ti mod 22GB) · Threadripper 2950X · 128GB RAM · chạy Qwen 122B-A10B MoE @ ~44–61 tok/s · VM Windows 10 với GPU passthrough nóng (hot-switch, không reboot).
>
> 💡 **Nói thật về chi phí:** 4× RTX 2080 Ti mod 22GB (88GB VRAM) là đồ cũ, giá ngang **1 chiếc RTX 5070 Ti mới**. Nhưng cùng số tiền đó, một card mới 16GB chỉ đủ chạy model ~14B — còn bộ này chạy được **model 122B**, vừa AI vừa game, VM và LLM dùng chung máy: **làm được khối việc hơn hẳn**.

---

## 🧱 Cấu hình phần cứng

| Component | Thông số |
|---|---|
| Mainboard | MSI MEG X399 CREATION |
| CPU | AMD Threadripper 2950X (16C/32T) |
| RAM | 4× Kingston 32GB DDR4-3200 = **128GB** |
| GPU | 4× RTX 2080 Ti **22GB** (mod chip nhớ) = **88GB VRAM** |
| PSU | ASUS TUF Gaming 1200G 1200W Gold |
| NVMe | Patriot P410 1TB Gen4 (chạy PCIe 3.0 trên X399) |
| OS | Ubuntu Server 26.04 (headless) |

### Chi tiết GPU

- **Card:** Gigabyte RTX 2080 Ti blower, VRAM mod 11GB → **22GB** bằng cách **thay 11 chip nhớ 1GB bằng 11 chip 2GB** (thay chip trên board, không phải hàn thêm chip mặt sau). Test bằng `cuda_memtest` full pattern (Test0→Test10) đều **PASS** — ổn định.
- **Power limit:** 200W/card (từ 250W) — tiết kiệm ~100W tổng, nhiệt mát hơn, performance gần như không đổi.
- **PCIe layout:** khe 1 & 3 chạy **x16**, khe 2 & 4 chỉ **x8** (giới hạn cứng của mainboard X399 CREATION).

### Bố trí PCIe thực tế

| Khe | GPU | PCIe link |
|---|---|---|
| 1 (gần CPU) | GPU3 | **x16** |
| 2 | GPU2 | x8 |
| 3 | GPU1 | **x16** |
| 4 | GPU0 | x8 |

---

## 🦙 Khả năng chạy model AI (Ollama)

**Ollama 0.32.13** trên 4 GPU (backend llama.cpp CUDA multi-GPU + MTP speculative decoding).

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

### Benchmark thực tế (tok/s — prefill / generation)

**Qwen 3.5 122B-A10B (Q4_K_S, 74GB) — 4 GPU, config chuẩn:**

| Mốc prompt | Prefill | Generation |
|---|---|---|
| 2K | ~981 | ~60.8 |
| 4K–16K | 790–900 | 44–55 |
| 32K | ~790 | ~43.9 |
| 64K | ~640 | ~34 |

> So với config cũ (batch 2048): gen chỉ 32.9–45.6 → sau khi tinh chỉnh **+28–54%**.

**Qwen 36 35B-A3B MoE (Q6, 30GB) — 3 GPU, MTP:**

| Mốc prompt | Prefill | Generation |
|---|---|---|
| 2K | 2095 | 115.7 |
| 4K | 2416 | 114.1 |
| 8K | 2518 | 117.0 |
| 16K | 2451 | 111.0 |
| 32K | 2215 | 99.1 |
| 64K | 1807 | 84.7 |

**Qwen 38 27B Q6 dense (23GB):** gen ~38 tok/s, chạy **full GPU @ 262K context** — model agent mặc định (MTP).

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

### Test game thật (Black Myth: Wukong)

| Setting | Kết quả |
|---|---|
| **Preset Cinema** @ 3440×1440 | **~86 FPS** |

→ Chạy ngon ở mức đồ họa **Cinema** (cao nhất của game). Muốn cao hơn nữa thì bật **FSR + Frame Gen**.

### Chuyển đổi AI ↔ VM không reboot

```
[AI 4 GPU] --chạy VM--> GPU3 chuyển sang vfio → VM dùng GPU3
[VM tắt]   --hook tự động--> GPU3 trả về nvidia → AI lại đủ 4 GPU
```

---

## 🛠️ Scripts tham khảo

Toàn bộ script dùng thật trên máy, để trong [`scripts/`](scripts/):

| File | Chức năng |
|---|---|
| `preload_2gpu.sh` | Preload model dùng 2 GPU (nhường GPU cho việc khác) |
| `preload_3gpu.sh` | Preload model 3 GPU (GPU3 rảnh cho VM) |
| `preload_4gpu.sh` | Preload model 4 GPU (full AI) |
| `start-vm.sh` | Tự động chuyển GPU3 sang vfio-pci → start VM Win10 (không tắt Ollama) |
| `libvirt-hook-qemu` | Hook libvirt: check disk trước khi VM start + trả GPU3 về nvidia khi VM tắt |

> Lưu ý: các script chứa đường dẫn/PCI address (43:00.0) riêng của máy này — dùng làm tham khảo, cần chỉnh theo hardware của bạn.

---

## 💡 Kinh nghiệm đắt giá

1. **Tắt DRM module của NVIDIA** nếu máy chạy headless (không cần màn hình console): block `nvidia_drm` qua `/etc/modprobe.d/` + `update-initramfs -u`. Không làm điều này, khi unbind/bind GPU để chuyển qua lại giữa AI và VM rất dễ **treo máy** (rmmod nvidia_drm kẹt D-state).
2. **Remote desktop vào Windows VM**: nếu không có HDMI dummy plug (không có màn hình ảo để GPU render), dùng **Parsec** thay vì Sunshine + Moonlight — Parsec hoạt động tốt hơn hẳn trong môi trường headless/GPU passthrough.
3. **Power limit 200W** là mức ngọt cho 2080 Ti chạy 24/7 — mát hơn, ổn định hơn, mất ~0% hiệu năng.
4. **TRIM/discard** cho qcow2: bật virtio-blk discard để file ảnh Windows tự co lại, không phình vô hạn.
5. Với multi-GPU llama.cpp: `SCHED_SPREAD=1` giúp dàn layer đều, tránh 1 GPU nghẽn.

---

## 📈 Tổng kết

- 💰 **Chi phí thấp, hiệu năng cao**: 4× 2080 Ti mod 22GB = 88GB VRAM với chi phí bằng một phần nhỏ so với GPU mới (dù chỉ tương đương ~1 RTX 5070 Ti mới).
- 🤖 **LLM lớn chạy local**: Qwen 122B-A10B @ ~44–61 tok/s, context 256K — đủ dùng cho agent + chat + vision.
- 🪟 **Windows VM "miễn phí"** trên cùng máy, GPU passthrough không bottleneck, chuyển đổi AI/VM không cần reboot.
- 🔧 Toàn bộ quy trình đều được script hóa (switch GPU, preload model, backup, restore).

---

*Dự án cá nhân — build & test từ tháng 7/2026. Mọi đóng góp ý tưởng đều hoan nghênh!*

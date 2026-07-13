# NeuroFPGA

Spiking neural network inference on a Zynq-7020 FPGA, using a Liquid State Machine (LSM) architecture. Camera input goes in, spikes happen in the middle, a servo moves at the end.

> 🚧 **Work in progress** — actively being built as part of an 8-week portfolio project.

---

## What is this?

This project implements a **neuromorphic inference system** on the [Smart ZYNQ SP2](http://hellofpga.com) board (Xilinx XC7Z020-CLG484). Instead of a conventional CNN or MLP, it uses a **Liquid State Machine** — a reservoir of spiking neurons that processes temporal information naturally.

The key idea: the reservoir's weights are **random and fixed** (never trained), so the entire spiking network can be baked into FPGA fabric. Only a lightweight linear readout layer runs on the ARM core and gets retrained with simple ridge regression. Switching tasks means retraining a tiny matrix — no resynthesizing the bitstream.

### The pipeline

```
OV7670 Camera
    │
    ▼
Frame Differencing (ARM)      ← converts frames into pseudo-events
    │
    ▼
AXI DMA → PL Fabric           ← events cross into FPGA
    │
    ▼
LIF Reservoir (PL)            ← fixed random spiking neurons, Q8.8/INT8
    │
    ▼
Linear Readout (ARM)          ← ridge regression, retrained per task
    │
    ▼
Decision → Servo/LED          ← closed-loop physical output
```

## Why LSM?

Training spiking neural networks end-to-end is painful — spikes are non-differentiable, and backprop-through-time gets messy fast. LSMs sidestep all of that:

- **No backprop needed.** Reservoir weights are random and frozen. The only training is a closed-form ridge regression on the readout layer: `W = (XᵀX + λI)⁻¹XᵀY`.
- **FPGA-friendly.** Fixed weights mean the reservoir can be fully hardened into PL. Membrane decay `β = 1 − 2⁻ᵏ` uses bit-shifts instead of multipliers.
- **Task-flexible.** Swap tasks by retraining just the readout on ARM. The PL bitstream stays the same.

## Hardware

| Component | Details |
|---|---|
| **Board** | Smart ZYNQ SP2 (hellofpga.com) |
| **FPGA** | XC7Z020-CLG484, speed grade -2 |
| **PL Resources** | ~53.2K LUT, 220 DSP48, 140×36Kb BRAM (~630 KB) |
| **PS** | Dual-core ARM Cortex-A9 |
| **Memory** | 512 MB DDR3 |
| **Camera** | OV7670 (may need ADB_ZD02 adapter for differential IO) |
| **Toolchain** | Vivado 2018.3 (HLS, not Vitis) |

## Project Phases

### Phase 0 — Software Baseline (PC) `← current`
- Build LSM in snnTorch: data loading → fixed recurrent LIF reservoir → spike counting → ridge regression readout
- Target dataset: **SHD** (Spiking Heidelberg Digits) — spoken digits encoded as spikes, good for testing temporal memory
- Quantization-aware simulation (INT8/Q8.8) to validate before hardware

### Phase 1 — On-Board PS (ARM / PYNQ)
- Port inference to ARM, replay spikes, verify numerical consistency against PC baseline

### Phase 2 — Live Input
- OV7670 frame differencing → pseudo-event generation → feed into reservoir

### Phase 3 — PL Acceleration
- Reservoir as AXI accelerator: time-multiplexed LIF processing elements
- Membrane potential in Q8.8, weights in INT8
- Readout stays on PS

### Stretch Goals
- Mixture-of-Experts readout (multiple linear heads, simple router)
- LIF neuron array fully in PL fabric
- Adaptive LIF / heterogeneous time constants

## Roadmap (8 weeks)

| Week | Milestone |
|---|---|
| 1 | Environment setup + camera → LCD display |
| 2 | ARM preprocessing (frame diff → events) + PC software baseline + export weights |
| 3 | **Walking skeleton**: events → partition counting → servo/LED (end-to-end proof of life) |
| 4 | FPGA video pipeline (FIFO, line buffer, filtering) |
| 5–6 | **MVP**: reservoir + readout on PS → smart tracking; *stretch*: LIF array in PL |
| 7 | Decision output + closed-loop tracking polish |
| 8 | Benchmarks + system diagram + demo video + this README + resume bullets |

## Metrics to Collect

- End-to-end latency (camera → actuator)
- Frames per second
- ARM vs FPGA processing latency breakdown
- PL resource utilization (LUT / DSP / BRAM)
- Closed-loop reaction time
- Power consumption

## Repository Structure

```
NeuroFPGA/
├── docs/                  # Theory notes, specs, architecture docs
├── software/              # snnTorch baseline, training scripts, weight export
├── firmware/              # ARM-side C code (preprocessing, readout, servo control)
├── hdl/                   # Verilog/HLS for PL (LIF reservoir, AXI interfaces)
├── vivado/                # Vivado project files, constraints, block designs
├── benchmarks/            # Performance measurement scripts and results
└── README.md
```

## Tech Stack

**Languages:** Python, C, Verilog

**Frameworks & Libraries:** snnTorch, PyTorch, NumPy, OpenCV

**Hardware Tools:** Vivado 2018.3, Vivado HLS

**Protocols & Interfaces:** AXI4-Lite, AXI4-Stream, AXI DMA, SPI (camera), PWM (servo)

**Concepts:** Leaky Integrate-and-Fire neurons, Liquid State Machine, reservoir computing, ridge regression, fixed-point arithmetic (Q8.8/INT8), frame differencing, event-driven processing

## References

- Maass, W., Natschläger, T., & Markram, H. (2002). *Real-time computing without stable states: A new framework for neural computation based on perturbations.* Neural Computation.
- Eshraghian, J.K., et al. (2023). *Training Spiking Neural Networks Using Lessons From Deep Learning.* Proceedings of the IEEE. ([snnTorch](https://snntorch.readthedocs.io/))
- Xilinx. *Zynq-7000 SoC Technical Reference Manual* (UG585).

## License

MIT

## Author

**Shiheng Wang** — Computer Engineering, University of Waterloo (Honours, Co-op)

[LinkedIn](https://www.linkedin.com/in/shiheng-wang-uw/) · [GitHub](https://github.com/Wshhgugugu)

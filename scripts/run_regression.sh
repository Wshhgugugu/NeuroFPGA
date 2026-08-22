#!/bin/bash
# run_regression.sh — 全部仿真回归 (xsim 批处理)
# 用法: bash scripts/run_regression.sh
set -e
cd "$(dirname "$0")/.."
XV=/e/AMD_FPGA/2025.2/Vivado/bin/xvlog
XE=/e/AMD_FPGA/2025.2/Vivado/bin/xelab
XS=/e/AMD_FPGA/2025.2/Vivado/bin/xsim

RTL="rtl/common/sync_2ff.v rtl/common/fifo_async.v rtl/common/line_buffer.v rtl/common/window_kxk.v rtl/sensor/sccb_master.v rtl/sensor/ov5640_ctrl.v rtl/img_proc/gaussian_5x5.v rtl/img_proc/scharr_3x3.v rtl/img_proc/gradient_mag_dir.v rtl/img_proc/median_3x3.v rtl/img_proc/nms.v rtl/img_proc/double_threshold.v rtl/img_proc/hysteresis.v rtl/img_proc/canny_top.v rtl/snn/lif_neuron.v rtl/snn/spike_encoder.v rtl/snn/synapse_array.v rtl/snn/snn_top.v rtl/display/vga_timing.v rtl/display/color_map.v rtl/display/hdmi_tx.v rtl/interconnect/axi_crossbar_wrap.v rtl/interconnect/mode_switch.v rtl/riscv/custom_alu.v rtl/riscv/instr_decoder_ext.v rtl/riscv/vexriscv_wrapper.v rtl/cpu/mcu8.v rtl/cpu/axi_mcu_bridge.v"

# 激励与 golden 再生成 (保证一致)
python scripts/gen_test_image.py --size 64 --pattern edge --out sim/stimulus/test_image_64x64.hex >/dev/null
python scripts/gen_test_image.py --size 64 --pattern edgecase --out sim/stimulus/test_edge_case.hex >/dev/null
python scripts/gen_test_image.py --size 64 --pattern noise --out sim/stimulus/test_noise.hex >/dev/null
python scripts/gen_test_image.py --size 64 --pattern flat --out sim/stimulus/test_flat.hex >/dev/null
python scripts/golden_model.py --in sim/stimulus/test_image_64x64.hex --size 64 --out sim/reference/golden_output.hex --dump-dir sim/reference >/dev/null
python scripts/golden_model.py --in sim/stimulus/test_noise.hex --size 64 --out sim/reference/golden_noise.hex >/dev/null
python scripts/golden_model_snn.py --act sim/stimulus/act_64.hex --out out/golden_snn.hex >/dev/null
python scripts/asm8.py mem/prog_adaptive.asm mem/prog_adaptive.hex >/dev/null

$XV -sv -i rtl/sensor $RTL sim/tb/tb_window.sv sim/tb/tb_stage_gauss.sv sim/tb/tb_scharr.sv sim/tb/tb_canny.sv sim/tb/tb_hyst.sv sim/tb/tb_lif.sv sim/tb/tb_display.sv sim/tb/tb_sccb.sv sim/tb/tb_custom_alu.sv sim/tb/tb_regs.sv sim/tb/tb_cpu.sv sim/tb/tb_framebuf.sv 2>&1 | grep ERROR && exit 1
$XV -sv -d SIMPLIFIED_CLK -i rtl/sensor -i rtl/top -i rtl/cpu $RTL rtl/top/vision_top.v sim/tb/tb_vision_top.sv 2>&1 | grep ERROR && exit 1
$XV -sv -d SIMPLIFIED_CLK -i rtl/sensor -i rtl/top -i rtl/cpu $RTL rtl/top/vision_top.v sim/tb/tb_multi.sv 2>&1 | grep ERROR && exit 1

declare -A SNAP
for tb in tb_window tb_stage_gauss tb_scharr tb_canny tb_hyst tb_lif tb_display tb_sccb tb_custom_alu tb_regs tb_cpu tb_framebuf tb_vision_top tb_multi; do
    $XE $tb -s reg_$tb -debug off 2>&1 | grep -iE '^ERROR' && exit 1
done

FAIL=0
for tb in tb_window tb_stage_gauss tb_scharr tb_lif tb_display tb_sccb tb_custom_alu tb_regs tb_cpu tb_framebuf tb_vision_top tb_multi; do
    R=$($XS reg_$tb --runall 2>&1 | grep -oE 'PASS|FAIL' | head -1)
    printf "%-18s %s\n" "$tb" "$R"
    [ "$R" = "PASS" ] || FAIL=1
done
# canny: 4 种图案
for t in edge edgecase noise flat; do
    f=sim/stimulus/test_image_64x64.hex
    [ $t = edgecase ] && f=sim/stimulus/test_edge_case.hex
    [ $t = noise ]    && f=sim/stimulus/test_noise.hex
    [ $t = flat ]     && f=sim/stimulus/test_flat.hex
    [ $f != sim/stimulus/test_image_64x64.hex ] && cp $f sim/stimulus/test_image_64x64.hex
    python scripts/golden_model.py --in sim/stimulus/test_image_64x64.hex --size 64 --out sim/reference/golden_output.hex >/dev/null
    R=$($XS reg_tb_canny --runall 2>&1 | grep -oE 'PASS|FAIL' | head -1)
    printf "%-18s %s\n" "tb_canny($t)" "$R"
    [ "$R" = "PASS" ] || FAIL=1
done
# 恢复默认
python scripts/gen_test_image.py --size 64 --pattern edge --out sim/stimulus/test_image_64x64.hex >/dev/null
python scripts/golden_model.py --in sim/stimulus/test_image_64x64.hex --size 64 --out sim/reference/golden_output.hex --dump-dir sim/reference >/dev/null
echo "==="; [ $FAIL = 0 ] && echo "REGRESSION ALL PASS" || echo "REGRESSION HAS FAILURES"

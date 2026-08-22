open_checkpoint [file normalize out/vision_top_routed.dcp]
report_utilization -hierarchical -file out/util_hier_full.rpt
report_utilization -file out/utilization_final.rpt
# vectorless 功耗估算
report_power -file out/power.rpt
puts "POWER_ANALYSIS_DONE"

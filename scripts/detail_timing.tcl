open_checkpoint [file normalize out/vision_top_routed.dcp]
report_timing -max_paths 10 -nworst 1 -delay_type max -group clk_proc -file out/worst_proc_paths.rpt
report_timing -max_paths 10 -nworst 1 -delay_type max -group async_default -file out/worst_async_paths.rpt
puts "TIMING_DETAIL_DONE"

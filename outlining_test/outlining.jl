include("utils_macros.jl")
include("utils_functions.jl")
include("test_functions.jl")


ir, linetable = @grab_ir_linetable bar(4)
ir_safe = deepcopy(ir)
ir = Core.Compiler.compact!(ir)
ir2 = compact_cut!(deepcopy(ir_safe))
ir3 = deepcopy(ir2)
cut_bb!(ir3, 15)
ir4 = compact_indirect!(deepcopy(ir3), 9)

domtree = Core.Compiler.construct_domtree(ir.cfg)

frame = @grab_frame bar(4)
src = @grab_src bar(4)

nothing

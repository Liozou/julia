include("utils_macros.jl")
include("utils_functions.jl")
include("test_functions.jl")


ir, linetable = @grab_ir measles(4)
ir_safe = deepcopy(ir)
ir = Core.Compiler.compact!(ir)
#=ir2 = compact_cut!(deepcopy(ir_safe))
ir3 = deepcopy(ir2)
cut_bb!(ir3, 11)
ir4 = compact_indirect!(deepcopy(ir3), 6)=#

domtree = Core.Compiler.construct_domtree(ir.cfg)

frame = @grab_frame measles(4)
src = @grab_src measles(4)
src.ssavaluetypes = length(src.ssavaluetypes)


if !(@isdefined count_boo)
    count_boo = 0
end
function regen!(src::Core.CodeInfo)
    global boo
    global argdata
    global count_boo
    boo = new_generic_function("boo", count_boo+=1, Main)
    argdata = Core.svec(Core.svec(typeof(boo), Int), Core.svec())
    ccall(:jl_method_def, Nothing, (Any, Any, Any), argdata, src, Main)
end
function regen!(v::Vector)
    global src
    src2 = deepcopy(src)
    src2.code = v
    regen(src2)
end
function regen!()
    global src
    regen!(src)
end
regen!()

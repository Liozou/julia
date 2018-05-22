using InteractiveUtils
const Compiler = Core.Compiler

function method_match_to_ir(methds, types)
    if length(methds) != 1
        @show methds
        @assert false
    end
    x = methds[1]
    meth = Core.Main.Base.func_for_method_checked(x[3], types)
    world = ccall(:jl_get_world_counter, UInt, ())
    params = Compiler.Params(world)
    code = Core.Compiler.code_for_method(meth, x[1], x[2], params.world)
    @assert code !== nothing
    code = code::Core.Compiler.MethodInstance
    frame = Core.Compiler.typeinf_frame(code, false, false, params)
    (_, ci, ty) = Compiler.typeinf_code(meth, x[1], x[2], false, false, params)

    ci === nothing && error("inference not successful") # Inference disabled?
    topline = Compiler.LineInfoNode(Main, Compiler.NullLineInfo.method, Compiler.NullLineInfo.file, 0, 0)
    linetable = [topline]
    bareframe = Core.Compiler.InferenceState(code, false, false, params)
    return Compiler.just_construct_ssa(ci, copy(ci.code), length(types.parameters), linetable), linetable
end



function grab_ir_for(func, argtypes)
    types = Core.Main.Base.to_tuple_type(argtypes)
    world = ccall(:jl_get_world_counter, UInt, ())
    methds = Core.Main.Base._methods(func, types, -1, world)
    if length(methds) != 1
        @show methds
        @assert false
    end
    x = methds[1]
    meth = Core.Main.Base.func_for_method_checked(x[3], types)
    world = ccall(:jl_get_world_counter, UInt, ())
    params = Compiler.Params(world)
    (_, ci, ty) = Compiler.typeinf_code(meth, x[1], x[2], false, false, params)
    ci === nothing && error("inference not successful") # Inference disabled?
    topline = Compiler.LineInfoNode(Main, Compiler.NullLineInfo.method, Compiler.NullLineInfo.file, 0, 0)
    linetable = [topline]
    return Compiler.just_construct_ssa(ci, copy(ci.code), length(types.parameters), linetable), linetable
end


function grab_src(func, argtypes)
    types = Core.Main.Base.to_tuple_type(argtypes)
    world = ccall(:jl_get_world_counter, UInt, ())
    methds = Core.Main.Base._methods(func, types, -1, world)
    if length(methds) != 1
        @show methds
        @assert false
    end
    x = methds[1]
    meth = Core.Main.Base.func_for_method_checked(x[3], types)
    world = ccall(:jl_get_world_counter, UInt, ())
    params = Compiler.Params(world)
    code = Core.Compiler.code_for_method(meth, x[1], x[2], params.world)
    @assert code !== nothing
    code = code::Core.Compiler.MethodInstance
    frame = Core.Compiler.typeinf_frame(code, false, false, params)
    (_, src, ty) = Compiler.typeinf_code(meth, x[1], x[2], false, false, params)
    return src
end


function grab_frame(func, argtypes)
    types = Core.Main.Base.to_tuple_type(argtypes)
    world = ccall(:jl_get_world_counter, UInt, ())
    methds = Core.Main.Base._methods(func, types, -1, world)
    if length(methds) != 1
        @show methds
        @assert false
    end
    x = methds[1]
    meth = Core.Main.Base.func_for_method_checked(x[3], types)
    world = ccall(:jl_get_world_counter, UInt, ())
    params = Compiler.Params(world)
    code = Core.Compiler.code_for_method(meth, x[1], x[2], params.world)
    @assert code !== nothing
    code = code::Core.Compiler.MethodInstance
    frame = Core.Compiler.typeinf_frame(code, false, false, params)
    (_, src, ty) = Compiler.typeinf_code(meth, x[1], x[2], false, false, params)
    return frame
end

IRShow = Module(:IRShow, true)
eval(IRShow, quote
    using Base
    using Base.Meta
    using Core.IR
    const Compiler = Core.Compiler
    using .Compiler: IRCode, ReturnNode, GotoIfNot, CFG, scan_ssa_use!, DomTree, DomTreeNode, Argument
    using Base.Iterators: peek
    #using AbstractTrees
end)
eval(IRShow, quote
    using Base: IdSet
    Compiler.push!(a::IdSet, b) = Base.push!(a, b)
    Base.size(r::Compiler.StmtRange) = Compiler.size(r)
    Base.show(io::IO, r::Compiler.StmtRange) = print(io, Compiler.first(r):Compiler.last(r))
    include(x) = Base.include(IRShow, x)
    include(Base.joinpath(Base.Sys.BINDIR, Base.DATAROOTDIR, "julia", "base", "compiler/ssair/show.jl"))

    struct DomTreeNodeRef
        tree::DomTree
        idx::Int
    end
end)

import Base:show
function show(io::IO, x::Core.Compiler.StmtRange)
    print(io, "$(x.first):$(x.last)")
end

import Base:getindex
function getindex(src::Core.CodeInfo, n)
    return getindex(src.code, n)
end

import Base:-
function -(src::Core.CodeInfo)
    src.code
end

macro grab_ir(expr)
    call = InteractiveUtils.gen_call_with_extracted_types(__module__, Expr(:quote, grab_ir_for), expr)
    quote
        $call
    end
end

macro grab_src(expr)
    call = InteractiveUtils.gen_call_with_extracted_types(__module__, Expr(:quote, grab_src), expr)
    quote
        $call
    end
end

macro grab_frame(expr)
    call = InteractiveUtils.gen_call_with_extracted_types(__module__, Expr(:quote, grab_frame), expr)
    quote
        $call
    end
end


function Base.deepcopy(ir::Core.Compiler.IRCode)
    ret = Core.Compiler.IRCode(deepcopy(ir.stmts), deepcopy(ir.types),
    deepcopy(ir.lines), deepcopy(ir.flags), deepcopy(ir.cfg),
    deepcopy(ir.argtypes), ir.mod, deepcopy(ir.meta))
    for x in ir.new_nodes
        push!(ret.new_nodes, deepcopy(x))
    end
    return ret
end


function new_generic_function(name, line, mod, specTypes)
    ccall(:jl_new_generic_function_with_binding, Any, (Any, Any),
        Symbol("outl_$(name)_$(specTypes)_$line"), mod)
end



"""
Set a cut at the place where type instability appears.
Incorrect - only use to experiment.
"""
function add_cut!(ir)
    used_dict = Core.Compiler.IdSet{Int}()
    node = Expr(:call, GlobalRef(Core, :OUTLINED_FUNCTION))
    unreachable = Core.Compiler.ReturnNode()
    foreach(stmt->Core.Compiler.scan_ssa_use!(used_dict, stmt), ir.stmts)
    new_nodes = ir.new_nodes[filter(i->isassigned(ir.new_nodes, i), eachindex(ir.new_nodes))]
    foreach(nn -> Core.Compiler.scan_ssa_use!(used_dict, nn.node), new_nodes)
    used = Set{Int}()
    for i in eachindex(used_dict.dict.ht)
        try
            x = used_dict.dict.ht[i]
            push!(used, x)
        end
    end
    for i in eachindex(ir.stmts)
        if i in used && ir.types[i] === Any
            Core.Compiler.insert_node!(ir, i+1, Union{}, node)
            Core.Compiler.insert_node!(ir, i+1, Union{}, unreachable)
            return ir
        end
    end
    return ir
end

function compact_cut!(ir)
    return Core.Compiler.compact!(add_cut!(ir))
end

function indirect!(ir, idx)
    Core.Compiler.insert_node!(ir, 1, Any, Core.GotoNode(idx))
    Core.Compiler.insert_node!(ir, 1, Union{}, Core.Compiler.ReturnNode()) #unreachable statement
    is_not_idx(x) = x != 1
    fst = ir.cfg.blocks[1]
    for b in fst.succs
        filter!(is_not_idx, ir.cfg.blocks[b].preds)
    end
    empty!(fst.succs)
    push!(fst.succs, idx)
    push!(ir.cfg.blocks[idx].preds, 1)
    return ir
end

function compact_indirect!(ir, idx)
    return Core.Compiler.compact!(indirect!(ir, idx))
end


function replace_slotnames!(src::Vector, list)
    for i in eachindex(src)
        x = src[i]
        if x isa Expr
            src[i] = replace_slotnames!(x, list)
        elseif x isa Core.NewvarNode
            src[i] = Core.NewvarNode(Core.SlotNumber(list[src[i].slot.id]))
        end
    end
end
function replace_slotnames!(e::Expr, list)
    for i in eachindex(e.args)
        x = e.args[i]
        if x isa Expr
            e.args[i] = replace_slotnames!(x, list)
        else
            e.args[i] = replace_slotnames(x, list)
        end
    end
    return e
end

function replace_slotnames(x::Core.SlotNumber, list)
    return Core.SlotNumber(list[x.id])
end
function replace_slotnames(x::Core.TypedSlot, list)
    return Core.TypedSlot(list[x.id], x.typ)
end
function replace_slotnames(x, list)
    return x
end


"""
Determine whether the function can be outlined at a given line.
If so, return the list of reordered slots for the outlined function and the
number of slot to give as an argument to the outlined function.
Otherwise, return an empty list and 0.
"""
function outlineable_at_line(frame, line)
    l = frame.stmt_types[line]
    n = length(l)
    defs = Int[]
    for i in 1:n
        x = l[i]
        if x isa Core.Compiler.VarState
            if x.undef
                if x.typ !== Union{}
                    return Int[], 0 # Slot cannot be determined to be defined or not.
                end
            else
                push!(defs, i)
            end
        else
            return Int[], 0 # Do not outline unreachable code.
        end
    end
    # The function is outlineable at the given point.
    sorted = Vector{Int}(undef, n)
    push!(defs, 0) # The last element of defs can never be reached by i below
    fst = 0; lst = n+1; current = 1
    for i in 1:n
        if i == defs[current] # defs is never empty because its last last element is 0
            sorted[fst+=1] = i
            current+=1
        else
            sorted[lst-=1] = i
        end
    end
    return sorted, current-1
end

"""
Enumerate the ssa values that are known to be defined when attaining bb i.
"""
function existing_ssa_bb(ir, bb, domtree=Core.Compiler.construct_domtree(ir.cfg))
    ssas = Int[]
    bb = domtree.idoms[bb]
    while bb!=0
        range = ir.cfg.blocks[bb].stmts
        for i in range.first:range.last
            x = ir.stmts[i]
            if !(x isa Core.Compiler.GotoIfNot || x isa Core.GotoNode ||
                x isa Core.Compiler.ReturnNode || (x isa Expr &&
                    (x.head == :leave || x.head == :gc_preserve_end)))
                push!(ssas, i)
            end
        end
        bb = domtree.idoms[bb]
    end
    return ssas
end

function existing_ssa(ir, i, domtree=Core.Compiler.construct_domtree(ir.cfg))
    bb::Int = findfirst(x -> x>i, ir.cfg.index)
    ssas = existing_ssa_bb(ir, bb, domtree)
    return append!(ssas, ir.cfg.blocks[bb].stmts.first:(i-1))
end


"""
Give the first line of the first loop and the last line of the last loop of a
function, or (0, 0) if there is no loop.
The first line corresponds to a LabelNode; the last to a GotoNode or GotoIfNot.
The argument is the code field of the CodeInfo of the function.
"""
function find_first_last_loop(code::Vector)
    labels = Set{Int}()
    kept_labels = Int[]
    kept_gotos = Int[]
    for i in 1:length(code)
        x = code[î]
        t = typeof(x)
        if t === Core.LabelNode
            push!(labels, x.label)
        elseif t === Core.GotoNode
            if x.label in labels # Already encountered label => loop
                push!(kept_labels, x.label) # The name of the label is the number of the line
                push!(kept_gotos, i)
            end
        elseif t === Expr && x.head == :gotoifnot # Similar to above
            if x.args[2] in labels
                push!(kept_labels, x.args[2])
                push!(kept_gotos, i)
            end
        end
    end
    if isempty(kept_labels) # No loop
        return (0, 0)
    end
    return minimum(kept_labels), maximum(kept_gotos)
end


"""
Cuts the ir at a given line.
"""
function cut_bb!(ir, line)
    block = Core.Compiler.block_for_inst(ir.cfg, line)
    if ir.cfg.blocks[block].stmts.first == line
        return block # The line is already at the beginning of a basic block.
    end
    # First, add a new bb in the cfg
    insert!(ir.cfg.index, block, line) # Start of the next block.
    old = ir.cfg.blocks[block]
    # No successor to the cut block: it should end with a tail call
    ir.cfg.blocks[block] = Core.Compiler.BasicBlock(
        Core.Compiler.StmtRange(old.stmts.first, line-1), old.preds, Int[])
    # As a consequence, no predecessor to the new block.
    insert!(ir.cfg.blocks, block+1, Core.Compiler.BasicBlock(
        Core.Compiler.StmtRange(line, old.stmts.last), Int[], old.succs))
    patch(x) = x<block ? x : x+1
    # Second, update the links within cfg: the bbs have to be renumbered.
    for i in eachindex(ir.cfg.blocks)
        b = ir.cfg.blocks[i]
        replace!(patch, b.preds)
        if i == block-1
            replace!(x -> x <= block ? x : x+1, b.succs)
        else
            replace!(patch, b.succs)
        end
    end
    # Last, update the stmts.
    for i in eachindex(ir.stmts)
        e = ir.stmts[i]
        if e isa Core.GotoNode && e.label >= block
            ir.stmts[i] = Core.GotoNode(e.label+1)
        elseif e isa Core.Compiler.GotoIfNot && e.dest >= block
            ir.stmts[i] = Core.Compiler.GotoIfNot(e.cond, e.dest+1)
        elseif e isa Core.PhiNode
            replace!(patch, e.edges)
        end
    end
    return block + 1
end

"""
Erase the instructions before give line and transforms ssa values into arguments
with position given by args.
"""
function cut_and_replace_args!(ir, line, args, initial_nargs)
    block = cut_bb!(ir, line)
    reverse = Dict{Int, Int}()
    for i in 1:length(args)
        x = args[i]
        reverse[x] = i
        push!(ir.argtypes, ir.types[x])
    end
    # Erase the bypassed instructions
    for i in 1:(line-1)
        ir.stmts[i] = nothing # will get compacted by compact!
    end

    function make_argument(x)
        if haskey(reverse, x.id)
            return Core.Compiler.Argument(initial_nargs + reverse[x.id])
        end
        return x
    end
    for i in 1:length(ir.stmts)
        ir.stmts[i] = Core.Compiler.ssamap(make_argument, ir.stmts[i])
    end
    return block
end

"""
Assuming that no bb before bb_start is reachable, shrink all phi nodes refering
to such bb.
"""
function shrink_phi_nodes(ir, bb_start)
    bb_start == 1 && return
    for i in ir.cfg.index[bb_start-1]:length(ir.stmts)
        x = ir.stmts[i]
        if x isa Core.PhiNode
            to_keep = map(edge -> edge >= bb_start, x.edges)
            if count(to_keep) == 1
                ir.stmts[i] = x.values[to_keep][1]
            else
                ir.stmts[i] = Core.PhiNode(x.edges[to_keep], x.values[to_keep])
            end
        end
    end
end


"""
Performs outlining above the given line, under the assumption that it occurs
outside any loop.
"""
function outline_outside_loop(frame, ir, linetable, line)
    # TODO Check if the line just before is a LineNumberNode, in which case
    # include it in the outlined function? To check.
    outlined = new_generic_function(frame.result.linfo.def.name, line, frame.mod,
                                    hash(frame.linfo.specTypes))
    name = string(outlined)

    args_int = existing_ssa(ir, line)
    println(args_int)
    for x in args_int
        if x isa Core.Compiler.MaybeUndef
            return nothing
        end
    end

    # Set argtypes: all arguments have no type requirement.
    initial_nargs = length(frame.linfo.def.sig.parameters)
    nargs = initial_nargs + length(args_int)
    argtypes = [Any for _ in 1:(nargs-1)] # The first type will get replaced.
    #=
    if Core.Compiler.isvarargtype(frame.linfo.def.sig.parameters[end])
        # n: number of non-vararg arguments
        n = length(frame.linfo.def.sig.parameters) - 1
        # m: number of vararg arguments
        m = length(frame.linfo.specTypes.parameters) - before_vararg - 1
        # vartype: type of the vararg arguments
        vartype = Core.Compiler.unwrap_unionall(frame.linfo.def.sig).parameters[1]
        # The first argument, typeof(fun), is omitted as it will get replaced.
        fst = [frame.linfo.def.sig.parameters[i] for i in 2:n]
        mid = [vartype for _ in 1:m]
        lst = [Any for _ in 1:length(args)]
        # argtypes: types of the arguments of the outlined function
        argtypes = vcat(fst, mid, lst)
        nargs = n + m + length(args) - 1
    else
        n = length(frame.linfo.specTypes.parameters)
        fst = [frame.linfo.def.sig.parameters[i] for i in 2:n]
        lst = [Any for _ in 1:length(args)]
        argtypes = vcat(fst, lst)
        nargs = n + length(args) - 1
    end
    =#
    argdata = Core.svec(Core.svec(typeof(outlined), argtypes...), Core.svec())

    new_ir = deepcopy(ir)
    block_start = cut_and_replace_args!(new_ir, line, args_int, initial_nargs)
    shrink_phi_nodes(new_ir, block_start)

    return new_ir

    src = deepcopy(frame.src)
    splitpoint = (initial_nargs+1):initial_nargs
    new_names = ["$(name)_$i" for i in args_int]
    splice!(src.slotnames, splitpoint, new_names)
    new_types = [ir.types[i] for i in args_int]
    splice!(src.slottypes, splitpoint, new_types)
    splice!(src.slotflags, splitpoint, [Compiler.SLOT_ASSIGNEDONCE for i in 1:length(args_int)])
    # XXX Check whether it should be nargs or nargs+1 at the next line
    Core.Compiler.replace_code_newstyle!(src, deepcopy(new_ir), nargs, linetable)
    src.ssavaluetypes = length(src.ssavaluetypes)
    ccall(:jl_method_def, Nothing, (Any, Any, Any), argdata, src, frame.mod)
    return src, new_ir
end

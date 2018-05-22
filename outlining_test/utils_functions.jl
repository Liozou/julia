
function Base.deepcopy(ir::Core.Compiler.IRCode)
    ret = Core.Compiler.IRCode(deepcopy(ir.stmts), deepcopy(ir.types),
    deepcopy(ir.lines), deepcopy(ir.flags), deepcopy(ir.cfg),
    deepcopy(ir.argtypes), ir.mod, deepcopy(ir.meta))
    for x in ir.new_nodes
        push!(ret.new_nodes, deepcopy(x))
    end
    return ret
end


"""
Set a cut at the place where type instability appears.
Incorrect but help for experiment.
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

"""
Cuts the ir at a given line.
"""
function cut_bb!(ir, line)
    # First, add a new bb in the cfg
    block = Core.Compiler.block_for_inst(ir.cfg, line)
    insert!(ir.cfg.index, block, line+1) # Start of the next block.
    bef = ir.cfg.blocks[block]
    # No successor to the cut block: it should end with a tail call
    ir.cfg.blocks[block] = Core.Compiler.BasicBlock(
        Core.Compiler.StmtRange(bef.stmts.first, line), bef.preds, Int[])
    # As a consequence, no predecessor to the new block.
    insert!(ir.cfg.blocks, block+1, Core.Compiler.BasicBlock(
        Core.Compiler.StmtRange(line+1, bef.stmts.last), Int[], bef.succs))
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
    nothing
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
    ssas = Int()
    bb = domtree.idoms[bb]
    while bb!=0
        range = ir.cfg.blocks[bb].stmts
        append!(ssas, range.first:range.last)
        bb = domtree.idoms[bb]
    end
    return ssas
end

function existing_ssa(ir, i, domtree=Core.Compiler.construct_domtree(ir.cfg))
    bb::Int = findfirst(x->x>i, ir.cfg.index)
    ssas = existing_ssa_bb(ir, bb, domtree)
    return append!(ssas, ir.cfg.blocks[bb].stmts.first:i)
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
Performs outlining at the given line, under the assumption that it occurs
before the main loop.
"""
function outline_before_loop(frame, ir, linetable, line)
    # TODO Check if the line just before is a LineNumberNode, in which case
    # include it in the outlined function? To check.
    outlined = new_generic_function(frame.result.linfo.def.name, line, frame.mod)
    args_int = existing_ssa(ir, line)
    args = Core.SSAValue[]
    for i in args_int
        if i isa Core.Compiler.MaybeUndef
            return nothing
        end
        push!(args, Core.SSAValue(i))
    end
    nargs = length(args)
    argdata = Core.svec(Core.svec(typeof(outlined), [Any for _ in 1:nargs]...), Core.svec())
    src = deepcopy(src)
    # XXX Check whether it should be nargs or nargs+1 at the next line
    replace_code_newstyle!(src, ir, nargs, linetable)
    ccall(:jl_method_def, Nothing, (Any, Any, Any), argdata, src, frame.mod)
end

function new_generic_function(name, line, mod)
    ccall(:jl_new_generic_function_with_binding, Any, (Any, Any), Symbol("#outl#$name#$line"), mod)
end

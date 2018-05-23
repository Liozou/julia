

macro code_only(expr)
    fun = expr.args[1]
    types = Base.typesof(expr.args[2:end]...)
    quote
        io = IOBuffer()
        InteractiveUtils.code_native(io, $fun, $types)
        join(filter(x->length(x)>1 && x[1]!=';', split(String(take!(io)), '\n')), '\n')
    end
end


function used_variables(src::Vector)
    slots = Int[]
    ssas  = Int[]
    for i in eachindex(src)
        x = src[i]
        if x isa Expr
            src[i] = replace_slotnames!(x, list)
        elseif x isa Core.NewvarNode
            src[i] = Core.NewvarNode(Core.SlotNumber(list[src[i].slot.id]))
        end
    end
end


function used_vars_line!(e::Expr, slots, ssas)
    if e.head == :(=)
        beg = 2
    else
        beg = 1
    end
    for i in beg:length(e.args)
        x = e.args[i]
        if x isa Core.Slot
            push!(slots, x.id)
        elseif x isa Core.SSAValue
            push!(ssas, x.id)
        elseif x isa Expr
            used_vars!(x, slots, ssas)
        end
    end
    return slots, ssas
end

function used_vars_line(code::Vector)
    slots = [Set{Int}() for _ in 1:length(code)]
    ssas  = [Set{Int}() for _ in 1:length(code)]
    for i in length(code):-1:1
        x = code[i]
        if x isa Expr
            used_vars!(x, slots[i], ssas[i])
        end
    end
    return slots, ssas
end


boo = eval(Expr(:function, Symbol("#outl"))) # Generate a function with forbidden name
m = ccall(:jl_new_method, Ref{Method}, (Any, Any, Any, Any, Int, Int, Any),
          src, :boo, Main, Tuple{typeof(boo), Int}, 2, 0, Core.svec())


## Code from ssair/outlining.jl

function foo(x, y)
  z = x + 2y
  return z
end

method_foo = first(methods(foo))

linfo = Core.Compiler.code_for_method(method_foo, Tuple{typeof(foo), Int64, Float64}, Core.Compiler.svec(), typemax(UInt))

frame = Core.Compiler.InferenceState(linfo, true, false, Core.Compiler.Params(typemax(UInt)))

def = frame.linfo.def
opt = Core.Compiler.OptimizationState(frame)
nargs = Int(opt.nargs) - 1
topline = Core.Compiler.LineInfoNode(opt.mod, def.name, def.file, Int(def.line), 0)
linetable = [topline]
ci = opt.src
ir = just_construct_ssa(ci, copy(ci.code), nargs, linetable)

show(ir)

#=
function my_optimize(me::Core.Compiler.InferenceState)
  # annotate fulltree with type information
  Core.Compiler.type_annotate!(me)

  # run optimization passes on fulltree
  force_noinline = true
  def = me.linfo.def
  if me.limited && me.cached && me.parent !== nothing
      # a top parent will be cached still, but not this intermediate work
      me.cached = false
      me.linfo.inInference = false
  elseif me.optimize
      opt = Core.Compiler.OptimizationState(me)
      Core.Compiler.reindex_labels!(opt)
      nargs = Int(opt.nargs) - 1
      if def isa Method
          topline = Core.Compiler.LineInfoNode(opt.mod, def.name, def.file, Int(def.line), 0)
      else
          topline = Core.Compiler.LineInfoNode(opt.mod, Core.Compiler.NullLineInfo.method, Core.Compiler.NullLineInfo.file, 0, 0)
      end
      linetable = [topline]
      ci = opt.src
      ir = just_construct_ssa(ci, copy(ci.code), nargs, linetable)
      return ir
  end
end
=#

## Ex utility from outlining.jl

src = @grab_src +(4)
src.ssavaluetypes = length(src.ssavaluetypes)

if !(@isdefined count_boo)
    count_boo = 0
end
function regen!(src::Core.CodeInfo)
    global boo
    global argdata
    global count_boo
    boo = new_generic_function("boo", count_boo+=1, Main, hash(Tuple{Int}))
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

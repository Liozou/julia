#= run with
make; julia --inline=no record_calls.jl 2>RECORD_LOG2
=#

ccall(:jl_toggle_a, Cvoid, ())

abstract type A end
struct C1 <: A end
struct C2 <: A end
struct B end

function foo(x::A) end
function foo(x::B) end

foo(C1())
foo(C2())
foo(C2())
foo(B())

ccall(:jl_toggle_a, Cvoid, ())
ccall(:jl_export_record, Cvoid, ())

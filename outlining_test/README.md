# Roadmap for the outlining pass


### TODO
- Consider exception handling.
- Take care of the new arguments to the function: `substitute!` from optimize.jl
- Watch out for meta instructions and such (bound checking, ...) that modify
  the behaviour of the function and which must be propagated to the oulined one.
- Create a mark in the IR that specifies where type instability stems.
  * Check for modifications of frame.stmt_types
- Enforce tail call elimination for the outline call.
  * In loops: necessary, otherwise the call stack grows with the loop
  * Outside: only necessary if the function is recursive. Otherwise, choose.
- Distinguish three cases:
  * Outline before the main loop: most the defined variables are well-known.
  * Outline after the main loop: most of the variables that are used after are
    well-known.
  * Outline within the main loop: difficult.
    + The two first cases are easy to do since the set of variables that must
     be given as arguments to the outlined function can be computed exactly.
    + Even in these two cases, branching can allow some variables to be defined
     or not through the entire loop. In this case, no optimization is possible.
     It should be fairly rare because that's poor style. Detectable through
     frame.stmt_types
    + The last case is more difficult. It can be associated to loop peeling to
     go back to the first case in some situations. For the other situations,
     don't forget to add the outlining call BEFORE copy-pasting the src code
     for the new outlined function
- \[OPTIONAL\] Compute whether type instability in a loop affects the prior parts
  of the loop. If not, do not recursify the loop, outline only the type instable
  part.
- Do not outline for a variable which is only used as a @nospecialize argument.
  * Do not outline functions that use @nospecialize arguments.

### DONE
- Choose whether to create an entire function to outline or only a method
  * If function, how to manually add a method to a function? (jl_method_def?)
  * If method, create a `jl_apply_method` that refines `jl_apply_generic` for
     functions with only one method. It can only be used by the compiler.
     Also refine method to add a cache of their instances.
     Use `jl_specializations_get_linfo`.

  ⇒ create a `jl_code_info_t` associated with a `jl_typemap_t` as cache for the
`jl_method_instance_t`.

  ⇒ old proposition by Jameson overriden by Jeff: create an entire function.

- The new IR is that on which outlining can be done. However, building a new
  method instance requires a CodeInfo, not a IRCode.

  ⇒ use OptimizationState instead of IRCode, since its src field is a CodeInfo.

  ⇒ overriden by Jeff's decision → use a generic function.

- How to create the new outlined function?
 1. In the original IR,
   1. at the desired point, cut the BB in two.
   2. add the tail call to the outlined function at the end of the first BB.
 2. Copy-paste this entire IR to be that of the outlined function.
 3. Dead code eliminate the unreachable part in the original IR.
    -> The second BB resulting from the cut can always be killed.
 4. Prepend the new IR by a goto to the created second BB created in 1)a).
 5. Dead code eliminate the beginning of the new IR.

  ⇒ The outlined function must be written in the old IR because type
     inference does not work on the new one.

- Check `jl_compile_linfo` (to compile linfo) and `jl_code_for_staged` (to get
  src from generator).

  ⇒ nothing.

- Check NewvarNode.

  ⇒ Marks a point where a variable is created. This has the effect of resetting
     a variable to undefined. (from docs)

- Choose where to place the outlining pass: during type inference or after.

  ⇒ After. Partial type inference has little sense.



Notes on low-level specialization:
- a method instance is created with its invoke field set to `jl_fptr_trampoline`
- calling a method instance actually calls its invoke field
- upon calling `jl_fptr_trampoline`, the code is specialized (via a call to
  `jl_compile_method_internal` that calls `jl_generate_fptr` in codegen.cpp)
- During specialization, the fptr to the specialized code is set as the ìnvoke
  field.

Notes on type inference:
- type inference is triggered by a call to `jl_type_infer`, which in turn calls
  `jl_typeinf_func`.
- `jl_typeinf_func` is a global variable, set to `typeinf_ext` in compiler.jl
  through a call to `jl_set_typeinf_func`.
- `typeinf_ext` is a julia function defined in typeinfer.jl, which already deals
  separately whether linfo.def is a method or not.

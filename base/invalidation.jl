# This file is a part of Julia. License is MIT: https://julialang.org/license

struct GlobalRefIterator
    mod::Module
end
IteratorSize(::Type{GlobalRefIterator}) = SizeUnknown()
globalrefs(mod::Module) = GlobalRefIterator(mod)

function iterate(gri::GlobalRefIterator, i = 1)
    m = gri.mod
    table = ccall(:jl_module_get_bindings, Ref{SimpleVector}, (Any,), m)
    i == length(table) && return nothing
    b = table[i]
    b === nothing && return iterate(gri, i+1)
    return ((b::Core.Binding).globalref, i+1)
end

const TYPE_TYPE_MT = Type.body.name.mt
const NONFUNCTION_MT = Core.MethodTable.name.mt
function foreach_module_mtable(visit, m::Module, world::UInt)
    for gb in globalrefs(m)
        binding = gb.binding
        bpart = lookup_binding_partition(world, binding)
        if is_some_const_binding(binding_kind(bpart))
            isdefined(bpart, :restriction) || continue
            v = partition_restriction(bpart)
            uw = unwrap_unionall(v)
            name = gb.name
            if isa(uw, DataType)
                tn = uw.name
                if tn.module === m && tn.name === name && tn.wrapper === v && isdefined(tn, :mt)
                    # this is the original/primary binding for the type (name/wrapper)
                    mt = tn.mt
                    if mt !== nothing && mt !== TYPE_TYPE_MT && mt !== NONFUNCTION_MT
                        @assert mt.module === m
                        visit(mt) || return false
                    end
                end
            elseif isa(v, Module) && v !== m && parentmodule(v) === m && _nameof(v) === name
                # this is the original/primary binding for the submodule
                foreach_module_mtable(visit, v, world) || return false
            elseif isa(v, Core.MethodTable) && v.module === m && v.name === name
                # this is probably an external method table here, so let's
                # assume so as there is no way to precisely distinguish them
                visit(v) || return false
            end
        end
    end
    return true
end

function foreach_reachable_mtable(visit, world::UInt)
    visit(TYPE_TYPE_MT) || return
    visit(NONFUNCTION_MT) || return
    for mod in loaded_modules_array()
        foreach_module_mtable(visit, mod, world)
    end
end

function invalidate_code_for_globalref!(gr::GlobalRef, src::CodeInfo)
    found_any = false
    labelchangemap = nothing
    stmts = src.code
    function get_labelchangemap()
        if labelchangemap === nothing
            labelchangemap = fill(0, length(stmts))
        end
        labelchangemap
    end
    isgr(g::GlobalRef) = gr.mod == g.mod && gr.name === g.name
    isgr(g) = false
    for i = 1:length(stmts)
        stmt = stmts[i]
        if isgr(stmt)
            found_any = true
            continue
        end
        found_arg = false
        ngrs = 0
        for ur in Compiler.userefs(stmt)
            arg = ur[]
            # If any of the GlobalRefs in this stmt match the one that
            # we are about, we need to move out all GlobalRefs to preserve
            # effect order, in case we later invalidate a different GR
            if isa(arg, GlobalRef)
                ngrs += 1
                if isgr(arg)
                    @assert !isa(stmt, PhiNode)
                    found_arg = found_any = true
                    break
                end
            end
        end
        if found_arg
            get_labelchangemap()[i] += ngrs
        end
    end
    next_empty_idx = 1
    if labelchangemap !== nothing
        Compiler.cumsum_ssamap!(labelchangemap)
        new_stmts = Vector(undef, length(stmts)+labelchangemap[end])
        new_ssaflags = Vector{UInt32}(undef, length(new_stmts))
        new_debuginfo = Compiler.DebugInfoStream(nothing, src.debuginfo, length(new_stmts))
        new_debuginfo.def = src.debuginfo.def
        for i = 1:length(stmts)
            stmt = stmts[i]
            urs = Compiler.userefs(stmt)
            new_stmt_idx = i+labelchangemap[i]
            for ur in urs
                arg = ur[]
                if isa(arg, SSAValue)
                    ur[] = SSAValue(arg.id + labelchangemap[arg.id])
                elseif next_empty_idx != new_stmt_idx && isa(arg, GlobalRef)
                    new_debuginfo.codelocs[3next_empty_idx - 2] = i
                    new_stmts[next_empty_idx] = arg
                    new_ssaflags[next_empty_idx] = UInt32(0)
                    ur[] = SSAValue(next_empty_idx)
                    next_empty_idx += 1
                end
            end
            @assert new_stmt_idx == next_empty_idx
            new_stmts[new_stmt_idx] = urs[]
            new_debuginfo.codelocs[3new_stmt_idx - 2] = i
            new_ssaflags[new_stmt_idx] = src.ssaflags[i]
            next_empty_idx = new_stmt_idx+1
        end
        src.code = new_stmts
        src.ssavaluetypes = length(new_stmts)
        src.ssaflags = new_ssaflags
        src.debuginfo = Core.DebugInfo(new_debuginfo, length(new_stmts))
    end
    return found_any
end

function invalidate_code_for_globalref!(gr::GlobalRef, new_max_world::UInt)
    valid_in_valuepos = false
    foreach_reachable_mtable(new_max_world) do mt::Core.MethodTable
        for method in MethodList(mt)
            if isdefined(method, :source)
                src = _uncompressed_ir(method)
                old_stmts = src.code
                if invalidate_code_for_globalref!(gr, src)
                    if src.code !== old_stmts
                        method.debuginfo = src.debuginfo
                        method.source = src
                        method.source = ccall(:jl_compress_ir, Ref{String}, (Any, Ptr{Cvoid}), method, C_NULL)
                    end

                    for mi in specializations(method)
                        ci = mi.cache
                        while true
                            if ci.max_world > new_max_world
                                ccall(:jl_invalidate_code_instance, Cvoid, (Any, UInt), ci, new_max_world)
                            end
                            isdefined(ci, :next) || break
                            ci = ci.next
                        end
                    end
                end
            end
        end
        return true
    end
end

# This file is a part of Julia. License is MIT: https://julialang.org/license

#####################
# structs/constants #
#####################

struct PartialTypeVar
    tv::TypeVar
    # N.B.: Currently unused, but would allow turning something back
    # into Const, if the bounds are pulled out of this TypeVar
    lb_certain::Bool
    ub_certain::Bool
    PartialTypeVar(tv::TypeVar, lb_certain::Bool, ub_certain::Bool) = new(tv, lb_certain, ub_certain)
end

# The type of a variable load is either a value or an UndefVarError
mutable struct VarState
    typ
    undef::Bool
    VarState(@nospecialize(typ), undef::Bool) = new(typ, undef)
end

const VarTable = Array{Any,1}

mutable struct StateUpdate
    var::Union{Slot,SSAValue}
    vtype::VarState
    state::VarTable
end

struct NotFound end

const NOT_FOUND = NotFound()

#################
# lattice logic #
#################

function issubconditional(a::Conditional, b::Conditional)
    avar = a.var
    bvar = b.var
    if (isa(avar, Slot) && isa(bvar, Slot) && slot_id(avar) === slot_id(bvar)) ||
       (isa(avar, SSAValue) && isa(bvar, SSAValue) && avar === bvar)
        if a.vtype ⊑ b.vtype
            if a.elsetype ⊑ b.elsetype
                return true
            end
        end
    end
    return false
end

function ⊑(@nospecialize(a), @nospecialize(b))
    (a === NOT_FOUND || b === Any) && return true
    (a === Any || b === NOT_FOUND) && return false
    a === Union{} && return true
    b === Union{} && return false
    if isa(a, Conditional)
        if isa(b, Conditional)
            return issubconditional(a, b)
        end
        a = Bool
    elseif isa(b, Conditional)
        return a === Bottom
    end
    if isa(a, Const)
        if isa(b, Const)
            return a.val === b.val
        end
        return isa(a.val, widenconst(b))
    elseif isa(b, Const)
        return a === Bottom
    elseif !(isa(a, Type) || isa(a, TypeVar)) ||
           !(isa(b, Type) || isa(b, TypeVar))
        return a === b
    else
        return a <: b
    end
end

widenconst(c::Conditional) = Bool
function widenconst(c::Const)
    if isa(c.val, Type)
        if isvarargtype(c.val)
            return Type
        end
        return Type{c.val}
    else
        return typeof(c.val)
    end
end
widenconst(c::PartialTypeVar) = TypeVar
widenconst(@nospecialize(t)) = t

issubstate(a::VarState, b::VarState) = (a.typ ⊑ b.typ && a.undef <= b.undef)

function tmerge(@nospecialize(typea), @nospecialize(typeb))
    typea ⊑ typeb && return typeb
    typeb ⊑ typea && return typea
    if isa(typea, Conditional) && isa(typeb, Conditional)
        if typea.var === typeb.var
            vtype = tmerge(typea.vtype, typeb.vtype)
            elsetype = tmerge(typea.elsetype, typeb.elsetype)
            if vtype != elsetype
                return Conditional(typea.var, vtype, elsetype)
            end
        end
        return Bool
    end
    typea, typeb = widenconst(typea), widenconst(typeb)
    typea === typeb && return typea
    if !(isa(typea,Type) || isa(typea,TypeVar)) || !(isa(typeb,Type) || isa(typeb,TypeVar))
        return Any
    end
    if (typea <: Tuple) && (typeb <: Tuple)
        if isa(typea, DataType) && isa(typeb, DataType) && length(typea.parameters) == length(typeb.parameters) && !isvatuple(typea) && !isvatuple(typeb)
            return typejoin(typea, typeb)
        end
        if isa(typea, Union) || isa(typeb, Union) || (isa(typea,DataType) && length(typea.parameters)>3) ||
            (isa(typeb,DataType) && length(typeb.parameters)>3)
            # widen tuples faster (see #6704), but not too much, to make sure we can infer
            # e.g. (t::Union{Tuple{Bool},Tuple{Bool,Int}})[1]
            return Tuple
        end
    end
    u = Union{typea, typeb}
    if unionlen(u) > MAX_TYPEUNION_LEN || type_too_complex(u, MAX_TYPE_DEPTH)
        # don't let type unions get too big
        # TODO: something smarter, like a common supertype
        return Any
    end
    return u
end

function smerge(sa::Union{NotFound,VarState}, sb::Union{NotFound,VarState})
    sa === sb && return sa
    sa === NOT_FOUND && return sb
    sb === NOT_FOUND && return sa
    issubstate(sa, sb) && return sb
    issubstate(sb, sa) && return sa
    return VarState(tmerge(sa.typ, sb.typ), sa.undef | sb.undef)
end

@inline tchanged(@nospecialize(n), @nospecialize(o)) = o === NOT_FOUND || (n !== NOT_FOUND && !(n ⊑ o))
@inline schanged(@nospecialize(n), @nospecialize(o)) = (n !== o) && (o === NOT_FOUND || (n !== NOT_FOUND && !issubstate(n, o)))

function stupdate!(state::Tuple{}, changes::StateUpdate)
    newst = copy(changes.state)
    if isa(changes.var, Slot)
        newst[slot_id(changes.var::Slot)] = changes.vtype
    end
    return newst
end

function stupdate!(state::VarTable, change::StateUpdate)
    if !isa(change.var, Slot)
        return stupdate!(state, change.state)
    end
    newstate = false
    changeid = slot_id(change.var::Slot)
    for i = 1:length(state)
        if i == changeid
            newtype = change.vtype
        else
            newtype = change.state[i]
        end
        oldtype = state[i]
        if schanged(newtype, oldtype)
            newstate = state
            state[i] = smerge(oldtype, newtype)
        end
    end
    return newstate
end

function stupdate!(state::VarTable, changes::VarTable)
    newstate = false
    for i = 1:length(state)
        newtype = changes[i]
        oldtype = state[i]
        if schanged(newtype, oldtype)
            newstate = state
            state[i] = smerge(oldtype, newtype)
        end
    end
    return newstate
end

stupdate!(state::Tuple{}, changes::VarTable) = copy(changes)

stupdate!(state::Tuple{}, changes::Tuple{}) = false

function stupdate1!(state::VarTable, change::StateUpdate)
    if !isa(change.var, Slot)
        return false
    end
    i = slot_id(change.var::Slot)
    newtype = change.vtype
    oldtype = state[i]
    if schanged(newtype, oldtype)
        state[i] = smerge(oldtype, newtype)
        return true
    end
    return false
end

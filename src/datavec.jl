##############################################################################
##
## Definitions for Data* types which can contain NA's
##
## Inspirations:
##  * R's NA's
##  * Panda's discussion of NA's:
##    http://pandas.pydata.org/pandas-docs/stable/missing_data.html
##  * NumPy's analysis of the issue:
##    https://github.com/numpy/numpy/blob/master/doc/neps/missing-data.rst
##
## NAtype is a composite type representing missingness:
## * An object of NAtype can be generated by writing NA
##
## AbstractDataVec's are an abstract type that can contain NA's:
##  * The core derived composite type is DataVec, which is a parameterized type
##    that wraps an vector of a type and a Boolean (bit) array for the mask.
##  * A secondary derived composite type is a PooledDataVec, which is a
##    parameterized type that wraps a vector of UInts and a vector of one type,
##    indexed by the main vector. NA's are 0's in the UInt vector.
##
##############################################################################

##############################################################################
##
## NA's via the NAtype
##
##############################################################################

type NAtype; end
const NA = NAtype()
show(io, x::NAtype) = print(io, "NA")

type NAException <: Exception
    msg::String
end

length(x::NAtype) = 1
size(x::NAtype) = ()

##############################################################################
##
## Default values for unspecified objects
##
## Sometimes needed when dealing with NA's for which some value must exist in
## the underlying data vector
##
##############################################################################

baseval(x) = zero(x)
baseval{T <: String}(s::Type{T}) = ""

##############################################################################
##
## DataVec type definition
##
##############################################################################

abstract AbstractDataVec{T}

type DataVec{T} <: AbstractDataVec{T}
    data::Vector{T}
    na::BitVector{Bool}

    # Sanity check that new data values and missingness metadata match
    function DataVec(new_data::Vector{T}, is_missing::BitVector{Bool})
        if length(new_data) != length(is_missing)
            error("data and missingness vectors not the same length!")
        end
        new(new_data, is_missing)
    end
end

##############################################################################
##
## DataVec constructors
##
##############################################################################

# Need to redefine inner constructor as outer constuctor
DataVec{T}(d::Vector{T}, n::BitVector) = DataVec{T}(d, n)

# Convert Vector{Bool}'s to BitArray's to save space
DataVec{T}(d::Vector{T}, m::Vector{Bool}) = DataVec{T}(d, bitpack(m))

# Explicitly convert an existing vector to a DataVec w/ no NA's
DataVec(x::Vector) = DataVec(x, bitfalses(length(x)))

# Explicitly convert a Range1 into a DataVec
DataVec{T}(r::Range1{T}) = DataVec([r], bitfalses(length(r)))

# A no-op constructor
DataVec(d::DataVec) = d

# Construct an all-NA DataVec of a specific type
DataVec(t::Type, n::Int64) = DataVec(Array(t, n), bittrues(n))

# Initialized constructors with 0's, 1's
for (f, basef) in ((:dvzeros, :zeros), (:dvones, :ones))
    @eval begin
        ($f)(n::Int64) = DataVec(($basef)(n), bitfalses(n))
        ($f)(t::Type, n::Int64) = DatavVec(($basef)(t, n), bitfalses(n))
    end
end

# Initialized constructors with false's or true's
for (f, basef) in ((:dvfalses, :falses), (:dvtrues, :trues))
    @eval begin
        ($f)(n::Int64) = DataVec(($basef)(n), bitfalses(n))
    end
end

##############################################################################
##
## PooledDataVec type definition
##
##############################################################################

# A DataVec with efficient storage when values are repeated
# TODO: Make sure we don't overflow from refs being Uint16
# TODO: Allow ordering of factor levels
# TODO: Add metadata for dummy conversion
const POOLTYPE = Uint16
const POOLCONV = uint16

type PooledDataVec{T} <: AbstractDataVec{T}
    refs::Vector{POOLTYPE}
    pool::Vector{T}

    function PooledDataVec{T}(refs::Vector{POOLTYPE}, pool::Vector{T})
        # refs mustn't overflow pool
        if max(refs) > length(pool)
            error("reference vector points beyond the end of the pool!")
        end
        new(refs, pool)
    end
end

##############################################################################
##
## PooledDataVec constructors
##
##############################################################################

# Echo inner constructor as an outer constructor
PooledDataVec{T}(refs::Vector{POOLTYPE}, pool::Vector{T}) = PooledDataVec{T}(refs, pool)

# How do you construct a PooledDataVec from a Vector?
# From the same sigs as a DataVec!
# Algorithm:
# * Start with:
#   * A null pool
#   * A pre-allocated refs
#   * A hash from T to Int
# * Iterate over d
#   * If value of d in pool already, set the refs accordingly
#   * If value is new, add it to the pool, then set refs
function PooledDataVec{T}(d::Vector{T}, m::AbstractArray{Bool,1})
    newrefs = Array(POOLTYPE, length(d))
    newpool = Array(T, 0)
    poolref = Dict{T, POOLTYPE}(0) # Why isn't this a set?
    maxref = 0

    # Loop through once to fill the poolref dict
    for i = 1:length(d)
        if !m[i]
            poolref[d[i]] = 0
        end
    end

    # Fill positions in poolref
    newpool = sort(keys(poolref))
    i = 1
    for p in newpool
        poolref[p] = i
        i += 1
    end

    # Fill in newrefs
    for i = 1:length(d)
        if m[i]
            newrefs[i] = 0
        else
            newrefs[i] = poolref[d[i]]
        end
    end

    return PooledDataVec(newrefs, newpool)
end

# Allow a pool to be provided by the user
function PooledDataVec{T}(d::Vector{T}, pool::Vector{T}, m::Vector{Bool})
    if length(pool) > typemax(POOLTYPE)
        error("Cannot construct a PooledDataVec with such a large pool")
    end

    newrefs = Array(POOLTYPE, length(d))
    poolref = Dict{T, POOLTYPE}(0)
    maxref = 0

    # loop through once to fill the poolref dict
    for i = 1:length(pool)
        poolref[pool[i]] = 0
    end

    # fill positions in poolref
    newpool = sort(keys(poolref))
    i = 1
    for p in newpool
        poolref[p] = i
        i += 1
    end

    # fill in newrefs
    for i = 1:length(d)
        if m[i]
            newrefs[i] = 0
        else
            if has(poolref, d[i])
              newrefs[i] = poolref[d[i]]
            else
              error("vector contains elements not in provided pool")
            end
        end
    end

    return PooledDataVec(newrefs, newpool)
end

# Convert a DataVec to a PooledDataVec
PooledDataVec(dv::DataVec) = PooledDataVec(dv.data, dv.na)

# Convert a vector to a PooledDataVec
PooledDataVec(x::Vector) = PooledDataVec(x, falses(length(x)))

# A no-op constructor
PooledDataVec(d::PooledDataVec) = d

##############################################################################
##
## PooledDataVec utilities
##
##############################################################################

values{T}(x::PooledDataVec{T}) = [x.pool[r] for r in x.refs]

levels{T}(x::PooledDataVec{T}) = x.pool

indices{T}(x::PooledDataVec{T}) = x.refs

function index_to_level{T}(x::PooledDataVec{T})
    d = Dict{POOLTYPE, T}()
    for i in POOLCONV(1:length(x.pool))
        d[i] = x.pool[i]
    end
    d
end

function level_to_index{T}(x::PooledDataVec{T})
    d = Dict{T, POOLTYPE}()
    for i in POOLCONV(1:length(x.pool))
        d[x.pool[i]] = i
    end
    d
end

function table{T}(d::PooledDataVec{T})
    poolref = Dict{T,Int64}(0)
    for i = 1:length(d)
        if has(poolref, d[i])
            poolref[d[i]] += 1
        else
            poolref[d[i]] = 1
        end
    end
    return poolref
end

# Constructor from type
function _dv_most_generic_type(vals)
    # iterate over vals tuple to find the most generic non-NA type
    toptype = None
    for i = 1:length(vals)
        if !isna(vals[i])
            toptype = promote_type(toptype, typeof(vals[i]))
        end
    end
    # TODO: confirm that this type has a baseval()
    toptype
end


function ref(::Type{DataVec}, vals...)
    # first, get the most generic non-NA type
    toptype = _dv_most_generic_type(vals)

    # then, allocate vectors
    lenvals = length(vals)
    ret = DataVec(Array(toptype, lenvals), BitArray(lenvals))
    # copy from vals into data and mask
    for i = 1:lenvals
        if isna(vals[i])
            ret.data[i] = baseval(toptype)
            ret.na[i] = true
        else
            ret.data[i] = vals[i]
            # ret.na[i] = false (default)
        end
    end

    return ret
end
function ref(::Type{PooledDataVec}, vals...)
    # for now, just create a DataVec and then convert it
    # TODO: rewrite for speed

    PooledDataVec(DataVec[vals...])
end

# copy does a deep copy
copy{T}(dv::DataVec{T}) = DataVec{T}(copy(dv.data), copy(dv.na))
copy{T}(dv::PooledDataVec{T}) = PooledDataVec{T}(copy(dv.refs), copy(dv.pool))

# TODO: copy_to

##############################################################################
##
## Basic size properties of all Data* objects
##
##############################################################################

size(v::DataVec) = size(v.data)
size(v::PooledDataVec) = size(v.refs)
length(v::DataVec) = length(v.data)
length(v::PooledDataVec) = length(v.refs)
ndims(v::AbstractDataVec) = 1
numel(v::AbstractDataVec) = length(v)
eltype{T}(v::AbstractDataVec{T}) = T

##############################################################################
##
## A new predicate: isna()
##
##############################################################################

isna(x::NAtype) = true
isna(v::DataVec) = v.na
isna(v::PooledDataVec) = v.refs .== 0
isna(x::AbstractArray) = falses(size(x))
isna(x::Any) = false

# TODO: fast version for PooledDataVec
# TODO: a::AbstractDataVec{T}, b::AbstractArray{T}
# TODO: a::AbstractDataVec{T}, b::AbstractDataVec{T}
# TODO: a::AbstractDataVec{T}, NA

##############################################################################
##
## ref()/assign() definitions
##
##############################################################################

# single-element access
ref(x::DataVec, i::Number) = x.na[i] ? NA : x.data[i]
ref(x::PooledDataVec, i::Number) = x.refs[i] == 0 ? NA : x.pool[x.refs[i]]

# range access
function ref(x::DataVec, r::Range1)
    DataVec(x.data[r], x.na[r])
end
function ref(x::DataVec, r::Range)
    DataVec(x.data[r], x.na[r])
end
# PooledDataVec -- be sure copy the pool!
function ref(x::PooledDataVec, r::Range1)
    # TODO: copy the whole pool or just the items in the range?
    # for now, the whole pool
    PooledDataVec(x.refs[r], copy(x.pool))
end

# logical access -- note that unlike Array logical access, this throws an error if
# the index vector is not the same size as the data vector
function ref(x::DataVec, ind::Vector{Bool})
    if length(x) != length(ind)
        throw(ArgumentError("boolean index is not the same size as the DataVec"))
    end
    DataVec(x.data[ind], x.na[ind])
end
# PooledDataVec
function ref(x::PooledDataVec, ind::Vector{Bool})
    if length(x) != length(ind)
        throw(ArgumentError("boolean index is not the same size as the PooledDataVec"))
    end
    PooledDataVec(x.refs[ind], copy(x.pool))
end

# array index access
function ref(x::DataVec, ind::Vector{Int})
    DataVec(x.data[ind], x.na[ind])
end
# PooledDataVec
function ref(x::PooledDataVec, ind::Vector{Int})
    PooledDataVec(x.refs[ind], copy(x.pool))
end

ref(x::AbstractDataVec, ind::AbstractDataVec{Bool}) = x[replaceNA(ind, false)]
ref(x::AbstractDataVec, ind::AbstractDataVec{Integer}) = x[removeNA(ind)]

ref(x::AbstractIndex, idx::AbstractDataVec{Bool}) = x[replaceNA(idx, false)]
ref(x::AbstractIndex, idx::AbstractDataVec{Int}) = x[removeNA(idx)]

# assign variants
# x[3] = "cat"
function assign{S, T}(x::DataVec{S}, v::T, i::Int)
    x.data[i] = v
    x.na[i] = false
    return x[i]
end
function assign{S, T}(x::PooledDataVec{S}, v::T, i::Int)
    # TODO handle pool ordering
    # note: NA replacement comes for free here

    # find the index of v in the pool
    pool_idx = findfirst(x.pool, v)
    if pool_idx > 0
        # new item is in the pool
        x.refs[i] = pool_idx
    else
        # new item is not in the pool; add it
        push(x.pool, v)
        x.refs[i] = length(x.pool)
    end
    return x[i]
end

# x[[3, 4]] = "cat"
function assign{S, T}(x::DataVec{S}, v::T, is::Vector{Int})
    x.data[is] = v
    x.na[is] = false
    return x[is] # this could get slow -- maybe not...
end
# PooledDataVec can use a possibly-slower generic approach
function assign{S, T}(x::AbstractDataVec{S}, v::T, is::Vector{Int})
    for i in is
        x[i] = v
    end
    return x[is]
end

# x[[3, 4]] = ["cat", "dog"]
function assign{S, T}(x::DataVec{S}, vs::Vector{T}, is::Vector{Int})
    if length(is) != length(vs)
        throw(ArgumentError("can't assign when index and data vectors are different length"))
    end
    x.data[is] = vs
    x.na[is] = false
    return x[is]
end
# PooledDataVec can use a possibly-slower generic approach
function assign{S, T}(x::AbstractDataVec{S}, vs::Vector{T}, is::Vector{Int})
    if length(is) != length(vs)
        throw(ArgumentError("can't assign when index and data vectors are different length"))
    end
    for vi in zip(vs, is)
        x[vi[2]] = vi[1]
    end
    return x[is]
end

# x[[true, false, true]] = "cat"
function assign{S, T}(x::DataVec{S}, v::T, mask::Vector{Bool})
    x.data[mask] = v
    x.na[mask] = false
    return x[mask]
end
# PooledDataVec can use a possibly-slower generic approach
function assign{S, T}(x::AbstractDataVec{S}, v::T, mask::Vector{Bool})
    for i = 1:length(x)
        if mask[i] == true
            x[i] = v
        end
    end
    return x[mask]
end

# x[[true, false, true]] = ["cat", "dog"]
function assign{S, T}(x::DataVec{S}, vs::Vector{T}, mask::Vector{Bool})
    if sum(mask) != length(vs)
        throw(ArgumentError("can't assign when boolean trues and data vectors are different length"))
    end
    x.data[mask] = vs
    x.na[mask] = false
    return x[mask]
end
# PooledDataVec can use a possibly-slower generic approach
function assign{S, T}(x::AbstractDataVec{S}, vs::Vector{T}, mask::Vector{Bool})
    if sum(mask) != length(vs)
        throw(ArgumentError("can't assign when boolean trues and data vectors are different length"))
    end
    ivs = 1
    # walk through mask. whenever true, assign and increment vs index
    for i = 1:length(mask)
        if mask[i] == true
            x[i] = vs[ivs]
            ivs += 1
        end
    end
    return x[mask]
end

# x[2:3] = "cat"
function assign{S, T}(x::DataVec{S}, v::T, rng::Range1)
    x.data[rng] = v
    x.na[rng] = false
    return x[rng]
end
# PooledDataVec can use a possibly-slower generic approach
function assign{S, T}(x::AbstractDataVec{S}, v::T, rng::Range1)
    for i in rng
        x[i] = v
    end
end

# x[2:3] = ["cat", "dog"]
function assign{S, T}(x::DataVec{S}, vs::Vector{T}, rng::Range1)
    if length(rng) != length(vs)
        throw(ArgumentError("can't assign when index and data vectors are different length"))
    end
    x.data[rng] = vs
    x.na[rng] = false
    return x[rng]
end
# PooledDataVec can use a possibly-slower generic approach
function assign{S, T}(x::AbstractDataVec{S}, vs::Vector{T}, rng::Range1)
    if length(rng) != length(vs)
        throw(ArgumentError("can't assign when index and data vectors are different length"))
    end
    ivs = 1
    # walk through rng. assign and increment vs index
    for i in rng
        x[i] = vs[ivs]
        ivs += 1
    end
    return x[rng]
end

# x[3] = NA
assign{T}(x::DataVec{T}, n::NAtype, i::Int) = begin (x.na[i] = true); return NA; end
assign{T}(x::PooledDataVec{T}, n::NAtype, i::Int) = begin (x.refs[i] = 0); return NA; end

# x[[3,5]] = NA
assign{T}(x::DataVec{T}, n::NAtype, is::Vector{Int}) = begin (x.na[is] = true); return x[is]; end
assign{T}(x::PooledDataVec{T}, n::NAtype, is::Vector{Int}) = begin (x.refs[is] = 0); return x[is]; end

# x[[true, false, true]] = NA
assign{T}(x::DataVec{T}, n::NAtype, mask::Vector{Bool}) = begin (x.na[mask] = true); return x[mask]; end
assign{T}(x::PooledDataVec{T}, n::NAtype, mask::Vector{Bool}) = begin (x.refs[mask] = 0); return x[mask]; end

# x[2:3] = NA
assign{T}(x::DataVec{T}, n::NAtype, rng::Range1) = begin (x.na[rng] = true); return x[rng]; end
assign{T}(x::PooledDataVec{T}, n::NAtype, rng::Range1) = begin (x.refs[rng] = 0); return x[rng]; end

# TODO: Abstract assignment of a union of T's and NAs
# x[3:5] = {"cat", NA, "dog"}
# x[3:5] = DataVec["cat", NA, "dog"]

##############################################################################
##
## PooledDataVecs: EXPLANATION SHOULD GO HERE
##
##############################################################################

function PooledDataVecs{S, T}(v1::AbstractDataVec{S}, v2::AbstractDataVec{T})
    ## Return two PooledDataVecs that share the same pool.

    refs1 = Array(POOLTYPE, length(v1))
    refs2 = Array(POOLTYPE, length(v2))
    poolref = Dict{T,POOLTYPE}(length(v1))
    maxref = 0

    # loop through once to fill the poolref dict
    for i = 1:length(v1)
        ## TODO see if we really need the NA checking here.
        ## if !isna(v1[i])
            poolref[v1[i]] = 0
        ## end
    end
    for i = 1:length(v2)
        ## if !isna(v2[i])
            poolref[v2[i]] = 0
        ## end
    end

    # fill positions in poolref
    pool = sort(keys(poolref))
    i = 1
    for p in pool
        poolref[p] = i
        i += 1
    end

    # fill in newrefs
    for i = 1:length(v1)
        ## if isna(v1[i])
        ##     refs1[i] = 0
        ## else
            refs1[i] = poolref[v1[i]]
        ## end
    end
    for i = 1:length(v2)
        ## if isna(v2[i])
        ##     refs2[i] = 0
        ## else
            refs2[i] = poolref[v2[i]]
        ## end
    end
    (PooledDataVec(refs1, pool),
     PooledDataVec(refs2, pool))
end

##############################################################################
##
## Generic Strategies for dealing with NA's
##
## Editing Functions:
##
## * failNA: Operations should die on the presence of NA's. Like KEEP?
## * removeNA: What was once called FILTER.
## * replaceNA: What was once called REPLACE.
##
## Iterator Functions:
##
## * each_failNA: Operations should die on the presence of NA's. Like KEEP?
## * each_removeNA: What was once called FILTER.
## * each_replaceNA: What was once called REPLACE.
##
## v = failNA(dv)
##
## for v in each_failNA(dv)
##     do_something_with_value(v)
## end
##
##############################################################################

function failNA{T}(dv::DataVec{T})
    n = length(dv)
    for i in 1:n
        if dv.na[i]
            error("NA's encountered. Failing...")
        end
    end
    return copy(dv.data)
end

function removeNA{T}(dv::DataVec{T})
    return dv.data[!dv.na]
end

function replaceNA{S, T}(dv::DataVec{S}, replacement_val::T)
    n = length(dv)
    res = copy(dv.data)
    for i in 1:n
        if dv.na[i]
            res[i] = replacement_val
        end
    end
    return res
end

type EachFailNA{T}
    dv::DataVec{T}
end
each_failNA{T}(dv::DataVec{T}) = EachFailNA(dv)
start(itr::EachFailNA) = 1
function done(itr::EachFailNA, ind::Int)
    return ind > length(itr.dv)
end
function next(itr::EachFailNA, ind::Int)
    if itr.dv.na[ind]
        error("NA's encountered. Failing...")
    else
        (itr.dv.data[ind], ind + 1)
    end
end

type EachRemoveNA{T}
    dv::DataVec{T}
end
each_removeNA{T}(dv::DataVec{T}) = EachRemoveNA(dv)
start(itr::EachRemoveNA) = 1
function done(itr::EachRemoveNA, ind::Int)
    return ind > length(itr.dv)
end
function next(itr::EachRemoveNA, ind::Int)
    while ind <= length(itr.dv) && itr.dv.na[ind]
        ind += 1
    end
    (itr.dv.data[ind], ind + 1)
end

type EachReplaceNA{T}
    dv::DataVec{T}
    replacement_val::T
end
each_replaceNA{T}(dv::DataVec{T}, v::T) = EachReplaceNA(dv, v)
start(itr::EachReplaceNA) = 1
function done(itr::EachReplaceNA, ind::Int)
    return ind > length(itr.dv)
end
function next(itr::EachReplaceNA, ind::Int)
    if itr.dv.na[ind]
        (itr.replacement_val, ind + 1)
    else
        (itr.dv.data[ind], ind + 1)
    end
end

vector(dv) = failNA(dv.data)

##############################################################################
##
## Generic iteration over AbstractDataVec's
##
##############################################################################

start(x::AbstractDataVec) = 1
function next(x::AbstractDataVec, state::Int)
    return (x[state], state+1)
end
function done(x::AbstractDataVec, state::Int)
    return state > length(x)
end

##############################################################################
##
## Conversion and promotion
##
##############################################################################

# TODO: Abstract? Pooled?

# Can promote in theory based on data type

promote_rule{T, T}(::Type{AbstractDataVec{T}}, ::Type{T}) = promote_rule(T, T)
promote_rule{S, T}(::Type{AbstractDataVec{S}}, ::Type{T}) = promote_rule(S, T)
promote_rule{T}(::Type{AbstractDataVec{T}}, ::Type{T}) = T

function convert{T}(::Type{T}, x::DataVec{T})
    if any_na(x)
        err = "Cannot convert DataVec with NA's to base type"
        throw(NAException(err))
    else
        return x.data
    end
end
function convert{S, T}(::Type{S}, x::DataVec{T})
    if any_na(x)
        err = "Cannot convert DataVec with NA's to base type"
        throw(NAException(err))
    else
        return convert(S, x.data)
    end
end

function convert{T}(::Type{T}, x::AbstractDataVec{T})
    try
        return [i::T for i in x]
    catch ee
        if isa(ee, TypeError)
            err = "Cannot convert AbstractDataVec with NA's to base type"
            throw(NAException(err))
        else
            throw(ee)
        end
    end
end
function convert{S, T}(::Type{S}, x::AbstractDataVec{T})
    if any_na(x)
        err = "Cannot convert DataVec with NA's to base type"
        throw(NAException(err))
    else
        return [i::S for i in x]
    end
end

# Should this be left in? Could be risky.
function convert{T}(::Type{DataVec{T}}, a::Array{T,1})
    DataVec(a, falses(length(a)))
end

##############################################################################
##
## Conversion convenience functions
##
##############################################################################

for f in (:int, :float, :bool)
    @eval begin
        function ($f){T}(dv::DataVec{T})
            if !any_na(dv)
                ($f)(dv.data)
            else
                error("Conversion impossible with NA's present")
            end
        end
    end
end
for (f, basef) in ((:dvint, :int), (:dvfloat, :float), (:dvbool, :bool))
    @eval begin
        function ($f){T}(dv::DataVec{T})
            DataVec(($basef)(dv.data), dv.na)
        end
    end
end

##############################################################################
##
## String representations and printing
##
##############################################################################

function string(x::AbstractDataVec)
    tmp = join(x, ", ")
    return "[$tmp]"
end

show(io, x::AbstractDataVec) = Base.show_comma_array(io, x, '[', ']')

function show(io, x::PooledDataVec)
    print("values: ")
    Base.show_vector(io, values(x), "[","]")
    print("\n")
    print("levels: ")
    Base.show_vector(io, levels(x), "[", "]")
end

function repl_show(io::IO, dv::DataVec)
    n = length(dv)
    print("$n-element $(typeof(dv))\n")
    for i in 1:(n - 1)
        println(strcat(' ', dv[i]))
    end
    print(strcat(' ', dv[n]))
end

##############################################################################
##
## Replacement operations
##
##############################################################################

# TODO: replace!(x::PooledDataVec{T}, from::T, to::T)
# and similar to and from NA
replace!{R}(x::PooledDataVec{R}, fromval::NAtype, toval::NAtype) = NA # no-op to deal with warning
function replace!{R, S, T}(x::PooledDataVec{R}, fromval::S, toval::T)
    # throw error if fromval isn't in the pool
    fromidx = findfirst(x.pool, fromval)
    if fromidx == 0
        error("can't replace a value not in the pool in a PooledDataVec!")
    end

    # if toval is in the pool too, use that and remove fromval from the pool
    toidx = findfirst(x.pool, toval)
    if toidx != 0
        x.refs[x.refs .== fromidx] = toidx
        #x.pool[fromidx] = None    TODO: what to do here??
    else
        # otherwise, toval is new, swap it in
        x.pool[fromidx] = toval
    end

    return toval
end
replace!(x::PooledDataVec{NAtype}, fromval::NAtype, toval::NAtype) = NA # no-op to deal with warning
function replace!{S, T}(x::PooledDataVec{S}, fromval::T, toval::NAtype)
    fromidx = findfirst(x.pool, fromval)
    if fromidx == 0
        error("can't replace a value not in the pool in a PooledDataVec!")
    end

    x.refs[x.refs .== fromidx] = 0

    return NA
end
function replace!{S, T}(x::PooledDataVec{S}, fromval::NAtype, toval::T)
    toidx = findfirst(x.pool, toval)
    # if toval is in the pool, just do the assignment
    if toidx != 0
        x.refs[x.refs .== 0] = toidx
    else
        # otherwise, toval is new, add it to the pool
        push(x.pool, toval)
        x.refs[x.refs .== 0] = length(x.pool)
    end

    return toval
end

##############################################################################
##
## Extras
##
##############################################################################

const letters = convert(Vector{ASCIIString}, split("abcdefghijklmnopqrstuvwxyz", ""))
const LETTERS = convert(Vector{ASCIIString}, split("ABCDEFGHIJKLMNOPQRSTUVWXYZ", ""))

# Like string(s), but preserves Vector{String} and converts
# Vector{Any} to Vector{String}.
_vstring(s) = string(s)
_vstring(s::Vector) = map(_vstring, s)
_vstring{T<:String}(s::T) = s
_vstring{T<:String}(s::Vector{T}) = s

function paste{T<:String}(s::Vector{T}...)
    sa = {s...}
    N = max(length, sa)
    res = fill("", N)
    for i in 1:length(sa)
        Ni = length(sa[i])
        k = 1
        for j = 1:N
            res[j] = strcat(res[j], sa[i][k])
            if k == Ni   # This recycles array elements.
                k = 1
            else
                k += 1
            end
        end
    end
    res
end
# The following converts all arguments to Vector{<:String} before
# calling paste.
function paste(s...)
    converted = map(vcat * _vstring, {s...})
    paste(converted...)
end

function cut{S, T}(x::Vector{S}, breaks::Vector{T})
    refs = fill(POOLCONV(0), length(x))
    for i in 1:length(x)
        refs[i] = search_sorted(breaks, x[i])
    end
    from = map(x -> sprint(showcompact, x), [min(x), breaks])
    to = map(x -> sprint(showcompact, x), [breaks, max(x)])
    pool = paste(["[", fill("(", length(breaks))], from, ",", to, "]")
    PooledDataVec(refs, pool, KEEP, "")
end
cut(x::Vector, ngroups::Integer) = cut(x, quantile(x, [1 : ngroups - 1] / ngroups))

##############################################################################
##
## Convenience predicates: any_na, isnan, isfinite
##
##############################################################################

function any_na(dv::DataVec)
    for i in 1:length(dv)
        if dv.na[i]
            return true
        end
    end
    return false
end

function isnan(dv::DataVec)
    new_data = isnan(dv.data)
    DataVec(new_data, dv.na)
end

function isfinite(dv::DataVec)
    new_data = isfinite(dv.data)
    DataVec(new_data, dv.na)
end

##############################################################################
##
## NA-aware unique
##
##############################################################################

function unique{T}(dv::DataVec{T})
  values = Dict()
  for i in 1:length(dv)
    values[dv[i]] = 0
  end
  return keys(values)
end

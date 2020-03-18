# This file is a part of ValueShapes.jl, licensed under the MIT License (MIT).


@inline _varoffset_cumsum_impl(s, x, y, rest...) = (s, _varoffset_cumsum_impl(s+x, y, rest...)...)
@inline _varoffset_cumsum_impl(s,x) = (s,)
@inline _varoffset_cumsum_impl(s) = ()
@inline _varoffset_cumsum(x::Tuple) = _varoffset_cumsum_impl(0, x...)


"""
    NamedTupleShape{names,...} <: AbstractValueShape

Defines the shape of a `NamedTuple` (resp.  set of variables, parameters,
etc.).

Constructors:

    NamedTupleShape(name1 = shape1::AbstractValueShape, ...)
    NamedTupleShape(named_shapes::NamedTuple)

Example:

```julia
shape = NamedTupleShape(
    a = ScalarShape{Real}(),
    b = ArrayShape{Real}(2, 3),
    c = ConstValueShape(42)
)

data = VectorOfSimilarVectors{Float64}(shape)
resize!(data, 10)
rand!(flatview(data))
table = shape.(data)
fill!(table.a, 4.2)
all(x -> x == 4.2, view(flatview(data), 1, :))
```

See also the documentation of [`AbstractValueShape`](@ref).
"""
struct NamedTupleShape{names,AT<:(NTuple{N,ValueAccessor} where N)} <: AbstractValueShape
    _accessors::NamedTuple{names,AT}
    _flatdof::Int

    @inline function NamedTupleShape(shape::NamedTuple{names,<:NTuple{N,AbstractValueShape}}) where {names,N}
        labels = keys(shape)
        shapes = values(shape)
        shapelengths = map(totalndof, shapes)
        offsets = _varoffset_cumsum(shapelengths)
        accessors = map(ValueAccessor, shapes, offsets)
        # acclengths = map(x -> x.len, accessors)
        # @assert shapelengths == acclengths
        n_flattened = sum(shapelengths)
        named_accessors = NamedTuple{labels}(accessors)
        new{names,typeof(accessors)}(named_accessors, n_flattened)
    end
end

export NamedTupleShape

@inline NamedTupleShape(;named_shapes...) = NamedTupleShape(values(named_shapes))


@inline _accessors(x::NamedTupleShape) = getfield(x, :_accessors)
@inline _flatdof(x::NamedTupleShape) = getfield(x, :_flatdof)

@inline totalndof(shape::NamedTupleShape) = _flatdof(shape)

@inline Base.keys(shape::NamedTupleShape) = keys(_accessors(shape))

@inline Base.values(shape::NamedTupleShape) = values(_accessors(shape))

@inline function Base.getproperty(shape::NamedTupleShape, p::Symbol)
    # Need to include internal fields of NamedTupleShape to make Zygote happy:
    if p == :_accessors
        getfield(shape, :_accessors)
    elseif p == :_flatdof
        getfield(shape, :_flatdof)
    else
        getproperty(_accessors(shape), p)
    end
end

@inline function Base.propertynames(shape::NamedTupleShape, private::Bool = false)
    names = propertynames(_accessors(shape))
    if private
        (names..., :_flatdof, :_accessors)
    else
        names
    end
end

@inline Base.length(shape::NamedTupleShape) = length(_accessors(shape))

@inline Base.getindex(shape::NamedTupleShape, i::Integer) = getindex(_accessors(shape), i)

@inline Base.map(f, shape::NamedTupleShape) = map(f, _accessors(shape))


function Base.merge(a::NamedTuple, shape::NamedTupleShape{names}) where {names}
    merge(a, NamedTuple{names}(map(x -> valshape(x), values(shape))))
end

Base.merge(a::NamedTupleShape) = a
Base.merge(a::NamedTupleShape, b::NamedTupleShape, cs::NamedTupleShape...) = merge(NamedTupleShape(;a..., b...), cs...)


valshape(x::NamedTuple) = NamedTupleShape(map(valshape, x))


(shape::NamedTupleShape)(::UndefInitializer) = map(x -> valshape(x)(undef), shape)


Base.@propagate_inbounds (shape::NamedTupleShape)(data::AbstractVector{<:Real}) = ShapedAsNT(data, shape)


@inline _multi_promote_type() = Nothing
@inline _multi_promote_type(T::Type) = T
@inline _multi_promote_type(T::Type, U::Type, rest::Type...) = promote_type(T, _multi_promote_type(U, rest...))


@inline default_unshaped_eltype(shape::NamedTupleShape) =
    _multi_promote_type(map(default_unshaped_eltype, values(shape))...)

@inline shaped_type(shape::NamedTupleShape{names}, ::Type{T}) where {names,T<:Real} =
    NamedTuple{names,Tuple{map(acc -> shaped_type(acc.shape, T), values(_accessors(shape)))...}}



"""
    ShapedAsNT{T<:NamedTuple,...} <: AbstractArray{T,0}

View of an `AbstractVector{<:Real}` as a zero-dimensional Array containing a
`NamedTuple`, according to a specified [`NamedTupleShape`](@ref).

Constructors:

    ShapedAsNT(data::AbstractVector{<:Real}, shape::NamedTupleShape)

    shape(data)

The resulting `ShapedAsNT` shares memory with `data`. It takes the form of a
(virtual) zero-dimensional Array to make the contents as editable as `data`
itself (compared to a standard immutable NamedTuple):

```julia
x = (a = 42, b = rand(1:9, 2, 3))
shape = valshape(x)
data = Vector{Int}(undef, shape)
y = shape(data)
@assert y isa ShapedAsNT
y[] = x
@assert y[] == x
y.a = 22
y.a[] = 33
@assert shape(data) == y
@assert unshaped(y) === data
```

Use `unshaped(x)` to access `data` directly.

See also [`ShapedAsNTArray`](@ref).
"""
struct ShapedAsNT{T<:NamedTuple,D<:AbstractVector{<:Real},S<:NamedTupleShape} <: AbstractArray{T,0}
    __internal_data::D
    __internal_valshape::S
end

export ShapedAsNT


Base.@propagate_inbounds function ShapedAsNT(data::D, shape::S) where {N,T<:Real,D<:AbstractVector{T},S<:NamedTupleShape}
    @boundscheck _checkcompat(shape, data)
    NT_T = shaped_type(shape, T)
    ShapedAsNT{NT_T,D,S}(data, shape)
end


@inline _data(A::ShapedAsNT) = getfield(A, :__internal_data)
@inline _valshape(A::ShapedAsNT) = getfield(A, :__internal_valshape)

@inline valshape(A::ShapedAsNT) = _valshape(A)
@inline unshaped(A::ShapedAsNT) = _data(A)


Base.@propagate_inbounds function Base.getproperty(A::ShapedAsNT, p::Symbol)
    # Need to include internal fields of ShapedAsNT to make Zygote happy:
    if p == :__internal_data
        getfield(A, :__internal_data)
    elseif p == :__internal_valshape
        getfield(A, :__internal_valshape)
    else
        data = _data(A)
        shape = _valshape(A)
        va = getproperty(_accessors(shape), p)
        view(data, va)
    end
end

Base.@propagate_inbounds function Base.setproperty!(A::ShapedAsNT, p::Symbol, x)
    data = _data(A)
    shape = _valshape(A)
    va = getproperty(_accessors(shape), p)
    setindex!(data, x, va)
    A
end

@inline function Base.propertynames(A::ShapedAsNT, private::Bool = false)
    names = Base.propertynames(_valshape(A))
    if private
        (names..., :__internal_data, :__internal_valshape)
    else
        names
    end
end


@inline Base.size(A::ShapedAsNT) = ()
@inline Base.IndexStyle(A::ShapedAsNT) = IndexLinear()


Base.@propagate_inbounds function _apply_ntshape_copy(data::AbstractVector{<:Real}, shape::NamedTupleShape)
    accessors = _accessors(shape)
    map(va -> getindex(data, va), accessors)
end

Base.@propagate_inbounds Base.getindex(A::ShapedAsNT) = _apply_ntshape_copy(_data(A), _valshape(A))

Base.@propagate_inbounds function Base.getindex(A::ShapedAsNT, i::Integer)
    @boundscheck Base.checkbounds(A, i)
    getindex(A)
end

Base.@propagate_inbounds function Base.getindex(A::ShapedAsNT, i::Union{AbstractArray,Colon})
    @boundscheck Base.checkbounds(A, i)
    [getindex(A)]
end


Base.@propagate_inbounds _apply_ntshape_view(A::AbstractVector{<:Real}, shape::NamedTupleShape) =
    ShapedAsNT(A, shape)

Base.@propagate_inbounds Base.view(A::ShapedAsNT) = A

Base.@propagate_inbounds function Base.view(A::ShapedAsNT, i::Integer)
    @boundscheck Base.checkbounds(A, i)
    view(A)
end

Base.@propagate_inbounds function Base.view(A::ShapedAsNT, i::Union{AbstractArray,Colon})
    @boundscheck Base.checkbounds(A, i)
    ShapedAsNTArray(view([_data(A)], :), _valshape(A))
end


Base.@propagate_inbounds function Base.setindex!(A::ShapedAsNT{<:NamedTuple{names}}, x::NamedTuple{names}) where {names}
    if @generated
        Expr(:block, map(p -> :(A.$p = x.$p), names)...)
    else
        @assert false
        data = _data(A)
        shape = _valshape(A)
        accessors = _accessors(shape)
        Expr(:block, map(p -> :(A.$p = x.$p), nms)...)
    end

    A
end

Base.@propagate_inbounds Base.setindex!(A::ShapedAsNT{T}, x) where {T} = setindex!(A, convert(T, x))

Base.@propagate_inbounds function Base.setindex!(A::ShapedAsNT, x, i::Integer)
    @boundscheck Base.checkbounds(A, i)
    setindex!(A, x)
end


Base.similar(A::ShapedAsNT{T}, ::Type{T}, ::Tuple{}) where T =
    ShapedAsNT(similar(_data(A)), _valshape(A))


Base.show(io::IO, ::MIME"text/plain", A::ShapedAsNT) = show(io, A)

function Base.show(io::IO, A::ShapedAsNT)
    print(io, "ShapedAsNT(")
    show(io, A[])
    print(io, ")")
end


Base.copy(A::ShapedAsNT) = ShapedAsNT(copy(_data(A)), _valshape(A))



"""
    ShapedAsNTArray{T<:NamedTuple,...} <: AbstractArray{T,0}

View of an `AbstractArray{<:AbstractVector{<:Real},N}` as an array of
`NamedTuple`s, according to a specified [`NamedTupleShape`](@ref).

`ShapedAsNTArray` implements the `Tables` API. Semantically, it acts a
broadcasted [`ShapedAsNT`](@ref).

Constructors:

    ShapedAsNTArray(
        data::AbstractArray{<:AbstractVector{<:Real},
        shape::NamedTupleShape
    )

    shape.(data)

The resulting `ShapedAsNTArray` shares memory with `data`:

```julia
using ArraysOfArrays, Tables, TypedTables

X = [
    (a = 42, b = rand(1:9, 2, 3))
    (a = 11, b = rand(1:9, 2, 3))
]

shape = valshape(X[1])
data = nestedview(Array{Int}(undef, totalndof(shape), 2))
Y = shape.(data)
@assert Y isa ShapedAsNTArray
Y[:] = X
@assert Y[1] == X[1] == shape(data[1])[]
@assert Y.a == [42, 11]
Tables.columns(Y)
@assert Y[:] isa TypedTables.Table
@assert unshaped.(Y) === data
```

Use `unshaped.(Y)` to access `data` directly.

`Tables.columns(Y)` will return a `NamedTuple` of columns. They will contain
a copy the data, using a memory layout as contiguous as possible for each
column.
"""
struct ShapedAsNTArray{T<:NamedTuple,N,D<:AbstractArray{<:AbstractVector{<:Real},N},S<:NamedTupleShape} <: AbstractVector{T}
    __internal_data::D
    __internal_elshape::S
end

export ShapedAsNTArray


function ShapedAsNTArray(data::D, shape::S) where {N,T<:Real,D<:AbstractArray{<:AbstractVector{T},N},S<:NamedTupleShape}
    NT_T = shaped_type(shape, T)
    ShapedAsNTArray{NT_T,N,D,S}(data, shape)
end


# Specialize (::NamedTupleShape).(::AbstractVector{<:AbstractVector}):
Base.copy(instance::VSBroadcasted1{1,<:NamedTupleShape,AbstractVector{<:AbstractVector{<:Real}}}) =
    ShapedAsNTArray(instance.args[1], instance.f)


@inline _data(A::ShapedAsNTArray) = getfield(A, :__internal_data)
@inline _elshape(A::ShapedAsNTArray) = getfield(A, :__internal_elshape)

@inline elshape(A::ShapedAsNTArray) = _elshape(A)

@inline _bcasted_unshaped(A::ShapedAsNTArray) = _data(A)

Base.copy(instance::VSBroadcasted1{N,typeof(unshaped),ShapedAsNTArray{T,N}}) where {T,N} =
    _bcasted_unshaped(instance.args[1])


@inline function Base.getproperty(A::ShapedAsNTArray, p::Symbol)
    # Need to include internal fields of ShapedAsNTArray to make Zygote happy:
    if p == :__internal_data
        getfield(A, :__internal_data)
    elseif p == :__internal_elshape
        getfield(A, :__internal_elshape)
    else
        data = _data(A)
        shape = _elshape(A)
        va = getproperty(_accessors(shape), p)
        view.(data, Ref(va))
    end
end

@inline function Base.propertynames(A::ShapedAsNTArray, private::Bool = false)
    names = Base.propertynames(_elshape(A))
    if private
        (names..., :__internal_data, :__internal_elshape)
    else
        names
    end
end


@inline Base.size(A::ShapedAsNTArray) = size(_data(A))
@inline Base.axes(A::ShapedAsNTArray) = axes(_data(A))
@inline Base.IndexStyle(A::ShapedAsNTArray) = IndexStyle(_data(A))


Base.@propagate_inbounds _apply_ntshape_copy(data::AbstractArray{<:AbstractVector{<:Real}}, shape::NamedTupleShape) =
    ShapedAsNTArray(data, shape)

Base.getindex(A::ShapedAsNTArray, idxs...) = _apply_ntshape_copy(getindex(_data(A), idxs...), _elshape(A))


Base.@propagate_inbounds _apply_ntshape_view(data::AbstractArray{<:AbstractVector{<:Real}}, shape::NamedTupleShape) =
    ShapedAsNTArray(data, shape)

Base.view(A::ShapedAsNTArray, idxs...) = _apply_ntshape_view(view(_data(A), idxs...), _elshape(A))


function Base.setindex!(A::ShapedAsNTArray, x, idxs::Integer...)
    A_idxs = ShapedAsNT(getindex(_data(A), idxs...), _elshape(A))
    setindex!(A_idxs, x)
end


function Base.similar(A::ShapedAsNTArray{T}, ::Type{T}, dims::Dims) where T
    data = _data(A)
    U = eltype(data)
    newdata = similar(data, U, dims)
    # In case newdata is not something like an ArrayOfSimilarVectors:
    if !isempty(newdata) && !isdefined(newdata, firstindex(newdata))
        for i in eachindex(newdata)
            newdata[i] = similar(data[firstindex(data)])
        end
    end
    ShapedAsNTArray(newdata, _elshape(A))
end


Base.empty(A::ShapedAsNTArray{T,N,D,S}) where {T,N,D,S} =
    ShapedAsNTArray{T,N,D,S}(empty(_data(A)), _elshape(A))

Base.show(io::IO, ::MIME"text/plain", A::ShapedAsNTArray) = show(io, A)
Base.show(io::IO, A::ShapedAsNTArray) = TypedTables.showtable(io, A)


Base.copy(A::ShapedAsNTArray) = ShapedAsNTArray(copy(_data(A)), _elshape(A))


Base.pop!(A::ShapedAsNTArray) = _elshape(A)(pop!(_data(A)))

# Base.push!(A::ShapedAsNTArray, x::Any)  # ToDo


Base.popfirst!(A::ShapedAsNTArray) = _elshape(A)(popfirst!(_data(A)))

# Base.pushfirst!(A::ShapedAsNTArray, x::Any)  # ToDo


function Base.append!(A::ShapedAsNTArray, B::ShapedAsNTArray)
    _elshape(A) == _elshape(B) || throw(ArgumentError("Can't append ShapedAsNTArray instances with different element shapes"))
    append!(_data(A), _data(B))
    A
end

# Base.append!(A::ShapedAsNTArray, B::AbstractArray)  # ToDo


function Base.prepend!(A::ShapedAsNTArray, B::ShapedAsNTArray)
    _elshape(A) == _elshape(B) || throw(ArgumentError("Can't prepend ShapedAsNTArray instances with different element shapes"))
    prepend!(_data(A), _data(B))
    A
end

# Base.prepend!(A::ShapedAsNTArray, B::AbstractArray)  # ToDo


function Base.deleteat!(A::ShapedAsNTArray, i)
    deleteat!(_data(A), i)
    A
end

# Base.insert!(A::ShapedAsNTArray, i::Integer, x::Any)  # ToDo


Base.splice!(A::ShapedAsNTArray, i) = _elshape(A)(splice!(_data(A), i))

# Base.splice!(A::ShapedAsNTArray, i, replacement)  # ToDo


function Base.vcat(A::ShapedAsNTArray, B::ShapedAsNTArray)
    _elshape(A) == _elshape(B) || throw(ArgumentError("Can't vcat ShapedAsNTArray instances with different element shapes"))
    ShapedAsNTArray(vcat(_data(A), _data(B)), _elshape(A))
end

# Base.vcat(A::ShapedAsNTArray, B::AbstractArray)  # ToDo


# Base.hcat(A::ShapedAsNTArray, B) # ToDo


Base.vec(A::ShapedAsNTArray{T,1}) where T = A
Base.vec(A::ShapedAsNTArray) = ShapedAsNTArray(vec(_data(A)), _elshape(A))


Tables.istable(::Type{<:ShapedAsNTArray}) = true
Tables.rowaccess(::Type{<:ShapedAsNTArray}) = true
Tables.columnaccess(::Type{<:ShapedAsNTArray}) = true
Tables.schema(A::ShapedAsNTArray{T}) where {T} = Tables.Schema(T)

function Tables.columns(A::ShapedAsNTArray)
    data = _data(A)
    accessors = _accessors(_elshape(A))
    # Copy columns to make each column as contiguous in memory as possible:
    map(va -> getindex.(data, Ref(va)), accessors)
end

@inline Tables.rows(A::ShapedAsNTArray) = A

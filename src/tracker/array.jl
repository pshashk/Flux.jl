import Base: *, ==

using LinearAlgebra

struct TrackedArray{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
  tracker::Tracked{A}
  data::A
  grad::A
  TrackedArray{T,N,A}(t::Tracked{A}, data::A) where {T,N,A} = new(t, data)
  TrackedArray{T,N,A}(t::Tracked{A}, data::A, grad::A) where {T,N,A} = new(t, data, grad)
end

data(x::TrackedArray) = x.data
tracker(x::TrackedArray) = x.tracker

TrackedVector{T,A} = TrackedArray{T,1,A}
TrackedMatrix{T,A} = TrackedArray{T,2,A}
TrackedVecOrMat{T,A} = Union{TrackedVector{T,A},TrackedMatrix{T,A}}

track(c::Call, x::AbstractArray) = TrackedArray(c, x)

TrackedArray(c::Call, x::A) where A <: AbstractArray =
  TrackedArray{eltype(A),ndims(A),A}(Tracked{A}(c), x)

TrackedArray(c::Call, x::A, Δ::A) where A <: AbstractArray =
  TrackedArray{eltype(A),ndims(A),A}(Tracked{A}(c, Δ), x, Δ)

TrackedArray(x::AbstractArray) = TrackedArray(Call(), x, zeros(x))

Base.eltype(x::Type{<:TrackedArray{T}}) where T <: Real = TrackedReal{T}

Base.show(io::IO, ::Type{TrackedArray{T,N,A}}) where {T,N,A<:AbstractArray{T,N}} =
  print(io, "TrackedArray{…,$A}")

function Base.summary(io::IO, x::TrackedArray)
  print(io, "Tracked ")
  summary(io, data(x))
end

Base.print_array(io::IO, x::TrackedArray) = Base.print_array(io, data(x))

Base.setindex!(xs::TrackedArray, v, i...) =
  error("Can't differentiate `setindex!`")

back!(::TrackedArray) = error("Value is not scalar; use `back!(sum(x))` or `back!(x, Δ)`")

# Fallthrough methods

for f in :[Base.size, Base.ndims].args
  @eval @inline $f(x::TrackedArray, a...) = $f(data(x), a...)
end

Base.size(x::TrackedArray, i::Integer, j::Integer, is::Integer...) =
  size(data(x), i, j, is...)

Base.similar(x::TrackedArray, dims::Union{AbstractUnitRange,Integer}...) =
  similar(data(x), dims...)

Base.similar(x::TrackedArray, T::Type) = similar(data(x), T)

x::TrackedArray == y = data(x) == y
y == x::TrackedArray = y == data(x)
x::TrackedArray == y::TrackedArray = data(x) == data(y)

# Array Stdlib

Base.getindex(xs::TrackedArray, i...) = track(getindex, xs, i...)

@grad function getindex(xs::AbstractArray, i...)
  data(xs)[i...], function (Δ)
    Δ′ = zero(xs)
    Δ′[i...] = data(Δ)
    (nobacksies(:getindex, Δ′), map(_->nothing, i)...)
  end
end

Base.:-(xs::TrackedArray) = track(-, xs)

@grad -(xs) = -data(xs), Δ -> (-Δ,)

Base.transpose(xs::TrackedArray) = track(transpose, xs)
Base.adjoint(xs::TrackedArray) = track(adjoint, xs)

@grad transpose(xs) = transpose(data(xs)), Δ -> (reshape(transpose(Δ), size(xs)),)
@grad adjoint(xs) = data(xs)', Δ -> (reshape(Δ', size(xs)),)

Base.repeat(A::TrackedArray; kw...) = track_kw(repeat, A; kw...)

@grad function repeat(xs; inner=ntuple(x->1, ndims(A)), outer=ntuple(x->1, ndims(A)))
  repeat(data(xs), inner = inner, outer = outer), function (Δ)
    Δ′ = zero(xs)
    S = size(xs)

    # Loop through each element of Δ, calculate source dimensions, accumulate into Δ′
    for (dest_idx, val) in enumerate(IndexCartesian(), data(Δ))
        # First, round dest_idx[dim] to nearest gridpoint defined by inner[dim], then
        # wrap around based on original size S.
        src_idx = [mod1(div(dest_idx[dim] - 1, inner[dim]) + 1, S[dim]) for dim in 1:length(S)]
        Δ′[src_idx...] += val
    end
    (nobacksies(:repeat, Δ′),)
  end
end

for f in [:vcat, :hcat]
  @eval begin
    # This section is a bit of a hack since julia doesn't have a standardised
    # promotion mechanism for concatenation yet
    # https://github.com/JuliaLang/julia/pull/20815

    # It should support tracked concatenation with rank ∈ (1,2) with a
    # TrackedArray anywhere among the arguments This works as long as base has
    # other functions that captures `(::Union{Vector,RowVector,Matrix}...)`.
    Base.$f(a::Union{TrackedArray,Vector,RowVector,Matrix}...) = track($f, a...)

    # It should support tracked concatenation with rank>2 if the TrackedArray is
    # first
    Base.$f(a::TrackedArray, b::AbstractArray...) = track($f, a, b...)
    Base.$f(a::TrackedArray, b::Union{TrackedArray,Vector,RowVector,Matrix}...) = track($f, a, b...) # resolves ambiguity introduced by previous row

    # It should support tracked concatenation with rank>2 if the TrackedArray is
    # second
    Base.$f(a::Array, b::TrackedArray, c::AbstractArray...) = track($f, a, b, c...)
    Base.$f(a::Union{Vector,RowVector,Matrix}, b::TrackedArray,
            c::Union{TrackedArray,Vector,RowVector,Matrix}...) =
      track($f, a, b, c...) # resolves ambiguity introduced by previous row
  end
end

@grad function vcat(xs...)
  vcat(data.(xs)...), function (Δ)
    start = 0
    Δs = [begin
      i = map(_ -> :, size(xsi)) |> Base.tail
      d = Δ[start+1:start+size(xsi,1), i...]
      start += size(xsi, 1)
      d
    end for xsi in xs]
    return (Δs...,)
  end
end

@grad function hcat(xs...)
  hcat(data.(xs)...), function (Δ)
    start = 0
    Δs = [begin
      d = if ndims(xsi) == 1
        Δ[:, start+1]
      else
        i = map(_ -> :, size(xsi)) |> Base.tail |> Base.tail
        Δ[:, start+1:start+size(xsi,2), i...]
      end
      start += size(xsi, 2)
      d
    end for xsi in xs]
    return (Δs...,)
  end
end

Base.cat(dims, a::TrackedArray, b::AbstractArray...) = track(cat, dims, a, b...)
Base.cat(dims, a::Union{RowVector,Array}, b::TrackedArray, c::AbstractArray...) = track(cat, dims, a, b, c...)

@grad function cat(dims, Xs...)
  cat(dims, data.(Xs)...), function (Δ)
    start = ntuple(i -> 0, Val{ndims(Δ)})
    Δs = [begin
      dim_xs = 1:ndims(xs)
      till_xs = ntuple((i -> i in dims ? (i in dim_xs ? size(xs,i) : 1) : 0), Val{ndims(Δ)})
      xs_in_Δ = ntuple(i -> till_xs[i] > 0 ? (start[i]+1:start[i]+till_xs[i]) : Colon(), Val{ndims(Δ)})
      d = reshape(Δ[xs_in_Δ...],size(xs))
      start = start .+ till_xs
      d
    end for xs in Xs]
    return (nothing, Δs...,)
  end
end

Base.reshape(xs::TrackedArray, dims::Union{Colon,Int64}...) = reshape(xs, dims)
Base.reshape(xs::TrackedArray, dims::Tuple{Vararg{Union{Int64,Colon}}}) = reshape(xs, Base._reshape_uncolon(xs, dims))
Base.reshape(xs::TrackedArray, dims::Tuple{Vararg{Int64}}) = track(reshape, xs, dims)

@grad reshape(xs, dims) = reshape(data(xs), dims), Δ -> (reshape(Δ, size(xs)),nothing)

Base.permutedims(xs::TrackedArray, dims) = track(permutedims, xs, dims)
@grad permutedims(xs, dims) = permutedims(data(xs), dims), Δ -> (permutedims(Δ, invperm(dims)),nothing)

function _kron(mat1::AbstractMatrix,mat2::AbstractMatrix)
    m1, n1 = size(mat1)
    mat1_rsh = reshape(mat1,(1,m1,1,n1))

    m2, n2 = size(mat2)
    mat2_rsh = reshape(mat2,(m2,1,n2,1))

    return reshape(mat1_rsh.*mat2_rsh, (m1*m2,n1*n2))
end

Base.kron(a::TrackedMatrix, b::TrackedMatrix)  = _kron(a, b)
Base.kron(a::TrackedMatrix, b::AbstractMatrix) = _kron(a, b)
Base.kron(a::AbstractMatrix, b::TrackedMatrix) = _kron(a, b)

# Reductions

Base.sum(xs::TrackedArray, dim) = track(sum, xs, dim)
Base.sum(xs::TrackedArray) = track(sum, xs)
Base.sum(f::Union{Function,Type},xs::TrackedArray) = sum(f.(xs))

@grad sum(xs, dim...) = sum(data(xs), dim...),
  Δ -> (zero(xs) .+ Δ, map(_->nothing,dim)...)

Base.prod(xs::TrackedArray, dim) = track(prod, xs, dim)
Base.prod(xs::TrackedArray) = track(prod, xs)
Base.prod(f::Union{Function, Type}, xs::TrackedArray) = prod(f.(xs))

@grad prod(xs) = prod(data(xs)), Δ -> (prod(xs) ./ xs .* Δ,)
@grad prod(xs, dim) = prod(data(xs), dim),
  Δ -> (nobacksies(:sum,
          reshape(.*(circshift.([reshape(data(xs), length(xs))], 1:length(xs)-1)...), size(xs)) .* Δ),
        nothing)

Base.findfirst(xs::TrackedArray, args...) = findfirst(xs.data, args...)

Base.mean(xs::TrackedArray) = track(mean, xs)
Base.mean(xs::TrackedArray, region) = track(mean, xs, region)

Base.maximum(xs::TrackedArray) = track(maximum, xs)
Base.maximum(xs::TrackedArray, region) = track(maximum, xs, region)
Base.minimum(xs::TrackedArray) = track(minimum, xs)
Base.minimum(xs::TrackedArray, region) = track(minimum, xs, region)

import LinearAlgebra: dot

dot(xs::TrackedVector, ys::TrackedVector) = track(dot, xs, ys)
dot(xs::AbstractVector, ys::TrackedVector) = track(dot, xs, ys)
dot(xs::TrackedVector, ys::AbstractVector) = track(dot, xs, ys)

@grad dot(xs, ys) = dot(data(xs), data(ys)), Δ -> (Δ .* ys, Δ .* xs)

using StatsBase

# Hacks to get std working
StatsBase.std(x::TrackedArray; mean = Base.mean(x)) =
  sqrt.(sum((x .- mean).^2) ./ (length(x)-1))
StatsBase.std(x::TrackedArray, dim; mean = Base.mean(x, dim)) =
  sqrt.(sum((x .- mean).^2, dim) ./ (size(x, dim)-1))

LinearAlgebra.vecnorm(x::TrackedArray, p::Real = 2) =
  sum(abs.(x).^p .+ eps(0f0))^(1/p) # avoid d(sqrt(x))/dx == Inf at 0

@grad mean(xs) = mean(data(xs)), Δ -> (Δ / length(xs),)
@grad mean(xs, region) = mean(data(xs), region), Δ -> (zero(xs) .+ Δ ./ prod(size(xs, region...)),nothing)

@grad function maximum(xs, r...)
  maximum(data(xs), r...), function (Δ)
    Δ′ = zero(xs)
    _, i = findmax(data(xs), r...)
    Δ′[i] = data(Δ)
    return (nobacksies(:maximum, Δ′),map(_->nothing,r)...)
  end
end
@grad function minimum(xs, r...)
  minimum(data(xs), r...), function (Δ)
    Δ′ = zero(xs)
    _, i = findmin(data(xs), r...)
    Δ′[i] = data(Δ)
    return (nobacksies(:minimum, Δ′),map(_->nothing,r)...)
  end
end

# BLAS

LinearAlgebra.diagm(x::TrackedVector) = track(diagm, x)
@grad diagm(x) = diagm(data(x)), Δ -> (diag(Δ),)

x::TrackedMatrix  * y::AbstractMatrix = track(*, x, y)
y::AbstractMatrix * x::TrackedMatrix  = track(*, x, y)
x::TrackedMatrix  * y::TrackedMatrix  = track(*, x, y)

x::TrackedMatrix  * y::AbstractVector = track(*, x, y)
y::AbstractMatrix * x::TrackedVector  = track(*, x, y)
x::TrackedMatrix  * y::TrackedVector  = track(*, x, y)

x::TrackedVector  * y::AbstractVector = track(*, x, y)
y::AbstractVector * x::TrackedVector  = track(*, x, y)
x::TrackedVector  * y::TrackedVector  = track(*, x, y)

@grad a::AbstractMatrix * b::AbstractVecOrMat =
  data(a)*data(b), Δ -> (Δ * transpose(b), transpose(a) * Δ)

# NNlib

using NNlib
import NNlib: softmax, ∇softmax, logsoftmax, ∇logsoftmax, conv, maxpool, meanpool

softmax(xs::TrackedArray) = track(softmax, xs)

@grad softmax(xs) = softmax(data(xs)), Δ -> (nobacksies(:softmax, ∇softmax(data(Δ), data(xs))),)

logsoftmax(xs::TrackedArray) = track(logsoftmax, xs)

@grad logsoftmax(xs) = logsoftmax(data(xs)), Δ -> (nobacksies(:logsoftmax, ∇logsoftmax(data(Δ), data(xs))),)

conv(x::TrackedArray,  w::TrackedArray;  kw...) = track_kw(conv, x, w; kw...)
conv(x::AbstractArray, w::TrackedArray;  kw...) = track_kw(conv, x, w; kw...)
conv(x::TrackedArray,  w::AbstractArray; kw...) = track_kw(conv, x, w; kw...)

@grad conv(x, w; kw...) =
  conv(data(x), data(w); kw...),
    Δ -> nobacksies(:conv,
      (NNlib.∇conv_data(data.((Δ, x, w))...; kw...),
       NNlib.∇conv_filter(data.((Δ, x, w))...; kw...)))

maxpool(x::TrackedArray, k; kw...) = track_kw(maxpool, x, k; kw...)

@grad function maxpool(x, k; kw...)
  y = maxpool(data(x), k; kw...)
  y, Δ -> (nobacksies(:maxpool, NNlib.∇maxpool(data.((Δ, y, x))..., k; kw...)), nothing)
end

meanpool(x::TrackedArray, k; kw...) = track_kw(meanpool, x, k; kw...)

@grad function meanpool(x, k; kw...)
  y = meanpool(data(x), k; kw...)
  y, Δ -> (nobacksies(:maxpool, NNlib.∇meanpool(data.((Δ, y, x))..., k; kw...)), nothing)
end

# Broadcasting

using ForwardDiff: Dual, partials, value

dualify(xs, n) = xs
dualify(xs::AbstractArray, ps) = map(x -> Dual(x, ps), xs)
dualify(xs::Real, ps) = Dual(xs, ps)

unbroadcast(x::Tuple, Δ) =
  x == size(Δ) ? Δ :
    reshape(sum(Δ, filter(n -> n > length(x) || x[n] == 1, 1:ndims(Δ))), x)

unbroadcast(x::Tuple{}, Δ) = sum(Δ)

function getpartial(Δ, x, i)
  @inbounds p = getindex(partials(x), i)
  return Δ * p
end

function ∇broadcast(f, args::Vararg{Any,N}) where N
  sizes = size.(args)
  dargs = map((x,i) -> dualify(data(x), ntuple(j -> i==j, Val{N})), args, ntuple(identity, Val{N}))
  out = broadcast(f, dargs...)
  eltype(out) <: Dual || return out
  y = value.(out)
  back = function (Δ_)
    Δ = data(Δ_)
    Δargs = ntuple(i -> getpartial.(Δ, out, i), Val{N})
    dxs = map((x, Δ) -> unbroadcast(x, Δ), sizes, Δargs)
    nobacksies(:broadcast, dxs)
  end
  # So we can return non-tracked arrays
  track(Call(back, tracker.(args)), y)
end

Base.Broadcast._containertype(::Type{<:TrackedReal}) = TrackedArray
Base.Broadcast._containertype(::Type{<:TrackedArray}) = TrackedArray
Base.Broadcast.promote_containertype(::Type{TrackedArray}, ::Type{TrackedArray}) = TrackedArray
Base.Broadcast.promote_containertype(::Type{Array}, ::Type{TrackedArray}) = TrackedArray
Base.Broadcast.promote_containertype(::Type{TrackedArray}, ::Type{Array}) = TrackedArray
Base.Broadcast.promote_containertype(::Type{TrackedArray}, ct) = TrackedArray
Base.Broadcast.promote_containertype(ct, ::Type{TrackedArray}) = TrackedArray
Base.Broadcast.broadcast_indices(::Type{TrackedArray}, A::Ref) = ()
Base.Broadcast.broadcast_indices(::Type{TrackedArray}, A) = indices(A)

Base.Broadcast.broadcast_c(f, ::Type{TrackedArray}, A, Bs...) = ∇broadcast(f, A, Bs...)
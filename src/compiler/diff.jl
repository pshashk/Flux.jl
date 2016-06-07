import Flow: isconstant, il, dl, cse, prewalk, graphm, syntax, @v

vertex(a...) = IVertex{Any}(a...)

# Special case a couple of operators to clean up output code
const symbolic = Dict()

symbolic[:+] = (Δ, args...) -> map(_->Δ, args)

function ∇v(v::Vertex, Δ)
  haskey(symbolic, value(v)) && return symbolic[value(v)](Δ, inputs(v)...)
  Δ = vertex(:back!, vertex(value(v)), Δ, inputs(v)...)
  map(i -> @flow(getindex($Δ, $i)), 1:Flow.nin(v))
end

function invert(v::IVertex, Δ, out = d())
  @assert !iscyclic(v)
  if isconstant(v)
    @assert !haskey(out, value(v))
    out[value(v)] = il(Δ)
  else
    Δ′s = ∇v(v, Δ)
    for (v′, Δ′) in zip(inputs(v), Δ′s)
      invert(v′, Δ′, out)
    end
  end
  return out
end

back!(::typeof(+), Δ, args...) = map(_ -> Δ, args)

back!(::typeof(*), Δ, a, b) = Δ*b', Δ*a'
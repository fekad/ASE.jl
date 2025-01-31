
"""
## module MatSciPy

### Summary

Julia wrappers for the [matscipy](https://github.com/libAtoms/matscipy) library.
At the moment, only the neighbourlist is wrapped, which is important for
fast neighbour calculations. `matscipy` depends on `ASE`, hence `MatSciPy.jl`
is a sub-module of `ASE.jl`.

This module ought to remain shielded from a user, calling
`neighbourlist(at)` for an object `at::ASEAtoms` should automatically
generate a `MatSciPy` neighbourlist.

* `ASE.MatSciPy.__neighbour_list__` : the raw neighbour_list wrapper
* `ASE.MatSciPy.NeighbourList` : boiler plate type, including iterators
"""
module MatSciPy

using PyCall, NeighbourLists

matscipy_neighbours = pyimport("matscipy.neighbours")

using JuLIP:  cutoff, JVecs, vecs, cell
using ASE: ASEAtoms, pyobject

import NeighbourLists: sites, pairs, nsites, npairs

# to implement the iterators
import Base: iterate, length


# renamed neighbour_list to __neighbour_list__ to make it clear this is
# an internal function now; this is due to the fact that we don't
# copy the neighbourlist arrays anymore

"""
`neighbour_list(atoms::ASEAtoms, cutoff::Float64, quantities::AbstractString)`
`neighbour_list(atoms::ASEAtoms, cutoff::Float64)`

For the second version, `quantities = "ijdDS"`;
The elements of the tuple depend on the content of `quantities`. E.g.,
```
    i, j, D, d = neighbours(at, 5.0, "ijDd")
```
will return a vector `i` of atom indices, a vector of neighbour indices `j`,
the distance vectors in `D` and the scalar distances in `d`.

By convention, the string *must* start with `"ij"`.

**Warning:** to minimise overhead, this does *not* automatically convert the relative
distance vectors `D` from the ASE N x 3 to the Atoms.jl 3 x N convention!
Use the kwarg `convertarrays=true` to do so.
"""
function __neighbour_list__(atoms::ASEAtoms,
                        cutoff::Float64,
                        quantities="ijdDS";
                        convertarrays=true)
   # compute the neighbourlist via matscipy, get the data as
   # PyArrays, i.e., just references, no copies

   results = pycall(matscipy_neighbours.neighbour_list,
                     NTuple{length(quantities), PyArray}, quantities,
                     pyobject(atoms), cutoff)
   # create Julia arrays ~~~referencing the same memory~~~
   #   >>> this caused too many problems, now just make copies!
   jresults = [Array(r) for r in results]
   # fix the arrays for later use
   for (idx, quantity) in enumerate(quantities)
      # convert indices to 1-based (Julia is 1-based, python 0-based)
      if (quantity == 'i' || quantity == 'j')
         r_idx = jresults[idx]::Vector{Int32}
         @simd for n = 1:length(r_idx)
            @inbounds r_idx[n] += 1
         end
      end
      # convert R and S matrices to arrays of vectors
      if convertarrays
         if quantity == 'D'; jresults[idx] = vecs(jresults[idx]'); end
         if quantity == 'S'; jresults[idx] = vecs(jresults[idx]'); end
      end
   end
   return tuple(jresults..., results)
end



"""
A basic wrapper around the `neighbour_list` builder.

Initialise an empty neighbourlist using
```
nlist = NeighbourList(at, cutoff)
```
where `at::ASEAtoms`, `cutoff::Float64`.
"""
mutable struct NeighbourList
    cutoff::Float64
    i::Vector{Int32}
    j::Vector{Int32}
    r::Vector{Float64}
    R::JVecs{Float64}
    S::JVecs{Int32}
    pyarrays
    length::Int
end

# the last field is a hack to make sure the python arrays are not freed
# TODO: should study this again and maybe file an issue with PyCall

# TODO: replace this neighbourlist with a NeighbourLists.PairList

# default constructor from an ASEAtoms object
NeighbourList(at::ASEAtoms, cutoff::Float64) =
   NeighbourList(cutoff, __neighbour_list__(at, cutoff)..., length(at) )


npairs(nlist::NeighbourList) = length(nlist.i)
nsites(nlist::NeighbourList) = nlist.length

######################################################################
#### implementation of some iterators

pairs(nlist::NeighbourList) = zip(nlist.i, nlist.j, nlist.r, nlist.R)

# iterator over sites
mutable struct Sites
   nlist::NeighbourList
end

length(s::Sites) = s.nlist.length

sites(nlist::NeighbourList) = Sites(nlist)

mutable struct SiteItState
   s::Int   # site index
   b::Int   # bond index
end

# first index is the site index, second index is the index into the nlist
iterate(s::Sites) = (state = SiteItState(0, 0); iterate(s, state))
done(s::Sites, state::SiteItState) = (state.b == npairs(s.nlist))

function iterate(s::Sites, state::SiteItState)
   if done(s, state); return nothing; end
   state.s += 1
   m0 = state.b+1
   while state.b < npairs(s.nlist) && s.nlist.i[state.b+1] <= state.s
      state.b += 1
   end
   m1 = state.b
   return (state.s, view(s.nlist.j, m0:m1), view(s.nlist.r, m0:m1),
               view(s.nlist.R, m0:m1)), state
end


end

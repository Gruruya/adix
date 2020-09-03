## This module provides a directly indexed set/table representation via a dense
## ``seq[T]`` with an auxilliary sparse direct index to accelerate searching.
## "direct" means the same size as the key space or "alphabet".  The index says
## what ``seq`` index has each (unique) key.  This can do any unordered set op
## in guaranteed unit time cost per element -- make, insert, delete, member
## query, iterate, union/intersect/etc. -- all with arbitrarily "aged" sets.
##
## The catch is that the "unit" in said cost will only be small if the key space
## is small enough to afford allocating index space & if the working set of the
## index fits into low enough latency memory to not be too slow.  Otherwise,
## other data structures like hash tables & B-trees will outperform this.
## Iteration is always in insertion order whenever no deletes have occurred.
##
## The earliest reference I have elaborating the properties of this approach is
## An Efficient Representation for Sparse Sets by Preston Briggs & Linda Torczon
## from Rice in 1993.  It's simple enough that the idea may date back to early
## 1960s DB work (likely by Codd), maybe under a term like "direct indexing".
## The key type here must have an available conversion to ``int``.  Duplicate
## keys are not allowed for this one.

import althash, sequint, heapqueue

type
  DITab*[K,V] = object  ## Alphabet size determines `K`; `V` may be `void`
    when V is void:
      data: seq[K]
    else:
      data: seq[tuple[key: K; val: V]]
    range: int
    idx: SeqUint

proc len*[K,V](t: DITab[K,V]): int {.inline.} = t.data.len

proc key[K,V](t: DITab[K,V], i: int): int {.inline.} =
  when V is void:
    when compiles(result.getKey):
      int(t.data[i].getKey) - K.low.int
    else:
      int(t.data[i]) - K.low.int
  else:
    when compiles(result.getKey):
      int(t.data[i].key.getKey) - K.low.int
    else:
      int(t.data[i].key) - K.low.int

proc rawGet[K,V](t: DITab[K,V], key: K): int {.inline.} =
  assert(t.range > 0, "Uninitialized DITab")  # Adjust *caller* not here
  when compiles(key.getKey):
    let i = int(key.getKey) - key.low.int
  else:
    let i = int(key) - key.low.int
  if i >= t.range:
    raise newException(RangeError, "Direct Indexed key limit exceeded")
  let j = t.idx[i].int                  # Get idx, cmp key
  if j < t.len and t.key(j) == i: j else: -1 - i

proc rawPut[K,V](t: var DITab[K,V], i: int): int {.inline.} =
  t.idx[i] = uint(t.data.len)           # Save idx
  t.data.setLen t.data.len + 1          # Make room at high index
  return t.data.len - 1                 # Return slot

proc rawDel[K,V](t: var DITab[K,V], i: int) {.inline.} =
  if i == t.data.len - 1:               # Avoid depending upon the
    discard t.data.pop                  # ..order of L/R eval below.
  else:
    t.data[i] = t.data.pop              # Move end to idx(del tgt)
    t.idx[t.key(i)] = uint(i)           # Update idx(end key)

template getPut(present: untyped, missing: untyped) {.dirty.} =
  if t.range == 0: t.init               # Ensure initialized table
  let i = t.rawGet(key)
  if i < 0:
    let k = t.rawPut(-1 - i)
    missing
  else:
    present

template popRet(present: untyped, missing: untyped) {.dirty.} =
  if t.data.len == 0:
    missing
  let i = t.rawGet(key)
  if i >= 0:
    present
  else:
    missing

proc depths*[K,V](t: DITab[K,V]): seq[int] =
  result.setLen 1; result[0] = t.len

##############################################################################
var diNumer*     = 0     ## default numerator (unused)
var diDenom*     = 0     ## default denominator (unused)
var diMinFree*   = 0     ## default min free slots (unused)
var diGrowPow2*  = 0     ## default growth power of 2 (unused)
var diRehash*    = false ## default hcode rehashing behavior (unused)
var diRobinHood* = false ## default to Robin Hood (unused)

proc init*[K,V](t: var DITab[K,V], initialSize=0, numer=0, denom=0, minFree=0,
              growPow2=0, rehash=false, robinhood=false) {.inline.} =
  let n = if initialSize != 0: initialSize else: K.high.int - K.low.int + 1
  if n != t.range:                      # Never need to zero the index!
    t.idx = initSeqUint(n, n)
    t.range = n
  if initialSize != 0:
    when V is void:
      t.data = newSeqOfCap[K](initialSize)
    else:
      t.data = newSeqOfCap[tuple[key: K; val: V]](initialSize)

proc initDITab*[K,V](initialSize=0, numer=0, denom=0, minFree=0, growPow2=0,
                   rehash=false, robinhood=false): DITab[K,V] {.inline.} =
  result.init(initialSize)

proc setPolicy*[K,V](t: var DITab[K,V], numer=0, denom=0, minFree=0, growPow2=0,
                   rehash=0, robinhood=0) {.inline.} = discard

proc rightSize*(count: int, numer=0, denom=0, minFree=0): int {.inline,
  deprecated: "Deprecated since 0.2; identity function".} = count

proc getCap*[K,V](t: var DITab[K,V]): int {.inline.} = t.range

proc setCap*[K,V](t: var DITab[K,V], newSize = -1) = discard

proc contains*[K,V](t: DITab[K,V]; key: K): bool {.inline.} = t.rawGet(key) >= 0

proc containsOrIncl*[K](t: var DITab[K,void]; key: K): bool {.inline.} =
  getPut do: result = true
  do       : result = false; t.data[k] = key

proc setOrIncl*[K](t: var DITab[K,void]; key: K): bool {.inline.} =
  getPut do: t.data[i] = key; result = true
  do       : t.data[k] = key; result = false

proc mgetOrPut*[K,V](t: var DITab[K,V]; key: K; val: V): var V {.inline.} =
  getPut do: return t.data[i].val
  do       : t.data[k].key = key; t.data[k].val = val; return t.data[k].val

proc mgetOrPut*[K,V](t: var DITab[K,V]; key: K; val: V;
                     had: var bool): var V {.inline.} =
  getPut do: had = true ; return t.data[i].val
  do       : had = false; t.data[k].key = key; t.data[k].val = val; return t.data[k].val

template editOrInit*[K,V](t: var DITab[K,V]; key: K; v,body1,body2: untyped) =
  getPut do:
    var v {.inject.} = t.data[i].val.addr
    body1
  do:
    t.data[k].key = key
    var v {.inject.} = t.data[k].val.addr
    body2

proc add*[K](t: var DITab[K,void]; key: K) {.inline.} =
  assert(false, "Direct Indexed tables cannot be multisets")

proc add*[K,V](t: var DITab[K,V]; key: K, val: V) {.inline.} =
  assert(false, "Direct Indexed tables cannot be multisets")

proc missingOrExcl*[K,V](t: var DITab[K,V], key: K): bool =
  popRet do: t.rawDel i
  do       : return true

proc take*[K](t: var DITab[K,void]; key: var K): bool {.inline.} =
  popRet do: key = move(t.data[i]); t.rawDel i; return true
  do: return false

proc take*[K,V: not void](t: var DITab[K,V]; key: K; val: var V): bool {.inline.} =
  popRet do:
    val = move(t.data[i].val)
    t.rawDel i
    result = true
  do: discard

proc pop*[K](t: var DITab[K,void]): K {.inline.} = t.data.pop

proc pop*[K,V:not void](t: var DITab[K,V]): tuple[key: K; val: V] {.inline.} =
  t.data.pop

proc clear*[K,V](t: var DITab[K,V]) {.inline.} = t.data.setLen 0

iterator items*[K](t: DITab[K,void]): K =
  for key in t.data: yield key

iterator mitems*[K](t: var DITab[K,void]): var K =
  for key in t.data: yield key

iterator allItems*[K](t: DITab[K,void]; key: K): K =
  assert(false, "Direct Indexed tables cannot be multisets")

iterator pairs*[K](t: DITab[K,void]): (int, K) =
  for i, key in t.data: yield (i, key)

iterator pairs*[K,V: not void](t: DITab[K,V]): (K,V) =
  for e in t.data: yield e

iterator mpairs*[K,V: not void](t: DITab[K,V]): var tuple[key: K; val: V] =
  for e in t.data: yield e

iterator hcodes*[K,V](t: DITab[K,V]): tuple[i: int, hc: Hash] =
  when compiles(key.getKey):
    for i, key in t.data: yield (i, Hash(key.getKey))
  else:
    for i, key in t.data: yield (i, Hash(key))

proc debugDump*[K,V](t: DITab[K,V], label="") =
  if label.len > 0: echo label
  echo t.len, " items"
  echo "data: ", t.data
  echo "index: "
  for i in 0 ..< t.range: echo "  ", t.idx[i]

iterator keys*[K,V](t: DITab[K,V]): K =
  for e in t.data: yield e.key

iterator values*[K,V](t: DITab[K,V]): V =
  for e in t.data: yield e.val

iterator mvalues*[K,V](t: var DITab[K,V]): var V =
  for e in t.data: yield e.val

iterator allValues*[K,V](t: DITab[K,V]; key: K): V =
  assert(false, "Direct Indexed tables cannot be multisets")

## Below here is pretty standard except for the generic signatures
proc pop*[K](s: var DITab[K,void]; key: var K): bool {.inline.} =
  s.take key

proc incl*[K](s: var DITab[K,void], elt: K) {.inline.} =
  discard s.containsOrIncl(elt)

proc excl*[K](s: var DITab[K,void], elt: K) {.inline.} =
  discard s.missingOrExcl(elt)

proc incl*[K](s: var DITab[K,void], other: DITab[K,void]) =
  for elt in other: s.incl elt

proc excl*[K](s: var DITab[K,void], other: DITab[K,void]) =
  for elt in other: s.excl elt

proc card*[K](s: DITab[K,void]): int {.inline.} = s.len

proc union*[K](s1, s2: DITab[K,void]): DITab[K,void] =
  result = s1
  result.incl s2

proc intersection*[K](s1, s2: DITab[K,void]): DITab[K,void] =
  result.init min(s1.len, s2.len)
  for elt in s1:
    if elt in s2: result.incl elt

proc difference*[K](s1, s2: DITab[K,void]): DITab[K,void] =
  result.init
  for elt in s1:
    if elt notin s2: result.incl elt

proc symmetricDifference*[K](s1, s2: DITab[K,void]): DITab[K,void] =
  result = s1
  for item in s2:
    if result.containsOrIncl(item): result.excl item

proc `+`*[K](s1, s2: DITab[K,void]): DITab[K,void] {.inline.} =
  s1.union s2

proc `*`*[K](s1, s2: DITab[K,void]): DITab[K,void] {.inline.} =
  s1.intersection s2

proc `-`*[K](s1, s2: DITab[K,void]): DITab[K,void] {.inline.} =
  s1.difference s2

proc `-+-`*[K](s1, s2: DITab[K,void]): DITab[K,void] {.inline.} =
  s1.symmetricDifference s2

proc disjoint*[K](s1, s2: DITab[K,void]): bool =
  for item in s1:
    if item in s2: return
  result = true

proc `<=`*[K](s, t: DITab[K,void]): bool =
  if s.counter <= t.counter:
    for item in s:
      if item notin t: return
    result = true

proc `<`*[K](s, t: DITab[K,void]): bool =
  s.counter != t.counter and s <= t

proc `==`*[K](s, t: DITab[K,void]): bool =
  s.counter == t.counter and s <= t

proc map*[K, A](data: DITab[K,void], op: proc (x: K): A {.closure.}): DITab[A,void] =
  result.init data.len
  for item in data: result.incl op(item)

proc toDITab*[K](keys: openArray[K], dups=false): DITab[K,void] =
  assert(not dups, "Direct Indexed tables cannot be multisets")
  result.init keys.len
  for key in keys: result.incl key

proc `$`*[K](s: DITab[K,void]): string =
  if s.len == 0: return "{}"
  result = "{"
  for key in s:
    if result.len > 1: result.add(", ")
    result.addQuoted(key)
  result.add("}")

proc hash*[K](s: DITab[K,void]): Hash =
  for i, hc in 0 .. s.hcodes: result = result xor hc
  result = !$result  #Important to use a COMMUTATIVE combiner above

proc depthStats*[K,V](s: DITab[K,V]): tuple[m1, m2: float; mx: int] =
  result.m1 = 0; result.m2 = 0; result.mx = 0 # really already zero

proc toDITab*[K,V: not void](pairs: openArray[(K,V)], dups=false): DITab[K,V] =
  assert(not dups, "Direct Indexed tables cannot be multisets")
  result.init pairs.len
  for key, val in pairs: result[key] = val    # replace

proc `$`*[K,V: not void](t: DITab[K,V]): string =
  if t.len == 0: return "{:}"
  result = "{"
  for key, val in t:
    if result.len > 1: result.add(", ")
    result.addQuoted(key)
    result.add(": ")
    result.addQuoted(val)
  result.add("}")

proc pop*[K,V: not void](t: var DITab[K,V]; key: K; val: var V): bool{.inline.}=
  t.take key, val

template withValue*[K,V](t: var DITab[K,V], key: K; value, body: untyped) =
  mixin rawGet
  let i = t.rawGet(key)
  if i >= 0:
    var value {.inject.} = t.data[i].val.addr
    body

template withValue*[K,V](t: var DITab[K,V], key: K; value, body1, body2: untyped) =
  mixin rawGet
  let i = t.rawGet(key)
  if i >= 0:
    var value {.inject.} = t.data[i].val.addr
    body1
  else: body2

proc `[]`*[K,V](t: DITab[K,V], key: K): V {.inline.} =
  mixin rawGet
  let i = t.rawGet(key)
  if i >= 0: result = t.data[i].val
  else: raiseNotFound(key)

proc `[]`*[K,V](t: var DITab[K,V], key: K): var V {.inline.} =
  mixin rawGet
  let i = t.rawGet(key)
  if i >= 0: result = t.data[i].val
  else: raiseNotFound(key)

proc `[]=`*[K,V](t: var DITab[K,V], key: K, val: V) =
  getPut do: t.data[i].val = val
  do       : t.data[k].key = key; t.data[k].val = val

proc `{}`*[K,V](t: DITab[K,V], key: K): V {.inline.} = t[key]
proc `{}`*[K,V](t: var DITab[K,V], key: K): var V {.inline.} = t[key]
proc `{}=`*[K,V](t: var DITab[K,V], key: K, val: V) {.inline.} = t[key] = val

proc hasKey*[K,V](t: DITab[K,V], key: K): bool {.inline.} = key in t

proc hasKeyOrPut*[K,V](t: var DITab[K,V], key: K, val: V): bool {.inline.} =
  discard t.mgetOrPut(key, val, result)

proc getOrDefault*[K,V](t: DITab[K,V], key: K, default=default(V)): V{.inline.}=
  mixin rawGet
  let i = t.rawGet(key)
  result = if i >= 0: t.data[i].val else: default

proc del*[K,V](t: var DITab[K,V], key: K) {.inline.} =
  if t.missingOrExcl(key): key.raiseNotFound

proc del*[K,V](t: var DITab[K,V], key: K, had: var bool) {.inline.} =
  had = not t.missingOrExcl(key)

proc `==`*[K,V](x, y: DITab[K,V]): bool =
  if isNil(x): return isNil(y)            # 2 nil => true
  if isNil(y): return false               # 1 nil => false
  if x.counter != y.counter: return false # diff size => false
  for key, val in x:                      # diff insert orders => diff `data`
    if not y.hasKey(key) or y.getOrDefault(key) != val: return false
  return true

proc indexBy*[A, K,V](collection: A, index: proc(x: V): K): DITab[K,V] =
  result.init
  for item in collection: result[index(item)] = item

#A few things to maybe totally obviate CountTable or let it be a type alias
proc inc*[K,V: SomeInteger](t: var DITab[K,V], key: K, amount: SomeInteger=1) {.inline.} =
  t.mgetOrPut(key, 0).inc amount

proc merge*[K,V: SomeInteger](s: var DITab[K,V], t: DITab[K,V]) =
  for key, val in t: s.inc(key, val)

iterator topPairsByVal*[K,V](h: DITab[K,V], n=10, above=V.low):
    tuple[key: K; val: V] =
  var q = initHeapQueue[tuple[val: V; key: T]]()
  for key, val in h:
    if val > above:
      if q.len < n:
        q.push((val, key))
      elif (val, key) > q[0]:
        discard q.replace((val, key))
  var r: tuple[key: K; val: V]
  while q.len > 0:        # q now has top n entries
    let next = q.pop
    r.key = next.key
    r.val = next.val
    yield r               # yield in ascending order
Prototyping interactions for [imp](https://github.com/jamii/imp) without getting bottlenecked on language design.

Build (dev):

``` bash
clj -M --main cljs.main --compile preimp.core

# or 

clj -M --main cljs.main --watch src --compile preimp.core
```

Serve:

``` bash
(require 'preimp.server :reload-all)
(preimp.server/-main)
```

Format:

``` bash
clojure -Sdeps '{:deps {cljfmt {:mvn/version "0.8.0"}}}' -m cljfmt.main fix
```

Build (prod):

```
clj -T:build build/uber
```

Deploy:

```
nixops create -d preimp
nixops deploy -d preimp
```
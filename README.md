Prototyping interactions for [imp](https://github.com/jamii/imp) without getting bottlenecked on language design.

Build:

``` bash
clj -M --main cljs.main --compile cljs-eval-example.core

# or 

clj -M --main cljs.main --watch src --compile cljs-eval-example.core
```

Serve:

``` bash
(require 'cljs-eval-example.server :reload-all)
(cljs-eval-example.server/-main)
```

Format:

``` bash
clojure -Sdeps '{:deps {cljfmt {:mvn/version "0.8.0"}}}' -m cljfmt.main fix
```

```
clj -M --main cljs.main --compile cljs-eval-example.core
clj -M --main cljs.main --watch src --compile cljs-eval-example.core
clojure -Sdeps '{:deps {cljfmt {:mvn/version "0.8.0"}}}' -m cljfmt.main fix
```

```
(require 'cljs-eval-example.server :reload-all)
(cljs-eval-example.server/-main)
```
Prototyping interactions for [imp](https://github.com/jamii/imp) without getting bottlenecked on language design.

Build (dev):

``` bash
clj -M --main cljs.main --watch src --compile preimp.core
```

Serve (dev):

``` clj
(require 'preimp.server :reload-all)
(preimp.server/-main)
```

Build (prod):

``` bash
clj -M --main cljs.main --optimizations simple --compile preimp.core
clj -T:build build/uber
```

Serve (prod):

``` bash
java -jar target/preimp-1.0.0-standalone.jar
```

Deploy:

``` bash
# on first deploy:
# nixops create -d preimp
nixops deploy -d preimp
```
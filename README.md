Prototyping interactions for [imp](https://github.com/jamii/imp) without getting bottlenecked on language design.

Build (dev):

``` bash
rm -rf out # :'(
clj -M --main cljs.main --watch src --output-to out/standalone.js --compile preimp.standalone
```

Serve (dev):

``` clj
(require 'preimp.server :reload-all)
(preimp.server/-main)
```

Build (prod):

``` bash
rm -rf out # :'(
clj -M --main cljs.main --optimizations simple --output-to out/standalone.js --compile preimp.standalone 
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

---

Build wasm version:

``` bash
zig build wasm
python3 -m http.server
$BROWSER localhost:8000/wasm/wasm.html
```
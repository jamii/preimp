(ns build
  (:require [clojure.tools.build.api :as b]
            [cljs.build.api :as cljs]

            [clojure.java.io :as io]))

(def lib 'preimp)
(def version "1.0.0")
(def class-dir "target/classes")
(def basis (b/create-basis {:project "deps.edn"}))
(def uber-file (format "target/%s-%s-standalone.jar" (name lib) version))

(defn compile-cljs [_]
  (b/delete {:path "out"})
  (let [t0 (System/currentTimeMillis)]
    (cljs/build (io/file "src")
                {:optimizations   :none
                 :closure-defines {"goog.DEBUG" false}
                 :parallel-build  true})
    (println "[package] Compiled cljs in" (- (System/currentTimeMillis) t0) "ms")))

(defn uber [_]
  (b/delete {:path "target"})
  (b/copy-dir {:src-dirs (:paths basis)
               :target-dir class-dir})
  (b/compile-clj {:basis basis
                  :src-dirs ["src"]
                  :class-dir class-dir})
  (b/uber {:class-dir class-dir
           :uber-file uber-file
           :basis basis
           :main 'preimp.server}))

(defn all [_]
  (compile-cljs nil)
  (uber nil))
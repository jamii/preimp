(ns build
  (:require [clojure.tools.build.api :as b]
            [cljs.build.api :as cljs]

            [clojure.java.io :as io]))

(def lib 'preimp)
(def version "1.0.0")
(def class-dir "target/classes")
(def basis (b/create-basis {:project "deps.edn"}))
(def uber-file (format "target/%s-%s-standalone.jar" (name lib) version))

(defn prod [_]
  (b/delete {:path "out"})
  (b/delete {:path "target"})
  (b/copy-dir {:src-dirs ["src"]
               :target-dir class-dir})
  (cljs/build (cljs/inputs "src")
              {:output-to "out/main.js"
               :output-dir "out/"
               :optimizations :simple
               :compiler-stats true})
  (b/copy-dir {:src-dirs ["out"]
               :target-dir class-dir})
  (b/compile-clj {:basis basis
                  :src-dirs ["src"]
                  :class-dir class-dir})
  (b/uber {:class-dir class-dir
           :uber-file uber-file
           :basis basis
           :main 'preimp.server}))
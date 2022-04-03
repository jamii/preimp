(ns cljs-eval-example.core
  (:require [cljs.env]))

(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))
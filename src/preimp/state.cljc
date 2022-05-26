(ns preimp.state
  (:require [clojure.test :refer [deftest is]]))

(defn new-cell-id []
  #?(:clj (java.util.UUID/randomUUID)
     :cljs (random-uuid)))

(defrecord Op [cell-id version client content])

(defn next-version [ops]
  (inc (reduce max 0 (for [op ops] (:version op)))))

(defn assoc-cell [ops client cell-id new-content]
  (conj ops
        (Op. cell-id (next-version ops) client new-content)))

(defn ops->state [ops]
  (let [sorted-ops (sort-by (fn [op] [(:version op) (:client op)]) ops)]
    (reduce
     (fn [state op]
       (assoc state (:cell-id op) (:content op)))
     {}
     sorted-ops)))

(deftest basic
  (is (= (ops->state #{}) {}))
  (is (= (ops->state
          #{(Op. "x" 0 "a" "ax0")
            (Op. "x" 1 "a" "ax1")})
         {"x" "ax1"}))
  (is (= (ops->state
          #{(Op. "x" 0 "a" "ax0")
            (Op. "y" 1 "a" "ay1")})
         {"x" "ax0"
          "y" "ay1"}))
  (is (= (ops->state
          #{(Op. "x" 0 "a" "ax0")
            (Op. "x" 0 "b" "bx0")})
         {"x" "bx0"}))
  (is (= (ops->state
          #{(Op. "x" 1 "a" "ax1")
            (Op. "x" 0 "b" "bx0")})
         {"x" "ax1"})))
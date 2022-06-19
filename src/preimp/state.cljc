(ns preimp.state
  (:require [clojure.test :refer [deftest is]]))

(defn new-cell-id []
  #?(:clj (java.util.UUID/randomUUID)
     :cljs (random-uuid)))

(defrecord InsertOp [version client cell-id prev-cell-id])
(defrecord DeleteOp [version client cell-id])
(defrecord AssocOp [version client cell-id key value])

(defn next-version [ops]
  (inc (reduce max 0 (for [op ops] (:version op)))))

(defn insert-cell [ops client cell-id prev-cell-id]
  (conj ops
        (InsertOp. (next-version ops) client cell-id prev-cell-id)))

(defn remove-cell [ops client cell-id]
  (conj ops
        (DeleteOp. (next-version ops) client cell-id)))

(defn assoc-cell [ops client cell-id key value]
  (conj ops
        (AssocOp. (next-version ops) client cell-id key value)))

(defn ops->state [ops]
  (let [removed (set (for [op ops :when (instance? DeleteOp op)] (:cell-id op)))
        inserted (set (for [op ops :when (instance? InsertOp op) :when (not (removed (:cell-id op)))] (:cell-id op)))
        sorted-ops (sort-by (fn [op] [(:version op) (:client op)]) ops)
        all-cell-ids (reduce
                      (fn [cell-ids op]
                        (if (instance? InsertOp op)
                          (let [ix (if (:prev-cell-id op)
                                     (inc (.indexOf cell-ids (:prev-cell-id op))) 0)]
                            (apply conj (subvec cell-ids 0 ix) (:cell-id op) (subvec cell-ids ix)))
                          cell-ids))
                      []
                      sorted-ops)
        cell-ids (into [] (filter inserted all-cell-ids))
        cell-maps (reduce
                   (fn [state op]
                     (if (and
                          (instance? AssocOp op)
                          (inserted (:cell-id op)))
                       (assoc-in state [(:cell-id op) (:key op)] (:value op))
                       state))
                   (into {} (for [cell-id inserted] [cell-id {}]))
                   sorted-ops)]
    {:cell-ids cell-ids
     :cell-maps cell-maps}))

(defn migrate-map->AssocOp [map]
  (if (contains? map :code)
    (AssocOp. (:version map) (:client map) (:cell-id map) :code (:code map))
    (map->AssocOp map)))

(def readers
  {'preimp.state.InsertOp map->InsertOp
   'preimp.state.DeleteOp map->DeleteOp
   'preimp.state.AssocOp migrate-map->AssocOp})

(deftest basic
  (is (= (ops->state #{})
         {:cell-ids []
          :cell-maps {}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (AssocOp. 1 "a" "x" :code "ax1")
            (AssocOp. 2 "a" "x" :code "ax2")})
         {:cell-ids ["x"]
          :cell-maps {"x" {:code "ax2"}}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (InsertOp. 1 "a" "y" "x")
            (InsertOp. 2 "a" "z" "x")
            (AssocOp. 3 "a" "x" :code "ax3")
            (AssocOp. 4 "a" "y" :code "ay4")})
         {:cell-ids ["x" "z" "y"]
          :cell-maps {"x" {:code "ax3"}
                      "y" {:code "ay4"}
                      "z" {}}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (AssocOp. 1 "b" "x" :code "bx1")
            (AssocOp. 1 "a" "x" :code "ax1")})
         {:cell-ids ["x"]
          :cell-maps {"x" {:code "bx1"}}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (AssocOp. 1 "b" "x" :code "bx1")
            (AssocOp. 2 "a" "x" :code "ax2")})
         {:cell-ids ["x"]
          :cell-maps {"x" {:code "ax2"}}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (InsertOp. 1 "a" "y" "x")
            (InsertOp. 2 "a" "z" "x")
            (AssocOp. 3 "a" "x" :code "ax3")
            (AssocOp. 4 "a" "y" :code "ay4")
            (DeleteOp. 5 "a" "x")})
         {:cell-ids ["z" "y"]
          :cell-maps {"y" {:code "ay4"}
                      "z" {}}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (InsertOp. 1 "a" "y" "x")
            (InsertOp. 2 "a" "z" "y")
            (DeleteOp. 3 "a" "y")})
         {:cell-ids ["x" "z"]
          :cell-maps {"x" {}
                      "z" {}}})))
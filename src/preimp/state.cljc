(ns preimp.state
  (:require [clojure.test :refer [deftest is]]))

(defn new-cell-id []
  #?(:clj (java.util.UUID/randomUUID)
     :cljs (random-uuid)))

(defrecord InsertOp [version client cell-id prev-cell-id])
(defrecord DeleteOp [version client cell-id])
(defrecord AssocOp [version client cell-id code])

(defn next-version [ops]
  (inc (reduce max 0 (for [op ops] (:version op)))))

(defn insert-cell [ops client cell-id prev-cell-id]
  (conj ops
        (InsertOp. (next-version ops) client cell-id prev-cell-id)))

(defn delete-cell [ops client cell-id]
  (conj ops
        (DeleteOp. (next-version ops) client cell-id)))

(defn assoc-cell [ops client cell-id new-code]
  (conj ops
        (InsertOp. (next-version ops) client new-code cell-id)))

(defn ops->state [ops]
  (let [inserted (set (for [op ops :when (instance? InsertOp op)] (:cell-id op)))
        deleted (set (for [op ops :when (instance? DeleteOp op)] (:cell-id op)))
        sorted-ops (sort-by (fn [op] [(:version op) (:client op)]) ops)
        cell-ids (reduce
                  (fn [cell-ids op]
                    (if (and
                         (instance? InsertOp op)
                         (not (deleted (:cell-id op))))
                      (let [ix (if (:prev-cell-id op)
                                 (inc (.indexOf cell-ids (:prev-cell-id op))) 0)]
                        (apply conj (subvec cell-ids 0 ix) (:cell-id op) (subvec cell-ids ix)))
                      cell-ids))
                  []
                  sorted-ops)
        cell-codes (reduce
                    (fn [state op]
                      (if (and
                           (instance? AssocOp op)
                           (inserted (:cell-id op))
                           (not (deleted (:cell-id op))))
                        (assoc state (:cell-id op) (:code op))
                        state))
                    (into {} (for [cell-id inserted] [cell-id ""]))
                    sorted-ops)]
    {:cell-ids cell-ids
     :cell-codes cell-codes}))

(deftest basic
  (is (= (ops->state #{})
         {:cell-ids []
          :cell-codes {}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (AssocOp. 1 "a" "x" "ax1")
            (AssocOp. 2 "a" "x" "ax2")})
         {:cell-ids ["x"]
          :cell-codes {"x" "ax2"}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (InsertOp. 1 "a" "y" "x")
            (InsertOp. 2 "a" "z" "x")
            (AssocOp. 3 "a" "x" "ax3")
            (AssocOp. 4 "a" "y" "ay4")})
         {:cell-ids ["x" "z" "y"]
          :cell-codes {"x" "ax3"
                       "y" "ay4"
                       "z" ""}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (AssocOp. 1 "b" "x" "bx1")
            (AssocOp. 1 "a" "x" "ax1")})
         {:cell-ids ["x"]
          :cell-codes {"x" "bx1"}}))
  (is (= (ops->state
          #{(InsertOp. 0 "a" "x" nil)
            (AssocOp. 1 "b" "x" "bx1")
            (AssocOp. 2 "a" "x" "ax2")})
         {:cell-ids ["x"]
          :cell-codes {"x" "ax2"}})))
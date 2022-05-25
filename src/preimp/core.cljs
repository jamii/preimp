(ns preimp.core
  (:require-macros [preimp.core :refer [analyzer-state]])
  (:require
   cljsjs.codemirror
   cljsjs.codemirror.mode.clojure
   cljsjs.codemirror.addon.edit.matchbrackets
   cljsjs.codemirror.addon.comment.comment
   [reagent.dom :as dom]
   [reagent.core :as r]
   [cljs.js :refer [empty-state eval-str js-eval]]
   [cljs.pprint :refer [pprint]]
   [cljs.reader :refer [read-string]]))

(defn d [& args] (js/console.log (pr-str args)) (last args))

;; --- util ---

(def eval-config
  {:eval js-eval
   :source-map true
   :context :expr})

(defn eval-form [state form]
  (let [result (atom nil)]
    (cljs.js/eval state `(let [~'edit! ~'preimp.core/edit!] ~form) eval-config #(reset! result %))
    ;; while eval can be async, it usually isn't
    (assert @result)
    @result))

(def eval-state (empty-state))
(cljs.js/load-analysis-cache! eval-state 'clojure.string (analyzer-state 'clojure.string))
(cljs.js/load-analysis-cache! eval-state 'preimp.core (analyzer-state 'preimp.core))

;; TODO I think the meta for end-col from tools.reader is accurate, so don't need to parse for end-ix
(defn line-col->ix [line-col code]
  (let [lines (clojure.string/split code "\n")
        start-ix (+ (reduce + (map #(inc (count %)) (take (dec (:line line-col)) lines))) (dec (:column line-col)))
        end-ix (loop [ix start-ix
                      open-parens 0]
                 (if (or (and (not= ix start-ix) (= open-parens 0)) (= ix (count code)))
                   ix
                   (let [open-parens (case (get code ix)
                                       "(" (inc open-parens)
                                       ")" (dec open-parens)
                                       open-parens)]
                     (recur (inc ix) open-parens))))]
    [start-ix end-ix]))

(defn replace-defs [line-col name code new-value]
  (let [[start-ix end-ix] (line-col->ix line-col code)]
    (str (subs code 0 start-ix)
         (pr-str `(~'defs ~name ~new-value))
         (subs code end-ix))))

;; TODO this doesn't handle shadowing global names
(defn names-into! [form names]
  (cond
    (or (list? form) (vector? form) (map? form))
    (doseq [subform form] (names-into! subform names))

    (symbol? form)
    (swap! names conj form)))

;; --- incr ---

(defprotocol Incremental
  (compute* [this compute]))

(defrecord CellIds [])

(defrecord CellCode [id])

(defrecord CellParse [id]
  Incremental
  (compute* [this compute]
    (let [code (compute (CellCode. id))
          reader (cljs.tools.reader.reader-types.indexing-push-back-reader code)
          defs (atom [])]
      (while (cljs.tools.reader.reader-types.peek-char reader)
         ;; reset gensym ids so repeated reads are always identical
        (reset! cljs.tools.reader.impl.utils/last-id 0)
        (let [form (cljs.tools.reader.read reader)
              _ (when-not (list? form)
                  (throw [:not-list form]))
              kind (nth form 0 nil)
              _  (when-not (#{'defs 'def 'defn} kind)
                   (throw [:bad-kind form]))
              name (nth form 1 nil)
              _  (when-not name
                   (throw [:no-name form]))
              body (-> form rest rest)
              _ (when (= (count body) 0)
                  (throw [:no-body form]))]
          (swap! defs conj {:cell-id id :form form :kind kind :name name :body body})))
      (case (count @defs)
        0 (throw [:no-def-in-cell id])
        1 (first @defs)
        (throw [:multiple-defs-in-cell id])))))

(defrecord Names []
  Incremental
  (compute* [this compute]
    (let [cell-ids (compute (CellIds.))]
      (into #{}
            (for [cell-id cell-ids
                  :let [cell-parse (try
                                     (compute (CellParse. cell-id))
                                     (catch :default error nil))]
                  :when cell-parse]
              (:name cell-parse))))))

(defrecord Def [name]
  Incremental
  (compute* [this compute]
    (let [cell-ids (compute (CellIds.))
          cell-parses (for [cell-id cell-ids]
                        (try (compute (CellParse. cell-id))
                             (catch :default error nil)))
          matching-defs (filter #(= name (:name %)) cell-parses)]
      (case (count matching-defs)
        0 (throw [:no-def-for-name name])
        1 (first matching-defs)
        2 (throw [:multiple-defs-for-name name])))))

(defrecord Deps [name]
  Incremental
  (compute* [this compute]
    (let [names (compute (Names.))
          def (compute (Def. name))
          refers (atom #{})]
      (names-into! (:form def) refers)
      (into #{}
            (filter #(and (not= name %) (names %)) @refers)))))

(defrecord Thunk [name]
  Incremental
  (compute* [this compute]
    (let [def (compute (Def. name))
          kind (:kind def)]
      (if (= kind 'defs)
        {:thunk (let [value (last (:body def))] (fn [] value))
         :args '()}
        (let [deps (sort (compute (Deps. name)))
              form (case kind
                     def `(fn [~@deps] ~@(:body def))

                     defn `(fn [~@deps] (fn ~@(:body def))))
              thunk (eval-form (atom @eval-state) form)]
          (if-let [error (:error :thunk)]
            (throw error)
            {:thunk (:value thunk)
             :args deps}))))))

(defrecord Value [name]
  Incremental
  (compute* [this compute]
    (let [thunk (compute (Thunk. name))
          args (for [arg (:args thunk)] (compute (Value. arg)))]
      (apply (:thunk thunk) args))))

;; --- state ---

(def next-cell-id (atom 1))

(def codemirrors (atom {}))
(def codes (r/atom {}))

(def state
  (r/atom {;; version increments on every change made from the outside
           :version 0

      ;; the last version at which this id was computed
           :id->version {(CellIds.) 0 (CellCode. 0) 0}

      ;; the value when this id was last computed
      ;; (may be an Error)
           :id->value {(CellIds.) [0] (CellCode. 0) ""}

      ;; other id/value pairs that were used to compute this id
           :id->deps {}}))

(defrecord Error [error])

(defn change-input [id value]
  (swap! state update-in [:version] inc)
  (swap! state assoc-in [:id->version id] (:version @state))
  (swap! state assoc-in [:id->value id] value))

(declare recall-or-recompute)

(defn deps-changed? [id]
  (some
   (fn [[dep dep-value]]
     (not= dep-value (recall-or-recompute dep)))
   (get-in @state [:id->deps id])))

(defn stale? [id]
  (or (not (contains? (@state :id->value) id))
      (and (not= (get-in @state [:id->version id]) (:version @state))
           (deps-changed? id))))

(defn recompute [id]
  (d :recompute id)
  (let [new-deps (atom {})
        new-value (try
                    (compute* id (fn [id]
                                   (let [value (recall-or-recompute id)]
                                     (swap! new-deps assoc id value)
                                     (if (instance? Error value)
                                       (throw (:error value))
                                       value))))
                    (catch :default error
                      (Error. error)))]
    (swap! state update-in [:id->version] assoc id (@state :version))
    (swap! state update-in [:id->value] assoc id new-value)
    (swap! state update-in [:id->deps] assoc id @new-deps)
    new-value))

(defn recall-or-recompute [id]
  (if (stale? id)
    (recompute id)
    (do
      (swap! state assoc-in [:id->version id] (:version @state))
      (get-in @state [:id->value id]))))

(defn edit! [name f & args]
  (let [cell-id (:cell-id (recall-or-recompute (Def. name)))
        old-value (recall-or-recompute (Value. name))
        new-value (apply f old-value args)
        new-code (pr-str `(~'defs ~name ~new-value))]
    (.setValue (get @codemirrors cell-id) new-code)
    (change-input (CellCode. cell-id) new-code)
    (change-input (Value. name) new-value)))

(defn update-cell [cell-id]
  (change-input (CellCode. cell-id) (.getValue (get @codemirrors cell-id))))

(defn insert-cell-at [ix]
  (let [cell-ids (recall-or-recompute (CellIds.))
        new-cell-ids (apply conj (subvec cell-ids 0 ix) @next-cell-id (subvec cell-ids ix))]
    (change-input (CellIds.) new-cell-ids)
    (change-input (CellCode. @next-cell-id) "")
    (swap! next-cell-id inc)))

(defn insert-cell [before-or-after near-cell-id]
  (let [cell-ids (recall-or-recompute (CellIds.))
        near-ix (.indexOf cell-ids near-cell-id)]
    (insert-cell-at (case before-or-after :before near-ix :after (inc near-ix)))))

(defn remove-cell [cell-id]
  (let [cell-ids (recall-or-recompute (CellIds.))
        ix (.indexOf cell-ids cell-id)
        new-cell-ids (apply conj (subvec cell-ids 0 ix) (subvec cell-ids (inc ix)))]
    (change-input (CellIds.) new-cell-ids)
    (when (empty? new-cell-ids)
      (insert-cell-at 0))
    (.focus (@codemirrors ((recall-or-recompute (CellIds.)) (if (= ix 0) 0 (dec ix)))))))

(defn editor [cell-id]
  (r/create-class
   {:render
    (fn [] [:textarea])
    :component-did-mount
    (fn [this]
      (let [codemirror (.fromTextArea
                        js/CodeMirror
                        (dom/dom-node this)
                        #js {:mode "clojure"
                             :lineNumbers false
                             :extraKeys #js {"Ctrl-Enter" (fn [_] (update-cell cell-id))
                                             "Shift-Enter" (fn [_]
                                                             (insert-cell :after cell-id)
                                                             (update-cell cell-id))
                                             "Shift-Alt-Enter" (fn [_]
                                                                 (insert-cell :before cell-id)
                                                                 (update-cell cell-id))
                                             "Ctrl-Backspace" (fn [_] (remove-cell cell-id))}
                             :matchBrackets true
                             :autofocus true
                             :viewportMargin js/Infinity})]
        (swap! codes assoc cell-id "")
        (.on codemirror "changes" (fn [_] (swap! codes assoc cell-id (.getValue codemirror))))
        (.on codemirror "blur" (fn [_] (update-cell cell-id)))
        (swap! codemirrors assoc cell-id codemirror)))}))

(defn output [cell-id]
  [:div
   (let [value (let [name (recall-or-recompute (CellParse. cell-id))]
                 (if (instance? Error name) name
                     (recall-or-recompute (Value. (:name name)))))]
     (pr-str value))])

(defn editor-and-output [cell-id]
  [:div
   [:div
    {:style {:border (if (= (@codes cell-id) (recall-or-recompute (CellCode. cell-id))) "1px solid #eee" "1px solid #bbb")}}
    [editor cell-id]]
   [output cell-id]
   [:div {:style {:padding "1rem"}}]])

(defn debug []
  [:div
   [:hr {:style {:margin "2rem"}}]
   (doall (for [[id value] (sort-by #(pr-str (first %)) (@state :id->value))]
            (let [color (if (instance? Error value) "red" "black")]
              ^{:key (pr-str id)} [:div
                                   [:span {:style {:color "blue"}} "v" (pr-str (get-in @state [:id->version id]))]
                                   " "
                                   [:span {:style {:font-weight "bold" :color color}} (pr-str id)]
                                   " "
                                   (pr-str value)
                                   " "
                                   [:span {:style {:color "grey"}} (pr-str (sort-by pr-str (keys (get-in @state [:id->deps id]))))]])))])

(defn app []
  [:div
   [:div (for [cell-id (recall-or-recompute (CellIds.))]
           ^{:key cell-id} [editor-and-output cell-id])]
   [debug]])

(defn mount-root []
  (dom/render [app] (.getElementById js/document "app"))
  ;; for some reason eval fails if we run it during load
  #_(js/setTimeout #(queue-recall-or-recompute-all) 1))

(defn init! []
  (mount-root))

(init!)
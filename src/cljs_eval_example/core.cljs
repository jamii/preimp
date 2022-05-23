(ns cljs-eval-example.core
  (:require-macros [cljs-eval-example.core :refer [analyzer-state]])
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

(defn d [& args] (prn args) (last args))

;; --- util ---

(def eval-config
  {:eval js-eval
   :source-map true
   :context :expr})

(defn eval-form [state form]
  (let [result (atom nil)]
    (cljs.js/eval state `(let [~'edit! ~'cljs-eval-example.core/edit!] ~form) eval-config #(reset! result %))
    ;; while eval can be async, it usually isn't
    (assert @result)
    @result))

(def eval-state (empty-state))
(cljs.js/load-analysis-cache! eval-state 'clojure.string (analyzer-state 'clojure.string))
(cljs.js/load-analysis-cache! eval-state 'cljs-eval-example.core (analyzer-state 'cljs-eval-example.core))

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

(defrecord Code [])

(defrecord Defs []
  Incremental
  (compute* [this compute]
    (let [code (compute (Code.))
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
          (swap! defs conj {:form form :kind kind :name name :body body})))
      @defs)))

(defrecord Names []
  Incremental
  (compute* [this compute]
    (let [defs (compute (Defs.))]
      (into (sorted-set) (for [def defs] (:name def))))))

(defrecord Def [name]
  Incremental
  (compute* [this compute]
    (let [all-defs (compute (Defs.))
          matching-defs (filter #(= name (:name %)) all-defs)]
      (case (count matching-defs)
        0 (throw [:undefined name])
        1 (first matching-defs)
        2 (throw [:multiple-defs name])))))

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

(def cm (atom nil))

(def state
  (r/atom {;; version increments on every change made from the outside
           :version 0

      ;; the last version at which this id was computed
           :id->version {(Code.) 0}

      ;; the value when this id was last computed
      ;; (may be an Error)
           :id->value {(Code.) ""}

      ;; other id/value pairs that were used to compute this id
           :id->deps {}

      ;; the set of ids which were recomputed in the last recompute
      ;; (used only for debugging) 
           :recomputed #{}}))

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

(defn recompute [id]
  (let [new-deps (atom {})
        new-value (try
                    (compute* id (fn [id]
                                   (let [value (recall-or-recompute id)]
                                     (swap! new-deps assoc id value)
                                     (if (instance? Error value)
                                       (throw (:error value))
                                       value))))
                    #_(catch :default error
                        (Error. error)))]
    (swap! state update-in [:id->version] assoc id (@state :version))
    (swap! state update-in [:id->value] assoc id new-value)
    (swap! state update-in [:id->deps] assoc id @new-deps)
    (swap! state update-in [:recomputed] conj id)
    new-value))

(defn recall-or-recompute [id]
  (cond
    (not (contains? (@state :id->value) id))
    (recompute id)

    (not= (:version @state) (get-in @state [:id->version id]))
    (if (deps-changed? id)
      (recompute id)
      (do
        (swap! state assoc-in [:id->version id] (get-in @state [:id->version id]))
        (get-in @state [:id->value id])))

    :else
    (get-in @state [:id->value id])))

(defn recall-or-recompute-all []
  (swap! state assoc :recomputed #{} :error nil)
  (try
    (recall-or-recompute (Value. 'app))
    (catch :default err (swap! state assoc :error err))))

(def needs-recall-or-recompute-all (atom false))

(defn unqueue-recall-or-recompute-all []
  (when @needs-recall-or-recompute-all
    (reset! needs-recall-or-recompute-all false)
    (recall-or-recompute-all)))

(defn queue-recall-or-recompute-all []
  (reset! needs-recall-or-recompute-all true)
  (js/setTimeout #(unqueue-recall-or-recompute-all) 0))

(defn edit! [name f & args]
  (let [form (get-in @state [:id->value (Def. name) :form])
        old-value (get-in @state [:id->value (Value. name)])
        new-value (apply f old-value args)]
    (.setValue @cm (replace-defs (meta form) name (.getValue @cm) new-value))
    (change-input (Code.) (.getValue @cm))
    (change-input (Value. name) new-value)
    (queue-recall-or-recompute-all)))

(defn editor []
  (r/create-class
   {:render (fn [] [:textarea
                    {:defaultValue (or (.. js/window.localStorage (getItem "preimp")) "")
                     :auto-complete "off"}])
    :component-did-mount (fn [this]
                           (reset! cm (.fromTextArea js/CodeMirror
                                                     (dom/dom-node this)
                                                     #js {:mode "clojure"
                                                          :lineNumbers true
                                                          :extraKeys #js {"Ctrl-Enter" (fn [_]
                                                                                         (change-input (Code.) (.getValue @cm))
                                                                                         (queue-recall-or-recompute-all))}
                                                          :matchBrackets true}))
                           (.on @cm "change" #(.. js/window.localStorage (setItem "preimp" (.getValue @cm)))))}))

(defn output-view []
  [:div
   ^{:key :app} [:div (get-in @state [:id->value (Value. 'app)])]
   #_[:div ":debug"
      [:div (pr-str :recomputed) (doall (for [id (sort-by pr-str (@state :recomputed))] [:div [:span {:style {:font-weight "bold"}} (pr-str id)]]))]
      [:div (pr-str :value)
       (doall (for [[id value] (sort-by #(pr-str (first %)) (@state :id->value))]
                (let [color (if (instance? Error value) "red" "black")]
                  [:div
                   [:span {:style {:color "blue"}} "v" (pr-str (get-in @state [:id->version id]))]
                   " "
                   [:span {:style {:font-weight "bold" :color color}} (pr-str id)]
                   " "
                   (pr-str value)
                   " "
                   [:span {:style {:color "grey"}} (pr-str (sort-by pr-str (keys (get-in @state [:id->deps id]))))]])))]]])

(defn err-boundary
  [& children]
  (r/create-class
   {:display-name "ErrBoundary"
    :component-did-catch (fn [err info]
                           (swap! state assoc :error [err info]))
    :reagent-render (fn [& children]
                      (if-let [err (get-in @state [:error])]
                        [:pre [:code (pr-str err)]]
                        (into [:<>] children)))}))

(defn app []
  [:div
   [editor]
   [:div
    [err-boundary [output-view]]]])

(defn mount-root []
  (dom/render [app] (.getElementById js/document "app"))
  ;; for some reason eval fails if we run it during load
  (js/setTimeout
   (fn []
     (change-input (Code.) (.getValue @cm))
     (queue-recall-or-recompute-all))
   1))

(defn init! []
  (mount-root))

(init!)
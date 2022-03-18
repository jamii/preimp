(ns cljs-eval-example.core
  (:require-macros [cljs-eval-example.core :refer [analyzer-state]])
  (:require
   [reagent.dom :as dom]
   [reagent.core :as reagent :refer [atom]]
   [cljs.js :refer [empty-state eval-str js-eval]]
   [cljs.pprint :refer [pprint]]
   [cljs.reader :refer [read-string]]))

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

(defn replace-var [line-col var code new-value]
  (let [[start-ix end-ix] (line-col->ix line-col code)]
    (str (subs code 0 start-ix)
         (pr-str `(def ~var ~new-value))
         (subs code end-ix))))

(def cm (atom nil))

(def output (atom {:code ""
                   :graph {:names []
                           :name->kind {}
                           :name->form {}
                           :name->deps {}
                           :errors []}
                   :state {}
                   :error nil}))

;; TODO this doesn't handle shadowing global names
(defn names-into! [form names]
  (cond
    (or (list? form) (vector? form) (map? form))
    (doseq [subform form] (names-into! subform names))

    (symbol? form)
    (swap! names conj form)))

(defn code->graph [code]
  (let [reader (cljs.tools.reader.reader-types.indexing-push-back-reader code)
        forms (atom [])
        names (atom [])
        name->kind (atom {})
        name->form (atom {})
        name->deps (atom {})
        name->def-deps (atom {})
        name->defn-deps (atom {})
        errors (atom [])]
    (while (cljs.tools.reader.reader-types.peek-char reader)
      ;; reset gensym ids so repeated reads are always identical
      (reset! cljs.tools.reader.impl.utils/last-id 0)
      (swap! forms conj (cljs.tools.reader.read reader)))
    (doseq [form @forms]
      (if-not (list? form)
        (swap! errors conj {:not-list form})
        (let [kind (nth form 0 nil)
              name (nth form 1 nil)]
          (if-not (#{'def 'defn} kind)
            (swap! errors conj {:no-name form})
            (do
              (swap! names conj name)
              (swap! name->kind assoc name kind)
              (swap! name->form assoc name form))))))
    (doseq [[name form] @name->form]
      (let [deps (atom #{})]
        (names-into! form deps)
        (swap! name->deps assoc name (into #{} (filter #(and (not= name %) (contains? @name->kind %)) @deps)))))
    (doseq [name @names]
      (let [deps (get @name->deps name)
            def-deps (atom #{})
            defn-deps (atom #{})]
        (doseq [dep deps]
          (case (get @name->kind dep)
            def
            (swap! def-deps conj dep)

            defn
            (do
              (swap! defn-deps conj dep)
              (swap! defn-deps clojure.set/union (get @name->defn-deps dep))
              (swap! def-deps clojure.set/union (get @name->def-deps dep)))))
        (swap! name->def-deps assoc name @def-deps)
        (swap! name->defn-deps assoc name @defn-deps)))
    {:names @names
     :name->kind @name->kind
     :name->form @name->form
     :name->deps @name->deps
     :name->def-deps @name->def-deps
     :name->defn-deps @name->defn-deps
     :errors @errors}))

(def eval-config
  {:eval js-eval
   :source-map true
   :context :statement})

(defn eval-form [state form]
  (let [result (atom nil)]
    (cljs.js/eval state form eval-config #(reset! result %))
    ;; while eval can be async, it usually isn't
    (assert @result)
    @result))

(defn refresh [old-state old-graph new-graph]
  (let [new-state (atom {})
        eval-state (empty-state)
        error (atom nil)
        re-evaled (atom #{})
        unchanged?
        (fn [name]
          (and
           (= (-> old-graph :name->kind name) (-> new-graph :name->kind name))
           (case (-> new-graph :name->kind name)
             defn (= (-> old-graph :name->form name) (-> new-graph :name->form name))
             def (= (old-state name) (@new-state name)))))
        can-reuse?
        (fn [name]
          (and
           (= (-> old-graph :name->kind name) (-> new-graph :name->kind name))
           (= (-> old-graph :name->form name) (-> new-graph :name->form name))
           (case (-> new-graph :name->kind (get name))
             defn
             true

             def
             (and
              (every? unchanged? (-> new-graph :name->def-deps name))
              (every? unchanged? (-> new-graph :name->defn-deps name))))))]
    (cljs.js/load-analysis-cache! eval-state 'clojure.string (analyzer-state 'clojure.string))
    (eval-form eval-state (cljs.tools.reader.read-string "(def edit! js/cljs_eval_example.core.edit_BANG_)"))
    (doseq [name (:names new-graph)]
      (when-not @error
        (if (can-reuse? name)
          (swap! new-state assoc name (old-state name))
          (let [result (eval-form eval-state (-> new-graph :name->form name))]
            (swap! re-evaled conj name)
            (if (:error result)
              (do
                (reset! error (:error result))
                nil)
              (swap! new-state assoc name (:value result)))))))
    {:eval-state eval-state :state @new-state :re-evaled @re-evaled :error @error}))

(defn run []
  (let [old-graph (@output :graph)
        old-state (@output :state)
        new-code (.getValue @cm)
        new-graph (code->graph new-code)
        refreshed (refresh old-state old-graph new-graph)]
    (reset! output (merge refreshed {:code new-code
                                     :graph new-graph}))))

(defn edit! [var f & args]
  (let [form (-> @output :graph :name->form (get var))
        old-value (-> @output :state (get var))
        new-value (apply f old-value args)]
    (.setValue @cm (replace-var (meta form) var (.getValue @cm) new-value))
    (run)))

(defn editor []
  (reagent/create-class
   {:render (fn [] [:textarea
                    {:defaultValue (or (.. js/window.localStorage (getItem "preimp")) "")
                     :auto-complete "off"}])
    :component-did-mount (fn [this]
                           (reset! cm (.fromTextArea js/CodeMirror
                                                     (dom/dom-node this)
                                                     #js {:mode "clojure"
                                                          :lineNumbers true
                                                          :extraKeys #js {"Ctrl-Enter" run}}))

                           (.on @cm "change" #(.. js/window.localStorage (setItem "preimp" (.getValue @cm)))))}))

(defn output-view []
  [:div
   [:div (or (-> @output :state (get 'app)) (pr-str (:error @output)))]
   [:div (pr-str {:re-evaled (-> @output :re-evaled)})]
   [:div (pr-str {:error (-> @output :error)})]])

(defn home-page []
  [:div
   [editor]
   [:div
    [output-view]]])

(defn mount-root []
  (dom/render [home-page] (.getElementById js/document "app"))
  ;; for some reason eval fails if we run it during load
  (js/setTimeout #(run) 1))

(defn init! []
  (mount-root))

(ns cljs-eval-example.core
  (:require-macros [cljs-eval-example.core :refer [analyzer-state]])
  (:require
   [reagent.dom :as dom]
   [reagent.core :as reagent :refer [atom]]
   [cljs.js :refer [empty-state eval-str js-eval]]
   [cljs.pprint :refer [pprint]]
   [cljs.reader :refer [read-string]]))

(defn var->line-col [state var]
  (-> state
      :cljs.analyzer/namespaces
      (get 'cljs.user)
      :defs
      (get var)
      (select-keys [:line :column])))

(defn var->ix [state var code]
  (let [line-col (var->line-col state var)
        lines (clojure.string/split code "\n")
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

(defn replace-var [state var code new-value]
  (let [[start-ix end-ix] (var->ix state var code)]
    (str (subs code 0 start-ix)
         (pr-str `(def ~var ~new-value))
         (subs code end-ix))))

(defn var->value [var]
  (js/eval (str (cljs.compiler.munge (symbol "cljs.user" var)))))

(def cm (atom nil))

(def output (atom [:div "loading..."]))

(defn run []
  (let [input (.getValue @cm)
        state (empty-state)]
    (cljs.js/load-analysis-cache! state 'clojure.string (analyzer-state 'clojure.string))
    (eval-str
     state
     "(def edit! js/cljs_eval_example.core.edit_BANG_)"
     nil
     {:eval       js-eval
      :source-map true
      :context    :statement}
     (fn [_]
       (eval-str
        state
        input
        nil
        {:eval       js-eval
         :source-map true
         :context    :statement}
        (fn [result]
          (reset! output (merge result {:input input
                                        :code (read-string input)
                                        :state state}))))))))

(defn edit! [var f & args]
  (let [state @(:state @output)
        old-value (var->value var)
        new-value (apply f old-value args)]
    (.setValue @cm (replace-var state var (.getValue @cm) new-value))
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
  [:div (or (:value @output) (pr-str (:error @output)))])

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

(ns cljs-eval-example.core
  (:require
   [reagent.dom :as dom]
   [reagent.core :as reagent :refer [atom]]
   [cljs.js :refer [empty-state eval-str js-eval]]
   [cljs.pprint :refer [pprint]]))

(def cm (atom nil))

(def output (atom nil))

(defn run []
  (eval-str
     (empty-state)
     (.getValue @cm)
     nil
     {:eval       js-eval    
      :source-map true
      :context    :statement}
     (fn [result]
       (reset! output result))))

(defn editor []
  (reagent/create-class
   {:render (fn [] [:textarea
                    {:defaultValue (or (.. js/window.localStorage (getItem "preimp")) "")
                     :auto-complete "off"}])
    :component-did-mount (fn [this]
      (reset! cm (.fromTextArea js/CodeMirror
                 (dom/dom-node this)
                 #js {
                   :mode "clojure"
                   :lineNumbers true
                   :extraKeys #js {
                     "Ctrl-Enter" run
                   }
                 })))}))

(defn output-view []
  [:pre>code.clj (pr-str @output)])

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

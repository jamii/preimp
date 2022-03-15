(ns cljs-eval-example.core
  (:require
   [reagent.dom :as dom]
   [reagent.core :as reagent :refer [atom]]
   [cljs.js :refer [empty-state eval-str js-eval]]
   [cljs.pprint :refer [pprint]]))

(defn evaluate [s cb]
  (eval-str
     (empty-state)
     s
     nil
     {:eval       js-eval    
      :source-map true
      :context    :statement}
     cb))
    
(def input (atom nil))
(def output (atom nil))
(defn run [] (evaluate @input (fn [result] (reset! output (str result)))))

(defn editor-did-mount [input]
  (fn [this]
    (let [cm (.fromTextArea  js/CodeMirror
                             (dom/dom-node this)
                             #js {:mode "clojure"
                                  :lineNumbers true
                                  :extraKeys #js {
                                      "Ctrl-Enter" run
                                  }})]
      (.on cm "change" #(reset! input (.getValue %))))))

(defn editor [input]
  (reagent/create-class
   {:render (fn [] [:textarea
                    {:default-value ""
                     :auto-complete "off"}])
    :component-did-mount (editor-did-mount input)}))

(defn result-view [output]
  [:pre>code.clj
    (with-out-str (pprint @output))])

(defn home-page []
      [:div
       [editor input]
       [:div
        [:button
         {:on-click run}
         "run"]]
       [:div
        [result-view output]]])

(defn mount-root []
  (dom/render [home-page] (.getElementById js/document "app")))

(defn init! []
  (mount-root))

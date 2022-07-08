(ns preimp.embedded
  (:require
    clojure.string
    [reagent.dom :as dom]
    preimp.core
    [preimp.core :as core]
    [preimp.state :as state]))

(defn init! []
  (swap! core/state assoc :online-mode? false)
  (doseq [dom-node (js/document.querySelectorAll "pre.language-preimp")]
    (let [code (clojure.string/trim (.-innerText dom-node))
          cell-id (state/new-cell-id)
          div (js/document.createElement "div")]
      (core/insert-ops #{(state/->InsertOp nil (@core/state :client-id) cell-id nil)
                         (state/->AssocOp nil (@core/state :client-id) cell-id :code code)})
      (.replaceChild (.-parentNode dom-node) div dom-node)
      (dom/render [core/editor-and-output cell-id] div))))

(init!)
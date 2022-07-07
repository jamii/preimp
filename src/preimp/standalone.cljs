(ns preimp.standalone
  (:require
    [reagent.dom :as dom]
    [preimp.core :as core]))

(defn app []
  [:div
   [:div (for [cell-id (core/recall-or-recompute (core/CellIds.))]
           ^{:key cell-id}
           [core/cell-name cell-id])]
   (when-let [cell-id (@core/state :focused-cell-id)]
     [core/editor-and-output cell-id])
   [:button

    {:on-click (fn []
                 (swap! core/state update-in [:online-mode?] not)
                 (if (@core/state :online-mode?)
                   (core/connect)
                   (core/disconnect)))}
    (if (@core/state :online-mode?)
      "go offline"
      "go online")]
   [:button
    {:on-click #(core/insert-cell-after nil)}
    "add cell"]
   [:button
    {:on-click #(swap! core/state update-in [:show-debug-panel?] not)}
    (if (@core/state :show-debug-panel?) "close debug panel" "show debug panel")]
   (when (@core/state :show-debug-panel?)
     [core/debug])])

(defn init! []
  (core/connect)
  (dom/render [app] (.getElementById js/document "app")))

(init!)
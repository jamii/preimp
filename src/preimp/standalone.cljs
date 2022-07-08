(ns preimp.standalone
  (:require
    [reagent.dom :as dom]
    [preimp.core :as core]))

(defn app []
  [:div
   [:div
    {:style {:display "flex"
             :flex-direction "row"}}
    [:div
     {:style {:flex "none"}}
     (for [cell-id (core/recall-or-recompute (core/CellIds.))]
       ^{:key cell-id}
       [core/cell-name cell-id])
     [:div
      {:style {:padding "1em"}}]
     [:div
      [:button
       {:on-click (fn []
                    (swap! core/state update-in [:online-mode?] not)
                    (if (@core/state :online-mode?)
                      (core/connect)
                      (core/disconnect)))}
       (if (@core/state :online-mode?)
         "go offline"
         "go online")]]
     [:div
      [:button
       {:on-click #(core/insert-cell-after nil)}
       "add cell"]]
     [:div
      [:button
       {:on-click #(swap! core/state update-in [:show-debug-panel?] not)}
       (if (@core/state :show-debug-panel?) "close debug panel" "show debug panel")]]
     [:div
      [:button
       {:on-click core/export}
       "export"]]]
    [:div
     {:style {:padding "1em"
              :border-right "1px solid black"}}]
    [:div
     {:style {:padding "1em"}}]
    [:div
     {:style {:flex "flex-grow"}}
     (when-let [cell-id (@core/state :focused-cell-id)]
       [core/editor-and-output cell-id])]]
   (when (@core/state :show-debug-panel?)
     [core/debug])])

(defn init! []
  (core/connect)
  (dom/render [app] (.getElementById js/document "app")))

(init!)
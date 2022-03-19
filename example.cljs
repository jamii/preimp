(def todos {})

(def next-id 18)

(def input-value {"new-todo" ""})

(def editing #{})

(def filt :all)

(defn add-todo [text]
  (let [id next-id]
    (edit! 'next-id inc)
    (edit! 'todos assoc id {:id id :title text :done false})))

(defn toggle [id] (edit! 'todos update-in [id :done] not))
(defn save [id title] (edit! 'todos assoc-in [id :title] title))
(defn delete [id] (edit! 'todos dissoc id))

(defn complete-all [b]
  (doseq [id (keys todos)]
    (edit! 'todos assoc-in [id :done] b)))

(defn clear-done []
  (doseq [id (keys todos)]
    (when (get-in todos [id :done])
      (delete id))))

(defn todo-input [{:keys [id class placeholder title on-save on-stop]}]
  (let [value (get input-value id "")
        stop #(do (edit! 'input-value dissoc id)
                  (if on-stop (on-stop)))
        save #(let [v (-> value str clojure.string/trim)]
                (if-not (empty? v) (on-save v))
                (stop))]
    [:input {:type "text" :value value
             :id id :class class :placeholder placeholder
             :on-blur save
             :on-change (fn [e] (edit! 'input-value assoc id (-> e .-target .-value)))
             :on-key-down #(case (.-which %)
                             13 (save)
                             27 (stop)
                             nil)}]))

(defn todo-edit [props]
  (todo-input props)
  #_(with-meta (todo-input props)
      {:component-did-mount #(.focus (rdom/dom-node %))}))

(defn todo-stats [{:keys [active done]}]
  (let [props-for (fn [name]
                    {:class (if (= name filt) "selected")
                     :on-click #(edit! 'filt (fn [] name))})]
    [:div
     [:span#todo-count
      [:strong active] " " (case active 1 "item" "items") " left"]
     [:ul#filts
      [:li [:a (props-for :all) "All"]]
      [:li [:a (props-for :active) "Active"]]
      [:li [:a (props-for :done) "Completed"]]]
     (when (pos? done)
       [:button#clear-completed {:on-click clear-done}
        "Clear completed " done])]))

(defn todo-item []
  (fn [{:keys [id done title]}]
    [:li {:class (str (if done "completed ")
                      (if (contains? editing id) "editing"))}
     [:div.view
      [:input.toggle {:type "checkbox" :checked done
                      :on-change #(toggle id)}]
      [:label {:on-double-click #(edit! 'editing conj id)} title]
      [:button.destroy {:on-click #(delete id)}]]
     (when (contains? editing id)
       [todo-edit {:id id
                   :class "edit" :title title
                   :on-save #(save id %)
                   :on-stop #(edit! 'editing disj id)}])]))

(def app
  (let [items (vals todos)
        done (->> items (filter :done) count)
        active (- (count items) done)]
    [:div
     [:section#todoapp
      [:header#header
       [:h1 "todos"]
       (todo-input {:id "new-todo"
                    :placeholder "What needs to be done?"
                    :on-save add-todo})]
      (when (-> items count pos?)
        [:div
         [:section#main
          [:input#toggle-all {:type "checkbox" :checked (zero? active)
                              :on-change #(complete-all (pos? active))}]
          [:label {:for "toggle-all"} "Mark all as complete"]
          [:ul#todo-list
           (for [todo (filter (case filt
                                :active (complement :done)
                                :done :done
                                :all identity) items)]
             ^{:key (:id todo)} [todo-item todo])]]
         [:footer#footer
          [todo-stats {:active active :done done :filt filt}]]])]
     [:footer#info
      [:p "Double-click to edit a todo"]]]))
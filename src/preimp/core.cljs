(ns preimp.core
  (:require-macros [preimp.core :refer [analyzer-state]])
  (:require
   cljsjs.codemirror
   cljsjs.codemirror.mode.clojure
   cljsjs.codemirror.addon.edit.matchbrackets
   cljsjs.codemirror.addon.comment.comment
   [reagent.dom :as dom]
   [reagent.core :as r]
   cljs.js
   preimp.state
   clojure.edn
   clojure.set
   cljs.tools.reader.impl.utils))

(defn d [& args] (js/console.log (pr-str args)) (last args))

;; --- state ---

(defrecord Ops [])
(defrecord Error [error])

(def client (random-uuid))

(def state
  (r/atom
   {:websocket nil

    :connect-retry-timeout 100

    ;; the codemirror object for each cell
    :cell-id->codemirror {}

    ;; code that was in each codemirror when it was last focused
    :code-at-focus {}

    ;; code that is currently in each codemirror
    :code-now {}

    ;; cell-id that was most recently inserted
    ;; (used for autofocus on mount)
    :last-inserted nil

    ;; version increments on every change made from the outside
    :version 0

    ;; the last version at which this id was computed
    :id->version {(Ops.) 0}

    ;; the value when this id was last computed
    ;; (may be an Error)
    :id->value {(Ops.) #{}}

    ;; other id/value pairs that were used to compute this id
    :id->deps {}

    :show-debug-panel? true

    :online-mode? true}))

;; --- compiler stuff ---

(def eval-state (cljs.js/empty-state))
(cljs.js/load-analysis-cache! eval-state 'clojure.string (analyzer-state 'clojure.string))
(cljs.js/load-analysis-cache! eval-state 'preimp.core (analyzer-state 'preimp.core))

(def eval-config
  {:eval cljs.js/js-eval
   :source-map true
   :context :expr
   :ns 'preimp.core})

(defn eval-form [state form]
  (let [result (atom nil)]
    (cljs.js/eval eval-state form eval-config #(reset! result %))
    ;; while eval can be async, it usually isn't
    (assert @result)
    @result))

;; TODO this doesn't handle shadowing global names
(defn names-into! [form names]
  (cond
    (or (list? form) (vector? form) (map? form))
    (doseq [subform form] (names-into! subform names))

    (symbol? form)
    (swap! names conj form)))

;; --- incremental core ---

(defprotocol Incremental
  (compute* [this compute]))

(declare recall-or-recompute)

(defn deps-changed? [id]
  (some
   (fn [[dep dep-value]]
     (not= (recall-or-recompute dep) dep-value))
   (get-in @state [:id->deps id])))

(defn stale? [id]
  (or
   (not (contains? (@state :id->value) id))
   (and (not= (get-in @state [:id->version id]) (:version @state))
        (deps-changed? id))))

(defn recompute [id]
  ;(d :recompute id)
  (let [old-value (get-in @state [:id->value id])
        new-deps (atom {})
        new-value (try
                    (compute* id (fn [id]
                                   (let [value (recall-or-recompute id)]
                                     (swap! new-deps assoc id value)
                                     (if (instance? Error value)
                                       (throw (:error value))
                                       value))))
                    (catch :default error
                      (Error. error)))]
    (swap! state assoc-in [:id->version id] (:version @state))
    (when (not= old-value new-value)
      (swap! state assoc-in [:id->value id] new-value))
    (swap! state assoc-in [:id->deps id] @new-deps)
    new-value))

(defn recall-or-recompute [id]
  (if (stale? id)
    (recompute id)
    (do
      (swap! state assoc-in [:id->version id] (:version @state))
      (get-in @state [:id->value id]))))

;; --- incremental nodes ---

(defrecord State []
  Incremental
  (compute* [this compute]
    (preimp.state/ops->state (compute (Ops.)))))

(defrecord CellIds []
  Incremental
  (compute* [this compute]
    (:cell-ids (compute (State.)))))

(defrecord CellMap [id]
  Incremental
  (compute* [this compute]
    (or
     (get-in (compute (State.)) [:cell-maps id])
     "")))

(defrecord CellParse [id]
  Incremental
  (compute* [this compute]
    (let [code (:code (compute (CellMap. id)))
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

                     defn `(fn [~@deps] (fn ~name ~@(:body def))))
              thunk (eval-form (atom @eval-state) form)]
          (if-let [error (:error thunk)]
            (throw error)
            {:thunk (:value thunk)
             :args deps}))))))

(defrecord Value [name]
  Incremental
  (compute* [this compute]
    (let [def (compute (Def. name))]
      (if (= 'defs (:kind def))
        (-> def :body last)
        (let [thunk (compute (Thunk. name))
              args (for [arg (:args thunk)] (compute (Value. arg)))]
          (apply (:thunk thunk) args))))))

(declare send-ops)

(defn change-input [id value]
  (swap! state update-in [:version] inc)
  (swap! state assoc-in [:id->version id] (:version @state))
  (swap! state assoc-in [:id->value id] value)
  (when (instance? Ops id)
    (send-ops)))

(defn update-cell [cell-id]
  (let [new-value (.getValue (get (@state :cell-id->codemirror) cell-id))
        old-ops (recall-or-recompute (Ops.))
        new-ops (preimp.state/assoc-cell old-ops client cell-id :code new-value)]
    (change-input (Ops.) new-ops)))

(defn insert-cell-after [prev-cell-id]
  (let [new-cell-id (random-uuid)
        old-ops (recall-or-recompute (Ops.))
        new-ops (-> old-ops
                    (preimp.state/insert-cell client new-cell-id prev-cell-id)
                    (preimp.state/assoc-cell client new-cell-id :code "")
                    (preimp.state/assoc-cell client new-cell-id :visibility :code-and-output))]
    (swap! state assoc :last-inserted new-cell-id)
    (change-input (Ops.) new-ops)))

(defn insert-cell-before [next-cell-id]
  (let [cell-ids (recall-or-recompute (CellIds.))
        next-ix (.indexOf cell-ids next-cell-id)
        prev-cell-id (if (= next-ix 0) nil (get cell-ids (dec next-ix)))]
    (insert-cell-after prev-cell-id)))

(defn remove-cell [cell-id]
  (let [old-ops (recall-or-recompute (Ops.))
        new-ops (preimp.state/remove-cell old-ops client cell-id)]
    (change-input (Ops.) new-ops)))

;; --- network ---

(defn send-ops []
  (d :sending (count (recall-or-recompute (Ops.))))
  (try
    (.send (@state :websocket) (pr-str {:client client :ops (recall-or-recompute (Ops.))}))
    (catch :default error (d :ws-send-error error))))

(declare update-codemirrors)

(defn connect []
  (when (@state :online-mode?)
    (d :connecting)
    (swap! state update-in [:connect-retry-timeout] * 2)
    (let [ws-protocol (case js/location.protocol "https:" "wss:" "http:" "ws:")
          ws-address (str ws-protocol "//" js/location.host "/")]
      (swap! state assoc :websocket (new js/WebSocket. ws-address)))
    (set! (.-onopen (@state :websocket))
          (fn [_]
            (swap! state assoc :connect-retry-timeout 100)
            (send-ops)))
    (set! (.-onmessage (@state :websocket))
          (fn [event]
            (let [old-ops (recall-or-recompute (Ops.))
                  server-ops (clojure.edn/read-string
                              {:readers preimp.state/readers}
                              (.-data event))
                  _ (d :receiving (count server-ops))
                  new-ops (clojure.set/union old-ops server-ops)]
              (when (not= old-ops new-ops)
                (change-input (Ops.) new-ops)
                (update-codemirrors)))))
    (set! (.-onerror (@state :websocket))
          (fn [error]
            (d :ws-error error)
            (.close (@state :websocket))))
    (set! (.-onclose (@state :websocket))
          (fn []
            (js/setTimeout connect (@state :connect-retry-timeout))))))

(defn disconnect []
  (d :disconnecting)
  (.close (@state :websocket))
  (swap! state assoc :connect-retry-timeout 100))

;; --- gui ---

(defn editor [cell-id]
  (r/create-class
   {:render
    (fn [] [:textarea])
    :component-did-mount
    (fn [this]
      (let [value (:code (recall-or-recompute (CellMap. cell-id)))
            codemirror (.fromTextArea
                        js/CodeMirror
                        (dom/dom-node this)
                        #js {:mode "clojure"
                             :lineNumbers false
                             :extraKeys #js {"Ctrl-Enter" (fn [_] (update-cell cell-id))
                                             "Shift-Enter" (fn [_]
                                                             (insert-cell-after cell-id)
                                                             (update-cell cell-id))
                                             "Shift-Alt-Enter" (fn [_]
                                                                 (insert-cell-before cell-id)
                                                                 (update-cell cell-id))
                                             "Ctrl-Backspace" (fn [_] (remove-cell cell-id))}
                             :matchBrackets true
                             :autofocus (= cell-id (@state :last-inserted))
                             :viewportMargin js/Infinity})]
        (.on codemirror "changes" (fn [_]
                                    (swap! state assoc-in [:code-now cell-id] (.getValue codemirror))))
        (.on codemirror "blur" (fn [_]
                                 (when (not= ((@state :code-now) cell-id) ((@state :code-at-focus) cell-id))
                                   (swap! state assoc-in [:code-at-focus cell-id] (.getValue codemirror))
                                   (update-cell cell-id))))
        (.on codemirror "focus" (fn [_]
                                  (swap! state assoc-in [:code-at-focus cell-id] (.getValue codemirror))))
        (swap! state assoc-in [:cell-id->codemirror cell-id] codemirror)
        (swap! state assoc-in [:code-at-focus cell-id] value)
        (swap! state assoc-in [:code-now cell-id] value)
        (.setValue codemirror value)))}))

(defn update-codemirrors []
  (doseq [cell-id (recall-or-recompute (CellIds.))
          :let [cell-code (:code (recall-or-recompute (CellMap. cell-id)))]]
    (when-let [code-mirror ((@state :cell-id->codemirror) cell-id)]
      (when (= ((@state :code-at-focus) cell-id) ((@state :code-now) cell-id))
        (.setValue code-mirror cell-code)))))

(defn fn-name [f]
  (cond
    (instance? cljs.core.MetaFn f)
    (or (:name (meta f))
        (fn-name (.-afn f)))

    (fn? f)
    (last (clojure.string/split (.-name f) "$"))

    :else
    (throw (str "Not a function: " (pr-str f)))))

(defn fn-num-args [f]
  (cond
    (instance? cljs.core.MetaFn f)
    (fn-num-args (.-afn f))

    (fn? f)
    (.-length f)

    :else
    (throw (str "Not a function: " (pr-str f)))))

(defn edn [value]
  (cond
    (fn? value)
    ;; TODO reagent can't tell when a function changes, so this doesn't update nicely
    (let [arg-ixes (range (fn-num-args value))
          args (into [] (for [_ arg-ixes] (r/atom "")))
          output (r/atom nil)]
      (fn [value]
        [:form
         {:action "function () {}"}
         (doall (for [[arg-ix arg] (map vector arg-ixes args)]
                  ^{:key arg-ix}
                  [:input
                   {:type "text"
                    :value @arg
                    :on-change (fn [event] (reset! arg (-> event .-target .-value)))}]))
         [:button
          {:on-click (fn [event]
                       (reset! output
                               (try (apply value (for [arg args]
                                                   (clojure.edn/read-string @arg)))
                                    (catch :default err (Error. err))))
                       (.preventDefault event))}
          (fn-name value)]
         (when @output
           [edn @output])]))

    (map? value)
    (let [value (try (sort value) (catch :default _ value))]
      [:table
       {:style {:border-left "1px solid black"
                :border-right "1px solid black"
                :border-radius "0.5em"
                :padding "0.5em"}}
       [:tbody
        (for [[k v] value]
          ^{:key (pr-str k)}
          [:tr
           [:td [edn k]]
           [:td [edn v]]])]])

    (vector? value)
    [:table
     {:style {:border-left "1px solid black"
              :border-right "1px solid black"
              :border-radius "0"
              :padding "0.5em"}}
     [:tbody
      (for [[elem i] (map vector value (range))]
        ^{:key i}
        [:tr
         [:td [edn elem]]])]]

    (set? value)
    (let [value (try (sort value) (catch :default _ value))]
      [:table
       {:style {:border-left "1px solid black"
                :border-right "1px solid black"
                :border-radius "0.5em"
                :padding "0.5em"}}
       [:tbody
        (for [[elem i] (map vector value (range))]
          ^{:key i}
          [:tr
           [:td [edn elem]]])]])
    :else
    [:code (pr-str value)]))

(defn output [cell-id]
  [:div
   (let [value (let [parse (recall-or-recompute (CellParse. cell-id))]
                 (if (instance? Error parse)
                   parse
                   (recall-or-recompute (Value. (:name parse)))))]
     [edn value])])

(defn toggle-visibility [cell-id old-visibility]
  (let [new-visibility (case old-visibility
                         :code-and-output :output
                         :output :none
                         :none :code-and-output)
        old-ops (recall-or-recompute (Ops.))
        new-ops (preimp.state/assoc-cell old-ops client cell-id :visibility new-visibility)]
    (change-input (Ops.) new-ops)))

(defn editor-and-output [cell-id]
  (let [visibility (or (:visibility (recall-or-recompute (CellMap. cell-id))) :code-and-output)]
    [:div
     [:button
      {:on-click #(toggle-visibility cell-id visibility)}
      (case visibility
        :code-and-output "--"
        :output "-"
        :none "+")]
     (if (= :code-and-output visibility)
       [:div
        {:style {:border (if (= ((@state :code-at-focus) cell-id) ((@state :code-now) cell-id)) "1px solid #eee" "1px solid #bbb")
                 :padding "0.5em"}}
        [editor cell-id]]
       [:div
        (if-let [name (:name (recall-or-recompute (CellParse. cell-id)))]
          [:span name]
          [:span {:style {:color "grey"}} "no name"])])
     (when (#{:output :code-and-output} visibility)
       [:div {:style {:padding "0.5em"}}
        [output cell-id]])
     [:div {:style {:padding "1rem"}}]]))

(defn debug []
  [:div
   (doall (for [[id value] (sort-by #(pr-str (first %)) (@state :id->value))]
            (let [color (if (instance? Error value) "red" "black")]
              ^{:key (pr-str id)} [:div
                                   [:span {:style {:color "blue"}} "v" (pr-str (get-in @state [:id->version id]))]
                                   " "
                                   [:span {:style {:font-weight "bold"}} (pr-str id)]
                                   " "
                                   [:span {:style {:color color}} (pr-str value)]
                                   " "
                                   [:span {:style {:color "grey"}} (pr-str (sort-by pr-str (keys (get-in @state [:id->deps id]))))]])))])

(defn app []
  [:div
   [:div (for [cell-id (recall-or-recompute (CellIds.))]
           ^{:key cell-id} [editor-and-output cell-id])]
   [:button

    {:on-click (fn []
                 (swap! state update-in [:online-mode?] not)
                 (if (@state :online-mode?)
                   (connect)
                   (disconnect)))}
    (if (@state :online-mode?)
      "go offline"
      "go online")]
   [:button
    {:on-click #(insert-cell-after nil)}
    "add cell"]
   [:button
    {:on-click #(swap! state update-in [:show-debug-panel?] not)}
    (if (@state :show-debug-panel?) "close debug panel" "show debug panel")]
   (when (@state :show-debug-panel?)
     [debug])])

(defn mount-root []
  (dom/render [app] (.getElementById js/document "app"))
  ;; for some reason eval fails if we run it during load
  #_(js/setTimeout #(queue-recall-or-recompute-all) 1))

;; --- fns exposed to cells ---

(defn edit! [name f & args]
  (let [def (recall-or-recompute (Def. name))]
    (if (instance? Error def)
      def
      (let [cell-id (:cell-id def)
            old-value (recall-or-recompute (Value. name))
            new-value (apply f old-value args)
            new-code (pr-str `(~'defs ~name ~new-value))
            old-ops (recall-or-recompute (Ops.))
            new-ops (preimp.state/assoc-cell old-ops client cell-id :code new-code)]
        (.setValue (get (@state :cell-id->codemirror) cell-id) new-code)
        (change-input (Ops.) new-ops)
        nil))))

;; --- init ---

(defn init! []
  (connect)
  (mount-root))

(init!)
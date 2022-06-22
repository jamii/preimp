(ns preimp.core
  (:require-macros [preimp.core :refer [analyzer-state]])
  (:require
   cljsjs.codemirror
   cljsjs.codemirror.mode.clojure
   cljsjs.codemirror.addon.edit.matchbrackets
   cljsjs.codemirror.addon.comment.comment
   [rum.core :as rum]
   cljs.js
   preimp.state
   clojure.edn
   clojure.set
   cljs.tools.reader
   cljs.tools.reader.impl.utils
   clojure.string))

(defn d [& args] (js/console.log (pr-str args)) (last args))

;; --- state ---

(defrecord Ops [])
(defrecord Error [error])

(def client (atom (random-uuid)))

(def state
  (atom
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

    :show-debug-panel? false

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
          reader (cljs.tools.reader.reader-types/indexing-push-back-reader code)
          defs (atom [])]
      (loop []

         ;; reset gensym ids so repeated reads are always identical
        (reset! cljs.tools.reader.impl.utils/last-id 0)
        (let [form (binding [cljs.tools.reader/*data-readers*
                             {'inst (fn [date] (new js/Date date))}]
                     (cljs.tools.reader/read {:eof ::eof} reader))]
          (when (not= form ::eof)
            (let [_ (when-not (list? form)
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
              (swap! defs conj {:cell-id id :form form :kind kind :name name :body body})
              (recur)))))
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
  (swap! state assoc-in [:id->value id] value))

(defn insert-ops [ops]
  (let [old-ops (recall-or-recompute (Ops.))
        version (preimp.state/next-version old-ops)
        ops (set (for [op ops] (assoc op :version version)))
        new-ops (preimp.state/union-ops old-ops ops)]
    (change-input (Ops.) new-ops)
    (send-ops ops)))

(defn update-cell [cell-id]
  (let [new-value (.getValue (get (@state :cell-id->codemirror) cell-id))]
    (insert-ops #{(preimp.state/->AssocOp nil @client cell-id :code new-value)})))

(defn insert-cell-after [prev-cell-id]
  (let [new-cell-id (random-uuid)]
    (swap! state assoc :last-inserted new-cell-id)
    (insert-ops #{(preimp.state/->InsertOp nil @client new-cell-id prev-cell-id)
                  (preimp.state/->AssocOp nil @client new-cell-id :code "")
                  (preimp.state/->AssocOp nil @client new-cell-id :visibility :code-and-output)})))

(defn insert-cell-before [next-cell-id]
  (let [cell-ids (recall-or-recompute (CellIds.))
        next-ix (.indexOf cell-ids next-cell-id)
        prev-cell-id (if (= next-ix 0) nil (get cell-ids (dec next-ix)))]
    (insert-cell-after prev-cell-id)))

(defn remove-cell [cell-id]
  (insert-ops #{(preimp.state/->DeleteOp nil @client cell-id)}))

(defn set-visibility [cell-id new-visibility]
  (insert-ops #{(preimp.state/->AssocOp nil @client cell-id :visibility new-visibility)}))

;; --- network ---

(defn send-ops [ops]
  (d :sending (count ops))
  (try
    (.send (@state :websocket) (pr-str {:client @client :ops ops}))
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
            ;; switch client so that sever-side tracking of what has been sent resets and we get a fresh start
            (reset! client (random-uuid))
            (send-ops (recall-or-recompute (Ops.)))))
    (set! (.-onmessage (@state :websocket))
          (fn [event]
            (let [old-ops (recall-or-recompute (Ops.))
                  server-ops (clojure.edn/read-string
                              {:readers preimp.state/readers}
                              (.-data event))
                  _ (d :receiving (count server-ops))
                  new-ops (preimp.state/compact-ops (clojure.set/union old-ops server-ops))]
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

#_(rum/set-warn-on-interpretation! true)

(def editor-mixin
  {:did-mount
   (fn [rum-state]
     (let [component (:rum/react-component rum-state)
           dom-node (js/ReactDOM.findDOMNode component)
           [cell-id] (:rum/args rum-state)
           value (:code (recall-or-recompute (CellMap. cell-id)))
           codemirror (.fromTextArea
                       js/CodeMirror
                       dom-node
                       #js {:mode "clojure"
                            :lineNumbers false
                            :extraKeys #js {"Ctrl-Enter" #(update-cell cell-id)
                                            "Shift-Enter" #(insert-cell-after cell-id)
                                            "Shift-Alt-Enter" #(insert-cell-before cell-id)
                                            "Ctrl-Backspace" #(remove-cell cell-id)}
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
       (.setValue codemirror value)
       rum-state))

   :will-unmount
   (fn [rum-state]
     (let [[cell-id] (:rum/args rum-state)
           codemirror (get-in @state [:cell-id->codemirror cell-id])]
       (swap! state update-in [:cell-id->codemirror] dissoc cell-id)
       (.toTextArea codemirror)
       rum-state))})

(rum/defc editor <
  editor-mixin
  [cell-id]
  [:textarea])

(defn update-codemirrors []
  (doseq [[cell-id code-mirror] (@state :cell-id->codemirror)
          :let [cell-code (:code (recall-or-recompute (CellMap. cell-id)))]]
    (when (= ((@state :code-at-focus) cell-id) ((@state :code-now) cell-id))
      (.setValue code-mirror cell-code))))

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

(declare edn)

(rum/defcs edn-hide <
  rum/static
  (rum/local true ::hidden)
  [local-state value]
  (let [hidden (::hidden local-state)]
    [:div
     [:button
      {:on-click #(swap! hidden not)}
      (if @hidden "+" "-")]
     (when-not @hidden
       (edn value))]))

(rum/defcs edn-fn <
  rum/static
  (rum/local nil ::args)
  (rum/local nil ::output)
  [local-state value]
  (let [arg-ixes (range (fn-num-args value))
        args (::args local-state)
        output (::output local-state)]
    (reset! args (into [] (for [_ arg-ixes] "")))
    [:form
     {:action "function () {}"}
     (doall (for [[arg-ix arg] (map vector arg-ixes @args)]
              [:input
               {:key arg-ix
                :type "text"
                :value arg
                :on-change (fn [event] (swap! args assoc arg-ix (-> event .-target .-value)))}]))
     [:button
      {:on-click (fn [event]
                   (reset! output
                           (try (apply value (for [arg @args]
                                               (clojure.edn/read-string arg)))
                                (catch :default err (Error. err))))
                   (.preventDefault event))}
      (fn-name value)]
     (when @output
       (edn @output))]))

(rum/defc edn <
  rum/static
  [value]
  (cond
    (contains? (meta value) :hide)
    (edn-hide (with-meta value {}))

    (fn? value)
    (edn-fn value)

    (map? value)
    (let [value (try (sort value) (catch :default _ value))]
      [:table
       {:style {:border-left "1px solid black"
                :border-right "1px solid black"
                :border-radius "0.5em"
                :padding "0.5em"}}
       [:tbody
        (for [[[k v] i] (map vector value (range))]
          [:tr
           {:key i}
           [:td (edn k)]
           [:td (edn v)]])]])

    (vector? value)
    [:table
     {:style {:border-left "1px solid black"
              :border-right "1px solid black"
              :border-radius "0"
              :padding "0.5em"}}
     [:tbody
      (for [[elem i] (map vector value (range))]
        [:tr
         {:key i}
         [:td (edn elem)]])]]

    (set? value)
    (let [value (try (sort value) (catch :default _ value))]
      [:table
       {:style {:border-left "1px solid black"
                :border-right "1px solid black"
                :border-radius "0.5em"
                :padding "0.5em"}}
       [:tbody
        (for [[elem i] (map vector value (range))]
          [:tr
           {:key i}
           [:td (edn elem)]])]])

    :else
    [:code (pr-str value)]))

(rum/defc output <
  [cell-id]
  [:div
   (let [value (let [parse (recall-or-recompute (CellParse. cell-id))]
                 (if (instance? Error parse)
                   parse
                   (recall-or-recompute (Value. (:name parse)))))]
     (edn value))])

(rum/defc visibility-button <
  [cell-id text new-visibility]
  [:div [:button
         {:on-click #(set-visibility cell-id new-visibility)}
         text]])

(rum/defc cell-name <
  [cell-id]
  (let [props {:on-click #(set-visibility cell-id :code-and-output)}]
    [:div
     (if-let [name (:name (recall-or-recompute (CellParse. cell-id)))]
       [:span props (str name)]
       [:span (merge props {:style {:color "grey"}}) "no name"])]))

(rum/defc editor-and-output <
  [cell-id]
  (let [visibility (or (:visibility (recall-or-recompute (CellMap. cell-id))) :code-and-output)]
    (conj
     (case visibility
       :none
       [:div
        (visibility-button cell-id "+" :output)
        (cell-name cell-id)]

       :output
       [:div
        (visibility-button cell-id "-" :none)
        (cell-name cell-id)
        [:div {:style {:padding "0.5em"}}
         (output cell-id)]]

       :code-and-output
       [:div
        (visibility-button cell-id "-" :none)
        (visibility-button cell-id "-" :output)
        [:div
         {:style {:border (if (= ((@state :code-at-focus) cell-id) ((@state :code-now) cell-id)) "1px solid #eee" "1px solid #bbb")
                  :padding "0.5em"}}
         (editor cell-id)]
        [:div {:style {:padding "0.5em"}}
         (output cell-id)]])
     [:div {:style {:padding "1em"}}])))

(rum/defc debug
  []
  [:div
   (doall (for [[id value] (sort-by #(pr-str (first %)) (@state :id->value))]
            (let [color (if (instance? Error value) "red" "black")]
              {:key (pr-str id)}
              [:div
               [:span {:style {:color "blue"}} "v" (pr-str (get-in @state [:id->version id]))]
               " "
               [:span {:style {:font-weight "bold"}} (pr-str id)]
               " "
               [:span {:style {:color color}} (pr-str value)]
               " "
               [:span {:style {:color "grey"}} (pr-str (sort-by pr-str (keys (get-in @state [:id->deps id]))))]])))])

(rum/defcs app <
  rum/reactive
  [rum-state]
  (rum/react state)
  [:div
   [:div (for [cell-id (recall-or-recompute (CellIds.))]
           (rum/with-key (editor-and-output cell-id) cell-id))]
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
   [:button
    {:on-click #(rum/request-render (:rum/react-component rum-state))}
    "rerender"]
   (when (@state :show-debug-panel?)
     (debug))])

(defn mount-root []
  (rum/mount (app) (.getElementById js/document "app")))

;; --- fns exposed to cells ---

(defn edit! [name f & args]
  (let [def (recall-or-recompute (Def. name))]
    (if (instance? Error def)
      def
      (let [cell-id (:cell-id def)
            old-value (recall-or-recompute (Value. name))
            new-value (apply f old-value args)
            new-code (pr-str `(~'defs ~name ~new-value))]
        (when-let [codemirror (get-in @state [:cell-id->codemirror cell-id])]
          (.setValue codemirror new-code))
        (insert-ops (preimp.state/->AssocOp nil @client cell-id :code new-code))
        nil))))

;; --- init ---

(defn init! []
  (connect)
  (mount-root))

(init!)
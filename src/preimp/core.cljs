(ns preimp.core
  (:require-macros
    [preimp.core :refer [analyzer-state]])
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
    cljs.tools.reader
    cljs.tools.reader.impl.utils
    clojure.string
    [fipp.edn :as fipp]))

(defn d [& args] (js/console.log (pr-str args)) (last args))

;; --- state ---

(defrecord Ops [])
(defrecord Error [error])

(def state
  (r/atom
    {;; --- network state ----

     :client-id (random-uuid)

     :websocket nil

     :connect-retry-timeout 100

     ;; --- gui state ---

     :focused-cell-id nil

     :show-debug-panel? false

     :online-mode? true

     ;; --- incremental eval state ---

     ;; version increments on every change made from the outside
     :version 0

     ;; the value when this id was last computed
     ;; (may be an Error)
     :id->value {(Ops.) #{}}

     ;; the version at which the currently cached value of this id was computed
     :id->last-changed-at-version {(Ops.) 0}

     ;; the version at which we last checked if the cached value of this id need to be recomputed
     :id->last-checked-at-version {(Ops.) 0}

     ;; the ids that were used during the last compute of this id
     :id->deps {}}))

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
  (let [last-checked (get-in @state [:id->last-checked-at-version id])]
    (some
      (fn [dep-id]
        (recall-or-recompute dep-id)
        (> (get-in @state [:id->last-changed-at-version dep-id]) last-checked))
      (get-in @state [:id->deps id]))))

(defn stale? [id]
  (or
    (not (contains? (@state :id->value) id))
    (and (not= (get-in @state [:id->last-checked-at-version id]) (:version @state))
      (deps-changed? id))))

(defn recompute [id]
  #_(d :recompute id)
  (let [old-value (get-in @state [:id->value id])
        new-deps (atom #{})
        new-value (try
                    (compute* id (fn [id]
                                   (let [value (recall-or-recompute id)]
                                     (swap! new-deps conj id)
                                     (if (instance? Error value)
                                       (throw (:error value))
                                       value))))
                    (catch :default error
                      (Error. error)))]
    (swap! state assoc-in [:id->last-checked-at-version id] (:version @state))
    (when (not= old-value new-value)
      (swap! state assoc-in [:id->last-changed-at-version id] (:version @state))
      (swap! state assoc-in [:id->value id] new-value))
    (swap! state assoc-in [:id->deps id] @new-deps)
    new-value))

(defn recall-or-recompute [id]
  (let [value (if (stale? id)
                (recompute id)
                (get-in @state [:id->value id]))]
    (swap! state assoc-in [:id->last-checked-at-version id] (:version @state))
    value))

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
  (when (not= value (get-in @state [:id->value id]))
    (swap! state update-in [:version] inc)
    (swap! state assoc-in [:id->last-checked-at-version id] (:version @state))
    (swap! state assoc-in [:id->last-changed-at-version id] (:version @state))
    (swap! state assoc-in [:id->value id] value)))

(defn insert-ops [ops]
  (let [old-ops (recall-or-recompute (Ops.))
        version (preimp.state/next-version old-ops)
        ops (set (for [op ops] (assoc op :version version)))
        new-ops (preimp.state/union-ops old-ops ops)]
    (change-input (Ops.) new-ops)
    (send-ops ops)))

(defn set-cell-code [cell-id code]
  (when (not= code (:code (recall-or-recompute (CellMap. cell-id))))
    (insert-ops #{(preimp.state/->AssocOp nil (@state :client-id) cell-id :code code)})))

(defn insert-cell-after [prev-cell-id]
  (let [new-cell-id (random-uuid)]
    (swap! state assoc :focused-cell-id new-cell-id)
    (insert-ops #{(preimp.state/->InsertOp nil (@state :client-id) new-cell-id prev-cell-id)
                 (preimp.state/->AssocOp nil (@state :client-id) new-cell-id :code "")})))

(defn insert-cell-before [next-cell-id]
  (let [cell-ids (recall-or-recompute (CellIds.))
        next-ix (.indexOf cell-ids next-cell-id)
        prev-cell-id (if (= next-ix 0) nil (get cell-ids (dec next-ix)))]
    (insert-cell-after prev-cell-id)))

(defn remove-cell [cell-id]
  (let [cell-ids (recall-or-recompute (CellIds.))
        ix (.indexOf cell-ids cell-id)
        prev-cell-id (if (= ix 0) nil (get cell-ids (dec ix)))]
    (insert-ops #{(preimp.state/->DeleteOp nil (@state :client-id) cell-id)})
    (swap! state assoc :focused-cell-id prev-cell-id)))

;; --- network ---

(defn send-ops [ops]
  (when (@state :online-mode?)
    (d :sending (count ops))
    (try
      (.send (@state :websocket) (pr-str {:client (@state :client-id) :ops ops}))
      (catch :default error (d :ws-send-error error)))))

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
        ;; switch client-id so that sever-side tracking of what has been sent resets and we get a fresh start
        (swap! state assoc :client-id (random-uuid))
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
            (change-input (Ops.) new-ops)))))
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

(defn editor [init-cell-id]
  (let [!codemirror (atom nil)
        !cell-id (atom init-cell-id)]
    (r/create-class
      {:render
       (fn []
         [:textarea])

       :should-component-update
       (fn [this old-argv new-argv]
         (let [cell-id (get new-argv 1)]
           (reset! !cell-id cell-id)
           (not= old-argv new-argv)))

       :component-did-update
       (fn [this]
         (let [new-code (or (get-in @state [:id->value (CellMap. @!cell-id) :code]) "")]
           (.setValue @!codemirror new-code)))

       :component-did-mount
       (fn [this]
         (let [value (:code (recall-or-recompute (CellMap. @!cell-id)))
               codemirror (.fromTextArea
                            js/CodeMirror
                            (dom/dom-node this)
                            #js {:mode "clojure"
                                 :lineNumbers false
                                 :extraKeys #js {"Ctrl-Enter" (fn [codemirror]
                                                                (set-cell-code @!cell-id (.getValue codemirror)))
                                                 "Shift-Enter" (fn [codemirror]
                                                                  (set-cell-code @!cell-id (.getValue codemirror))
                                                                  (insert-cell-after @!cell-id))
                                                 "Shift-Alt-Enter" (fn [codemirror]
                                                                      (set-cell-code @!cell-id (.getValue codemirror))
                                                                      (insert-cell-before @!cell-id))
                                                 "Ctrl-Backspace" #(remove-cell @!cell-id)}
                                 :matchBrackets true
                                 ; :autofocus true
                                 :viewportMargin js/Infinity})]
           (.setValue codemirror value)
           (.on codemirror "blur" (fn [codemirror]
                                    (set-cell-code @!cell-id (.getValue codemirror))))
           (add-watch
             state
             codemirror
             (fn [_ _ old-state new-state]
               (let [old-code (or (get-in old-state [:id->value (CellMap. @!cell-id) :code]) "")
                     ;; can't recompute here because it causes infinite recursion, so use stale value for now
                     new-code (or (get-in new-state [:id->value (CellMap. @!cell-id) :code]) "")]
                 (when (and (not= old-code new-code) (not= new-code (.getValue codemirror)))
                   (.setValue codemirror new-code)))))
           (reset! !codemirror codemirror)))

       :component-will-unmount
       (fn [this]
         (let [codemirror @!codemirror]
           (remove-watch state codemirror)
           (.toTextArea codemirror)))})))

(defn fn-name [f]
  (cond
    (instance? cljs.core.MetaFn f)
    (or (:preimp/named (meta f))
      (fn-name (.-afn f)))

    (fn? f)
    (-> (.-name f)
      (clojure.string/split "$")
      last
      (clojure.string/replace #"^_" "")
      (clojure.string/replace "_GT_" ">")
      (clojure.string/replace "_LT_" "<")
      (clojure.string/replace "_BANG_" "!")
      (clojure.string/replace "_" "-"))

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

(defn edn-hide [value]
  (let [hidden (r/atom true)]
    (fn [value]
      (let [value (with-meta value (dissoc (meta value) :preimp/hidden))]
        [:div
         [:button
          {:on-click #(swap! hidden not)}
          (if @hidden "+" "-")]
         (when-not @hidden
           [edn value])]))))

;; TODO reagent can't tell when a function changes, so this doesn't update nicely
(defn edn-fn [value]
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
         [:div [edn @output]])])))

(defn edn-map [value]
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
         [:td [edn v]]])]]))

(defn edn-vector [value]
  [:table
   {:style {:border-left "1px solid black"
            :border-right "1px solid black"
            :border-radius "0"
            :padding "0.5em"}}
   [:tbody
    (for [[elem i] (map vector value (range))]
      ^{:key i}
      [:tr
       [:td [edn elem]]])]])

(defn edn-set [value]
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
         [:td [edn elem]]])]]))

(defn edn-default [value]
  [:code (pr-str value)])

(defn edn [value]
  (cond
    (contains? (meta value) :preimp/hidden)
    [edn-hide value]

    (fn? value)
    [edn-fn value]

    (map? value)
    [edn-map value]

    (vector? value)
    [edn-vector value]

    (set? value)
    [edn-set value]

    :else
    [edn-default value]))

(defn output [cell-id]
  [:div
   (let [value (let [parse (recall-or-recompute (CellParse. cell-id))]
                 (if (instance? Error parse)
                   parse
                   (recall-or-recompute (Value. (:name parse)))))]
     [edn value])])

(defn cell-name [cell-id]
  [:div
   {:style {:margin "0.25em"
            :background-color (if (= cell-id (@state :focused-cell-id))
                                "LightCyan"
                                "inherit")}}
   (if-let [name (:name (recall-or-recompute (CellParse. cell-id)))]
     [:span
      {:on-click #(swap! state assoc :focused-cell-id cell-id)}
      name]
     [:span
      {:on-click #(swap! state assoc :focused-cell-id cell-id)
       :style {:color "grey"}}
      "no name"])])

(defn editor-and-output [cell-id]
  [:div
   [:div
    {:style {:padding "0.5em"}}
    [editor cell-id]]
   [:div {:style {:padding "0.5em"}}
    [:div {:style {:padding "4px"}} ; to line up with codemirror text
     [output cell-id]]]])

(defn debug []
  [:div
   (doall (for [[id value] (sort-by #(pr-str (first %)) (@state :id->value))]
            (let [color (if (instance? Error value) "red" "black")]
              ^{:key (pr-str id)} [:div
                                   [:span {:style {:color "blue"}} "v" (pr-str (get-in @state [:id->last-changed-at-version id]))]
                                   " "
                                   [:span {:style {:font-weight "bold"}} (pr-str id)]
                                   " "
                                   [:span {:style {:color color}} (pr-str value)]
                                   " "
                                   [:span {:style {:color "grey"}} (pr-str (sort-by pr-str (keys (get-in @state [:id->deps id]))))]])))])

;; --- fns exposed to cells ---

(defn hidden [v]
  (with-meta v {:preimp/hidden true}))

(defn named [name v]
  (with-meta v {:preimp/named name}))

(defn edit! [name f & args]
  (let [def (recall-or-recompute (Def. name))]
    (if (instance? Error def)
      def
      (let [cell-id (:cell-id def)
            old-value (recall-or-recompute (Value. name))
            new-value (apply f old-value args)
            new-code (with-out-str (fipp/pprint `(~'defs ~name ~new-value) {}))]
        (when-let [codemirror (get-in @state [:cell-id->codemirror cell-id])]
          (.setValue codemirror new-code))
        (insert-ops #{(preimp.state/->AssocOp nil (@state :client-id) cell-id :code new-code)})
        nil))))
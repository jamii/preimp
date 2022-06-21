(ns preimp.core
  (:require
   [ring.adapter.jetty9 :as jetty]
   [cljs.env]
   [hiccup.page :refer [include-js include-css html5]]
   [ring.middleware.file :refer [wrap-file]]
   [ring.middleware.resource :refer [wrap-resource]]
   preimp.state
   [next.jdbc :as jdbc]
   [clojure.data.json :as json]))

;; --- state ---

(def state
  (atom
   {:ops #{}
    :client->websocket {}
    :client->ops {}}))

;; --- actions ---

(def db (jdbc/get-datasource "jdbc:sqlite:preimp.db"))

(defn init-db []
  (jdbc/execute!
   db
   ["create table if not exists op (edn text)"]))

(defn write-ops [ops]
  (doseq [op ops]
    (jdbc/execute! db ["insert into op values (?)" (pr-str op)])))

(defn read-ops []
  (let [ops (for [row (jdbc/execute! db ["select * from op"])]
              (clojure.edn/read-string {:readers preimp.state/readers} (:op/edn row)))]
    (swap! state update-in [:ops] preimp.state/union-ops ops)))

(defn send-ops []
  (doseq [[client ws] (@state :client->websocket)]
    (let [new-ops (get @state :ops)
          old-ops (get-in @state [:client->ops client])
          novel-ops (clojure.set/difference new-ops old-ops)]
      (try
        (jetty/send! ws (pr-str novel-ops))
        (swap! state assoc-in [:client->ops client] new-ops)
        (catch Exception error
          (prn [:ws-send-error ws error]))))))

(defn recv-ops [new-ops]
  (let [old-ops (@state :ops)
        novel-ops (clojure.set/difference new-ops old-ops)]
    (write-ops novel-ops)
    (swap! state update-in [:ops] preimp.state/union-ops novel-ops)
    (send-ops)))

(defn recv-ops-from-ws [recv-ws msg-str]
  (let [msg (clojure.edn/read-string {:readers preimp.state/readers} msg-str)]
    (swap! state assoc-in [:client->websocket (:client msg)] recv-ws)
    (swap! state update-in [:client->ops (:client msg)] preimp.state/union-ops (:ops msg))
    (recv-ops (:ops msg))))

(defn recv-ops-from-put [input-stream]
  (let [msg (json/read-str (slurp input-stream))
        op (preimp.state/->AssocOp
            (preimp.state/next-version (@state :ops))
            (java.util.UUID/randomUUID)
            (java.util.UUID/fromString (get msg "cell-id"))
            :code
            (get msg "value"))]
    (recv-ops #{op})))

;; --- change polling ---

(def data-version-connection (jdbc/get-connection db))

(def last-data-version (atom nil))

(defn db-changed? []
  (let [current-data-version (:data_version (jdbc/execute-one! data-version-connection ["PRAGMA data_version;"]))
        changed? (not= @last-data-version current-data-version)]
    (reset! last-data-version current-data-version)
    changed?))

(defn read-ops-if-changed []
  (when (db-changed?)
    (read-ops)
    (send-ops)))

;; --- handlers ---

(def page
  (html5
   [:head
    [:meta {:charset "utf-8"}]
    [:meta {:name "viewport"
            :content "width=device-width, initial-scale=1"}]]
   [:body
    [:div#app "loading..."]
    (include-css "cljsjs/codemirror/development/codemirror.css")
    [:style ".CodeMirror {height: auto;}"]
    (include-js "main.js")]))

(def websocket-handler
  {:on-connect (fn [ws])
   :on-error (fn [ws e]
               (prn [:ws-error e])
               (jetty/close! ws))
   :on-close (fn [ws status-code reason]
           ;; TODO remove client from client->websocket
               (prn [:ws-close status-code reason]))
   :on-text (fn [ws text]
              (read-ops-if-changed)
              (recv-ops-from-ws ws text))
   :on-bytes (fn [ws bytes offset len])
   :on-ping (fn [ws bytebuffer])
   :on-pong (fn [ws bytebuffer]
              (read-ops-if-changed))})

(defn handler [request]
  (cond
    (jetty/ws-upgrade-request? request)
    (jetty/ws-upgrade-response websocket-handler)

    (= :put (:request-method request))
    (do
      (recv-ops-from-put (:body request))
      {:status 200})

    :else
    {:status 200
     :headers {"Content-Type" "text/html"}
     :body page}))

(def app-inner
  (-> handler
      (wrap-resource "")))

(defn app [request]
  ;; this is a hack to make cljs debug builds work with wrap-resource
  (let [request (if (.startsWith (:uri request) "/out")
                  (assoc request :uri (subs (:uri request) (count "/out")))
                  request)]
    (app-inner request)))

;; --- misc ---

;; dump analyzer state for frontend
(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))
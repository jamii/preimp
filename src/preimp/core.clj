(ns preimp.core
  (:require
   [ring.adapter.jetty9 :as jetty]
   [cljs.env]
   [hiccup.page :refer [include-js include-css html5]]
   [ring.middleware.file :refer [wrap-file]]
   [ring.middleware.resource :refer [wrap-resource]]
   preimp.state
   [next.jdbc :as jdbc]))

;; --- state ---

(def state
  (atom
   {:ops #{}
    :client->websocket {}}))

;; --- actions ---

(def db (jdbc/get-datasource "jdbc:sqlite:preimp.db"))

(defn init-db []
  (jdbc/execute!
   db
   ["create table if not exists op (edn text)"]))

(defn read-ops []
  (let [ops (for [row (jdbc/execute! db ["select * from op"])]
              (clojure.edn/read-string {:readers preimp.state/readers} (:op/edn row)))]
    (swap! state assoc :ops (into #{} ops))))

(defn write-ops [ops]
  (doseq [op ops]
    (jdbc/execute! db ["insert into op values (?)" (pr-str op)])))

(defn send-ops [ws]
  (try
    (jetty/send! ws (pr-str (@state :ops)))
    (catch Exception error
      (prn [:ws-send-error ws error]))))

(defn recv-ops [recv-ws msg-str]
  (let [msg (clojure.edn/read-string {:readers preimp.state/readers} msg-str)
        old-ops (@state :ops)
        novel-ops (clojure.set/difference (:ops msg) old-ops)]
    (write-ops novel-ops)
    (swap! state assoc-in [:client->websocket (:client msg)] recv-ws)
    (swap! state update-in [:ops] clojure.set/union (:ops msg))
    (when (not= old-ops (:ops msg))
      (send-ops recv-ws))
    (when (not= old-ops (@state :ops))
      (doseq [[client other-ws] (@state :client->websocket)]
        (when (not= client (:client msg))
          (send-ops other-ws))))))

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
    (prn :refreshing)
    (read-ops)
    ;; TODO need to centralize decisions about when to send updates
    (doseq [[client other-ws] (@state :client->websocket)]
      (send-ops other-ws))))

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
              (recv-ops ws text))
   :on-bytes (fn [ws bytes offset len])
   :on-ping (fn [ws bytebuffer])
   :on-pong (fn [ws bytebuffer]
              (read-ops-if-changed))})

(defn handler [request]
  (if (jetty/ws-upgrade-request? request)
    (jetty/ws-upgrade-response websocket-handler)
    {:status 200
     :headers {"Content-Type" "text/html"}
     :body page}))

(def app-inner
  (-> handler
      (wrap-resource "")))

(defn app [request]
  ;; this is a hack to make cljs debug builds work with wrap-resource
  (let [request (if (.startsWith (:uri request) "/out")
                  (assoc request :uri (subs (:uri request) 4))
                  request)]
    (app-inner request)))

;; --- misc ---

;; dump analyzer state for frontend
(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))
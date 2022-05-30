(ns preimp.core
  (:require
   [ring.adapter.jetty9 :as jetty]
   [cljs.env]
   [hiccup.page :refer [include-js include-css html5]]
   [ring.middleware.file :refer [wrap-file]]
   [ring.middleware.resource :refer [wrap-resource]]
   preimp.state))

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
    (include-js "out/main.js")]))

(def ops (atom (preimp.state/insert-cell #{} "root" (preimp.state/new-cell-id) nil)))

(def client->websocket (atom {}))

(defn send-ops [ws]
  (try
    (jetty/send! ws (pr-str @ops))
    (catch Exception error
      (prn [:ws-send-error ws error]))))

(def websocket-handler
  {:on-connect (fn [ws])
   :on-error (fn [ws e]
               (prn [:ws-error e])
               (jetty/close! ws))
   :on-close (fn [ws status-code reason]
               (prn [:ws-close status-code reason])
           ;; TODO remove client from client->websocket
               )
   :on-text (fn [ws text]
              (prn text)
              (let [msg (clojure.edn/read-string
                         {:readers {'preimp.state.InsertOp preimp.state/map->InsertOp
                                    'preimp.state.DeleteOp preimp.state/map->DeleteOp
                                    'preimp.state.AssocOp preimp.state/map->AssocOp}}
                         text)
                    old-ops @ops]
                (swap! client->websocket assoc (:client msg) ws)
                (swap! ops clojure.set/union (:ops msg))
                (when (not= old-ops (:ops msg))
                  (send-ops ws))
                (when (not= old-ops @ops)
                  (doseq [[client other-ws] @client->websocket]
                    (when (not= client (:client msg))
                      (send-ops other-ws))))))
   :on-bytes (fn [ws bytes offset len])
   :on-ping (fn [ws bytebuffer])
   :on-pong (fn [ws bytebuffer])})

(defn handler [request]
  (if (jetty/ws-upgrade-request? request)
    (jetty/ws-upgrade-response websocket-handler)
    {:status 200
     :headers {"Content-Type" "text/html"}
     :body page}))

(def app
  (-> handler
      (wrap-file "public" {:allow-symlinks? true})
      (wrap-resource "")))

(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))

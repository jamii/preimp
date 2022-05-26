(ns preimp.core
  (:require
   [ring.adapter.jetty9 :as jetty]
   [cljs.env]
   [hiccup.page :refer [include-js include-css html5]]
   [ring.middleware.file :refer [wrap-file]]
   [ring.middleware.resource :refer [wrap-resource]]))

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

(def ws-handler {:on-connect (fn [ws] (prn :ok))
                 :on-error (fn [ws e])
                 :on-close (fn [ws status-code reason])
                 :on-text (fn [ws text-message])
                 :on-bytes (fn [ws bytes offset len])
                 :on-ping (fn [ws bytebuffer])
                 :on-pong (fn [ws bytebuffer])})

(defn handler [request]
  (if (jetty/ws-upgrade-request? request)
    (jetty/ws-upgrade-response ws-handler)
    {:status 200
     :headers {"Content-Type" "text/html"}
     :body page}))

(def app
  (-> handler
      (wrap-file "public" {:allow-symlinks? true})
      (wrap-resource "")))

(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))

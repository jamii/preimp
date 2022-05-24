(ns preimp.core
  (:require
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
    (include-js "out/main.js")]))

(defn handler [_request]
  {:status 200
   :headers {"Content-Type" "text/html"}
   :body page})

(def app
  (-> handler
      (wrap-file "public" {:allow-symlinks? true})
      (wrap-resource "")))

(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))

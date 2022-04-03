(ns cljs-eval-example.server
  (:require
   [cljs-eval-example.core :refer [app]]
   [ring.adapter.jetty :refer [run-jetty]])
  (:gen-class))

(defn -main [& args]
  (let [port 3000]
    (run-jetty #'app {:port port :join? false})))

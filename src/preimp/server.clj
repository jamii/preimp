(ns preimp.server
  (:require
    preimp.core
    [ring.adapter.jetty9 :refer [run-jetty]])
  (:gen-class))

(defn -main [& args]
  (preimp.core/init-db)
  (preimp.core/read-ops)
  (let [port 3000]
    (run-jetty #'preimp.core/app
      {:port port
       :join? false
       :ws-max-text-message-size (* 1024 1024 1024 1)})))

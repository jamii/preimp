(ns preimp.standalone
  (:require
    preimp.core))

(defn init! []
  (preimp.core/connect)
  (preimp.core/mount-root))

(init!)
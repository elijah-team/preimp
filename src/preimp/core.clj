(ns preimp.core
  (:require
   [ring.adapter.jetty9 :as jetty]
   [cljs.env]
   [hiccup.page :refer [include-js include-css html5]]
   [ring.middleware.file :refer [wrap-file]]
   [ring.middleware.resource :refer [wrap-resource]]
   preimp.state
   [clojure.java.jdbc :as jdbc]))

;; --- state ---

(def state
  (atom
   {:ops #{}
    :client->websocket {}}))

;; --- actions ---

(def db
  {:classname   "org.sqlite.JDBC"
   :subprotocol "sqlite"
   :subname     "preimp.db"})

(defn init-db []
  (jdbc/db-do-commands
   db
   "create table if not exists op (edn text)"))

(defn read-ops []
  (swap! state assoc :ops (into #{}
                                (for [row (jdbc/query db ["select * from op"])]
                                  (clojure.edn/read-string {:readers preimp.state/readers} (:edn row))))))

(defn write-ops [ops]
  (doseq [op ops]
    (jdbc/insert! db :op {:edn (pr-str op)})))

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
    (include-js "out/main.js")]))

(def websocket-handler
  {:on-connect (fn [ws])
   :on-error (fn [ws e]
               (prn [:ws-error e])
               (jetty/close! ws))
   :on-close (fn [ws status-code reason]
           ;; TODO remove client from client->websocket
               (prn [:ws-close status-code reason]))
   :on-text (fn [ws text]
              (recv-ops ws text))
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

;; --- misc ---

;; dump analyzer state for frontend
(defmacro analyzer-state [[_ ns-sym]]
  `'~(get-in @cljs.env/*compiler* [:cljs.analyzer/namespaces ns-sym]))
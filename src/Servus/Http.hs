{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Servus.Http where

import           Control.Concurrent.STM
import           Control.Monad.Reader
import           Data.Aeson
import qualified Data.Map.Strict                      as M
import           Data.Monoid                                 ((<>))
import           Data.Text.Encoding                          (decodeUtf8)
import           Data.Text.Lazy                              (Text, empty, fromStrict)
import           Network.HTTP.Types
import           Network.Wai.Middleware.RequestLogger
import qualified System.Mesos.Types                   as MT
import           Web.Scotty.Trans
import qualified Web.Scotty.Trans                     as WST

import           Servus.Config
import           Servus.Server
import           Servus.Task

data ApiEntryPoint = ApiEntryPoint
    { _epRun     :: Text
    , _epTasks   :: Text
    , _epHistory :: Text
    }
  deriving (Show, Eq, Ord)

instance ToJSON ApiEntryPoint where
    toJSON (ApiEntryPoint run tasks history) = object [ "links" .= links ]
      where
        links = [ (toLink run), (toLink tasks), (toLink history) ]
        toLink l = object [ "href" .= l ]

data ApiTaskList = ApiTaskList TaskLibrary

instance ToJSON ApiTaskList where
    toJSON (ApiTaskList library) = object [ "links" .= links ]
      where
        links = tasks library
        tasks (TaskLibrary library) = object $ map toLink (M.keys library)
        toLink l = "href" .= ("/tasks/?name=" <> l) 

data ApiTask = ApiTask TaskConf

instance ToJSON ApiTask where
    toJSON (ApiTask task) = toJSON task

data ApiRunList = ApiRunList [Task Running] [Task Ready]

instance ToJSON ApiRunList where
    toJSON (ApiRunList running ready) = object [ "links" .= links ]
      where
        links = object $ (map toLink running) ++ (map toLink ready)
        toLink l = "href" .= ("/run/?name=" <> (_tcName $ _tConf l) <> "&tid=" <> (text $ _tInfo l))
        text = decodeUtf8 . MT.fromTaskID . MT.taskID

liftTask f = taskM $ ask >>= liftIO . f

restApi :: ScottyT Text TaskM ()
restApi = do
    middleware logStdoutDev
    get "/" $ do
        WST.json $ ApiEntryPoint "/run" "/tasks" "/history"

    get "/run/" $ do
        arenaTasks <- liftTask getArenaTasks
        bullpenTasks <- liftTask getBullpenTasks
        WST.json $ ApiRunList arenaTasks bullpenTasks

{--
    get "/run/:name/" $ do
        ...

    get "/run/:name/:taskid" $ do
        ...

    delete "/run/:name/:taskid" $ do
        ...
--}
    post "/run/" $ do
       conf <- jsonData
       (liftTask $ runTaskConf conf) >>= \case
           Left err  -> status status404
	   Right tid -> WST.json $ object [ "tid" .= show tid ]

{--
    post "/run/:name/" $ do
        ...
        --}
    get "/tasks/" $ do
        library <- liftTask getTaskLibrary
        WST.json $ ApiTaskList library

    get "/tasks/" $ do
        name <- param "name"
        (liftTask $ getTaskConf name) >>= \case
            Nothing   -> status status404
            Just task -> WST.json task

    post "/tasks/" $ do
        conf <- jsonData
        liftTask $ putTaskConf conf
        setHeader "Location" ("/tasks/?name=" <> (fromStrict $ _tcName conf))
        status status201
        {--
    get "/history/" $ do
        ...
--}

restApiLoop :: ServerState -> IO ()
restApiLoop server = do
    let runM m = runReaderT (runTaskM m) server
        runActionToIO = runM

    scottyT (_hcPort $ _scHttp $ _conf server) runM runActionToIO restApi
    return ()



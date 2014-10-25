{-# LANGUAGE OverloadedStrings #-}

module Servus.Http where

import Control.Concurrent.STM
import Control.Monad.Reader
import Data.Text.Lazy                        (Text)
import Network.Wai.Middleware.RequestLogger
import Web.Scotty.Trans

import Servus.Server
import Servus.Task

newtype HalTaskLibrary = HalTaskLibrary TaskLibrary

instance ToJSON HalTaskLibrary where
    toJSON (HalTaskLibrary tl) = object $ [ "_links" .= hal ]
      where
        hal = object $ [ "self"          .= object $ [ "href" .= "/" ]
                       , "curies"        .= toJSON curies
                       , "x:taskLibrary" .= toJSON tasks
                       ]
        curies = [ object $ [ "name" .= "x", "href" .= "xxx", "templated" .= toJSON True ] ]
        tasks = map toLink $ M.keys tl
        toLink (name, Nothing)    = object $ [ "href" .= "/taskLibrary/system/" <> name ]
        toLink (name, Just owner) = object $ [ "href" .= "/taskLibrary/user/" <> owner <> "/" <> name ]

restApi :: ScottyT Text TaskM ()
restApi = do
    middleware logStdoutDev
    get "/" $ do
       library <- taskM $ ask >>= _library . readTVar
       json library
